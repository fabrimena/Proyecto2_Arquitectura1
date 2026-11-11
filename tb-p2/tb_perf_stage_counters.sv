/*
 * Comprueba el issue #8 con seis parejas de procesadores reales y un estímulo
 * unitario independiente. Cada pareja recibe el mismo programa: solo CPU tiene
 * monitores externos; SHADOW permite comprobar que observar no altera efectos.
 * Se cubren memoria directa, esperas de uno/cuatro ciclos, L1-D con l2_model
 * y ROM síncrona/combinacional. No se leen secretos ni se modifica el pipeline.
 *
 * El oráculo transporta identidades y validez desde un programa conocido y
 * aplica sus saltos/excepción, sin consultar acumuladores del módulo probado.
 * En memoria directa/modelada también predice cada avance; en caché observa el
 * handshake público, comprueba el pulso real y contrasta igual progreso con la
 * ejecución directa. No intenta reimplementar el algoritmo de la L1-D.
 *
 * Las trazas describen entradas PRE y resultados POST NBA. +mutacion=1..14
 * introduce defectos solo en conexiones diagnósticas de CFG=3; cada defecto
 * debe terminar en la primera aserción divergente, con salida distinta de cero.
 * +vcd guarda únicamente contadores y señales públicas, nunca la bóveda.
 */
`timescale 1ns/1ps
`include "isa_defs.sv"

// Una configuración mantiene sus propias referencias, acumulados y archivos.
// MODE/WAIT seleccionan memoria y SYNC la ROM; CFG distingue evidencias.
// scenario=0 contiene NOP; scenario=1 ejecuta el programa mixto. policy selecciona
// ventana completa, pausada o vacía. Reset reinicia la referencia y los contadores,
// pero el número global de comprobaciones se conserva para el resumen final.
module stage_case_issue8 #(
    parameter integer MODE=0, WAIT=0, SYNC=1, CFG=0
) (input logic clk, reset, flush_req, input integer scenario, policy);

top #(.MEM_MODE(MODE), .STALL_CYCLES(WAIT), .ROM_SYNC(SYNC)) CPU (
    .clk(clk), .reset(reset), .flush_req(flush_req), .flush_done(flush_done),
    .debug_result(), .debug_rd(), .debug_write());
top #(.MEM_MODE(MODE), .STALL_CYCLES(WAIT), .ROM_SYNC(SYNC)) SHADOW (
    .clk(clk), .reset(reset), .flush_req(flush_req), .flush_done(shadow_flush_done),
    .debug_result(), .debug_rd(), .debug_write());
wire flush_done, shadow_flush_done;
wire [3:0] id_mask, ex_mask, wb_mask;
wire meta_ex, meta_wb, complete;
perf_slot_mask CLASSIFIER (.bundle_in(CPU.id_bundle), .non_nop_mask(id_mask));
// La validez de WB corresponde a todos los slots. El seguimiento usa clk y
// core_en y continúa aun cuando la ventana de acumulación esté cerrada.
perf_pipeline_monitor METADATA (
    .clk(clk), .reset(reset), .advance(CPU.core_en),
    .id_valid(CPU.id_valid), .id_non_nop_mask(id_mask),
    .ex_branch_taken(CPU.id_ex_valid && CPU.branch_flush),
    .ex_exception(CPU.id_ex_valid && CPU.crypto_fault),
    .ex_valid(meta_ex), .ex_non_nop_mask(ex_mask), .ex_cancel_cause(),
    .wb_valid(meta_wb), .wb_non_nop_mask(wb_mask), .wb_cancel_cause(),
    .bundle_complete(complete));

