/* Valida la instrumentación integrada con top real y retenciones abstractas independientes. */
`timescale 1ns/1ps
`include "isa_defs.sv"

// Cada configuración mantiene un oráculo por fechas y un procesador sin métricas
// con igual reloj. El programa reducido tiene expectativas propias, distintas de D5-A.
module perf_real_d4b1 #(parameter int MODE=0,WAIT=0,CONFIG=0)(input logic clk,reset);
`include "tb_utils.svh"
top #(.MEM_MODE(MODE),.STALL_CYCLES(WAIT)) CPU (.clk(clk),.reset(reset),.debug_result(),.debug_rd(),.debug_write());
top #(.MEM_MODE(MODE),.STALL_CYCLES(WAIT)) SHADOW (.clk(clk),.reset(reset),.debug_result(),.debug_rd(),.debug_write());
logic measuring=0,complete,recovery,memory_wait;
logic [3:0] mask;
logic [63:0] cycles,bundles,instructions,memories,branches;
perf_vliw_monitor MONITOR (
    .clk(clk),.reset(reset),.measure_enable(measuring),.core_advance(CPU.core_en),
    .id_valid(CPU.id_valid),.id_bundle(CPU.id_bundle),.ex_valid(CPU.id_ex_valid),
    .ex_branch_taken(CPU.branch_flush),.ex_exception(CPU.crypto_fault),
    .cycle_count(cycles),.bundle_count(bundles),.instruction_count(instructions),
    .memory_stall_count(memories),.branch_penalty_count(branches),
    .bundle_complete(complete),.branch_recovery(recovery),.memory_stall(memory_wait),.wb_non_nop_mask(mask));

localparam int LIMIT=160;
logic [3:0] pmask[0:1023],dmask[0:LIMIT-1];
logic [31:0] dest[0:1023],dpc[0:LIMIT-1],pc_expected=0;
bit valid_due[0:LIMIT-1],rec_due[0:LIMIT-1];
int kind[0:1023],visits[0:1023],series[0:LIMIT-1];
int a=0,c=0,n=0,waited=0,serial=0,last_serial=0,last_branch=-10,policy=0,scenario=0;
int accesses=0,stalls=0,taken=0,faults=0,nops=0,held=0,event_count=0,fd,ef,errors_before;
logic [63:0] ec=0,eb=0,ei=0,em=0,er=0;
bit done=0,move,req,jump_now,fault_now,rec_now,finish_now;
logic [79:0] effects[0:255];
int event_progress[0:255];
logic [31:0] regs_saved[0:31],mem_saved[0:16383],state_saved,pc_saved,trap_saved,count_saved;
int mutation=0;
logic previous_complete=0,observed_complete,observed_recovery,observed_memory;
logic [3:0] observed_mask;
logic [63:0] observed_cycles;
always @(posedge clk)if(reset)previous_complete<=0;else previous_complete<=complete;
// Solo se corrompe la lectura diagnóstica del testbench: el módulo RTL y sus
// entradas permanecen intactos. Cada control debe fallar por la aserción prevista.
always_comb begin
    observed_complete=complete;observed_recovery=recovery;observed_memory=memory_wait;
    observed_mask=mask;observed_cycles=cycles;
    case(mutation)
        1: observed_complete=previous_complete;
        2: observed_complete=complete || memory_wait;
        3: observed_mask=complete?(mask^4'b0001):mask;
        4: observed_recovery=recovery || (!reset && CPU.core_en && CPU.branch_flush);
        5: observed_recovery=0;
        6: observed_memory=0;
        7: observed_cycles=cycles+64'(!reset && !measuring && !done);
        8: observed_recovery=recovery || (!reset && CPU.crypto_fault);
        9: observed_complete=0;
        default: begin end
    endcase
end
function automatic logic [127:0] b(input logic [31:0] alu_,lsu_,bru_,crypto_);return {crypto_,bru_,lsu_,alu_};endfunction
function automatic logic [31:0] ai(input int rd,rs,imm);return {TYPE_IMM,OP_SUMI,5'(rs),5'(rd),11'(imm)};endfunction
function automatic logic [31:0] ls(input logic [3:0] op,input int rd,off);return {TYPE_LSU,op,5'd0,5'(rd),11'(off)};endfunction
function automatic logic [31:0] br(input logic [3:0] op,input int x,y,off);return {TYPE_BRU_COND,op,5'(x),5'(y),11'(off)};endfunction
function automatic logic [31:0] j(input int rd,off);return {TYPE_BRU_JUMP,OP_SYE,5'(rd),16'(off)};endfunction
function automatic int pop(input logic [3:0] m);return int'(m[0])+int'(m[1])+int'(m[2])+int'(m[3]);endfunction

task automatic clear_ref;
    a=0;c=0;waited=0;serial=0;last_serial=0;last_branch=-10;pc_expected=0;done=0;
    accesses=0;stalls=0;taken=0;faults=0;nops=0;held=0;event_count=0;ec=0;eb=0;ei=0;em=0;er=0;
    for(int i=0;i<LIMIT;i++)begin valid_due[i]=0;dmask[i]=0;dpc[i]=0;series[i]=0;rec_due[i]=0;end
    for(int i=0;i<1024;i++)visits[i]=0;
endtask

task automatic put(input int pos,input logic [127:0] word_,input logic [3:0] m,input int k,input int target_);
    CPU.IMEM.memory[pos]=word_;SHADOW.IMEM.memory[pos]=word_;pmask[pos]=m;kind[pos]=k;dest[pos]=32'(target_);
endtask

task automatic prepare(input int p);
    policy=p;scenario=p+1;clear_ref();
    // Precarga solo de memorias con reset activo y reloj bajo, como los bancos aprobados.
    for(int i=0;i<1024;i++)put(i,0,0,0,0);
    for(int i=0;i<16384;i++)begin CPU.DMEM.mem[i]=0;SHADOW.DMEM.mem[i]=0;end
    for(int i=3;i<=6;i++)begin CPU.DMEM.mem[i]=32'hfeed0000+i;SHADOW.DMEM.mem[i]=32'hfeed0000+i;end
    put(0,b(ai(2,0,3),0,0,0),1,0,0);put(1,b(ai(4,0,77),0,0,0),1,0,0);
    // x4 se produce en 1 y se consume en 4: N+3. El condicional es falso.
    put(4,b(ai(5,0,5),ls(OP_GUARDAP,4,0),br(OP_IGUALNO,0,0,64),0),7,2,128);
    put(5,b(0,ls(OP_CARGAI,6,0),0,0),2,0,0);
    put(6,b(0,ls(OP_GUARDAB,4,5),0,0),2,0,0);put(7,b(0,ls(OP_CARGABAI,7,5),0,0),2,0,0);
    put(8,b(ai(8,6,1),0,0,0),1,0,0);
    // Tres decrementos, dos saltos atrás. El store y la BRU usan x2 en N+3.
    put(9,b(ai(2,2,-1),0,0,0),1,0,0);
    put(12,b(0,ls(OP_GUARDAP,2,8),br(OP_MENORA,0,2,-48),0),6,4,144);
    put(13,b(0,0,j(0,48),0),4,1,256);
    put(14,b(ai(20,0,99),0,0,0),1,0,0);put(15,b(0,ls(OP_GUARDAP,0,12),0,0),2,0,0);
    put(17,b(ai(9,0,9),0,0,0),1,0,0);
    put(18,b(0,ls(OP_CARGAI,10,0),j(11,48),0),6,1,336);
    put(19,b(ai(21,0,99),0,0,0),1,0,0);put(20,b(0,ls(OP_GUARDAP,0,16),0,0),2,0,0);
    put(21,b(ai(13,0,13),0,0,0),1,0,0);
    put(22,b(ai(22,0,99),ls(OP_GUARDAP,0,20),j(12,32),
             {TYPE_CRYPTO,OP_FSL,2'd0,2'd0,5'd24,5'd0,7'd0}),15,3,TRAP_VECTOR);
    put(23,b(ai(25,0,99),0,0,0),1,0,0);put(24,b(0,ls(OP_GUARDAP,0,24),0,0),2,0,0);
    put(1023,b(ai(30,0,99),0,j(0,0),0),5,1,TRAP_VECTOR);
endtask

task automatic event_(input logic [7:0] type_,port_,input logic [31:0] addr_,data_);
    if(event_count>=256)$fatal(1,"referencia sin espacio para efectos");
    effects[event_count]={type_,port_,addr_,data_};event_progress[event_count]=n;
    $fdisplay(ef,"%0d,%0d,%0d,%0d,%0d,%h,%h",scenario,event_count,n,type_,port_,addr_,data_);event_count++;
endtask

task automatic trace_(input string phase_);
    $fdisplay(fd,"%0d,%0d,%0d,%s,%0d,%0d,%0d,%h,%h,%h,%0d,%0d,%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
        scenario,c,a,phase_,reset,measuring,CPU.core_en,CPU.pc,CPU.id_pc,CPU.ex_pc,
        CPU.id_valid,CPU.id_ex_valid,CPU.ex_wb_valid,observed_complete,observed_mask,observed_memory,
        observed_recovery,observed_cycles,bundles,instructions,memories,branches,ec,eb,ei,em,er,n,series[n]);
endtask

task automatic pre;
    int ix,k;
    errors_before=tb_errors;finish_now=0;
    if(reset)begin clear_ref();n=0;measuring=1;end
    else if(!done)begin
        c++;n=a+1;if(n+4>=LIMIT)$fatal(1,"referencia fuera de límites");
        ix=(dpc[n+1]>>4)&1023;k=valid_due[n+1]?kind[ix]:0;
        jump_now=(k==1 || (k==4 && visits[ix]<2));fault_now=(k==3);
        req=valid_due[n+1] && dmask[n+1][1] && !fault_now;
        move=!(MODE==1 && req && waited<WAIT);rec_now=move && rec_due[n];
        case(policy)
            0: measuring=1;
            1: measuring=(c>=8);
            2: measuring=!( (a==6 && !move) || (rec_due[n] && n==last_branch+1) );
            3: measuring=0;
        endcase
        #1;
        check_true("avance predicho por instrucción y esperas",CPU.core_en===move && CPU.cache_stall===!move);
        check_true("PC IF predicho",CPU.pc===pc_expected);
        check_true("validez por fechas independientes",CPU.id_valid===valid_due[n+2] && CPU.id_ex_valid===valid_due[n+1] && CPU.ex_wb_valid===valid_due[n]);
        if(valid_due[n+2])check_true("PC ID predicho",CPU.id_pc===dpc[n+2]);
        if(valid_due[n+1])check_true("PC EX predicho",CPU.ex_pc===dpc[n+1]);
        check_true("BRU y excepción contra programa",CPU.branch_flush===jump_now && CPU.crypto_fault===fault_now);
        check_true("petición LSU conocida",(CPU.mem_re || CPU.mem_we)===req);
        if(jump_now || fault_now)check_true("destino dirigido",CPU.redirect_pc===(fault_now?TRAP_VECTOR:dest[ix]));
        check_true("finalización en flanco exacto",observed_complete===(move && valid_due[n]));
        check_true("máscara WB conocida",observed_mask===(valid_due[n]?dmask[n]:4'b0));
        check_true("memoria del flanco aplicado",observed_memory===!move);
        check_true("recuperación por fecha causal",observed_recovery===rec_now);
        if(measuring)begin
            ec++;if(!move)em++;
            else begin
                if(valid_due[n])begin eb++;ei+=pop(dmask[n]);end
                if(rec_now)er++;
            end
        end
        finish_now=move && faults==1 && visits[1023]==1 && rec_due[n] && n==last_branch+2;
        if(!move)begin waited++;stalls++;if(jump_now)held++;end
        else begin
            a=n;waited=0;if(req)accesses++;
            if(valid_due[n])begin
                check_true("serie WB sin duplicados",series[n]>last_serial);last_serial=series[n];
                if(dmask[n]==0)nops++;
            end
            // Los puertos GPR y DMEM describen efectos, nunca sirven de oráculo del conteo.
            for(int p=0;p<5;p++)if(CPU.wb_we[p])event_(1,8'(p),{27'd0,CPU.wb_waddr[p]},CPU.wb_wdata[p]);
            if(CPU.dmem_we)event_(2,{4'd0,CPU.dmem_be},CPU.dmem_addr,CPU.dmem_wdata);
            if(CPU.dmem_we_b)event_(3,0,CPU.dmem_addr_b,CPU.dmem_wdata_b);
            if(CPU.redirect)event_(fault_now?5:4,0,CPU.ex_pc,CPU.redirect_pc);
            if(valid_due[n+1])visits[ix]++;
            if(jump_now || fault_now)begin
                if(fault_now)begin faults++;valid_due[n+1]=0;dmask[n+1]=0;end
                else begin taken++;last_branch=n;rec_due[n+1]=1;rec_due[n+2]=1;end
                valid_due[n+2]=0;dmask[n+2]=0;valid_due[n+3]=0;dmask[n+3]=0;
                pc_expected=fault_now?TRAP_VECTOR:dest[ix];
            end else begin
                valid_due[n+3]=1;dmask[n+3]=pmask[(pc_expected>>4)&1023];dpc[n+3]=pc_expected;
                serial++;series[n+3]=serial;pc_expected+=16;
            end
        end
        check_true("escrituras GPR pasivas",{CPU.wb_we,CPU.wb_waddr,CPU.wb_wdata}==={SHADOW.wb_we,SHADOW.wb_waddr,SHADOW.wb_wdata});
        check_true("DMEM y redirecciones pasivas",{CPU.dmem_we,CPU.dmem_be,CPU.dmem_addr,CPU.dmem_wdata,CPU.dmem_we_b,CPU.dmem_addr_b,CPU.dmem_wdata_b,CPU.redirect,CPU.redirect_pc}===
                   {SHADOW.dmem_we,SHADOW.dmem_be,SHADOW.dmem_addr,SHADOW.dmem_wdata,SHADOW.dmem_we_b,SHADOW.dmem_addr_b,SHADOW.dmem_wdata_b,SHADOW.redirect,SHADOW.redirect_pc});
    end else measuring=0;
    if(!done || reset)trace_("PRE");
endtask

task automatic post;
    int differences;
    if(reset || !done)begin
        check_true("cinco acumulados completos",observed_cycles===ec && bundles===eb && instructions===ei && memories===em && branches===er);
        check_true("penalizaciones acotadas",{1'b0,memories}+{1'b0,branches}<={1'b0,cycles});
        for(int i=0;i<32;i++)check_true($sformatf("GPR x%0d pasivo",i),CPU.REGFILE.regs[i]===SHADOW.REGFILE.regs[i]);
        check_true("estado público y reloj pasivos",{CPU.pc,CPU.crypto_estado,CPU.trap_pc,CPU.trap_count,CPU.core_clk}===
                   {SHADOW.pc,SHADOW.crypto_estado,SHADOW.trap_pc,SHADOW.trap_count,SHADOW.core_clk});
        if(reset)check_true("reset de diagnóstico y núcleo",!complete && !recovery && !memory_wait && CPU.pc===0);
        else check_true("PC posterior al flanco",CPU.pc===pc_expected);
        trace_("POST");
        if(finish_now)begin
            for(int i=0;i<32;i++)regs_saved[i]=CPU.REGFILE.regs[i];
            differences=0;
            for(int i=0;i<16384;i++)begin mem_saved[i]=CPU.DMEM.mem[i];if(CPU.DMEM.mem[i]!==SHADOW.DMEM.mem[i])differences++;end
            check("DMEM completa frente a sombra sin instrumentación",differences,0);
            pc_saved=CPU.pc;state_saved=CPU.crypto_estado;trap_saved=CPU.trap_pc;count_saved=CPU.trap_count;done=1;
            $display("D4B1 caso=%0d config=%0d reales=%0d avances=%0d accesos=%0d stalls=%0d ciclos=%0d bundles=%0d instrucciones=%0d memoria=%0d BRU=%0d tomados=%0d excepciones=%0d efectos=%0d",
                      scenario,CONFIG,c,a,accesses,stalls,cycles,bundles,instructions,memories,branches,taken,faults,event_count);
        end
    end
    if(tb_errors!=errors_before)begin
        $display("PRIMERA DIVERGENCIA D4B1 caso=%0d config=%0d ciclo=%0d avance=%0d n=%0d",scenario,CONFIG,c,a,n);
        $fclose(fd);$fclose(ef);$fatal(1,"fallo de referencia independiente D4-B1");
    end
endtask
initial begin
    if($value$plusargs("mutacion=%d",mutation))if(mutation<0 || mutation>9)$fatal(1,"mutación fuera de 0..9");
    fd=$fopen($sformatf("d4b1-config%0d.csv",CONFIG),"w");ef=$fopen($sformatf("d4b1-efectos%0d.csv",CONFIG),"w");
    if(!fd || !ef)$fatal(1,"no se pudo abrir evidencia");
    $fdisplay(fd,"caso,ciclo,avances,fase,reset,medir,core_advance,pc_if,pc_id,pc_ex,id_valid,ex_valid,wb_valid,complete,mask,memory_stall,recovery,cycles,bundles,instructions,memory_count,branch_count,esp_cycles,esp_bundles,esp_instructions,esp_memory,esp_branch,fecha,serie_wb");
    $fdisplay(ef,"caso,indice,avance,tipo,puerto,direccion,dato");
end
endmodule

module tb_perf_vliw_monitor_d4b1;
`include "tb_utils.svh"
logic clk=0,reset=1;
perf_real_d4b1 #(.CONFIG(0)) REF (.clk(clk),.reset(reset));
perf_real_d4b1 #(.MODE(1),.WAIT(1),.CONFIG(1)) DUT1 (.clk(clk),.reset(reset));
perf_real_d4b1 #(.MODE(1),.WAIT(4),.CONFIG(4)) DUT4 (.clk(clk),.reset(reset));

