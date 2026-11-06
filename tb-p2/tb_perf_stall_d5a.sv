/* Valida métricas durante esperas LSU reales con referencias por ciclo y avance efectivo. */
`timescale 1ns/1ps
`include "isa_defs.sv"

// Cada observador tiene procesador, métricas, referencia y evidencia propios.
// Compartir la implementación de la prueba no comparte acumulados ni expectativas.
module perf_stall_case_d5a #(parameter int MODE=0, WAIT=0, CONFIG=0)
    (input logic clk,reset);
`include "tb_utils.svh"
top #(.MEM_MODE(MODE),.STALL_CYCLES(WAIT)) CPU
    (.clk(clk),.reset(reset),.debug_result(),.debug_rd(),.debug_write());
logic [3:0] id_mask,ex_mask,wb_mask;
logic ex_valid,wb_valid,complete;
logic [1:0] ex_cause,wb_cause;
logic [63:0] cycles,bundles,instructions,memory_cycles,branch_cycles;
logic measuring=0;
wire accepted=!reset && CPU.core_en && CPU.id_ex_valid && CPU.branch_flush && !CPU.crypto_fault;
wire memory_wait=!reset && !CPU.core_en;
logic discarded_id=0,discarded_ex=0;
wire recovery=!reset && CPU.core_en && discarded_ex && !CPU.id_ex_valid;
always @(posedge clk) begin
    if(reset)begin discarded_id<=0;discarded_ex<=0;end
    else if(CPU.core_en)begin discarded_id<=accepted;discarded_ex<=accepted || discarded_id;end
end
perf_slot_mask CLASSIFIER (.bundle_in(CPU.id_bundle),.non_nop_mask(id_mask));
perf_pipeline_monitor MONITOR (
    .clk(clk),.reset(reset),.advance(CPU.core_en),.id_valid(CPU.id_valid),.id_non_nop_mask(id_mask),
    .ex_branch_taken(CPU.id_ex_valid && CPU.branch_flush),.ex_exception(CPU.id_ex_valid && CPU.crypto_fault),
    .ex_valid(ex_valid),.ex_non_nop_mask(ex_mask),.ex_cancel_cause(ex_cause),
    .wb_valid(wb_valid),.wb_non_nop_mask(wb_mask),.wb_cancel_cause(wb_cause),.bundle_complete(complete));

// Las mutaciones opcionales afectan solo conexiones diagnósticas de esta prueba.
// La referencia conserva sus eventos originales y debe rechazar cada defecto.
int mutation=0;
logic counted_complete,counted_memory,counted_recovery,counted_enable;
logic [3:0] counted_mask;
always_comb begin
    counted_complete=complete;counted_memory=memory_wait;counted_recovery=recovery;
    counted_enable=measuring;counted_mask=wb_mask;
    case(mutation)
        1: counted_complete=!reset && wb_valid; // Duplicación al retener WB.
        2: counted_memory=0;                   // Omite tiempo de memoria.
        3: counted_recovery=recovery || memory_wait;
        4: counted_recovery=0;                 // Pierde recuperación posterior.
        5: counted_mask=0;                     // Pierde instrucciones sin perder bundles.
        6: counted_enable=!reset && !done;              // Ignora las ventanas.
        7: counted_complete=complete && !CPU.id_ex_valid; // Omite WB con EX ocupado.
        default: begin end
    endcase
end
perf_counters COUNTERS (
    .clk(clk),.reset(reset),.measure_enable(counted_enable),.bundle_complete(counted_complete),
    .non_nop_mask(counted_mask),.memory_stall(counted_memory),.branch_recovery(counted_recovery),
    .cycle_count(cycles),.bundle_count(bundles),.instruction_count(instructions),
    .memory_stall_count(memory_cycles),.branch_penalty_count(branch_cycles));

localparam logic [31:0] NOP=0;
function automatic logic [31:0] sumai(input logic [4:0] rg, input logic [4:0] rf1,
                                      input logic [10:0] imm);

    return {TYPE_IMM, OP_SUMI, rf1, rg, imm};
endfunction

function automatic logic [31:0] suma(input logic [4:0] rg, input logic [4:0] rf1,
                                     input logic [4:0] rf2);

    return {TYPE_REG, OP_SUM, rg, rf1, rf2, 6'b0};
endfunction

function automatic logic [31:0] lsu(input logic [3:0] id, input logic [4:0] base,
                                    input logic [4:0] reg_dato, input logic [10:0] off);

    return {TYPE_LSU, id, base, reg_dato, off};
endfunction

function automatic logic [31:0] branch(input logic [3:0] id, input logic [4:0] rf1,
                                       input logic [4:0] rf2, input logic [10:0] off);

    return {TYPE_BRU_COND, id, rf1, rf2, off};
endfunction

function automatic logic [31:0] sye(input logic [4:0] rg, input logic [15:0] off);

    return {TYPE_BRU_JUMP, OP_SYE, rg, off};
endfunction

function automatic logic [31:0] fsl(input logic [4:0] rd, input logic [4:0] r1,
                                    input logic [1:0] lk, input logic [1:0] rk);

    return {TYPE_CRYPTO, OP_FSL, lk, rk, rd, r1, 7'b0};
endfunction

function automatic logic [31:0] ell(input logic [1:0] lk, input logic [1:0] off,
                                    input logic [4:0] rs1, input logic [4:0] rs2);

    return {TYPE_CRYPTO, OP_ELL, lk, off, rs1, rs2, 7'b0};
endfunction

function automatic logic [31:0] vcr(input logic [15:0] dir);

    return {TYPE_CRYPTO, OP_VCR, dir, 5'b0};
endfunction

function automatic logic [31:0] camcon(input logic [15:0] dir, input logic [4:0] imm);

    return {TYPE_CRYPTO, OP_CAMCON, dir, imm};
endfunction

function automatic logic [31:0] setpwd(input logic [4:0] rs);

    return {TYPE_CRYPTO, OP_SETPWD, 16'b0, rs};
endfunction

// Bundle: slot 0 ALU en los bits bajos, slot 3 CRIPTO en los altos
function automatic logic [127:0] bundle(input logic [31:0] alu, input logic [31:0] mem,
                                        input logic [31:0] bru, input logic [31:0] cripto);

    return {cripto, bru, mem, alu};
endfunction

function automatic logic [127:0] solo_alu(input logic [31:0] i);

    return bundle(i, NOP, NOP, NOP);
endfunction

function automatic logic [127:0] solo_lsu(input logic [31:0] i);

    return bundle(NOP, i, NOP, NOP);
endfunction

function automatic logic [127:0] solo_cri(input logic [31:0] i);

    return bundle(NOP, NOP, NOP, i);
endfunction


localparam int LIMIT=256,MAX_EVENTS=1024;
logic [127:0] words [0:1023];
logic [3:0] masks [0:1023],due_mask [0:LIMIT-1];
int control_kind [0:1023],visits [0:1023],due_cause [0:LIMIT-1],due_serial [0:LIMIT-1];
logic [31:0] targets [0:1023],due_pc [0:LIMIT-1],next_pc=0;
bit due_valid [0:LIMIT-1],recovery_due [0:LIMIT-1];
int scenario=0,policy=0,program_id=0,real_cycle=0,advances=0,waited=0,serial=0,last_serial=0;
int accesses=0,stalls=0,taken_count=0,untaken_count=0,faults=0,recoveries=0,nops=0;
int stores=0,camcons=0,held_branches=0,overlaps=0,paused_stalls=0,paused_recovery=0;
int last_branch=-10,events=0,logfd=0,effectfd=0,errors_before=0,sample_n=0;
logic [63:0] expected_cycles=0,expected_bundles=0,expected_instructions=0,expected_memory=0,expected_branch=0;
bit done=0,expected_move=0,expected_taken=0,expected_fault=0,expected_request=0,expected_recovery=0,will_finish=0;
logic [31:0] expected_target=0;
logic [79:0] event_data [0:MAX_EVENTS-1];
int event_advance [0:MAX_EVENTS-1];
logic [31:0] saved_regs [0:31],saved_mem [0:16383],saved_pc,saved_state,saved_trap_pc,saved_traps;
logic [1023:0] packed_gprs,gprs_before;
logic [2047:0] pipeline_before;
logic [31:0] public_before;
int progress_before=0;
logic sampled_stall;
logic [31:0] sampled_pc,sampled_ex_pc;
logic [31:0] metadata_before;
logic [1:0] marks_before;
wire [31:0] metadata={ex_valid,ex_mask,ex_cause,wb_valid,wb_mask,wb_cause,MONITOR.id_cancel_cause};
// Se incluyen todos los resultados públicos de ID/EX y los registros de salida
// de las unidades; no se inspeccionan llaves, contraseña ni subllaves de la bóveda.
wire [2047:0] pipeline_state={CPU.pc,CPU.id_bundle,CPU.id_pc,CPU.id_valid,
    CPU.id_ex_valid,CPU.ex_pc,CPU.ex_alu_op,CPU.ex_alu_rd,CPU.ex_alu_operand_a,
    CPU.ex_alu_operand_b,CPU.ex_alu_imm,CPU.ex_alu_use_imm,CPU.ex_lsu_valid,
    CPU.ex_lsu_op,CPU.ex_lsu_rd,CPU.ex_lsu_imm,CPU.ex_lsu_operand_a,CPU.ex_lsu_operand_b,
    CPU.ex_bru_op,CPU.ex_bru_rd,CPU.ex_bru_br_imm,CPU.ex_bru_jmp_imm,
    CPU.ex_bru_is_branch,CPU.ex_bru_is_jump,CPU.ex_bru_operand_a,CPU.ex_bru_operand_b,
    CPU.ex_crypto_valid,CPU.ex_crypto_fault,CPU.ex_crypto_op,CPU.ex_crypto_lk,
    CPU.ex_crypto_rk,CPU.ex_crypto_rd,CPU.ex_crypto_addr,CPU.ex_crypto_imm,
    CPU.ex_crypto_operand_a,CPU.ex_crypto_operand_b,CPU.ex_wb_valid,CPU.ex_wb_rd,
    CPU.ex_wb_alu_result,CPU.wb_we,CPU.wb_waddr,CPU.wb_wdata,
    CPU.crypto_estado,CPU.trap_pc,CPU.trap_count};
for(genvar g=0;g<32;g++)assign packed_gprs[32*g+:32]=CPU.REGFILE.regs[g];

function automatic int pop(input logic [3:0] mask_);
    return int'(mask_[0])+int'(mask_[1])+int'(mask_[2])+int'(mask_[3]);
endfunction

task automatic put(input int pos,input logic [127:0] word_,input logic [3:0] mask_,
                   input int kind_,input logic [31:0] target_);
    words[pos]=word_;masks[pos]=mask_;control_kind[pos]=kind_;targets[pos]=target_;
    CPU.IMEM.memory[pos]=word_;
endtask

task automatic clear_reference;
    real_cycle=0;advances=0;waited=0;serial=0;last_serial=0;next_pc=0;done=0;
    accesses=0;stalls=0;taken_count=0;untaken_count=0;faults=0;recoveries=0;nops=0;
    stores=0;camcons=0;held_branches=0;overlaps=0;paused_stalls=0;paused_recovery=0;
    expected_cycles=0;expected_bundles=0;expected_instructions=0;expected_memory=0;expected_branch=0;
    events=0;last_branch=-10;
    for(int i=0;i<LIMIT;i++)begin
        due_valid[i]=0;due_mask[i]=0;due_pc[i]=0;due_cause[i]=0;due_serial[i]=0;recovery_due[i]=0;
    end
    for(int i=0;i<1024;i++)visits[i]=0;
endtask

// Programa del testbench de stalls aprobado, con una cadena de dos saltos y
// BRU dentro del culpable. Las máscaras se declaran sin leer CLASSIFIER.
task automatic prepare(input int number_,window_,program_);
    scenario=number_;policy=window_;program_id=program_;clear_reference();
    for(int i=0;i<1024;i++)put(i,0,0,0,0);
    for(int i=0;i<16384;i++)CPU.DMEM.mem[i]=0;
    if(program_==0)begin
        CPU.DMEM.mem['h100>>2]=32'h5ec2e7a1;CPU.DMEM.mem['h104>>2]=32'h5ec2e7a1;
        CPU.DMEM.mem['h108>>2]=32'h0bad0bad;
        CPU.DMEM.mem['h110>>2]=32'h0f1e2d3c;CPU.DMEM.mem['h114>>2]=32'h4b5a6978;
        CPU.DMEM.mem['h118>>2]=32'h8796a5b4;CPU.DMEM.mem['h11c>>2]=32'hc3d2e1f0;
        CPU.DMEM.mem['h200>>2]=32'h414c4f48;CPU.DMEM.mem['h204>>2]=32'h36323032;
        CPU.DMEM.mem['h208>>2]=32'h636f7250;CPU.DMEM.mem['h20c>>2]=32'h64617365;
        put(0,bundle(sumai(16,0,'h200),lsu(OP_CARGAI,0,6,'h100),0,0),3,0,0);
        put(1,bundle(sumai(17,0,'h210),lsu(OP_CARGAI,0,8,'h110),0,0),3,0,0);
        put(2,solo_lsu(lsu(OP_CARGAI,0,9,'h114)),2,0,0);
        put(3,bundle(0,lsu(OP_CARGAI,0,10,'h118),0,setpwd(6)),10,0,0);
        put(4,bundle(0,lsu(OP_CARGAI,0,11,'h11c),0,vcr('h104)),10,0,0);
        put(7,solo_cri(ell(0,0,8,9)),8,0,0);put(8,solo_cri(ell(0,2,10,11)),8,0,0);
        put(9,solo_lsu(lsu(OP_CARGAI,16,4,0)),2,0,0);
        put(10,solo_lsu(lsu(OP_CARGAI,16,5,4)),2,0,0);
        put(11,solo_alu(sumai(16,16,8)),1,0,0);put(12,solo_alu(suma(20,20,4)),1,0,0);
        put(13,bundle(suma(21,21,5),0,0,fsl(4,4,0,0)),9,0,0);
        put(16,solo_cri(fsl(4,4,0,1)),8,0,0);put(19,solo_cri(fsl(4,4,0,2)),8,0,0);
        put(22,solo_cri(fsl(4,4,0,3)),8,0,0);
        put(25,solo_lsu(lsu(OP_GUARDAP,16,4,-8)),2,0,0);
        put(26,bundle(0,lsu(OP_GUARDAP,16,5,-4),branch(OP_MENORA,16,17,11'(-272)),0),6,4,144);
        put(27,solo_alu(sumai(22,0,11'(-5))),1,0,0);
        put(30,solo_lsu(lsu(OP_GUARDAP,0,22,'h300)),2,0,0);
        put(31,solo_lsu(lsu(OP_CARGAI,0,23,'h300)),2,0,0);
        put(32,solo_lsu(lsu(OP_GUARDAB,0,22,'h305)),2,0,0);
        put(33,solo_lsu(lsu(OP_CARGABAI,0,24,'h305)),2,0,0);
        put(34,bundle(0,lsu(OP_CARGAI,0,25,'h300),0,camcon('h300,4)),10,0,0);
        put(35,bundle(0,lsu(OP_CARGAI,0,26,'h300),sye(1,32),0),6,1,592);
        put(36,solo_alu(sumai(29,0,1)),1,0,0);
        put(37,bundle(0,0,sye(0,48),0),4,1,640);
        put(40,solo_cri(vcr('h108)),8,0,0);
        put(43,bundle(sumai(27,0,7),lsu(OP_CARGAI,0,28,'h200),sye(3,32),fsl(4,4,0,0)),15,3,TRAP_VECTOR);
        put(44,solo_alu(sumai(29,0,2)),1,0,0);put(45,solo_alu(sumai(29,0,3)),1,0,0);
        put(1023,bundle(sumai(30,0,99),0,sye(0,0),0),5,1,TRAP_VECTOR);
    end else begin
        // Programas mínimos para reset pendiente: una carga o un store. Se
        // usan datos públicos constantes para observar el efecto de liberar stall.
        CPU.DMEM.mem[0]=32'h12345678;
        put(0,solo_lsu(lsu(program_==1?OP_CARGAI:OP_GUARDAP,0,2,0)),2,0,0);
    end
endtask

task automatic add_event(input logic [7:0] type_,port_,input logic [31:0] address_,value_);
    if(events>=MAX_EVENTS)$fatal(1,"capacidad de eventos agotada");
    event_data[events]={type_,port_,address_,value_};event_advance[events]=sample_n;
    // Solo efectos públicos: puertos GPR/DMEM, accesos y control; nunca VAULT.
    $fdisplay(effectfd,"%0d,%0d,%0d,%0d,%0d,%0d,%h,%h",CONFIG,scenario,events,
              sample_n,type_,port_,address_,value_);events++;
endtask

task automatic trace_row(input string phase);
    $fdisplay(logfd,"%0d,%0d,%0d,%0d,%s,%0d,%0d,%0d,%0d,%h,%h,%h,%0d,%0d,%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h",
        CONFIG,scenario,real_cycle,advances,phase,reset,measuring,CPU.cache_stall,CPU.core_en,
        CPU.pc,CPU.id_pc,CPU.ex_pc,CPU.id_valid,CPU.id_ex_valid,CPU.ex_wb_valid,complete,wb_mask,
        accepted,recovery,cycles,bundles,instructions,memory_cycles,branch_cycles,
        expected_cycles,expected_bundles,expected_instructions,expected_memory,expected_branch,
        expected_move,expected_recovery,due_pc[sample_n],due_serial[sample_n],waited,CPU.core_clk,progress_before,CPU.dmem_we,CPU.dmem_we_b,CPU.dmem_addr,CPU.dmem_wdata);
endtask

// PRE separa tiempo real de progreso. El número de esperas se predice desde la
// instrucción EX conocida y WAIT, sin leer core_en ni contadores como oráculo.
task automatic before_edge;
    int ix,k;
    bit expected_complete;
    errors_before=tb_errors;progress_before=advances;
    sampled_stall=CPU.cache_stall;sampled_pc=CPU.pc;sampled_ex_pc=CPU.ex_pc;
    if(reset)begin
        clear_reference();sample_n=0;expected_move=1;expected_recovery=0;
        expected_taken=0;expected_fault=0;measuring=1;
    end else if(!done)begin
        real_cycle++;sample_n=advances+1;
        if(sample_n+4>=LIMIT)$fatal(1,"referencia sin capacidad");
        ix=(due_pc[sample_n+1]>>4)&1023;k=due_valid[sample_n+1]?control_kind[ix]:0;
        expected_taken=(k==1 || (k==4 && visits[ix]==0));expected_fault=(k==3);
        expected_target=expected_fault?TRAP_VECTOR:targets[ix];
        expected_request=due_valid[sample_n+1] && due_mask[sample_n+1][1] && !expected_fault;
        expected_move=!(MODE==1 && expected_request && waited<WAIT);
        expected_recovery=expected_move && recovery_due[sample_n];
        // Cada política depende de la referencia, no de los acumulados DUT.
        case(policy)
            0: measuring=1;
            1: measuring=(real_cycle>=12);
            2: measuring=!(advances==2 && !expected_move);
            3: measuring=!(recovery_due[sample_n] && sample_n==last_branch+1);
            4: measuring=0;
            5: measuring=!expected_move;
            6: measuring=!(advances==2 || advances==3);
            default: $fatal(1,"política desconocida");
        endcase
        #1; // Propaga la ventana a los puertos diagnósticos antes de comprobarlos.
        check_true("avance efectivo contra esperas independientes",CPU.core_en===expected_move);
        check_true("stall estable antes del flanco",CPU.cache_stall===!expected_move);
        check_true("IF PC predicho",CPU.pc===next_pc);
        check_true("validez real por fechas",CPU.id_valid===due_valid[sample_n+2] &&
                   CPU.id_ex_valid===due_valid[sample_n+1] && CPU.ex_wb_valid===due_valid[sample_n]);
        if(due_valid[sample_n+2])begin
            check_true("ID conserva palabra y PC",CPU.id_pc===due_pc[sample_n+2] &&
                       CPU.id_bundle===words[(due_pc[sample_n+2]>>4)&1023]);
            check_true("D1 contra máscara declarada",id_mask===due_mask[sample_n+2]);
        end
        if(due_valid[sample_n+1])check_true("EX identidad dinámica",CPU.ex_pc===due_pc[sample_n+1]);
        check_true("decisión BRU real, aun retenida",CPU.branch_flush===expected_taken);
        check_true("fault real independiente de BRU",CPU.crypto_fault===expected_fault);
        check_true("solicitud LSU contra tabla",(CPU.mem_re || CPU.mem_we)===expected_request);
        check_true("aceptación única al avanzar",accepted===(expected_taken && expected_move));
        if(expected_taken || expected_fault)
            check_true("destino dirigido",CPU.redirect && CPU.redirect_pc===expected_target);
        expected_complete=expected_move && due_valid[sample_n];
        check_true("evento WB exacto, nunca durante stall",counted_complete===expected_complete);
        check_true("máscara WB alineada",counted_mask===(due_valid[sample_n]?due_mask[sample_n]:4'b0));
        check_true("atribución memoria del flanco efectivo",counted_memory===!expected_move);
        check_true("atribución BRU del avance exacto",counted_recovery===expected_recovery);
        check_true("ventana aplicada solo al contador",counted_enable===measuring);
        if(memory_wait && discarded_ex)overlaps++;
        if(measuring)begin
            expected_cycles++;
            if(!expected_move)expected_memory++;
            else begin
                if(expected_complete)begin expected_bundles++;expected_instructions+=pop(due_mask[sample_n]);end
                if(expected_recovery)expected_branch++;
            end
        end
        // El punto común queda al consumir ambos huecos del primer salto del manejador.
        // Se captura antes de consumir otra iteración; el núcleo sigue corriendo.
        will_finish=program_id==0 && faults==1 && visits[1023]==1 &&
                    recovery_due[sample_n] && sample_n==last_branch+2 && expected_move;
        if(!expected_move)begin
            stalls++;waited++;
            check_true("ninguna escritura DMEM durante stall",!CPU.dmem_we && !CPU.dmem_we_b);
            if(expected_taken)held_branches++;
            if(!measuring)paused_stalls++;
        end else begin
            waited=0;advances=sample_n;
            if(expected_complete)begin
                check_true("serie WB no duplicada",due_serial[sample_n]>last_serial);last_serial=due_serial[sample_n];
                if(due_mask[sample_n]==0)nops++;
            end
            if(expected_recovery)begin recoveries++;if(!measuring)paused_recovery++;end
            // Secuencia de efectos ordenada por avance, no por ciclo absoluto.
            for(int port_=0;port_<5;port_++)if(CPU.wb_we[port_])
                add_event(1,8'(port_),{27'd0,CPU.wb_waddr[port_]},CPU.wb_wdata[port_]);
            if(CPU.dmem_we)begin add_event(2,{4'd0,CPU.dmem_be},CPU.dmem_addr,CPU.dmem_wdata);stores++;end
            if(CPU.dmem_we_b)begin add_event(3,0,CPU.dmem_addr_b,CPU.dmem_wdata_b);camcons++;end
            if(expected_request)begin add_event(4,{7'd0,CPU.mem_we},CPU.mem_addr,CPU.mem_rdata);accesses++;end
            if(due_valid[sample_n+1])begin
                visits[ix]++;
                if(k==4 && !expected_taken)untaken_count++;
            end
            if(expected_taken || expected_fault)begin
                add_event(expected_fault?6:5,0,CPU.ex_pc,CPU.redirect_pc);
                if(expected_taken)begin
                    taken_count++;last_branch=sample_n;
                    recovery_due[sample_n+1]=1;recovery_due[sample_n+2]=1;
                end else begin
                    faults++;check_true("excepción suprime BRU del culpable",CPU.ex_bru_is_jump && !CPU.bru_branch_flush);
                    due_valid[sample_n+1]=0;due_mask[sample_n+1]=0;due_cause[sample_n+1]=2;
                end
                due_valid[sample_n+2]=0;due_mask[sample_n+2]=0;due_cause[sample_n+2]=expected_fault?2:1;
                due_valid[sample_n+3]=0;due_mask[sample_n+3]=0;due_cause[sample_n+3]=expected_fault?2:1;
                next_pc=expected_target;
            end else begin
                due_valid[sample_n+3]=1;due_mask[sample_n+3]=masks[(next_pc>>4)&1023];
                due_pc[sample_n+3]=next_pc;serial++;due_serial[sample_n+3]=serial;next_pc+=16;
            end
        end
    end else measuring=0;
    pipeline_before=pipeline_state;gprs_before=packed_gprs;public_before=CPU.crypto_estado;
    metadata_before=metadata;marks_before={discarded_id,discarded_ex};
    if(!done || reset)trace_row("PRE");
endtask

// POST observa NBA, conserva el estado durante retenciones y captura el punto
// equivalente al consumirse el segundo hueco del primer salto del manejador.
task automatic after_edge;
    if(reset)begin
        check_true("reset abre reloj del núcleo",CPU.core_clk===1 && CPU.core_en===1);
        check_true("reset limpia pipeline y marcas",!CPU.id_valid && !CPU.id_ex_valid && !CPU.ex_wb_valid &&
                   !ex_valid && !wb_valid && !discarded_id && !discarded_ex);
        check_true("reset de contadores prioritario",cycles===0 && bundles===0 && instructions===0 && memory_cycles===0 && branch_cycles===0);
        check_true("reset público del núcleo",CPU.pc===0 && packed_gprs===1024'd0 && CPU.crypto_estado===2 && CPU.trap_count===0);
    end else if(!done)begin
        check_true("core_clk solo pulsa si hubo avance",CPU.core_clk===expected_move);
        if(!expected_move)begin
            check_true("pipeline completo retenido",pipeline_state===pipeline_before);
            check_true("32 GPR retenidos",packed_gprs===gprs_before);
            check_true("metadatos EX/WB retenidos",metadata===metadata_before);
            check_true("marcas BRU retenidas",{discarded_id,discarded_ex}===marks_before);
        end else begin
            check_true("PC tras avance",CPU.pc===next_pc);
            check_true("EX posterior por fecha",ex_valid===due_valid[advances+2] && ex_mask===(due_valid[advances+2]?due_mask[advances+2]:4'b0));
            check_true("WB posterior por fecha",wb_valid===due_valid[advances+1] && wb_mask===(due_valid[advances+1]?due_mask[advances+1]:4'b0));
            check_true("causas conservadas",ex_cause===2'(due_cause[advances+2]) && wb_cause===2'(due_cause[advances+1]));
            if(CPU.crypto_estado!==public_before)add_event(7,0,0,CPU.crypto_estado);
        end
        check_true("monitor alineado con pipeline real",ex_valid===CPU.id_ex_valid && wb_valid===CPU.ex_wb_valid);
        check_true("ciclos reales exactos",cycles===expected_cycles);
        check_true("bundles exactos",bundles===expected_bundles);
        check_true("instrucciones exactas",instructions===expected_instructions);
        check_true("memoria exacta",memory_cycles===expected_memory);
        check_true("BRU exacta",branch_cycles===expected_branch);
        check_true("categorías sin doble atribución",{1'b0,memory_cycles}+{1'b0,branch_cycles}<={1'b0,cycles});
        if(will_finish)begin
            for(int i=0;i<32;i++)saved_regs[i]=CPU.REGFILE.regs[i];
            for(int i=0;i<16384;i++)saved_mem[i]=CPU.DMEM.mem[i];
            saved_pc=CPU.pc;saved_state=CPU.crypto_estado;saved_trap_pc=CPU.trap_pc;saved_traps=CPU.trap_count;
            done=1;
            $display("D5A caso=%0d config=%0d real=%0d avances=%0d accesos=%0d stalls=%0d bundles=%0d instrucciones=%0d ciclos_medidos=%0d memoria=%0d BRU=%0d saltos=%0d excepciones=%0d eventos=%0d",
                scenario,CONFIG,real_cycle,advances,accesses,stalls,bundles,instructions,cycles,memory_cycles,branch_cycles,taken_count,faults,events);
            if(cycles==0)$display("IPC NO DEFINIDO");else $display("IPC externo=%0.9f",real'(instructions)/real'(cycles));
        end
    end
    if(!done || will_finish || reset)trace_row("POST");
    if(tb_errors!=errors_before)begin
        $display("PRIMERA DIVERGENCIA D5A caso=%0d config=%0d ciclo=%0d avance=%0d n=%0d esperado_avanza=%b stall_pre=%b pc_pre=%h pc_ex_pre=%h",
            scenario,CONFIG,real_cycle,advances,sample_n,expected_move,sampled_stall,sampled_pc,sampled_ex_pc);
        $fclose(logfd);$fclose(effectfd);$fatal(1,"D5-A: primera divergencia; revisar PRE/POST");
    end
    will_finish=0;
endtask

initial begin
    if($value$plusargs("mutacion=%d",mutation))begin
        if(mutation<0 || mutation>7)$fatal(1,"mutacion permitida 0..7");
    end
    logfd=$fopen($sformatf("d5a-config%0d.csv",CONFIG),"w");if(!logfd)$fatal(1,"no se pudo abrir traza");
    effectfd=$fopen($sformatf("d5a-efectos-config%0d.csv",CONFIG),"w");
    if(!effectfd)$fatal(1,"no se pudo abrir secuencia pública");
    $fdisplay(effectfd,"config,caso,indice,avance,tipo,puerto,direccion,dato");
    $fdisplay(logfd,"config,caso,ciclo_general,avances,fase,reset,medir,cache_stall,core_en,pc,id_pc,ex_pc,id_valid,ex_valid,wb_valid,bundle_complete,mask_wb,salto_aceptado,recuperacion_bru,ciclos_totales,bundles,instrucciones,stalls_memoria,penalizaciones_bru,esp_ciclos,esp_bundles,esp_instrucciones,esp_memoria,esp_bru,esp_avance,esp_recuperacion,pc_wb_ref,serie_wb_ref,esperas_consumidas,core_clk,avances_antes,dmem_we,dmem_we_b,dmem_addr,dmem_wdata");
end
endmodule

module tb_perf_stall_d5a;
`include "tb_utils.svh"
logic clk=0,reset=1;
perf_stall_case_d5a #(.MODE(0),.WAIT(0),.CONFIG(0)) REF (.clk(clk),.reset(reset));
perf_stall_case_d5a #(.MODE(1),.WAIT(1),.CONFIG(1)) DUT1 (.clk(clk),.reset(reset));
perf_stall_case_d5a #(.MODE(1),.WAIT(4),.CONFIG(4)) DUT4 (.clk(clk),.reset(reset));
int total_checks=0;