logic measuring=0, extra_toggle=0, resume_reset=0;
bit active_seen=0, redirect_seen=0, previous_stall=0;
integer mutation=0;
wire [3:0] raw_valid={meta_wb, CPU.id_ex_valid, CPU.id_valid, CPU.fetch_valid};
logic [3:0] delayed_valid=0, observed_valid;
logic observed_advance, observed_reset, observed_enable;
wire counter_clk = (mutation==7 && CFG==3) ? CPU.core_clk :
                   (clk ^ ((mutation==6 && CFG==3) ? extra_toggle : 1'b0));
wire [63:0] measured;
wire [3:0][63:0] occupied, bubbles, stalls, held;

// Este registro es exclusivamente diagnóstico: permite provocar una lectura
// atrasada sin retrasar ningún dato del procesador ni de la referencia.
always @(posedge clk) begin
    if (reset) delayed_valid <= 0;
    else delayed_valid <= raw_valid;
end

// Las mutaciones corrompen únicamente puertos de COUNTERS. La referencia y
// los procesadores reciben siempre las señales originales, sin force/deposit.
always @(*) begin
    observed_valid=raw_valid;
    observed_advance=CPU.core_en;
    observed_reset=reset;
    observed_enable=measuring;
    if (CFG==3) begin
        case (mutation)
            1: observed_valid[1]=CPU.fetch_valid; // Adelanta ID al observar IF.
            2: observed_valid=delayed_valid;
            3: observed_valid[2]=1'b1;           // Convierte una burbuja EX en válida.
            4: observed_valid[3]=meta_wb && (wb_mask!=0);
            5: observed_advance=1'b1;           // Omite congelamientos reales.
            8: if (!CPU.core_en) observed_valid=0;
            9: if (active_seen) observed_reset=1'b0;
            10: observed_enable=1'b1;
            11: observed_valid[3]=CPU.wb_we[0] && (CPU.wb_waddr[0]!=0);
            12: if (redirect_seen) observed_valid[1]=1'b1;
            13: observed_valid={raw_valid[2],raw_valid[3],raw_valid[1:0]};
            14: observed_reset=reset || resume_reset;
            default: begin end
        endcase
    end
end

perf_stage_counters COUNTERS (
    .clk(counter_clk), .reset(observed_reset), .measure_enable(observed_enable),
    .core_advance(observed_advance), .if_valid(observed_valid[0]),
    .id_valid(observed_valid[1]), .ex_valid(observed_valid[2]),
    .wb_valid(observed_valid[3]), .measured_cycles(measured),
    .occupied_cycles(occupied), .bubble_cycles(bubbles),
    .stall_cycles(stalls), .stalled_occupied_cycles(held));

// La tabla se prepara durante reset: contiene palabras, máscaras declaradas y
// decisiones conocidas. kind=1 es salto tomado, 2 no tomado y 3 excepción.
logic [127:0] words[0:1023];
logic [3:0] masks[0:1023];
integer kind[0:1023];
logic [31:0] targets[0:1023];
logic [31:0] pc_ref=0, id_pc_ref=0, ex_pc_ref=0, wb_pc_ref=0;
bit id_ref=0, ex_ref=0, wb_ref=0;
integer id_tag=0, ex_tag=0, wb_tag=0, next_tag=0, retired_tag=0;
integer cycle=0, advances=0, waited=0, retirements=0;
integer freeze_count=0, frozen_bubble=0, frozen_valid=0;
integer frozen_full=0, paused_stalls=0, freeze_run=0, max_freeze_run=0;
integer taken_count=0, untaken_count=0, fault_count=0, checks=0;
integer edges=0, edges_before=0, fd;
bit done=0, sampled_advance=1, sampled_reset=1, sampled_enable=0;
logic [3:0] expected_valid=0;
logic [3:0] sampled_input_valid=0;
logic [63:0] total_ref=0;
logic [63:0] occ_ref[0:3], bubble_ref[0:3], stall_ref[0:3], held_ref[0:3];
logic [31:0] saved_regs[0:31], saved_pc, saved_state, saved_traps, saved_trap_pc;

// Un flanco real del reloj efectivo debe existir exactamente cuando el avance
// muestreado lo permitió. Se cuenta por eventos, sin leerlo después como decisión.
always @(posedge CPU.core_clk) edges=edges+1;

// Construye un bundle en orden ISA: ALU ocupa los bits bajos y CRIPTO los altos.
// Recibe cuatro palabras ya codificadas y no consulta decoders ni estado del DUT.
function automatic logic [127:0] bundle(input logic [31:0] a,l,b,c);
    return {c,b,l,a};
endfunction

// Codifica sumai(rd,rs,imm). El inmediato se representa con los 11 bits de ISA;
// los programas de prueba usan valores que caben y respetan dependencias N+3.
function automatic logic [31:0] ai(input integer rd,rs,imm);
    return {TYPE_IMM,OP_SUMI,5'(rs),5'(rd),11'(imm)};
endfunction

// Codifica una carga/store sobre x0 como base. rd también identifica el registro
// fuente del store; la operación concreta se recibe desde isa_defs.sv.
function automatic logic [31:0] ls(input logic [3:0] op,input integer rd,off);
    return {TYPE_LSU,op,5'd0,5'(rd),11'(off)};
endfunction

// Codifica un salto relativo al PC del bundle. off está en bytes con signo;
// se utiliza también para salir del vector de excepción hacia el manejador.
function automatic logic [31:0] jump(input integer rd,off);
    return {TYPE_BRU_JUMP,OP_SYE,5'(rd),16'(off)};
endfunction

// Comunica la primera divergencia, con entradas PRE y valores después de NBA.
// tag identifica la aserción para que el ejecutor negativo rechace un fallo de
// infraestructura o una divergencia distinta de la que pretendía provocar.
task automatic compare(input string tag,input integer stage,
                       input logic [63:0] got,wanted);
    checks=checks+1;
    if (got !== wanted) begin
        $display("STAGE_FIRST_DIVERGENCE tag=%s cfg=%0d scenario=%0d ciclo=%0d etapa=%0d esperado_estado=%b observado_estado=%b avance=%b reset=%b medir=%b contador_esperado=%0d contador_obtenido=%0d",
                 tag,CFG,scenario,cycle,stage,expected_valid,sampled_input_valid,
                 sampled_advance,sampled_reset,sampled_enable,wanted,got);
        $fatal(1,"issue8: %s",tag);
    end
endtask

// Comprueba una propiedad temporal o arquitectónica de un solo bit. X no
// satisface el valor uno: así una señal indefinida no pasa como igualdad casual.
task automatic require_true(input string tag,input logic condition);
    compare(tag,-1,{63'd0,condition},64'd1);
endtask

// Instala palabras y contratos durante reset. Solo escribe memorias iniciales
// permitidas, nunca registros del pipeline, contadores o estado de la bóveda.
task automatic put(input integer index_,input logic [127:0] word_,
                   input logic [3:0] mask_,input integer kind_,target_);
    words[index_]=word_; masks[index_]=mask_; kind[index_]=kind_;
    targets[index_]=32'(target_);
    CPU.IMEM.memory[index_]=word_; SHADOW.IMEM.memory[index_]=word_;
endtask

// Prepara un programa idéntico en ambas instancias. Las palabras centinela de
// DMEM permiten descubrir stores jóvenes/culpables que debían ser anulados.
// scenario=0 deja NOP válidos; scenario=1 añade LSU, BRU y CRIPTO.
task automatic prepare;
    for (integer i=0;i<1024;i=i+1) put(i,128'd0,4'd0,0,0);
    for (integer i=0;i<DMEM_BYTES/4;i=i+1) begin
        CPU.DMEM.mem[i]=0; SHADOW.DMEM.mem[i]=0;
    end
    CPU.DMEM.mem[0]=32'h1234; SHADOW.DMEM.mem[0]=32'h1234;
    CPU.DMEM.mem[16]=32'h400; SHADOW.DMEM.mem[16]=32'h400;
    for (integer i=20;i<=22;i=i+1) begin
        CPU.DMEM.mem[i]=32'hfeed0000+i;
        SHADOW.DMEM.mem[i]=32'hfeed0000+i;
    end
    if (scenario==1) begin
        // El primer load congela EX cuando WB todavía es burbuja. La ALU del
        // mismo bundle produce x1=77; su store en el bundle 3 cumple N+3.
        put(0,bundle(ai(1,0,77),ls(OP_CARGAI,2,0),0,0),3,0,0);
        put(1,bundle(ai(3,0,3),0,0,0),1,0,0);
        // Cuatro slots válidos ocupan una sola posición. igualno x0,x0 no
        // salta; setpwd consume INIT y mantiene AUTH=0 para la excepción final.
        put(3,bundle(ai(4,0,11),ls(OP_GUARDAP,1,32),
            {TYPE_BRU_COND,OP_IGUALNO,5'd0,5'd0,11'd32},
            {TYPE_CRYPTO,OP_SETPWD,16'd0,5'd0}),15,2,0);
        put(4,bundle(0,ls(OP_CARGAI,5,32),0,0),2,0,0);
        put(5,bundle(0,ls(OP_GUARDAB,1,37),0,0),2,0,0);
        put(6,bundle(0,ls(OP_CARGABAI,6,37),0,0),2,0,0);
        put(7,bundle(ai(7,5,1),0,0,0),1,0,0);
        // El load y el salto están en el mismo bundle. BRU puede permanecer
        // varios ciclos activa, pero su redirección solo se acepta al avanzar.
        put(8,bundle(0,ls(OP_CARGAI,8,64),jump(9,48),0),6,1,176);
        put(9,bundle(ai(20,0,99),ls(OP_GUARDAP,0,80),0,0),3,0,0);
        put(10,bundle(ai(21,0,99),ls(OP_GUARDAP,0,84),0,0),3,0,0);
        put(12,bundle(0,0,{TYPE_BRU_COND,OP_IGUALSI,5'd0,5'd0,11'd32},0),4,1,224);
        put(13,bundle(ai(22,0,99),0,0,0),1,0,0);
        // FSL sin AUTH anula el bundle entero y gana sobre su solicitud BRU.
        // El WB anterior sí puede retirarse; el culpable no ocupa un WB válido.
        put(15,bundle(ai(23,0,99),ls(OP_GUARDAP,0,88),jump(24,64),
            {TYPE_CRYPTO,OP_FSL,2'd0,2'd0,5'd26,5'd0,7'd0}),15,3,TRAP_VECTOR);
        put(16,bundle(ai(25,0,99),0,0,0),1,0,0);
        put(17,bundle(ai(27,0,99),0,0,0),1,0,0);
        put(1023,bundle(0,0,jump(0,512-TRAP_VECTOR),0),4,1,512);
        put(32,bundle(ai(30,0,9),0,0,0),1,0,0);
        // El bucle final mantiene el programa dentro de IMEM. No termina el
        // pipeline: las capturas se hacen al mismo número de avances efectivos.
        put(40,bundle(0,0,jump(0,0),0),4,1,640);
    end
endtask

// Reinicia exclusivamente el modelo y sus resultados de la época. El código
// real se reinicia por su propio puerto reset. El historial de checks no se borra.
task automatic clear_reference;
    pc_ref=0; id_pc_ref=0; ex_pc_ref=0; wb_pc_ref=0;
    id_ref=0; ex_ref=0; wb_ref=0;
    id_tag=0; ex_tag=0; wb_tag=0; next_tag=0; retired_tag=0;
    cycle=0; advances=0; waited=0; retirements=0; total_ref=0;
    freeze_count=0; frozen_bubble=0; frozen_valid=0;
    frozen_full=0; paused_stalls=0; freeze_run=0; max_freeze_run=0;
    taken_count=0; untaken_count=0; fault_count=0;
    done=0; redirect_seen=0; previous_stall=0;
    for (integer s=0;s<4;s=s+1) begin
        occ_ref[s]=0; bubble_ref[s]=0; stall_ref[s]=0; held_ref[s]=0;
    end
endtask

// PRE identifica el bundle y sus decisiones antes de alterar el modelo.
// La referencia de ocupación nace de las admisiones/flush del programa, no de
// los bits de validez del DUT. Solo después se contrastan ambos recorridos.
task automatic pre;
    integer index_, control_;
    bit taken_, fault_, request_, predicted_advance;
    logic [31:0] old_pc;
    edges_before=edges; sampled_reset=reset;
    resume_reset=0;
    if (reset) begin
        clear_reference(); measuring=1; sampled_advance=1; expected_valid=0;
    end
    else begin
        active_seen=1; cycle=cycle+1;
        expected_valid={wb_ref,ex_ref,id_ref,1'b1};
        measuring=!done && ((policy==0) ||
                  (policy==1 && ((cycle>=5 && cycle<=10) || cycle>=17)));
        sampled_advance=CPU.core_en;
        index_=(ex_pc_ref>>4)&1023;
        control_=ex_ref ? kind[index_] : 0;
        taken_=(control_==1); fault_=(control_==3);
        request_=ex_ref && masks[index_][1] && !fault_;
        // El modelo 1 tiene N esperas exactas por acceso LSU. En caché, el
        // avance es un dato observado del handshake; no inventamos su latencia.
        predicted_advance=!(MODE==1 && request_ && waited<WAIT);
        if (MODE!=2)
            require_true("advance_prediction",CPU.core_en===predicted_advance);
        require_true("stable_advance",CPU.core_en===!CPU.cache_stall);
        require_true("known_inputs",(^raw_valid!==1'bx) &&
                     (CPU.core_en===0 || CPU.core_en===1));
        require_true("validity_oracle",raw_valid===expected_valid && meta_ex===ex_ref);
        require_true("fetch_pc_word",CPU.fetch_pc===pc_ref &&
                     CPU.fetch_bundle===words[(pc_ref>>4)&1023]);
        if (id_ref) require_true("id_identity",CPU.id_pc===id_pc_ref &&
                               CPU.id_bundle===words[(id_pc_ref>>4)&1023]);
        if (ex_ref) require_true("ex_identity",CPU.ex_pc===ex_pc_ref);
        require_true("control_program",CPU.branch_flush===taken_ && CPU.crypto_fault===fault_);
        require_true("retirement_event",complete===(sampled_advance && wb_ref));
        require_true("wb_bundle_mask",wb_mask===(wb_ref ? masks[(wb_pc_ref>>4)&1023] : 4'd0));
        if (taken_ || fault_)
            require_true("redirect_target",CPU.redirect_pc===targets[index_]);
        // El monitor puede ver la excepción en EX ocupado; el siguiente WB
        // será inválido. No corregimos retrospectivamente la ocupación de EX.
        if (!sampled_advance) begin
            freeze_count=freeze_count+1;
            if (expected_valid!=15) frozen_bubble=frozen_bubble+1;
            if (expected_valid!=0) frozen_valid=frozen_valid+1;
            if (!done) begin
                // Contamos rachas dentro del horizonte capturado, sin mezclar
                // el vaciado posterior. Prueba que las N esperas son consecutivas.
                freeze_run=freeze_run+1;
                if (freeze_run>max_freeze_run) max_freeze_run=freeze_run;
                if (expected_valid==15) frozen_full=frozen_full+1;
                if (!measuring) paused_stalls=paused_stalls+1;
            end
        end
        else freeze_run=0;
        if (mutation==14 && CFG==3)
            resume_reset=previous_stall && sampled_advance;
    end
    sampled_enable=measuring;
    // Damos tiempo a las conexiones diagnósticas para estabilizarse con la
    // ventana elegida. Todavía no ha ocurrido el flanco positivo del reloj.
    #1;
    // Conservamos también el puerto diagnóstico consumido. Después de NBA
    // puede haber otra validez: no se imprime como si perteneciera a este flanco.
    sampled_input_valid=observed_valid;
    if (!reset) begin
        require_true("passive_pre_writes",{CPU.wb_we,CPU.wb_waddr,CPU.wb_wdata,
                     CPU.dmem_we,CPU.dmem_be,CPU.dmem_addr,CPU.dmem_wdata,
                     CPU.dmem_we_b,CPU.dmem_addr_b,CPU.dmem_wdata_b}===
                     {SHADOW.wb_we,SHADOW.wb_waddr,SHADOW.wb_wdata,
                     SHADOW.dmem_we,SHADOW.dmem_be,SHADOW.dmem_addr,SHADOW.dmem_wdata,
                     SHADOW.dmem_we_b,SHADOW.dmem_addr_b,SHADOW.dmem_wdata_b});
        // Estos son los efectos candidatos PRE del flanco real, antes de que
        // las unidades registradas publiquen los candidatos del ciclo siguiente.
        $fdisplay(fd,"EFFECT_PRE,%0d,%0d,%0d,%b,%h,%h,%h,%b,%h,%h,%b,%h,%h,%b,%h",
                  scenario,cycle,advances,sampled_advance,CPU.wb_we,CPU.wb_waddr,
                  CPU.wb_wdata,CPU.dmem_we,CPU.dmem_addr,CPU.dmem_wdata,
                  CPU.dmem_we_b,CPU.dmem_addr_b,CPU.dmem_wdata_b,CPU.redirect,CPU.redirect_pc);
    end
    if (!reset && measuring) begin
        total_ref=total_ref+64'd1;
        for (integer s=0;s<4;s=s+1) begin
            if (expected_valid[s]) occ_ref[s]=occ_ref[s]+64'd1;
            else bubble_ref[s]=bubble_ref[s]+64'd1;
            if (!sampled_advance) begin
                stall_ref[s]=stall_ref[s]+64'd1;
                if (expected_valid[s]) held_ref[s]=held_ref[s]+64'd1;
            end
        end
    end
    $fdisplay(fd,"PRE,%0d,%0d,%0d,%b,%b,%b,%b,%b,%h,%0d",scenario,policy,cycle,
              reset,measuring,sampled_advance,expected_valid,raw_valid,pc_ref,total_ref);
    if (!reset && sampled_advance) begin
        // Una identidad WB solo puede retirarse una vez. Los ciclos retenidos
        // sí suman residencia, pero nunca llegan a esta aceptación de retiro.
        if (wb_ref) begin
            require_true("retirement_unique",wb_tag>retired_tag);
            retired_tag=wb_tag; retirements=retirements+1;
        end
        advances=advances+1; waited=0;
        if (taken_) taken_count=taken_count+1;
        if (control_==2) untaken_count=untaken_count+1;
        if (fault_) fault_count=fault_count+1;
        old_pc=pc_ref;
        pc_ref=(taken_ || fault_) ? targets[index_] : pc_ref+16;
        wb_ref=ex_ref && !fault_; wb_pc_ref=ex_pc_ref; wb_tag=ex_tag;
        ex_ref=id_ref && !taken_ && !fault_; ex_pc_ref=id_pc_ref; ex_tag=id_tag;
        id_ref=!taken_ && !fault_; id_pc_ref=old_pc;
        if (id_ref) begin next_tag=next_tag+1; id_tag=next_tag; end
        if (taken_ || fault_) redirect_seen=1;
    end
    else if (!reset) waited=waited+1;
endtask

// POST comprueba todos los acumuladores, las identidades y la pasividad después
// de NBA. El estado esperado ya fue calculado a partir de las entradas PRE.
task automatic post;
    // El pulso adicional de la mutación 6 solo llega al monitor. Simula contar
    // dos veces un mismo ciclo, sin fabricar un avance o escritura del núcleo.
    if (mutation==6 && CFG==3 && !sampled_reset && !sampled_advance) begin
        extra_toggle=1; #1; extra_toggle=0; #1;
    end
    compare("measured",-1,measured,total_ref);
    for (integer s=0;s<4;s=s+1) begin
        compare("occupied",s,occupied[s],occ_ref[s]);
        compare("bubble",s,bubbles[s],bubble_ref[s]);
        compare("stall",s,stalls[s],stall_ref[s]);
        compare("stalled_occupied",s,held[s],held_ref[s]);
        require_true("partition",occupied[s]+bubbles[s]==measured);
        require_true("bounds",held[s]<=stalls[s] && held[s]<=occupied[s] && stalls[s]<=measured);
    end
    require_true("effective_clock",edges==edges_before+integer'(sampled_advance));
    require_true("post_validity",{meta_wb,meta_ex,CPU.id_valid}==={wb_ref,ex_ref,id_ref});
    require_true("post_pc",CPU.pc===pc_ref);
    // Se comparan todas las escrituras públicas, no solo debug_write. Así se
    // detecta una duplicación incluso si coincidiera el estado final de un GPR.
    require_true("passive_wb",{CPU.wb_we,CPU.wb_waddr,CPU.wb_wdata}===
                 {SHADOW.wb_we,SHADOW.wb_waddr,SHADOW.wb_wdata});
    require_true("passive_memory_control",{CPU.dmem_we,CPU.dmem_be,CPU.dmem_addr,
                 CPU.dmem_wdata,CPU.dmem_we_b,CPU.dmem_addr_b,CPU.dmem_wdata_b}===
                 {SHADOW.dmem_we,SHADOW.dmem_be,SHADOW.dmem_addr,
                 SHADOW.dmem_wdata,SHADOW.dmem_we_b,SHADOW.dmem_addr_b,SHADOW.dmem_wdata_b});
    require_true("passive_public",{CPU.pc,CPU.redirect,CPU.redirect_pc,CPU.crypto_estado,
                 CPU.trap_pc,CPU.trap_count,CPU.core_en,CPU.core_clk,flush_done}===
                 {SHADOW.pc,SHADOW.redirect,SHADOW.redirect_pc,SHADOW.crypto_estado,
                 SHADOW.trap_pc,SHADOW.trap_count,SHADOW.core_en,SHADOW.core_clk,shadow_flush_done});
    for (integer r=0;r<32;r=r+1)
        require_true("passive_gpr",CPU.REGFILE.regs[r]===SHADOW.REGFILE.regs[r]);
    if (!reset && !done && advances==(scenario==0 ? 6 : 64)) begin
        done=1;
        for (integer r=0;r<32;r=r+1) saved_regs[r]=CPU.REGFILE.regs[r];
        saved_pc=CPU.pc; saved_state=CPU.crypto_estado;
        saved_traps=CPU.trap_count; saved_trap_pc=CPU.trap_pc;
        $display("STAGE_CASE cfg=%0d mode=%0d wait=%0d rom=%0d scenario=%0d policy=%0d ciclos=%0d avances=%0d retiros=%0d stalls=%0d burbujas_retenidas=%0d validos_retenidos=%0d",
                 CFG,MODE,WAIT,SYNC,scenario,policy,cycle,advances,retirements,
                 freeze_count,frozen_bubble,frozen_valid);
        if (scenario==0) begin
            // Fechas precalculadas: IF ocupa los seis flancos; ID entra uno
            // después, EX dos y WB tres. Todos son NOP válidos, no burbujas.
            for (integer s=0;s<4;s=s+1) begin
                compare("known_first_bundle",s,occupied[s],64'(6-s));
                compare("known_start_bubbles",s,bubbles[s],64'(s));
            end
        end
    end
    for (integer s=0;s<4;s=s+1)
        $fdisplay(fd,"POST,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",scenario,policy,cycle,
                  s,measured,occupied[s],bubbles[s],stalls[s],held[s]);
    previous_stall=!sampled_advance;
endtask

// Comprueba todos los bytes públicos de DMEM mediante 16384 palabras exactas.
// Se invoca después de flush_done: con write-back, comparar antes sería inválido.
task automatic compare_memory;
    integer differences;
    differences=0;
    require_true("flush_completed",flush_done && shadow_flush_done);
    for (integer i=0;i<DMEM_BYTES/4;i=i+1) begin
        if (CPU.DMEM.mem[i] !== SHADOW.DMEM.mem[i]) begin
            if (differences==0) $display("Primera diferencia DMEM cfg=%0d byte=%0d",CFG,4*i);
            differences=differences+1;
        end
    end
    compare("passive_65536_bytes",-1,64'(differences),0);
endtask

initial begin
    if ($value$plusargs("mutacion=%d",mutation))
        if (mutation<0 || mutation>14) $fatal(1,"mutación fuera de 0..14");
    fd=$fopen($sformatf("issue8-cfg%0d.csv",CFG),"w");
    if (!fd) $fatal(1,"no se pudo crear traza issue8");
    $fdisplay(fd,"PRE:scenario,policy,cycle,reset,measure,advance,expected_valid,raw_valid,pc,total_ref");
    $fdisplay(fd,"POST:scenario,policy,cycle,stage,total,occupied,bubble,stall,stalled_occupied");
end
endmodule

// Coordina flancos manuales para separar estímulo, muestreo PRE y comprobación
// posterior a NBA. Mantiene seis configuraciones reales y una unidad sintética
// para combinaciones de validez que el fetch actual no puede producir.
module tb_perf_stage_counters;
`include "tb_utils.svh"
logic clk=0, reset=1, flush_req=0;
integer scenario=0, policy=0;
stage_case_issue8 #(.CFG(0)) A0 (.clk(clk),.reset(reset),.flush_req(flush_req),.scenario(scenario),.policy(policy));
stage_case_issue8 #(.CFG(1),.SYNC(0)) A1 (.clk(clk),.reset(reset),.flush_req(flush_req),.scenario(scenario),.policy(policy));
stage_case_issue8 #(.CFG(2),.MODE(1),.WAIT(1)) A2 (.clk(clk),.reset(reset),.flush_req(flush_req),.scenario(scenario),.policy(policy));
stage_case_issue8 #(.CFG(3),.MODE(1),.WAIT(4)) A3 (.clk(clk),.reset(reset),.flush_req(flush_req),.scenario(scenario),.policy(policy));
stage_case_issue8 #(.CFG(4),.MODE(2)) A4 (.clk(clk),.reset(reset),.flush_req(flush_req),.scenario(scenario),.policy(policy));
stage_case_issue8 #(.CFG(5),.MODE(2),.SYNC(0)) A5 (.clk(clk),.reset(reset),.flush_req(flush_req),.scenario(scenario),.policy(policy));

logic uc=0, ur=1, um=0, ua=0;
logic [3:0] uv=0;
wire [63:0] ut;
wire [3:0][63:0] uo,ub,us,uh;
logic [63:0] et=0,eo[0:3],eb[0:3],es[0:3],eh[0:3];
perf_stage_counters UNIT (
    .clk(uc),.reset(ur),.measure_enable(um),.core_advance(ua),
    .if_valid(uv[0]),.id_valid(uv[1]),.ex_valid(uv[2]),.wb_valid(uv[3]),
    .measured_cycles(ut),.occupied_cycles(uo),.bubble_cycles(ub),
    .stall_cycles(us),.stalled_occupied_cycles(uh));

// Un tick del procesador conserva una fase baja para el latch core_en. Primero
// se calculan expectativas y después se levanta clk; #1 separa la lectura de NBA.
task automatic tick;
    clk=0; #4;
    A0.pre(); A1.pre(); A2.pre(); A3.pre(); A4.pre(); A5.pre();
    clk=1; #1;
    A0.post(); A1.post(); A2.post(); A3.post(); A4.post(); A5.post();
    clk=0; #4;
endtask

// Carga solo memorias iniciales durante reset y deja que la ROM síncrona lea
// bundle 0 antes de soltar reset. Los registros se inicializan por su propio RTL.
task automatic start_case(input integer program_,window_);
    reset=1; flush_req=0; tick(); scenario=program_; policy=window_;
    A0.prepare(); A1.prepare(); A2.prepare(); A3.prepare(); A4.prepare(); A5.prepare();
    tick(); reset=0;
endtask

// Ejecuta hasta que todos capturen el mismo progreso arquitectónico. El límite
// es de infraestructura: no se fuerza al núcleo a terminar ni a saltar un stall.
task automatic run_to_capture;
    integer timeout_;
    timeout_=0;
    while (!(A0.done && A1.done && A2.done && A3.done && A4.done && A5.done) && timeout_<2000) begin
        tick(); timeout_=timeout_+1;
    end
    check_true("seis capturas a igual progreso",A0.done && A1.done && A2.done && A3.done && A4.done && A5.done);
    if (timeout_==2000) $fatal(1,"no se alcanzó el progreso común");
endtask

// El flush usa la interfaz real, no acceso a arrays de caché. A partir de los
// puntos de captura solo quedan NOP/saltos finales, sin nuevos efectos de memoria.
task automatic flush_and_compare;
    integer timeout_;
    flush_req=1; timeout_=0;
    while (!(A0.flush_done && A1.flush_done && A2.flush_done && A3.flush_done && A4.flush_done && A5.flush_done) && timeout_<2000) begin
        tick(); timeout_=timeout_+1;
    end
    if (timeout_==2000) $fatal(1,"flush_done no llegó");
    A0.compare_memory(); A1.compare_memory(); A2.compare_memory();
    A3.compare_memory(); A4.compare_memory(); A5.compare_memory();
    // La igualdad por palabras compara todos los bytes, sin sustituirlos por un hash.
    for (integer i=0;i<DMEM_BYTES/4;i=i+1)
        check_true($sformatf("DMEM completa palabra %0d",i),
            A0.CPU.DMEM.mem[i]===A1.CPU.DMEM.mem[i] && A0.CPU.DMEM.mem[i]===A2.CPU.DMEM.mem[i] &&
            A0.CPU.DMEM.mem[i]===A3.CPU.DMEM.mem[i] && A0.CPU.DMEM.mem[i]===A4.CPU.DMEM.mem[i] &&
            A0.CPU.DMEM.mem[i]===A5.CPU.DMEM.mem[i]);
    flush_req=0;
endtask

// Contrasta snapshots al mismo avance, no el estado corriente de un procesador
// que ya siguió ejecutando. La comparación no incluye bóveda ni subllaves.
task automatic snapshots;
    for (integer r=0;r<32;r=r+1)
        check_true($sformatf("snapshot GPR %0d",r),
            A0.saved_regs[r]===A1.saved_regs[r] && A0.saved_regs[r]===A2.saved_regs[r] &&
            A0.saved_regs[r]===A3.saved_regs[r] && A0.saved_regs[r]===A4.saved_regs[r] &&
            A0.saved_regs[r]===A5.saved_regs[r]);
    check_true("snapshot PC",A0.saved_pc===A1.saved_pc && A0.saved_pc===A2.saved_pc &&
        A0.saved_pc===A3.saved_pc && A0.saved_pc===A4.saved_pc && A0.saved_pc===A5.saved_pc);
    check_true("snapshot estado público",A0.saved_state===A1.saved_state && A0.saved_state===A2.saved_state &&
        A0.saved_state===A3.saved_state && A0.saved_state===A4.saved_state && A0.saved_state===A5.saved_state);
    check_true("snapshot excepción",A0.saved_traps===A1.saved_traps && A0.saved_traps===A2.saved_traps &&
        A0.saved_traps===A3.saved_traps && A0.saved_traps===A4.saved_traps && A0.saved_traps===A5.saved_traps &&
        A0.saved_trap_pc===A1.saved_trap_pc && A0.saved_trap_pc===A2.saved_trap_pc &&
        A0.saved_trap_pc===A3.saved_trap_pc && A0.saved_trap_pc===A4.saved_trap_pc && A0.saved_trap_pc===A5.saved_trap_pc);
endtask

// Estimula únicamente la unidad aislada. El modelo lleva explícitamente las
// cuatro categorías, mientras el RTL deriva burbujas y replica el stall global.
// Así se comprueban también entradas IF inválidas que top no expone fuera de reset.
task automatic unit_step(input bit rst,en,move_,input logic [3:0] valid_);
    uc=0; ur=rst; um=en; ua=move_; uv=valid_; #2;
    if (rst) begin
        et=0;
        for (integer s=0;s<4;s=s+1) begin eo[s]=0;eb[s]=0;es[s]=0;eh[s]=0;end
    end
    else if (en) begin
        et=et+1;
        for (integer s=0;s<4;s=s+1) begin
            if (valid_[s]) eo[s]=eo[s]+1; else eb[s]=eb[s]+1;
            if (!move_) begin es[s]=es[s]+1; if (valid_[s]) eh[s]=eh[s]+1;end
        end
    end
    uc=1; #1;
    check_true("unidad: total después de NBA",ut===et);
    for (integer s=0;s<4;s=s+1)
        check_true("unidad: cuatro categorías",uo[s]===eo[s] && ub[s]===eb[s] && us[s]===es[s] && uh[s]===eh[s]);
    uc=0; #1;
endtask

initial begin
    if ($test$plusargs("vcd")) begin
        $dumpfile("issue8.vcd");
        $dumpvars(0,clk,reset,uc,ur,uv,A0.COUNTERS,A1.COUNTERS,A2.COUNTERS,
                     A3.COUNTERS,A4.COUNTERS,A5.COUNTERS,UNIT);
    end
    #1;
    // Primer recorrido: seis NOP válidos, con fechas 6/5/4/3 precalculadas.
    // Detecta usar máscara no NOP como validez y desfases de una etapa/ciclo.
    tb_section("Fechas de llenado y NOP válidos");
    start_case(0,0); run_to_capture(); snapshots(); flush_and_compare();

    // El mismo programa mezcla cuatro slots, loads/stores, saltos tomados y
    // no tomados y una excepción que anula también su BRU. El contador registra
    // posiciones, y las parejas verifican la ausencia de efectos de observarlas.
    tb_section("Programa mixto y congelamientos con posiciones válidas y burbujas");
    start_case(1,0); run_to_capture(); snapshots(); flush_and_compare();
    check_true("oráculos de datos",A0.saved_regs[1]===77 && A0.saved_regs[2]===32'h1234 &&
        A0.saved_regs[5]===77 && A0.saved_regs[6]===77 && A0.saved_regs[7]===78 && A0.saved_regs[8]===32'h400);
    check_true("jóvenes y culpable anulados",A0.saved_regs[20]===0 && A0.saved_regs[21]===0 &&
        A0.saved_regs[22]===0 && A0.saved_regs[23]===0 && A0.saved_regs[24]===0 && A0.saved_regs[25]===0 && A0.saved_regs[27]===0);
    check_true("excepción y manejador",A0.saved_traps===1 && A0.saved_trap_pc===240 && A0.saved_regs[30]===9);
    check_true("store palabra y byte",A0.CPU.DMEM.mem[8]===77 && A0.CPU.DMEM.mem[9]===32'h4d00);
    check_true("stores descartados",A0.CPU.DMEM.mem[20]===32'hfeed0014 &&
        A0.CPU.DMEM.mem[21]===32'hfeed0015 && A0.CPU.DMEM.mem[22]===32'hfeed0016);
    check_true("esperas exactas uno y cuatro",A2.freeze_count>0 && A3.freeze_count==4*A2.freeze_count);
    check_true("rachas consecutivas uno y cuatro",A2.max_freeze_run==1 && A3.max_freeze_run==4);
    check_true("burbujas retenidas y bundles retenidos",A3.frozen_bubble>0 && A3.frozen_valid>0);
    check_true("las cuatro etapas ocupadas durante congelamiento",A3.frozen_full>0);
    check_true("caché realmente congela",A4.freeze_count>0 && A5.freeze_count>0);
    check_true("saltos y excepciones ejercitados",A0.taken_count>=3 && A0.untaken_count==1 && A0.fault_count==1);

    // La ventana tardía y su pausa no detienen el transporte de metadatos.
    // El programa termina en los mismos snapshots aunque acumule menos tiempo.
    tb_section("Inicio tardío, pausa y reanudación");
    start_case(1,1); run_to_capture(); snapshots(); flush_and_compare();
    check_true("pausa dentro de congelamiento real",A3.paused_stalls>0);

    // La ventana vacía conserva todos los resultados en cero durante una
    // ejecución real completa, incluidas las esperas y redirecciones.
    tb_section("Ventana vacía");
    start_case(1,2); run_to_capture(); snapshots(); flush_and_compare();
    check_true("cero en ventana vacía",A0.measured===0 && A1.measured===0 && A2.measured===0 &&
        A3.measured===0 && A4.measured===0 && A5.measured===0);

    // Reset a mitad de ejecución abre una época nueva. Se verifica cada
    // acumulador aun con posiciones válidas y medición habilitada.
    tb_section("Reset durante ejecución y después de un congelamiento");
    start_case(1,0); repeat (8) tick(); reset=1; tick(); reset=0; repeat (6) tick();
    start_case(1,0);
    while (A3.freeze_count==0) tick();
    reset=1; tick(); reset=0; repeat (6) tick();

    // Las 16 combinaciones de validez separan posiciones de slots y prueban
    // burbujas congeladas. La pausa cambia entradas sin cambiar acumulados.
    tb_section("Unidad aislada: patrones exhaustivos de validez y control");
    unit_step(1,0,0,15);
    check_true("ancho unsigned de salida",$bits(ut)==64 && $bits(uo)==256 && $bits(ub)==256 && $bits(us)==256 && $bits(uh)==256);
    for (integer pattern_=0;pattern_<16;pattern_=pattern_+1) begin
        unit_step(0,1,1,4'(pattern_));
        unit_step(0,1,0,4'(pattern_));
        unit_step(0,0,0,4'(pattern_));
    end
    unit_step(1,0,0,15); unit_step(0,1,0,0);
    unit_step(1,1,0,15); unit_step(0,1,0,0);
    unit_step(0,0,1,15); unit_step(0,1,1,15);

    tb_checks=tb_checks+A0.checks+A1.checks+A2.checks+A3.checks+A4.checks+A5.checks;
    $fclose(A0.fd);$fclose(A1.fd);$fclose(A2.fd);$fclose(A3.fd);$fclose(A4.fd);$fclose(A5.fd);
    tb_finish("tb_perf_stage_counters");
end
endmodule