// Esta instancia abstracta comprueba marcas no cero retenidas, inalcanzables
// por stalls LSU sobre un EX vacío. Solo sus puertos se estimulan; no hay top.
logic ac=0,ar=1,am=0,aa=0,aiv=0,aex=0,ataken=0,afault=0;
logic [127:0] aid=0;
logic [63:0] cy,bu,ins,me,pe;
logic bc,rc,mc;
perf_vliw_monitor ABSTRACT (
    .clk(ac),.reset(ar),.measure_enable(am),.core_advance(aa),.id_valid(aiv),.id_bundle(aid),
    .ex_valid(aex),.ex_branch_taken(ataken),.ex_exception(afault),
    .cycle_count(cy),.bundle_count(bu),.instruction_count(ins),.memory_stall_count(me),
    .branch_penalty_count(pe),.bundle_complete(bc),.branch_recovery(rc),.memory_stall(mc),.wb_non_nop_mask());

task automatic tick;
    clk=0;#4;REF.pre();DUT1.pre();DUT4.pre();#1;clk=1;#1;
    REF.post();DUT1.post();DUT4.post();clk=0;#5;
endtask

task automatic start_case(input int p);
    reset=1;tick();REF.prepare(p);DUT1.prepare(p);DUT4.prepare(p);
    // Un flanco más con reset después de cargar el programa: la ROM síncrona lee el bundle 0 en ese flanco.
    tick();reset=0;
