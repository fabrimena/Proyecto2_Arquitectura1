`timescale 1ns/1ps

// Adaptador de simulación para el ensamblador. Se carga la memoria existente
// por jerarquía, como tb_regfile_pipeline, sin modificar top ni el RTL.
// Issue28: registros al corte de ejecución y DMEM solo después de flush.
// La persistencia exige que el programa no produzca nuevos efectos durante
// el mantenimiento; el protocolo no detiene por sí solo el procesador.
`include "isa_defs.sv"

// MEM_MODE se resuelve al elaborar: -P del módulo raíz llega a top. Cero
// conserva los consumidores anteriores; un plusarg solo verifica lo elaborado.
module tb_assembled_program #(
    parameter int MEM_MODE = 0,
    // Parámetros de elaboración: los defaults conservan la jerarquía vigente.
    // No se utilizan plusargs para alterar políticas después de elaborar.
    parameter int L2_MODEL=0, MEM_DIV=4, PERF_ENABLE=1, ROM_SYNC=1,
    parameter int WRITE_POLICY=1, ALLOC_POLICY=WRITE_POLICY, INCL_POLICY=2,
    parameter int L1_REPL_POLICY=0, L2_REPL_POLICY=0, N_MSHR=2,
    parameter int WB_DEPTH=4, EB_DEPTH=4, STALL_CYCLES=3
);

    // El límite protege la simulación sin sustituir el protocolo por un retardo.
    // Se configura solo para pruebas/diagnóstico; la persistencia siempre exige done=1.
    // Peor caso con la jerarquía completa: 640 líneas sucias (128 de la L1-D y 512
    // de la L2) a unos 56 ciclos cada una hacia la RAM, cerca de 37000 ciclos.
    integer flush_limit = 100000;
    // req nace inactivo; done pertenece al productor y confirma DMEM persistente.
    logic flush_req = 1'b0;
    wire flush_done;

    // Rechaza actividad útil mientras el vaciado necesita avanzar clk. La caché
    // no detiene un pipeline que solo ejecuta ALU o saltos: no existe un halt en
    // esta interfaz. Permitimos NOP y saltos sin enlace, pero no nuevas demandas,
    // escrituras GPR, operaciones cripto ni excepciones que cambiarían el corte.
    // Solo observa señales del núcleo; las escrituras de mantenimiento a DMEM
    // deben seguir funcionando y no se confunden con stores nuevos de CPU.
    task automatic check_flush_quiescence(input string phase);
        begin
            if ({DUT.mem_re,DUT.mem_we,DUT.mem_re_b,DUT.crypto_mem_we} !== 4'b0000 ||
                DUT.crypto_fault !== 1'b0 ||
                (DUT.id_ex_valid && DUT.ex_crypto_valid))
                $fatal(1,"[FAIL] programa no quiescente durante vaciado fase=%s pc=%h ex=%h",phase,DUT.pc,DUT.ex_pc);
            for (int p=0;p<5;p++)
                if (DUT.wb_we[p] !== 1'b0 && DUT.wb_waddr[p] !== 5'd0)
                    $fatal(1,"[FAIL] escritura GPR durante vaciado fase=%s puerto=%0d",phase,p);
        end
    endtask

    // Contrato local del issue28: el llamador ya alcanzó su corte y terminó las
    // lecturas/escrituras útiles. Recibe la fase para diagnosticar cada programa;
    // modifica solo flush_req y consume clk general, nunca core_clk ni reset.
    // #1 sitúa la solicitud fuera del flanco que pudo aceptar el último bundle.
    // Otro #1 deja propagar done combinacional en modos0/1 sin añadir un ciclo.
    // En modo2 esperamos posedge y observamos POST-NBA: MSHR, scan, WBUF y la
    // última palabra de l2_model deben terminar antes de leer DUT.DMEM.mem.
    task automatic flush_cache(input string phase);
        // waited mide mantenimiento hasta done; released mide retorno a FL_IDLE.
        // Ninguno se suma al presupuesto de ejecución útil del programa.
        int waited, released;
        begin
            if ($value$plusargs("FLUSH_MAXCYCLES=%d",flush_limit)) begin end
            if (flush_limit<1) $fatal(1,"[FAIL] límite de vaciado inválido");
            if (flush_req !== 1'b0)
                $fatal(1,"[FAIL] solicitud de vaciado ya activa fase=%s",phase);
            #1; flush_req=1'b1; #1;
            waited=0; released=0;
            // X/Z no son ni espera normal ni éxito. Se informa antes de permitir
            // cualquier dump, manteniendo el diagnóstico de la señal observable.
            while (flush_done !== 1'b1) begin
                if (flush_done !== 1'b0)
                    $fatal(1,"[FAIL] flush_done desconocido fase=%s espera=%0d limite=%0d req=%b done=%b etapa=espera",
                           phase,waited,flush_limit,flush_req,flush_done);
                if (waited>=flush_limit)
                    $fatal(1,"[FAIL] vaciado de caché no completado fase=%s espera=%0d limite=%0d req=%b done=%b etapa=espera",
                           phase,waited,flush_limit,flush_req,flush_done);
                @(posedge clk);
                check_flush_quiescence(phase); // PRE: evita aceptar efectos del programa durante mantenimiento.
                #1; waited++;
            end
            // Bajamos la solicitud después de confirmar persistencia. FL_DONE
            // del productor vuelve a FL_IDLE en el siguiente posedge; en0/1 la
            // respuesta baja combinacionalmente. No se agregan ciclos ficticios.
            flush_req=1'b0; #1;
            while (flush_done !== 1'b0) begin
                if (flush_done !== 1'b1 || released>=flush_limit)
                    $fatal(1,"[FAIL] retorno de vaciado inválido fase=%s espera=%0d limite=%0d req=%b done=%b etapa=salida",
                           phase,released,flush_limit,flush_req,flush_done);
                @(posedge clk); check_flush_quiescence(phase);
                #1; released++;
            end
            $display("[FLUSH] fase=%s modo=%0d espera=%0d salida=%0d",phase,DUT.MEM_MODE,waited,released);
        end
    endtask

    logic clk = 0;
    logic reset = 1;
    wire [31:0] debug_result;
    wire [4:0] debug_rd;
    wire debug_write;
    string mem_path, dump_path, wave_path, data_dump_path;
    integer bundles, dump_fd, cycles, data_fd;

    // La ventana externa se cierra al capturar GPR; flush continúa con clk.
    logic measurement=1;
    // Estudios con calentamiento pueden excluir el arranque anterior al primer
    // medir 0. Después de observarlo, la entrada externa queda en 1 y D18 gobierna
    // la apertura. Solo cambia observación; no se detienen instrucciones o reloj.
    initial if ($test$plusargs("DEFER_MEASUREMENT")) begin
        measurement=0;
        wait(DUT.cisa_measure_enable===1'b0);
        measurement=1;
    end
    top #(.MEM_MODE(MEM_MODE), .L2_MODEL(L2_MODEL), .MEM_DIV(MEM_DIV),
        .PERF_ENABLE(PERF_ENABLE), .ROM_SYNC(ROM_SYNC), .WRITE_POLICY(WRITE_POLICY),
        .ALLOC_POLICY(ALLOC_POLICY), .INCL_POLICY(INCL_POLICY),
        .L1_REPL_POLICY(L1_REPL_POLICY), .L2_REPL_POLICY(L2_REPL_POLICY),
        .N_MSHR(N_MSHR), .WB_DEPTH(WB_DEPTH), .EB_DEPTH(EB_DEPTH),
        .STALL_CYCLES(STALL_CYCLES)) DUT (
        .perf_measure_enable(measurement),
        .clk(clk), .reset(reset), .flush_req(flush_req), .flush_done(flush_done),
        .debug_result(debug_result), .debug_rd(debug_rd),
        .debug_write(debug_write)
    );

    // Acreditamos la instancia real antes de ejecutar. REQUESTED_MEM_MODE no
    // configura hardware: detecta un binario reutilizado del otro modo.
    integer requested_mode;
    initial begin
        requested_mode=MEM_MODE;
        if ($value$plusargs("REQUESTED_MEM_MODE=%d",requested_mode)) begin end
        #1;
        if (MEM_MODE<0 || MEM_MODE>2 || requested_mode!==MEM_MODE || DUT.MEM_MODE!==MEM_MODE)
            $fatal(1,"[FAIL] modo de memoria distinto solicitado=%0d banco=%0d efectivo=%0d",requested_mode,MEM_MODE,DUT.MEM_MODE);
        $display("[MEM_MODE] solicitado=%0d efectivo=%0d",requested_mode,DUT.MEM_MODE);
    end

    // Acreditación de parámetros públicos de las instancias elaboradas. El
    // consumidor contrasta esta línea con su solicitud, incluso en modos 0/1.
    initial begin
        #2;
        if(DUT.IMEM.SYNC!=ROM_SYNC) $fatal(1,"[FAIL] ROM_SYNC no propagado");
        $display("[ELAB_CONFIG] L2_MODEL=%0d MEM_DIV=%0d PERF_ENABLE=%0d ROM_SYNC=%0d WRITE_POLICY=%0d ALLOC_POLICY=%0d INCL_POLICY=%0d L1_REPL_POLICY=%0d L2_REPL_POLICY=%0d N_MSHR=%0d WB_DEPTH=%0d EB_DEPTH=%0d STALL_CYCLES=%0d",
            DUT.L2_MODEL,DUT.MEM_DIV,DUT.PERF_ENABLE,DUT.ROM_SYNC,DUT.WRITE_POLICY,DUT.ALLOC_POLICY,
            DUT.INCL_POLICY,DUT.L1_REPL_POLICY,DUT.L2_REPL_POLICY,DUT.N_MSHR,DUT.WB_DEPTH,DUT.EB_DEPTH,DUT.STALL_CYCLES);
    end
    generate if (MEM_MODE==2) begin : verify_cache_config
        string write_name,alloc_name,inclusion_name,replacement_name,l2_name;
        initial begin
            if(WRITE_POLICY) write_name="WB"; else write_name="WT";
            if(ALLOC_POLICY) alloc_name="WA"; else alloc_name="NWA";
            if(INCL_POLICY==2) inclusion_name="EXCLUSIVE"; else inclusion_name="NINE";
            if(L1_REPL_POLICY==0) replacement_name="LRU";
            else if(L1_REPL_POLICY==1) replacement_name="FIFO"; else replacement_name="RANDOM";
            if(L2_MODEL) l2_name="MODEL"; else l2_name="REAL";
            #2;
            if (DUT.g_mem_cache.HIER.L1D.WRITE_POLICY != WRITE_POLICY ||
                DUT.g_mem_cache.HIER.L1D.ALLOC_POLICY != ALLOC_POLICY ||
                DUT.g_mem_cache.HIER.L1D.INCL_POLICY != INCL_POLICY ||
                DUT.g_mem_cache.HIER.L1D.REPL_POLICY != L1_REPL_POLICY ||
                DUT.g_mem_cache.HIER.L1D.WB_DEPTH != WB_DEPTH ||
                DUT.g_mem_cache.HIER.L1D.N_MSHR != N_MSHR ||
                DUT.g_mem_cache.HIER.L2_MODEL != L2_MODEL ||
                DUT.g_mem_cache.HIER.MEM_DIV != MEM_DIV ||
                DUT.g_mem_cache.HIER.PERF_ENABLE != PERF_ENABLE)
                $fatal(1,"[FAIL] parámetros no propagados a la jerarquía");
            $display("[CACHE_CONFIG] write=%0s alloc=%0s inclusion=%0s replacement=%0s wb_depth=%0d mshr=%0d bus_v2=1 l2=%0s",
                write_name,alloc_name,inclusion_name,replacement_name,WB_DEPTH,N_MSHR,l2_name);
        end
        if (!L2_MODEL) begin : verify_real
            initial begin
                #2;
                if (DUT.g_mem_cache.HIER.g_l2_real.L2.INCL_POLICY != INCL_POLICY ||
                    DUT.g_mem_cache.HIER.g_l2_real.L2.REPL_POLICY != L2_REPL_POLICY ||
                    DUT.g_mem_cache.HIER.g_l2_real.EB.EB_DEPTH != EB_DEPTH ||
                    DUT.g_mem_cache.HIER.g_l2_real.MC.MEM_DIV != MEM_DIV ||
                    DUT.g_mem_cache.HIER.g_l2_real.MC.TMEM != 25+7*MEM_DIV)
                    $fatal(1,"[FAIL] parámetros no propagados a L2 real");
            end
        end
    end endgenerate

    // Snapshot POST-NBA al mismo corte de GPR. Los índices se imprimen en
    // orden creciente: Python verifica las poblaciones antes de calcular ratios.
    task automatic capture_metrics;
        $display("[PERF_VLIW] %0d %0d %0d %0d %0d",DUT.perf_cycle_count,DUT.perf_bundle_count,
            DUT.perf_instruction_count,DUT.perf_memory_stall_count,DUT.perf_branch_penalty_count);
        for (int k=0;k<4;k++)
            $display("[PERF_STAGE%0d] %0d %0d %0d %0d",k,DUT.perf_stage_occupied[k],DUT.perf_stage_bubbles[k],
                DUT.perf_stage_stalls[k],DUT.perf_stage_stalled_occupied[k]);
        $write("[PERF_L2]");
        for (int k=0;k<10;k++) $write(" %0d",DUT.l2_counts[k]);
        $write("\n[PERF_RAM]");
        for (int k=0;k<6;k++) $write(" %0d",DUT.ram_counts[k]);
        $write("\n");
    endtask
    generate if (MEM_MODE==2) begin : cache_metrics
        task automatic capture;
            $write("[PERF_L1]");
            for (int k=0;k<19;k++) $write(" %0d",DUT.g_mem_cache.HIER.perf_event_counts[k]);
            $write("\n[PERF_K1B] %0d %0d %0d %0d %0d %0d\n",
                DUT.g_mem_cache.HIER.perf_completed_accesses,DUT.g_mem_cache.HIER.perf_service_cycles,
                DUT.g_mem_cache.HIER.perf_wait_cycles,DUT.g_mem_cache.HIER.perf_excluded_accesses,
                DUT.g_mem_cache.HIER.perf_protocol_errors,DUT.g_mem_cache.HIER.perf_pending);
            for (int k=0;k<4;k++)
                $display("[PERF_CLASS%0d] %0d %0d %0d",k,DUT.g_mem_cache.HIER.perf_completed_by_class[k],
                    DUT.g_mem_cache.HIER.perf_service_by_class[k],DUT.g_mem_cache.HIER.perf_wait_by_class[k]);
        endtask
    end else begin : cache_metrics
        task automatic capture;
            $display("[PERF_L1] 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0");
            $display("[PERF_K1B] 0 0 0 0 0 0");
            for (int k=0;k<4;k++) $display("[PERF_CLASS%0d] 0 0 0",k);
        endtask
    end endgenerate

    // Contamos todos los posedge de clk, incluso reset y mantenimiento. La
    // diferencia entre dos capturas POST-NBA mide flush sin modificar su tarea.
    // Los tres intervalos permiten detectar que mantenimiento se sumó por error
    // a la ejecución. Ninguno de estos observadores controla el procesador.
    longint unsigned clock_edges=0, start_edges, flush_start_edges;
    integer execution_advances, execution_edges;
    // time usa unidades de 1 ns por timescale. Imprimir %0d evita confundir
    // estos enteros con %t, que Icarus puede presentar en precisión de 1 ps.
    time start_ns, execution_ns, maintenance_start_ns, maintenance_ns;
    always @(posedge clk) clock_edges <= clock_edges+1;

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!reset && DUT.wb_conflict !== 1'b0)
            $fatal(1, "[FAIL] conflicto o estado indeterminado de writeback");
    end

    // Traza dinámica (+TRACE=<archivo>): ciclo a ciclo, cada registro escrito
    // (valor anterior y nuevo), cada escritura en memoria, cada cambio de
    // ESTADO, cada salto tomado y cada excepción. run_program.py le agrega el
    // texto del bundle.
    string  trace_path;
    integer trace_fd = 0;
    integer ciclo = 1;          // ciclo 1: el bundle 0 está en IF; llega a WB en el ciclo 4
    logic [31:0] wb_pc = 0;     // PC del bundle en WB: estaba en EX el ciclo anterior

    always @(posedge clk) begin
        ciclo <= reset ? 1 : ciclo + 1;
        wb_pc <= DUT.ex_pc;
    end

    always @(negedge clk) begin
        if (trace_fd && !reset) begin
            for (int p = 0; p < 5; p++)
                if (DUT.wb_we[p] && DUT.wb_waddr[p] != 5'd0)
                    $fdisplay(trace_fd, "%0d REG %08x %0d %08x %08x", ciclo, wb_pc, DUT.wb_waddr[p],
                              DUT.REGFILE.regs[DUT.wb_waddr[p]], DUT.wb_wdata[p]);
            if (DUT.CRYPTO.auth_we_d || DUT.CRYPTO.init_clr_d)     // ESTADO se escribe al final de WB
                $fdisplay(trace_fd, "%0d ESTADO %08x %b%b %b%b", ciclo, wb_pc, DUT.CRYPTO.init, DUT.CRYPTO.auth,
                          DUT.CRYPTO.init_clr_d ? 1'b0 : DUT.CRYPTO.init,
                          DUT.CRYPTO.auth_we_d ? DUT.CRYPTO.auth_d : DUT.CRYPTO.auth);
            if (DUT.mem_we)
                $fdisplay(trace_fd, "%0d MEM %08x %08x %08x %04b", ciclo, DUT.ex_pc, DUT.mem_addr,
                          DUT.mem_wdata, DUT.mem_be);
            if (DUT.crypto_mem_we)
                $fdisplay(trace_fd, "%0d MEM %08x %08x %08x 1111", ciclo, DUT.ex_pc, DUT.crypto_mem_addr,
                          DUT.crypto_mem_wdata);
            if (DUT.crypto_fault)
                $fdisplay(trace_fd, "%0d TRAP %08x %08x", ciclo, DUT.ex_pc, TRAP_VECTOR);
            else if (DUT.branch_flush)
                $fdisplay(trace_fd, "%0d JUMP %08x %08x", ciclo, DUT.ex_pc, DUT.bru_target_pc);
        end
    end

    initial begin
        if (!$value$plusargs("MEM=%s", mem_path) ||
            !$value$plusargs("REGDUMP=%s", dump_path) ||
            !$value$plusargs("BUNDLES=%d", bundles))
            $fatal(1, "[FAIL] faltan +MEM, +REGDUMP o +BUNDLES");
        if (!$value$plusargs("MEMDUMP=%s", data_dump_path) ||
            !$value$plusargs("CYCLES=%d", cycles))
            $fatal(1, "[FAIL] faltan MEMDUMP o CYCLES");
        if ($value$plusargs("TRACE=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (!trace_fd) $fatal(1, "[FAIL] no se puede escribir la traza");
        end
        // La memoria tiene IMEM_BUNDLES entradas. Se reservan 4 ciclos para
        // completar IF -> ID -> EX -> WB -> REGFILE antes de salir de ella.
        if (bundles < 1 || bundles > IMEM_BUNDLES - 4)
            $fatal(1, "[FAIL] esta prueba admite 1..%0d bundles de programa", IMEM_BUNDLES - 4);
        if ($value$plusargs("VCD=%s", wave_path)) begin
            $dumpfile(wave_path);
            $dumpvars(0, tb_assembled_program);
        end

        // instruction_memory ejecuta su initial en t=0; cargar después.
        #1;
        for (int i = 0; i < IMEM_BUNDLES; i++) DUT.IMEM.memory[i] = 128'b0;
        $readmemh(mem_path, DUT.IMEM.memory, 0, bundles - 1);
        for (int i = 0; i < bundles; i++)
            if ((^DUT.IMEM.memory[i]) === 1'bx)
                $fatal(1, "[FAIL] bundle %0d incompleto o desconocido", i);

        // Precarga opcional completa, propiedad del experimento. Nunca modifica
        // código generado y ocurre durante reset, antes del primer acceso CPU.
        begin : initial_data
            string path;
            if ($value$plusargs("INITIAL_MEMORY=%s",path)) $readmemh(path,DUT.DMEM.mem);
        end
        repeat (2) @(negedge clk);
        reset = 0;
        start_edges=clock_edges; start_ns=$time;
        // CYCLES delimita avances efectivos, incluidos saltos y NOP: los stalls
        // no completan el pipeline. En modo0 coincide con el presupuesto anterior.
        // El límite general evita colgarse si core_en nunca permite avanzar.
        begin : execution_window
            int advanced, elapsed;
            advanced=0; elapsed=0;
            while (advanced<cycles && elapsed<cycles*256+1024) begin
                @(posedge clk);
                if (DUT.core_en === 1'b1) advanced++;
                else if (DUT.core_en !== 1'b0) $fatal(1,"[FAIL] avance desconocido");
                elapsed++;
            end
            if (advanced<cycles) $fatal(1,"[FAIL] programa no alcanza presupuesto avances=%0d generales=%0d",advanced,elapsed);
            #1; // Snapshot del banco una vez consumidas las NBA del último avance.
            // Conservamos las medidas del mismo horizonte usado por GPR/traza.
            // elapsed-advanced son flancos observados con core_en=0, no saltos
            // ni instrucciones retiradas. Los saltos también consumen avances.
            execution_advances=advanced; execution_edges=elapsed;
            execution_ns=$time-start_ns;
        end
        $display("[ARCH_STATE] crypto=%0d traps=%0d trap_pc=%0d",DUT.crypto_estado,DUT.trap_count,DUT.trap_pc);
        capture_metrics(); cache_metrics.capture();
        measurement=0; // Mantenimiento no pertenece a las demandas medidas.
        dump_fd = $fopen(dump_path, "w");
        if (!dump_fd) $fatal(1, "[FAIL] no se puede escribir el dump de registros");
        for (int r = 0; r < 32; r++) begin
            if ((^DUT.REGFILE.regs[r]) === 1'bx)
                $fatal(1, "[FAIL] x%0d contiene X/Z", r);
            $fdisplay(dump_fd, "x%0d %08x", r, DUT.REGFILE.regs[r]);
        end
        $fclose(dump_fd);
        // Cerramos la traza en el mismo horizonte que los registros. El reloj
        // sigue durante mantenimiento, pero esos flancos no son ejecución medida.
        if (trace_fd) begin $fclose(trace_fd); trace_fd=0; end
        // Capturamos el contador general a ambos lados del handshake existente.
        // Su diferencia incluye espera y retorno a IDLE, y vale cero en modo 0/1.
        flush_start_edges=clock_edges; maintenance_start_ns=$time;
        flush_cache("assembled");
        maintenance_ns=$time-maintenance_start_ns;
        data_fd = $fopen(data_dump_path, "w");
        if (!data_fd) $fatal(1, "[FAIL] no se puede escribir el dump de memoria");
        for (int m = 0; m < 16384; m++) $fdisplay(data_fd, "%08x", DUT.DMEM.mem[m]);
        $fclose(data_fd);
        if (DUT.REGFILE.regs[0] !== 32'b0)
            $fatal(1, "[FAIL] x0 dejó de ser cero");
        // bundles es tamaño estático de IMEM; no representa bundles retirados.
        // Publicamos unidades y fronteras explícitas para comprobar identidades
        // de ejecución/mantenimiento sin estimarlas a partir del tiempo de Python.
        $display("[EXEC_STATS] bundles=%0d avances=%0d flancos=%0d stalls=%0d flush=%0d inicio_flancos=%0d total_flancos=%0d inicio_ns=%0d ejecucion_ns=%0d mantenimiento_ns=%0d total_ns=%0d",
                 bundles,execution_advances,execution_edges,execution_edges-execution_advances,
                 clock_edges-flush_start_edges,start_edges,clock_edges,start_ns,execution_ns,maintenance_ns,$time);
        $display("[OK] programa ejecutado: %0d bundles; 32 registros definidos", bundles);
        if (trace_fd) $fclose(trace_fd);
        $finish;
    end

    initial begin
        // Respaldo global para el límite de avances y ambos timeouts de flush.
        // El límite por fase produce primero el diagnóstico específico habitual.
        #300000000;
        $fatal(1, "[FAIL] tiempo máximo excedido");
    end
endmodule
