`timescale 1ns/1ps

// Fixture para r = (a + b) - 1, emitido por test_generacion --ejemplo.
// Inicializar gp/datos aquí no sustituye el arranque del compilador completo.
// Issue28: fin del fixture observado por su store final y avances efectivos;
// r se comprueba en DMEM solo después del vaciado, también en modo2.
`include "isa_defs.sv"

module tb_ce1108_program;

    // El límite protege la simulación sin sustituir el protocolo por un retardo.
    // Se configura solo para pruebas/diagnóstico; la persistencia siempre exige done=1.
    integer flush_limit = 10000;
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

    logic clk = 0, reset = 1;
    string mem_path;
    integer bundles;
    top DUT (.clk(clk), .reset(reset), .flush_req(flush_req), .flush_done(flush_done),
             .debug_result(), .debug_rd(), .debug_write());
    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("MEM=%s", mem_path) || !$value$plusargs("BUNDLES=%d", bundles))
            $fatal(1, "[FAIL] faltan MEM y BUNDLES");
        if (bundles < 1 || bundles > IMEM_BUNDLES - 4) $fatal(1, "[FAIL] capacidad de IMEM");
        #1;
        for (int i = 0; i < IMEM_BUNDLES; i++) DUT.IMEM.memory[i] = 0;
        $readmemh(mem_path, DUT.IMEM.memory, 0, bundles - 1);
        for (int i = 0; i < bundles; i++)
            if ((^DUT.IMEM.memory[i]) === 1'bx) $fatal(1, "[FAIL] bundle desconocido");
        repeat (2) @(negedge clk);
        DUT.REGFILE.regs[3] = 32'h4000;
        DUT.DMEM.mem[4096] = 8;
        DUT.DMEM.mem[4097] = 3;
        DUT.DMEM.mem[4098] = 32'hdeadbeef;
        reset = 0;
        // El fixture es lineal. Observamos el store final al puerto del núcleo,
        // no su dato posiblemente viejo en DMEM. Seguimos hasta bundles+4 avances
        // para completar el pipeline: un miss no puede consumirse como un avance.
        begin : fixture_completion
            // advanced usa core_en PRE-flanco; elapsed limita la espera general.
            // final_store recuerda la demanda aceptada, aunque continúe en MSHR.
            int advanced, elapsed;
            bit final_store;
            advanced=0; elapsed=0; final_store=0;
            while (advanced<bundles+4 && elapsed<(bundles+4)*256+1024) begin
                @(posedge clk);
                if (DUT.core_en === 1'b1) begin
                    advanced++;
                    if (DUT.mem_we && DUT.mem_addr[15:0]==16'h4008 && DUT.mem_be==4'b1111)
                        final_store=1;
                end else if (DUT.core_en !== 1'b0) $fatal(1,"[FAIL] avance CE1108 desconocido");
                elapsed++;
            end
            #1;
            if (advanced<bundles+4 || !final_store)
                $fatal(1,"[FAIL] CE1108: no se observó store final avances=%0d generales=%0d",advanced,elapsed);
        end
        flush_cache("ce1108");
        if (DUT.DMEM.mem[4098] !== 32'd10)
            $fatal(1, "[FAIL] CE1108: r=%08x; esperado=0000000a", DUT.DMEM.mem[4098]);
        if (DUT.DMEM.mem[4096] !== 8 || DUT.DMEM.mem[4097] !== 3)
            $fatal(1, "[FAIL] se modificaron a/b");
        $display("[PASS] expresión CE1108: (8 + 3) - 1 = 10");
        $finish;
    end
    initial begin
        // Respaldo global: los límites de ejecución y flush dan antes el motivo
        // habitual. Este tiempo no se usa como garantía de persistencia.
        #300000000;
        $fatal(1, "[FAIL] tiempo máximo excedido");
    end
endmodule