endtask

`define SAME(D) \
    for(int i=0;i<32;i++)check_true($sformatf("GPR x%0d a igual progreso",i),D.regs_saved[i]===REF.regs_saved[i]); \
    begin int dif;dif=0;for(int i=0;i<16384;i++)if(D.mem_saved[i]!==REF.mem_saved[i])dif++; \
        check("65536 bytes a igual progreso",dif,0);end \
    check_true("PC y estado público equivalentes",{D.pc_saved,D.state_saved,D.trap_saved,D.count_saved}=== \
               {REF.pc_saved,REF.state_saved,REF.trap_saved,REF.count_saved}); \
    check("misma cantidad de efectos",D.event_count,REF.event_count); \
    for(int e=0;e<REF.event_count;e++)check_true($sformatf("efecto %0d en orden",e), \
        D.effects[e]===REF.effects[e] && D.event_progress[e]==REF.event_progress[e]); \
    check_true("mismo progreso y ocho accesos únicos",D.a==REF.a && D.accesses==8); \
    check_true("tiempo contrastado después de verificar cada espera",D.stalls==8*D.WAIT && D.c-REF.c==D.stalls); \
    check_true("BRU retenida no crea aceptaciones repetidas",D.held>0 && D.taken==5);

// El resultado esperado de cada paso es explícito y no lee registros internos
// de ABSTRACT. Se comprueba recuperación PRE y acumulados completos después de NBA.
task automatic astep(input bit rst,move_,iv_,input logic [3:0] m_,input bit ex_,taken_,fault_,enabled_,
                     input int ec_,eb_,ei_,em_,er_,input bit rec_);
    ac=0;ar=rst;aa=move_;aiv=iv_;aex=ex_;ataken=taken_;afault=fault_;am=enabled_;aid=0;
    if(m_[0])aid[31:0]=32'h80000801;
    if(m_[1])aid[63:32]=32'h92000000;
    if(m_[2])aid[95:64]=32'h96000000;
    if(m_[3])aid[127:96]=32'h04600000;
    #4;check_true("abstracto: oportunidad causal antes del flanco",rc===rec_);
    ac=1;#1;
    check_true("abstracto: cinco acumulados de 64 bits",cy===64'(ec_) && bu===64'(eb_) && ins===64'(ei_) && me===64'(em_) && pe===64'(er_));
    ac=0;#5;
endtask

initial begin
    if($test$plusargs("vcd"))begin
        $dumpfile("d4b1.vcd");
        $dumpvars(0,clk,reset,REF.cycles,REF.bundles,REF.branches,DUT1.cycles,DUT1.memories,
                  DUT4.cycles,DUT4.memories,DUT4.branches,DUT4.complete,DUT4.mask,DUT4.recovery,
                  DUT4.CPU.pc,DUT4.CPU.core_en,ac,ar,aa,rc,cy,bu,pe);
    end
    #1;
    for(int p=0;p<4;p++)begin
        tb_section($sformatf("Programa reducido real, ventana %0d",p));start_case(p);
        begin int deadline;deadline=0;
            while(!(REF.done && DUT1.done && DUT4.done) && deadline<180)begin tick();deadline++;end
            check_true("tres puntos equivalentes alcanzados",REF.done && DUT1.done && DUT4.done);
        end
        `SAME(DUT1)
        `SAME(DUT4)
        check_true("oráculos ALU y loads N+3",REF.regs_saved[2]===0 && REF.regs_saved[6]===77 && REF.regs_saved[7]===77 && REF.regs_saved[8]===78);
        check_true("enlace, destino y WB anterior a excepción",REF.regs_saved[11]===304 && REF.regs_saved[9]===9 && REF.regs_saved[13]===13);
        check_true("culpable y jóvenes sin efectos",REF.regs_saved[20]===0 && REF.regs_saved[21]===0 && REF.regs_saved[22]===0 && REF.regs_saved[25]===0);
        check_true("palabra, byte y stores anulados",REF.mem_saved[0]===77 && REF.mem_saved[1]===32'h4d00 && REF.mem_saved[2]===0 &&
                   REF.mem_saved[3]===32'hfeed0003 && REF.mem_saved[4]===32'hfeed0004 && REF.mem_saved[5]===32'hfeed0005 && REF.mem_saved[6]===32'hfeed0006);
        check_true("excepción y manejador",REF.trap_saved===352 && REF.count_saved===1 && REF.regs_saved[30]===99);
        if(p==0)check_true("diez recuperaciones completas en las tres configuraciones",REF.branches==10 && DUT1.branches==10 && DUT4.branches==10);
        if(p==3)check_true("ventana vacía preserva cero",REF.cycles==0 && DUT1.cycles==0 && DUT4.cycles==0);
    end

    tb_section("Reset real con store pendiente, sin cambiar la política de memoria");
    start_case(0);
    while(DUT4.stalls==0)tick();
    check_true("store realmente detenido",DUT4.CPU.mem_we && DUT4.CPU.cache_stall);
    reset=1;tick();check("store puede publicarse durante reset",DUT4.CPU.DMEM.mem[0],77);
    reset=0;repeat(6)tick();
    tb_section("Reset real con recuperación pendiente");start_case(0);
    while(!DUT4.recovery)tick();reset=1;tick();reset=0;repeat(6)tick();
    check_true("sin recuperación antigua tras reset",DUT4.branches==0);

    tb_section("Retención abstracta de dos marcas BRU y reset sin avance");
    astep(1,0,0,0,0,1,1,1,0,0,0,0,0,0);
    astep(0,1,1,1,0,0,0,1,1,0,0,0,0,0);
    astep(0,1,1,4,1,0,0,1,2,0,0,0,0,0);
    astep(0,1,1,3,1,1,0,1,3,1,1,0,0,0);
    // Las cuatro esperas no consumen ninguna de las dos marcas causales.
    for(int t=1;t<=4;t++)astep(0,0,0,0,0,1,0,1,3+t,1,1,t,0,0);
    astep(0,1,0,0,0,0,0,1,8,2,2,4,1,1);
    // Otras tres esperas interrumpen la recuperación entre la primera y segunda posición.
    for(int t=1;t<=3;t++)astep(0,0,1,8,0,0,0,1,8+t,2,2,4+t,1,0);
    astep(0,1,1,8,0,0,0,1,12,2,2,7,2,1);
    astep(0,1,0,0,1,0,0,1,13,2,2,7,2,0);
    astep(0,1,0,0,0,0,0,1,14,3,3,7,2,0);
    astep(0,1,1,4,0,0,0,1,15,3,3,7,2,0);
    astep(0,1,1,1,1,1,0,1,16,3,3,7,2,0);
    astep(1,0,0,0,0,0,0,1,0,0,0,0,0,0);
    astep(0,1,0,0,0,1,1,1,1,0,0,0,0,0); // Controles en EX inválido se ignoran.
    // Raw BRU y excepción simultáneos: prioridad de excepción y culpable anulado.
    astep(0,1,1,15,0,0,0,1,2,0,0,0,0,0);
    astep(0,1,1,1,1,1,1,1,3,0,0,0,0,0);
    astep(0,1,0,0,0,0,0,1,4,0,0,0,0,0);
    astep(0,1,0,0,0,0,0,1,5,0,0,0,0,0);
    // Otra época hace completar las cuatro operaciones y comprueba una pausa real.
    astep(1,1,0,0,0,0,0,0,0,0,0,0,0,0);
    astep(0,1,1,15,0,0,0,0,0,0,0,0,0,0);
    astep(0,1,0,0,1,0,0,0,0,0,0,0,0,0);
    astep(0,1,0,0,0,0,0,1,1,1,4,0,0,0);
    check_true("observadores reales sin errores",REF.tb_errors==0 && DUT1.tb_errors==0 && DUT4.tb_errors==0);
    $fclose(REF.fd);$fclose(DUT1.fd);$fclose(DUT4.fd);$fclose(REF.ef);$fclose(DUT1.ef);$fclose(DUT4.ef);
    tb_checks+=REF.tb_checks+DUT1.tb_checks+DUT4.tb_checks;
    tb_finish("tb_perf_vliw_monitor_d4b1");
end
endmodule
