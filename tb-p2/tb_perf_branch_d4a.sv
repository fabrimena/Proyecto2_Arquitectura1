/* Valida la recuperación BRU por flanco sobre top real, sin integrar ni alterar el núcleo. */
`timescale 1ns/1ps
`include "isa_defs.sv"
module tb_perf_branch_d4a;
`include "tb_utils.svh"

logic clk=0, reset=1, measure_enable=0;
top #(.MEM_MODE(0)) DUT (.clk(clk),.reset(reset),.debug_result(),.debug_rd(),.debug_write());
// REF ejecuta el mismo horizonte sin conexiones de métricas; solo se observa estado público.
top #(.MEM_MODE(0)) REF (.clk(clk),.reset(reset),.debug_result(),.debug_rd(),.debug_write());
logic [3:0] id_mask,ex_mask,wb_mask;
logic ex_valid,wb_valid,bundle_complete;
logic [1:0] ex_cause,wb_cause;
logic [63:0] cycles,bundles,instructions,memory_cycles,branch_cycles;
wire accepted=!reset && DUT.core_en && DUT.id_ex_valid && DUT.branch_flush &&
              DUT.redirect && !DUT.crypto_fault;
perf_slot_mask CLASSIFIER (.bundle_in(DUT.id_bundle),.non_nop_mask(id_mask));
perf_pipeline_monitor MONITOR (
    .clk(clk),.reset(reset),.advance(DUT.core_en),.id_valid(DUT.id_valid),.id_non_nop_mask(id_mask),
    .ex_branch_taken(DUT.id_ex_valid && DUT.branch_flush),
    .ex_exception(DUT.id_ex_valid && DUT.crypto_fault),
    .ex_valid(ex_valid),.ex_non_nop_mask(ex_mask),.ex_cancel_cause(ex_cause),
    .wb_valid(wb_valid),.wb_non_nop_mask(wb_mask),.wb_cancel_cause(wb_cause),
    .bundle_complete(bundle_complete));

// Estas marcas diagnósticas siguen las dos posiciones jóvenes descartadas.
// En R, ID se convierte en hueco EX; el hueco IF/ID llega a EX al avanzar otra vez.
// Se observa la ocupación EX real, sin deducir recuperación de una palabra cero
// ni de las causas del monitor D2. La ventana de medición no detiene este seguimiento.
logic discarded_id=0,discarded_ex=0,previous_recovery=0;
wire recovery_nominal=!reset && DUT.core_en && discarded_ex && !DUT.id_ex_valid;
logic branch_recovery;
integer mutation=0;
always @(posedge clk) begin
    if(reset)begin discarded_id<=0;discarded_ex<=0;previous_recovery<=0;end
    else if(DUT.core_en)begin
        discarded_id<=accepted;
        discarded_ex<=accepted || discarded_id;
        previous_recovery<=recovery_nominal;
    end
end
// Controles negativos opcionales: corrompen solo el diagnóstico del testbench,
// nunca señales del procesador. Deben terminar en FAIL y no son ejecuciones normales.
always_comb begin
    branch_recovery=recovery_nominal;
    case(mutation)
        1: branch_recovery=accepted || (!reset && discarded_id); // Un flanco adelantado.
        2: branch_recovery=!reset && previous_recovery;          // Un flanco atrasado.
        3: branch_recovery=recovery_nominal || accepted;         // Tercer ciclo espurio.
        4: branch_recovery=1'b0;                                // Omisión completa.
        5: branch_recovery=recovery_nominal || (!reset && DUT.ex_bru_is_branch);
        6: branch_recovery=recovery_nominal || (!reset && DUT.crypto_fault);
        7: branch_recovery=recovery_nominal || (!reset && DUT.id_ex_valid && ex_mask==0);
        8: branch_recovery=recovery_nominal && measure_enable;  // Pausa mal aplicada al seguimiento.
        default: begin end
    endcase
end
perf_counters COUNTERS (
    .clk(clk),.reset(reset),.measure_enable(measure_enable),.bundle_complete(bundle_complete),
    .non_nop_mask(wb_mask),.memory_stall(1'b0),.branch_recovery(branch_recovery),
    .cycle_count(cycles),.bundle_count(bundles),.instruction_count(instructions),
    .memory_stall_count(memory_cycles),.branch_penalty_count(branch_cycles));

// Referencia por fechas: programa conocido y PC predicho, no salidas del diagnóstico.
// Cada IF admitido en n finaliza en n+3 salvo anulación por una instrucción anterior.
localparam int LIMIT=256;
logic [127:0] program_words [0:1023];
logic [3:0] program_masks [0:1023],due_mask [0:LIMIT-1];
int kind [0:1023],visits [0:1023]; // 1 tomado, 2 no tomado, 3 fault, 4 tres vueltas tomadas.
logic [31:0] targets [0:1023],due_pc [0:LIMIT-1],next_pc=0;
bit due_valid [0:LIMIT-1],recovery_due [0:LIMIT-1];
int due_cause [0:LIMIT-1],due_serial [0:LIMIT-1];
int c=0,scenario=0,epoch=0,serial=0,last_serial=0;
logic [63:0] expected_cycles=0,expected_bundles=0,expected_instructions=0,expected_penalty=0;
int taken_count=0,untaken_count=0,fault_count=0,recovery_count=0,nop_count=0,old_wb_count=0;
int recovery_with_wb=0,disabled_recovery=0,memory_checks=0;
int total_taken=0,total_faults=0,total_recovery=0,total_nops=0,total_disabled=0;
int logfd,errors_before;
logic [31:0] sampled_wb_pc;
int sampled_wb_serial,sampled_ex_cause;
bit expected_taken,expected_fault,expected_recovery;
logic [31:0] expected_target;

function automatic logic [127:0] b(input logic [31:0] a,l,j,k);return {k,j,l,a};endfunction
function automatic logic [31:0] ai(input int rd,rs,imm);
    return {TYPE_IMM,OP_SUMI,5'(rs),5'(rd),11'(imm)};
endfunction
function automatic logic [31:0] jump(input int rd,off);
    return {TYPE_BRU_JUMP,OP_SYE,5'(rd),16'(off)};
endfunction
function automatic logic [31:0] cond(input logic [3:0] op,input int a,z,off);
    return {TYPE_BRU_COND,op,5'(a),5'(z),11'(off)};
endfunction
function automatic logic [31:0] store_word(input int off);
    return {TYPE_LSU,OP_GUARDAP,5'd0,5'd0,11'(off)};
endfunction
function automatic int pop(input logic [3:0] m);
    return int'(m[0])+int'(m[1])+int'(m[2])+int'(m[3]);
endfunction

task automatic clear_epoch;
    c=0;epoch++;serial=0;last_serial=0;next_pc=0;
    expected_cycles=0;expected_bundles=0;expected_instructions=0;expected_penalty=0;
    taken_count=0;untaken_count=0;fault_count=0;recovery_count=0;nop_count=0;old_wb_count=0;
    recovery_with_wb=0;disabled_recovery=0;
    for(int i=0;i<LIMIT;i++)begin
        due_valid[i]=0;due_mask[i]=0;due_pc[i]=0;due_cause[i]=0;due_serial[i]=0;recovery_due[i]=0;
    end
    for(int i=0;i<1024;i++)visits[i]=0;
endtask

// PRE conserva entradas consumidas; POST muestra salidas después de NBA.
// La misma columna esperada describe siempre el flanco indicado, también en POST.
task automatic trace_row(input string phase);
    $fdisplay(logfd,"%0d,%0d,%0d,%s,%0d,%0d,%h,%h,%h,%0d,%0d,%0d,%0d,%0d,%0d,%h,%0d,%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%h",
        scenario,epoch,c,phase,reset,measure_enable,DUT.pc,DUT.id_pc,DUT.ex_pc,
        DUT.id_valid,DUT.id_ex_valid,DUT.ex_wb_valid,DUT.branch_flush,DUT.crypto_fault,DUT.redirect,
        DUT.redirect_pc,expected_taken,expected_recovery,branch_recovery,wb_mask,bundle_complete,
        cycles,bundles,instructions,branch_cycles,expected_penalty,memory_cycles,
        sampled_wb_pc,sampled_wb_serial,sampled_ex_cause,accepted,discarded_id,discarded_ex,expected_target);
endtask

// Flanco manual: cuatro ns de estabilización y un ns tras NBA. Cada error
// conserva una fila y el primer ciclo divergente antes de terminar con salida no cero.
task automatic tick;
    int ix,k;
    logic [31:0] pc_before,ex_before;
    logic recovery_before;
    clk=0;#4;errors_before=tb_errors;
    expected_taken=0;expected_fault=0;expected_recovery=0;expected_target=0;
    sampled_wb_pc=0;sampled_wb_serial=0;sampled_ex_cause=0;
    if(reset)begin
        clear_epoch();
        check_true("reset inhibe recuperación y finalización",branch_recovery===0 && bundle_complete===0);
    end else begin
        c++;
        if(c+4>=LIMIT)$fatal(1,"capacidad de referencia excedida");
        expected_recovery=recovery_due[c];
        sampled_wb_pc=due_pc[c];sampled_wb_serial=due_serial[c];sampled_ex_cause=due_cause[c+1];
        check_true("modo directo avanza en cada flanco",DUT.core_en===1 && DUT.cache_stall===0);
        check_true("IF contra PC predicho independientemente",DUT.fetch_pc===next_pc && DUT.fetch_valid===1);
        check_true("ID real por fecha",DUT.id_valid===due_valid[c+2]);
        check_true("EX real por fecha",DUT.id_ex_valid===due_valid[c+1]);
        check_true("WB real por fecha",DUT.ex_wb_valid===due_valid[c]);
        if(due_valid[c+2])begin
            ix=(due_pc[c+2]>>4)&1023;
            check_true("ID PC, palabra y máscara conocidos",DUT.id_pc===due_pc[c+2] &&
                       DUT.id_bundle===program_words[ix] && id_mask===program_masks[ix]);
        end
        if(due_valid[c+1])begin
            check_true("PC EX contra identidad dinámica",DUT.ex_pc===due_pc[c+1]);
            ix=(due_pc[c+1]>>4)&1023;visits[ix]++;k=kind[ix];
            expected_taken=(k==1 || (k==4 && visits[ix]<=3));expected_fault=(k==3);
            expected_target=expected_fault?TRAP_VECTOR:targets[ix];
            if(k==2 || (k==4 && !expected_taken))untaken_count++;
        end
        check_true("salto aceptado contra programa",accepted===expected_taken);
        check_true("BRU efectiva requiere EX válido",DUT.branch_flush===expected_taken);
        check_true("excepción independiente de BRU",DUT.crypto_fault===expected_fault);
        check_true("redirect efectivo",DUT.redirect===(expected_taken||expected_fault));
        if(expected_taken || expected_fault)
            check_true("destino de redirección conocido",DUT.redirect_pc===expected_target);
        check_true("recuperación en el flanco exacto",branch_recovery===expected_recovery);
        check_true("recuperación tiene hueco EX real",!expected_recovery || !DUT.id_ex_valid);
        check_true("evento WB sin duplicación ni burbujas",bundle_complete===due_valid[c]);
        check_true("máscara WB contra programa",wb_mask===(due_valid[c]?due_mask[c]:4'b0));
        if(due_valid[c])begin
            check_true("identidad dinámica no repetida",due_serial[c]>last_serial);last_serial=due_serial[c];
            if(due_mask[c]==0)begin nop_count++;total_nops++;end
        end
        if(expected_recovery)begin
            recovery_count++;total_recovery++;
            if(due_valid[c])recovery_with_wb++;
            if(!measure_enable)begin disabled_recovery++;total_disabled++;end
        end
        if(measure_enable)begin
            expected_cycles++;
            if(due_valid[c])begin expected_bundles++;expected_instructions+=pop(due_mask[c]);end
            if(expected_recovery)expected_penalty++;
        end
        // Programa y fechas deciden las anulaciones; no leen MONITOR ni las marcas diagnósticas.
        if(expected_taken || expected_fault)begin
            if(due_valid[c])old_wb_count++;
            if(expected_taken)begin
                taken_count++;total_taken++;
                check_true("posiciones jóvenes de salto presentes",DUT.id_valid && DUT.fetch_valid);
                recovery_due[c+1]=1;recovery_due[c+2]=1;
            end else begin
                fault_count++;total_faults++;
                check_true("fault tiene prioridad sobre solicitud BRU",DUT.ex_bru_is_jump && !DUT.bru_branch_flush);
                due_valid[c+1]=0;due_mask[c+1]=0;due_cause[c+1]=2;
            end
            due_valid[c+2]=0;due_mask[c+2]=0;due_cause[c+2]=expected_fault?2:1;
            due_valid[c+3]=0;due_mask[c+3]=0;due_cause[c+3]=expected_fault?2:1;
            next_pc=expected_target;
        end else begin
            ix=(next_pc>>4)&1023;
            check_true("IF contiene programa conocido",DUT.fetch_bundle===program_words[ix]);
            due_valid[c+3]=1;due_mask[c+3]=program_masks[ix];due_pc[c+3]=next_pc;
            serial++;due_serial[c+3]=serial;next_pc+=16;
        end
        check_true("secuencia de cinco puertos GPR pasiva",{DUT.wb_we,DUT.wb_waddr,DUT.wb_wdata}===
                   {REF.wb_we,REF.wb_waddr,REF.wb_wdata});
        check_true("dos puertos de DMEM pasivos",{DUT.dmem_we,DUT.dmem_be,DUT.dmem_addr,DUT.dmem_wdata,
                   DUT.dmem_we_b,DUT.dmem_addr_b,DUT.dmem_wdata_b}===
                   {REF.dmem_we,REF.dmem_be,REF.dmem_addr,REF.dmem_wdata,
                    REF.dmem_we_b,REF.dmem_addr_b,REF.dmem_wdata_b});
        check_true("redirecciones pasivas",{DUT.redirect,DUT.redirect_pc}==={REF.redirect,REF.redirect_pc});
    end
    trace_row("PRE");pc_before=DUT.pc;ex_before=DUT.ex_pc;recovery_before=branch_recovery;clk=1;#1;
    check_true("reloj general y núcleo avanzan",DUT.core_clk===1);
    check_true("PC posterior verifica aceptación",DUT.pc===next_pc);
    check_true("validez real y monitor tras NBA",ex_valid===DUT.id_ex_valid && wb_valid===DUT.ex_wb_valid);
    check_true("EX posterior contra fecha",ex_valid===due_valid[c+2] && ex_mask===(due_valid[c+2]?due_mask[c+2]:4'b0));
    check_true("WB posterior contra fecha",wb_valid===due_valid[c+1] && wb_mask===(due_valid[c+1]?due_mask[c+1]:4'b0));
    check_true("causas distintas para salto y excepción",ex_cause===2'(due_cause[c+2]) && wb_cause===2'(due_cause[c+1]));
    if(expected_taken || expected_fault)
        check_true("IF/ID e ID/EX quedan vacíos al aceptar redirect",!DUT.id_valid && !DUT.id_ex_valid);
    check_true("ciclos exactos de ventana",cycles===expected_cycles);
    check_true("bundles exactos de ventana",bundles===expected_bundles);
    check_true("instrucciones exactas de ventana",instructions===expected_instructions);
    check_true("penalizaciones exactas de ventana",branch_cycles===expected_penalty);
    check_true("sin stalls y penalizaciones acotadas",memory_cycles===64'd0 && branch_cycles<=cycles);
    for(int r=0;r<32;r++)check_true($sformatf("GPR x%0d pasivo",r),DUT.REGFILE.regs[r]===REF.REGFILE.regs[r]);
    check_true("PC, ESTADO y excepción públicos pasivos",{DUT.pc,DUT.crypto_estado,DUT.trap_pc,DUT.trap_count}===
               {REF.pc,REF.crypto_estado,REF.trap_pc,REF.trap_count});
    trace_row("POST");
    if(tb_errors!=errors_before)begin
        $display("PRIMERA DIVERGENCIA caso=%0d epoca=%0d ciclo=%0d pc_pre=%h pc_ex=%h tomado=%b destino=%h rec_esperada=%b rec_observada=%b penal_esp=%0d penal_obt=%0d",
                  scenario,epoch,c,pc_before,ex_before,expected_taken,expected_target,expected_recovery,
                  recovery_before,expected_penalty,branch_cycles);
        $fclose(logfd);$fatal(1,"D4-A: primer flanco divergente; ver filas PRE/POST");
    end
    clk=0;#5;
endtask

task automatic load_word(input int pos,input logic [127:0] word_,input logic [3:0] mask,
                         input int control_,input logic [31:0] target_);
    program_words[pos]=word_;program_masks[pos]=mask;kind[pos]=control_;targets[pos]=target_;
    DUT.IMEM.memory[pos]=word_;REF.IMEM.memory[pos]=word_;
endtask

task automatic prepare(input int number_);
    reset=1;measure_enable=0;tick();scenario=number_;
    // Solo se preparan memorias de entrada con reset activo y clk bajo.
    // El patrón no uniforme ayuda a detectar escrituras indebidas de jóvenes anulados.
    for(int i=0;i<1024;i++)load_word(i,0,0,0,0);
    for(int i=0;i<16384;i++)begin DUT.DMEM.mem[i]=32'hcafe0000+i;REF.DMEM.mem[i]=32'hcafe0000+i;end
endtask

// Programa común: WB anterior, salto, dos jóvenes con ALU/store y destino NOP.
// El destino útil posterior permite observar llenado sin confundir NOP con burbuja.
task automatic forward_program;
    load_word(0,b(ai(2,0,77),0,0,0),1,0,0);
    load_word(1,b(0,0,jump(10,64),0),4,1,80);
    load_word(2,b(ai(20,0,99),store_word(4),0,0),3,0,0);
    load_word(3,b(ai(21,0,99),store_word(8),0,0),3,0,0);
    load_word(6,b(ai(3,0,55),0,0,0),1,0,0);
endtask

task automatic finish_case;
    int different;different=0;
    for(int i=0;i<16384;i++)if(DUT.DMEM.mem[i]!==REF.DMEM.mem[i])different++;
    check("DMEM completa: 16384 palabras",different,0);memory_checks++;
    $display("D4A CASO %0d epoca=%0d horizonte=%0d ciclos=%0d bundles=%0d instrucciones=%0d penal=%0d saltos=%0d no_tomados=%0d excepciones=%0d recuperacion=%0d rec_con_WB=%0d rec_fuera=%0d NOP=%0d",
              scenario,epoch,c,cycles,bundles,instructions,branch_cycles,taken_count,untaken_count,
              fault_count,recovery_count,recovery_with_wb,disabled_recovery,nop_count);
    if(cycles==0)$display("IPC NO DEFINIDO: ventana sin ciclos");
    else $display("IPC externo=%0.9f",real'(instructions)/real'(cycles));
    // Las aserciones finales también fallan con salida no cero por tb_finish.
endtask

task automatic run_cycles(input int n);
    // Un flanco más con reset después de cargar el programa: la ROM síncrona lee el bundle 0 en ese flanco.
    if(reset)tick();
    reset=0;measure_enable=1;repeat(n)tick();
endtask

initial begin
    if($value$plusargs("mutacion=%d",mutation))
        if(mutation<0 || mutation>8)$fatal(1,"mutacion permitida: 0..8");
    logfd=$fopen("d4a-eventos.csv","w");if(!logfd)$fatal(1,"no se pudo abrir traza");
    $fdisplay(logfd,"caso,epoca,ciclo,fase,reset,medir,pc_if,pc_id,pc_ex,id_valid,ex_valid,wb_valid,branch_flush,crypto_fault,redirect,redirect_pc,tomado_esperado,recuperacion_esperada,recuperacion_observada,non_nop_mask,bundle_complete,cycle_count,bundle_count,instruction_count,branch_penalty_count,penalizaciones_esperadas,memory_stall_count,pc_wb_ref,serie_wb_ref,causa_ex_ref,salto_aceptado,marca_id,marca_ex,destino_esperado");
    if($test$plusargs("vcd"))begin
        $dumpfile("d4a.vcd");
        $dumpvars(0,clk,reset,measure_enable,accepted,discarded_id,discarded_ex,branch_recovery,
                  bundle_complete,wb_mask,cycles,bundles,instructions,branch_cycles,
                  DUT.pc,DUT.id_pc,DUT.ex_pc,DUT.id_valid,DUT.id_ex_valid,DUT.ex_wb_valid,
                  DUT.branch_flush,DUT.crypto_fault,DUT.redirect,DUT.redirect_pc);
    end
    #1;
    prepare(1);tb_section("Salto adelante, WB anterior, jóvenes sin efectos y destino NOP");
    forward_program();run_cycles(14);finish_case();
    check("dos ciclos reales posteriores al salto",branch_cycles,2);
    check_true("WB puede completar durante recuperación",recovery_with_wb==1 && old_wb_count==1);
    check("WB anterior conserva resultado",DUT.REGFILE.regs[2],77);
    check("enlace del salto",DUT.REGFILE.regs[10],32);
    check("destino útil después de NOP",DUT.REGFILE.regs[3],55);
    check("ALU jóvenes anuladas",DUT.REGFILE.regs[20]|DUT.REGFILE.regs[21],0);
    check("store joven ID anulado",DUT.DMEM.mem[1],32'hcafe0001);
    check("store joven IF anulado",DUT.DMEM.mem[2],32'hcafe0002);

    prepare(2);tb_section("Condicional no tomado conserva flujo secuencial");
    load_word(1,b(0,0,cond(OP_IGUALNO,0,0,64),0),4,2,80);
    load_word(2,b(ai(4,0,12),0,0,0),1,0,0);run_cycles(12);finish_case();
    check("no tomado sin recuperación",branch_cycles,0);check("joven sí ejecutado",DUT.REGFILE.regs[4],12);
    check_true("un condicional falso observado",untaken_count==1);

    prepare(3);tb_section("Dos saltos en el mínimo flujo: destino es otro salto");
    load_word(0,b(0,0,jump(0,64),0),4,1,64);
    load_word(4,b(0,0,jump(0,64),0),4,1,128);
    load_word(8,b(ai(5,0,9),0,0,0),1,0,0);run_cycles(14);finish_case();
    check_true("dos redirecciones dinámicas",taken_count==2);check("cuatro huecos distintos",branch_cycles,4);
    check("segundo destino ejecutado",DUT.REGFILE.regs[5],9);

    prepare(4);tb_section("Bucle acotado: tres saltos atrás y salida no tomada");
    load_word(0,b(ai(2,0,4),0,0,0),1,0,0);
    load_word(3,b(ai(2,2,-1),0,0,0),1,0,0);
    load_word(6,b(0,0,cond(OP_MENORA,0,2,-48),0),4,4,48);
    run_cycles(36);finish_case();check("bucle termina",DUT.REGFILE.regs[2],0);
    check_true("mismo PC, cuatro identidades EX",visits[6]==4 && taken_count==3 && untaken_count==1);
    check("seis ciclos perdidos",branch_cycles,6);

    prepare(5);tb_section("NOP válidos antes, en jóvenes descartados y en destino");
    load_word(1,b(0,0,jump(0,64),0),4,1,80);run_cycles(12);finish_case();
    check("NOP no produce penalización adicional",branch_cycles,2);check_true("NOP sí completa",nop_count>0);

    prepare(6);tb_section("Excepción cripto suprime BRU, store y ALU; anterior sobrevive");
    load_word(0,b(ai(2,0,77),0,0,0),1,0,0);
    load_word(1,b(ai(15,0,99),store_word(4),jump(16,64),
                {TYPE_CRYPTO,OP_FSL,2'd0,2'd0,5'd18,5'd0,7'd0}),15,3,TRAP_VECTOR);
    load_word(2,b(ai(20,0,99),0,0,0),1,0,0);
    load_word(3,b(ai(21,0,99),0,0,0),1,0,0);
    // Se observa hasta la finalización del NOP del vector, antes de que el
    // direccionamiento circular de IMEM pueda volver a ejecutar al culpable.
    run_cycles(8);finish_case();check("excepción no suma BRU",branch_cycles,0);
    check_true("una excepción sin salto tomado",fault_count==1 && taken_count==0);
    check("WB viejo sobrevive a excepción",DUT.REGFILE.regs[2],77);
    check("culpable y jóvenes sin GPR",DUT.REGFILE.regs[15]|DUT.REGFILE.regs[16]|
          DUT.REGFILE.regs[18]|DUT.REGFILE.regs[19]|DUT.REGFILE.regs[20]|DUT.REGFILE.regs[21],0);
    check("store culpable suprimido",DUT.DMEM.mem[1],32'hcafe0001);
    check("PC culpable",DUT.trap_pc,16);check("una excepción pública",DUT.trap_count,1);

    // R=4, recuperación en 5 y 6. Cada ventana prueba el flanco consumido,
    // no una multiplicación del número de saltos que cayó dentro de la ventana.
    for(int window_=0;window_<5;window_++)begin
        prepare(7+window_);tb_section($sformatf("Ventana de medición %0d",window_));
        forward_program();tick();reset=0;
        for(int n=1;n<=12;n++)begin
            case(window_)
                0: measure_enable=(n<=4);                // Salto dentro, recuperación fuera.
                1: measure_enable=(n==5 || n==6);        // Salto fuera, recuperación dentro.
                2: measure_enable=(n!=6);                // Pausa en segundo hueco y reanuda.
                3: measure_enable=(n!=5);                // Pausa en primero, mide segundo.
                4: measure_enable=0;                    // Cero ciclos, pero seguimiento activo.
            endcase
            tick();
        end
        finish_case();
        case(window_)
            0: check("sin recuperación dentro",branch_cycles,0);
            1: check("dos ciclos sin contar evento",branch_cycles,2);
            2,3: check("solo hueco habilitado",branch_cycles,1);
            4: check_true("ventana vacía conserva todos los acumulados",cycles==0 && bundles==0 && instructions==0 && branch_cycles==0);
        endcase
        check_true("seguimiento independiente de ventana",recovery_count==2 && taken_count==1);
    end

    prepare(12);tb_section("Reset interrumpe recuperación pendiente y abre otra época");
    forward_program();run_cycles(4);finish_case();
    check("horizonte termina en redirección sin anticipar recuperación",branch_cycles,0);
    check_true("redirección pendiente observada",discarded_ex && discarded_id);
    reset=1;measure_enable=1;tick();finish_case();
    check_true("reset prioritario borra etiquetas",!discarded_ex && !discarded_id && branch_cycles==0);
    run_cycles(8);finish_case();check("solo recuperación de nueva época",branch_cycles,2);

    prepare(13);tb_section("Flujo sin saltos con útiles y NOPs, ventana íntegra");
    load_word(0,b(ai(1,0,7),0,0,0),1,0,0);
    load_word(3,b(ai(2,1,1),0,0,0),1,0,0);run_cycles(14);finish_case();
    check("dependencia N+3 preservada",DUT.REGFILE.regs[2],8);
    check_true("ninguna recuperación inventada",taken_count==0 && recovery_count==0 && branch_cycles==0);
    prepare(14);tb_section("Horizonte termina después del primer hueco de recuperación");
    forward_program();run_cycles(5);finish_case();
    check("solo un flanco observado, sin proyectar el pendiente",branch_cycles,1);
    check_true("segundo hueco sigue pendiente al terminar",discarded_ex && !DUT.id_ex_valid);

    check_true("cobertura transversal",total_taken>10 && total_faults==1 && total_recovery>20 && total_nops>20 && total_disabled>0);
    $display("D4A COBERTURA: saltos=%0d excepciones=%0d recuperaciones=%0d NOP=%0d rec_fuera=%0d comparaciones_DMEM=%0d",
             total_taken,total_faults,total_recovery,total_nops,total_disabled,memory_checks);
    $fclose(logfd);tb_finish("tb_perf_branch_d4a");
end
endmodule