task automatic tick;
    clk=0;#4;
    REF.before_edge();DUT1.before_edge();DUT4.before_edge();
    #1;clk=1;#1;
    REF.after_edge();DUT1.after_edge();DUT4.after_edge();
    clk=0;#5;
endtask

task automatic start_case(input int scenario_,policy_,program_);
    reset=1;tick();
    REF.prepare(scenario_,policy_,program_);DUT1.prepare(scenario_,policy_,program_);DUT4.prepare(scenario_,policy_,program_);
    reset=0;
endtask

// Las capturas se tomaron en flancos absolutos distintos, al completar el mismo
// segundo hueco BRU del manejador. La comparación incluye su avance efectivo.
`define COMPARE_SNAPSHOT(D) \
    for(int i=0;i<32;i++)check_true($sformatf("GPR x%0d en punto equivalente",i),D.saved_regs[i]===REF.saved_regs[i]); \
    begin int differences;differences=0; \
        for(int i=0;i<16384;i++)if(D.saved_mem[i]!==REF.saved_mem[i])differences++; \
        check("65536 bytes DMEM por igualdad real",differences,0); \
    end \
    check_true("PC, ESTADO y excepciones equivalentes", \
        {D.saved_pc,D.saved_state,D.saved_trap_pc,D.saved_traps}=== \
        {REF.saved_pc,REF.saved_state,REF.saved_trap_pc,REF.saved_traps}); \
    check("cantidad de efectos públicos",D.events,REF.events); \
    for(int e=0;e<REF.events;e++)check_true("secuencia y progreso de efectos", \
        D.event_data[e]===REF.event_data[e] && D.event_advance[e]==REF.event_advance[e]); \
    check("avances iguales",D.advances,REF.advances); \
    check("accesos LSU únicos",D.accesses,19); \
    check("duración acumulada contrastada por flanco",D.stalls,D.WAIT*19); \
    check("diferencia de tiempo real",D.real_cycle-REF.real_cycle,D.stalls); \
    check_true("sin coincidencia real memoria/hueco EX",D.overlaps==0); \
    check_true("BRU retenida durante esperas de su LSU",D.held_branches>0); \
    check("camcon publica una sola escritura",D.camcons,1);

task automatic compare_case;
    `COMPARE_SNAPSHOT(DUT1)
    `COMPARE_SNAPSHOT(DUT4)
    check("un camcon en REF",REF.camcons,1);
    check_true("Feistel conserva vector público",REF.saved_mem['h200>>2]===32'h03d44466 &&
               REF.saved_mem['h204>>2]===32'hd685afaf);
    check_true("palabra y byte cargados",REF.saved_regs[23]===32'hfffffffb && REF.saved_regs[24]===32'hfffffffb);
    check_true("camcon rota una vez, load anterior y posterior",REF.saved_regs[25]===32'hfffffffb &&
               REF.saved_regs[26]===32'hffffffbf && REF.saved_mem['h300>>2]===32'hffffffbf);
    check_true("byte store preservado",REF.saved_mem['h304>>2]===32'h0000fb00);
    check_true("culpable y jóvenes no escriben GPR",REF.saved_regs[27]===0 && REF.saved_regs[28]===0 &&
               REF.saved_regs[29]===0 && REF.saved_regs[3]===0);
    check_true("excepción y manejador públicos",REF.saved_traps===1 && REF.saved_trap_pc===688 && REF.saved_regs[30]===99);
endtask

// Solicita reset mientras hay una petición retenida. Con clk bajo, reset hace
// stall=0, el latch vuelve a abrir core_en y el siguiente flanco resetea el núcleo.
// En el caso store, la memoria no tiene reset: se documenta si el acceso se publica.
task automatic reset_pending(input int program_);
    start_case(8+program_,0,program_);
    tick();tick();tick();
    check_true("DUT4 tiene acceso pendiente y reloj bloqueado",DUT4.stalls==1 && DUT4.CPU.cache_stall && !DUT4.CPU.core_en);
    reset=1;#1;
    check_true("reset libera stall antes del flanco",DUT4.CPU.cache_stall===0 && DUT4.CPU.core_en===1);
    tick();
    if(program_==1)begin
        check("load pendiente no llega a GPR",DUT4.CPU.REGFILE.regs[2],0);
        check("reset no borra DMEM",DUT4.CPU.DMEM.mem[0],32'h12345678);
    end else begin
        check("store pendiente se publica al liberar stall por reset",DUT4.CPU.DMEM.mem[0],0);
        $display("D5A LIMITACION RESET: store pendiente publicado en DMEM al quitar stall; no hay cancelación atómica de memoria.");
    end
    check_true("reset descarta métricas y recuperación anteriores",DUT4.cycles==0 && DUT4.branch_cycles==0 && !DUT4.discarded_ex);
    reset=0;repeat(8)tick();
    check_true("nueva época progresa sin finalizaciones viejas",DUT4.advances>=3 && DUT4.last_serial<=DUT4.serial);
endtask

initial begin
    if($test$plusargs("vcd"))begin
        $dumpfile("d5a.vcd");
        $dumpvars(0,clk,reset,REF.cycles,REF.bundles,REF.branch_cycles,
            DUT1.cycles,DUT1.bundles,DUT1.memory_cycles,DUT1.branch_cycles,DUT1.CPU.core_clk,
            DUT1.CPU.core_en,DUT1.CPU.cache_stall,DUT1.recovery,DUT1.accepted,
            DUT4.cycles,DUT4.bundles,DUT4.memory_cycles,DUT4.branch_cycles,DUT4.CPU.core_clk,
            DUT4.CPU.core_en,DUT4.CPU.cache_stall,DUT4.recovery,DUT4.accepted,
            DUT4.CPU.pc,DUT4.CPU.id_pc,DUT4.CPU.ex_pc,DUT4.complete,DUT4.wb_mask);
    end
    #1;
    for(int p=0;p<7;p++)begin
        tb_section($sformatf("Tres modos con política de medición %0d",p));
        start_case(p+1,p,0);
        begin int deadline;deadline=0;
            while(!(REF.done && DUT1.done && DUT4.done) && deadline<250)begin tick();deadline++;end
            check_true("tres horizontes equivalentes alcanzados",REF.done && DUT1.done && DUT4.done);
        end
        compare_case();
        if(p==0)begin
            check_true("ventana completa conserva penalizaciones",REF.branch_cycles==DUT1.branch_cycles && DUT1.branch_cycles==DUT4.branch_cycles);
            check("tres saltos de programa más manejador",DUT4.taken_count,4);
            check("ocho oportunidades de recuperación",DUT4.recoveries,8);
        end
        if(p==2)check_true("pausa durante espera real",DUT1.paused_stalls>0 && DUT4.paused_stalls>0);
        if(p==3)check_true("pausa y reanudación durante recuperación",DUT1.paused_recovery>0 && DUT4.paused_recovery>0);
        if(p==4)check_true("ventana vacía mantiene cero",DUT1.cycles==0 && DUT4.cycles==0 && REF.cycles==0);
        if(p==5)check_true("solo stalls, ninguna finalización medida",DUT1.cycles==19 && DUT4.cycles==76 &&
                             DUT1.bundles==0 && DUT4.bundles==0 && DUT4.instructions==0);
    end
    reset_pending(1);reset_pending(2);
    tb_section("Reset con recuperación BRU pendiente");
    start_case(11,0,0);
    begin int deadline;deadline=0;
        while(!(DUT4.discarded_ex && DUT4.discarded_id) && deadline<200)begin tick();deadline++;end
        check_true("dos posiciones de recuperación pendientes reales",DUT4.discarded_ex && DUT4.discarded_id);
    end
    reset=1;tick();reset=0;repeat(8)tick();
    check_true("nueva época sin recuperación anterior",DUT1.branch_cycles==0 && DUT4.branch_cycles==0 &&
               !DUT4.discarded_ex && !DUT4.discarded_id);
    total_checks=tb_checks+REF.tb_checks+DUT1.tb_checks+DUT4.tb_checks+1;
    check_true("observadores sin fallos",REF.tb_errors==0 && DUT1.tb_errors==0 && DUT4.tb_errors==0);
    $display("D5A TOTAL: %0d verificaciones; REF=%0d DUT1=%0d DUT4=%0d principales=%0d",
              total_checks,REF.tb_checks,DUT1.tb_checks,DUT4.tb_checks,tb_checks);
    $fclose(REF.logfd);$fclose(DUT1.logfd);$fclose(DUT4.logfd);
    $fclose(REF.effectfd);$fclose(DUT1.effectfd);$fclose(DUT4.effectfd);
    // Incorpora las verificaciones de los tres observadores al resumen oficial.
    tb_checks+=REF.tb_checks+DUT1.tb_checks+DUT4.tb_checks;
    tb_finish("tb_perf_stall_d5a");
end
endmodule
