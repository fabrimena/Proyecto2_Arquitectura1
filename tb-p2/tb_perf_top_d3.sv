/* Valida A–D2 sobre top real con memoria directa y una referencia de eventos por fecha. */
`timescale 1ns/1ps
`include "isa_defs.sv"
module tb_perf_top_d3;
`include "tb_utils.svh"

logic clk=0, reset=1, measure_enable=0;
top #(.MEM_MODE(0)) DUT (.clk(clk),.reset(reset),.debug_result(),.debug_rd(),.debug_write());
// REF recibe el mismo programa y horizonte, sin conexiones de instrumentación.
top #(.MEM_MODE(0)) REF (.clk(clk),.reset(reset),.debug_result(),.debug_rd(),.debug_write());
logic [3:0] id_mask, ex_mask, wb_mask;
logic ex_valid,wb_valid,bundle_complete;
logic [1:0] ex_cause,wb_cause;
logic [63:0] cycles,bundles,instructions,memory_cycles,branch_cycles;
wire advance=DUT.core_en;
wire taken=DUT.id_ex_valid && DUT.branch_flush;
wire fault=DUT.id_ex_valid && DUT.crypto_fault;
perf_slot_mask CLASSIFIER (.bundle_in(DUT.id_bundle),.non_nop_mask(id_mask));
perf_pipeline_monitor MONITOR (
    .clk(clk),.reset(reset),.advance(advance),.id_valid(DUT.id_valid),.id_non_nop_mask(id_mask),
    .ex_branch_taken(taken),.ex_exception(fault),.ex_valid(ex_valid),.ex_non_nop_mask(ex_mask),
    .ex_cancel_cause(ex_cause),.wb_valid(wb_valid),.wb_non_nop_mask(wb_mask),
    .wb_cancel_cause(wb_cause),.bundle_complete(bundle_complete));
// Flush es un evento, no una duración. D4 decidirá cómo atribuir penalizaciones.
perf_counters COUNTERS (
    .clk(clk),.reset(reset),.measure_enable(measure_enable),.bundle_complete(bundle_complete),
    .non_nop_mask(wb_mask),.memory_stall(1'b0),.branch_recovery(1'b0),
    .cycle_count(cycles),.bundle_count(bundles),.instruction_count(instructions),
    .memory_stall_count(memory_cycles),.branch_penalty_count(branch_cycles));

localparam int MAX_DUE=512;
logic [127:0] programa [0:1023];
logic [3:0] mascara [0:1023];
int control_esperado [0:1023]; // 0 normal, 1 tomado, 2 no tomado, 3 excepción, 4 bucle dirigido.
int visitas [0:1023];
logic [31:0] destino_esperado [0:1023];
bit valido [0:MAX_DUE-1];
logic [3:0] mask_fecha [0:MAX_DUE-1];
int causa [0:MAX_DUE-1];
logic [31:0] pc_fecha [0:MAX_DUE-1];
int serie_fecha [0:MAX_DUE-1];
int c=0,serie=0,ultima_serie=0,caso=0;
logic [63:0] ref_cycles=0,ref_bundles=0,ref_instructions=0;
int anulados_salto=0,anulados_fault=0,finales_nop=0,finales_store=0,finales_bru=0;
int fuera_ventana=0,slots4=0,excepciones=0,tomados=0,no_tomados=0,pares_crypto=0;
integer logfd;

function automatic logic [127:0] b(input logic [31:0] a,l,j,k); return {k,j,l,a}; endfunction
function automatic logic [31:0] ai(input int rd,rs,imm);
    return {TYPE_IMM,OP_SUMI,5'(rs),5'(rd),11'(imm)};
endfunction
function automatic logic [31:0] ls(input logic [3:0] op,input int base,reg_,off);
    return {TYPE_LSU,op,5'(base),5'(reg_),11'(off)};
endfunction
function automatic logic [31:0] br(input logic [3:0] op,input int a,z,off);
    return {TYPE_BRU_COND,op,5'(a),5'(z),11'(off)};
endfunction
function automatic logic [31:0] jump(input int rd,off);
    return {TYPE_BRU_JUMP,OP_SYE,5'(rd),16'(off)};
endfunction
function automatic logic [31:0] jr(input int rd,rs,off);
    return {TYPE_BRU_JUMP,OP_SYER,5'(rd),5'(rs),11'(off)};
endfunction
function automatic logic [31:0] fsl(input logic [3:0] op,input int rd,rs);
    return {TYPE_CRYPTO,op,2'd0,2'd0,5'(rd),5'(rs),7'd0};
endfunction
function automatic int pop(input logic [3:0] m);
    return int'(m[0])+int'(m[1])+int'(m[2])+int'(m[3]);
endfunction

task automatic limpiar_referencia;
    c=0;serie=0;ultima_serie=0;ref_cycles=0;ref_bundles=0;ref_instructions=0;
    for(int i=0;i<MAX_DUE;i++)begin
        valido[i]=0;mask_fecha[i]=0;causa[i]=0;pc_fecha[i]=0;serie_fecha[i]=0;
    end
    for(int i=0;i<1024;i++)visitas[i]=0;
endtask

// Cada IF realmente admitido recibe fecha c+3 y número de secuencia propio.
// La máscara procede de una tabla declarada al construir el programa, nunca
// de CLASSIFIER o MONITOR. Solo se transportan eventos, no resultados ISA.
task automatic flanco;
    int ix,k,origen;
    bit salto,fallo;
    logic [3:0] expected_id;
    clk=0;#4;
    if(reset)begin
        limpiar_referencia();
        check_true("reset inhibe evento combinacional",bundle_complete===1'b0);
    end else begin
        c++;
        if(c+4>=MAX_DUE)$fatal(1,"referencia sin capacidad");
        check_true("MEM_MODE=0 nunca congela",DUT.cache_stall===0 && advance===1);
        check_true("ID real coincide con admisión previa",DUT.id_valid===valido[c+2]);
        expected_id=DUT.id_valid?mascara[(DUT.id_pc>>4)&1023]:4'b0;
        check_true("clasificación ID contra tabla independiente",id_mask===expected_id);
        if(DUT.id_valid)begin
            check_true("PC ID en orden",DUT.id_pc===pc_fecha[c+2]);
            check_true("bundle ID exacto",DUT.id_bundle===programa[(DUT.id_pc>>4)&1023]);
        end
        check_true("validez EX real",DUT.id_ex_valid===valido[c+1]);
        if(DUT.id_ex_valid)check_true("PC EX real",DUT.ex_pc===pc_fecha[c+1]);
        check_true("WB real y referencia",DUT.ex_wb_valid===valido[c]);
        check_true("evento PRE: consumir WB, sin adelantar ni retrasar",bundle_complete===valido[c]);
        check_true("máscara PRE del WB que finaliza",wb_mask===(valido[c]?mask_fecha[c]:4'b0));
        if(valido[c])begin
            check_true("secuencia de finalizaciones sin duplicación",serie_fecha[c]>ultima_serie);
            ultima_serie=serie_fecha[c];
            finales_nop+=(mask_fecha[c]==0);
            finales_store+=mask_fecha[c][1] &&
                (programa[(pc_fecha[c]>>4)&1023][56:53]==OP_GUARDAP ||
                 programa[(pc_fecha[c]>>4)&1023][56:53]==OP_GUARDAB);
            finales_bru+=mask_fecha[c][2];slots4+=(mask_fecha[c]==15);
            if(!measure_enable)fuera_ventana++;
        end
        if(measure_enable)begin
            ref_cycles++;
            if(valido[c])begin ref_bundles++;ref_instructions+=pop(mask_fecha[c]);end
        end
        salto=0;fallo=0;
        if(DUT.id_ex_valid)begin
            ix=(DUT.ex_pc>>4)&1023;visitas[ix]++;
            k=control_esperado[ix];
            salto=(k==1 || (k==4 && visitas[ix]<=3));fallo=(k==3);
            check_true("BRU tomada contra programa dirigido",DUT.branch_flush===salto);
            check_true("excepción contra programa dirigido",DUT.crypto_fault===fallo);
            if(salto)check_true("destino BRU contra tabla del programa",DUT.redirect_pc===destino_esperado[ix]);
            if(fallo)check_true("destino de excepción",DUT.redirect_pc===TRAP_VECTOR);
            if(k==2 || (k==4 && !salto))no_tomados++;
            if(k==3)begin
                check_true("excepción suprime BRU del mismo bundle",DUT.ex_bru_is_jump && !DUT.branch_flush);
                excepciones++;
            end
        end
        check_true("redirect separa salto de excepción",DUT.redirect===(salto||fallo));
        // Las cancelaciones se aplican por edad: EX culpable solo ante fault,
        // ID joven ante cualquier redirect; IF descartado no se admite.
        if(fallo)begin valido[c+1]=0;mask_fecha[c+1]=0;causa[c+1]=2;anulados_fault++;end
        if(salto || fallo)begin
            if(valido[c+2])begin
                if(fallo)anulados_fault++;else anulados_salto++;
            end
            valido[c+2]=0;mask_fecha[c+2]=0;causa[c+2]=fallo?2:1;
            valido[c+3]=0;mask_fecha[c+3]=0;causa[c+3]=fallo?2:1;
            if(salto)tomados++;
        end else begin
            valido[c+3]=DUT.fetch_valid;
            if(DUT.fetch_valid)begin
                ix=(DUT.fetch_pc>>4)&1023;serie++;
                mask_fecha[c+3]=mascara[ix];pc_fecha[c+3]=DUT.fetch_pc;serie_fecha[c+3]=serie;
                check_true("IF contiene el programa esperado",DUT.fetch_bundle===programa[ix]);
            end
        end
        if(DUT.wb_we[3] && DUT.wb_we[4])begin
            pares_crypto++;
            check_true("dos salidas cripto pertenecen a una instrucción de slot 3",valido[c] && mask_fecha[c][3]);
        end
        // Se comparan los cinco puertos antes de que el banco consuma WB.
        check_true("puertos WB pasivos",{DUT.wb_we,DUT.wb_waddr,DUT.wb_wdata}===
                   {REF.wb_we,REF.wb_waddr,REF.wb_wdata});
        check_true("efectos de memoria pasivos",{DUT.dmem_we,DUT.dmem_be,DUT.dmem_addr,DUT.dmem_wdata,
                   DUT.dmem_we_b,DUT.dmem_addr_b,DUT.dmem_wdata_b}===
                   {REF.dmem_we,REF.dmem_be,REF.dmem_addr,REF.dmem_wdata,
                    REF.dmem_we_b,REF.dmem_addr_b,REF.dmem_wdata_b});
        check_true("redirecciones pasivas",{DUT.redirect,DUT.redirect_pc}==={REF.redirect,REF.redirect_pc});
        $fdisplay(logfd,"%0d,%0d,PRE,%0d,%0d,%h,%0d,%h,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h,%h,%h",caso,c,measure_enable,
                  DUT.id_valid,DUT.id_pc,DUT.id_ex_valid,DUT.ex_pc,bundle_complete,wb_mask,ref_cycles,ref_bundles,ref_instructions,
                  DUT.branch_flush,DUT.crypto_fault,DUT.redirect,DUT.redirect_pc,pc_fecha[c],
                  valido[c]?mask_fecha[c]:4'b0,DUT.wb_we);
    end
    clk=1;#1;
    // NBA ya publicó EX/WB nuevos. No se trata esta elegibilidad nueva como
    // otra finalización en el mismo flanco: el contador consumió el WB anterior.
    check_true("reloj real avanzó",DUT.core_clk===1);
    check_true("metadatos alineados con registros reales después de NBA",
               ex_valid===DUT.id_ex_valid && wb_valid===DUT.ex_wb_valid);
    check_true("EX posterior",ex_valid===valido[c+2] && ex_mask===(valido[c+2]?mask_fecha[c+2]:4'b0));
    check_true("WB posterior",wb_valid===valido[c+1] && wb_mask===(valido[c+1]?mask_fecha[c+1]:4'b0));
    check_true("causa EX posterior",ex_cause===2'(causa[c+2]));
    check_true("causa WB posterior",wb_cause===2'(causa[c+1]));
    check_true("evento POST elegible para el próximo flanco",bundle_complete===(!reset && valido[c+1]));
    check_true("contador ciclos de 64 bits",cycles===ref_cycles);
    check_true("contador bundles de 64 bits",bundles===ref_bundles);
    check_true("contador instrucciones de 64 bits",instructions===ref_instructions);
    check_true("D3 no atribuye stalls o penalizaciones",memory_cycles===64'd0 && branch_cycles===64'd0);
    for(int r=0;r<32;r++)check_true($sformatf("GPR x%0d pasivo",r),DUT.REGFILE.regs[r]===REF.REGFILE.regs[r]);
    check_true("estado público pasivo",{DUT.pc,DUT.crypto_estado,DUT.trap_count,DUT.trap_pc}===
               {REF.pc,REF.crypto_estado,REF.trap_count,REF.trap_pc});
    $fdisplay(logfd,"%0d,%0d,POST,%0d,%0d,%h,%0d,%h,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h,%h,%h",caso,c,measure_enable,
              DUT.id_valid,DUT.id_pc,DUT.id_ex_valid,DUT.ex_pc,bundle_complete,wb_mask,cycles,bundles,instructions,
              DUT.branch_flush,DUT.crypto_fault,DUT.redirect,DUT.redirect_pc,pc_fecha[c+1],
              valido[c+1]?mask_fecha[c+1]:4'b0,DUT.wb_we);
    clk=0;#5;
endtask

task automatic cargar(input int pos,input logic [127:0] palabra,input logic [3:0] mask,input int kind);
    programa[pos]=palabra;mascara[pos]=mask;control_esperado[pos]=kind;
    DUT.IMEM.memory[pos]=palabra;REF.IMEM.memory[pos]=palabra;
endtask

task automatic preparar(input int numero);
    reset=1;measure_enable=0;flanco();flanco();caso=numero;
    for(int i=0;i<1024;i++)begin cargar(i,128'b0,0,0);destino_esperado[i]=0;end
    // Preparación de memorias de entrada documentada; ningún GPR ni registro
    // del pipeline se escribe desde el testbench durante la ejecución.
    for(int i=0;i<DMEM_BYTES/4;i++)begin DUT.DMEM.mem[i]=0;REF.DMEM.mem[i]=0;end
endtask

task automatic comparar_memoria;
    int distintos;distintos=0;
    for(int i=0;i<DMEM_BYTES/4;i++)if(DUT.DMEM.mem[i]!==REF.DMEM.mem[i])begin
        if(distintos==0)$display("Primera diferencia DMEM palabra %0d",i);
        distintos++;
    end
    check("DMEM completa: 16384 palabras / 65536 bytes",distintos,0);
    if(cycles==0)$display("D3 CASO %0d: IPC NO DEFINIDO, ciclos=0",caso);
    else $display("D3 CASO %0d: ciclos=%0d bundles=%0d instrucciones=%0d IPC=%0.9f",caso,cycles,bundles,instructions,
                  real'(instructions)/real'(cycles));
endtask

task automatic ejecutar(input int cuantos);
    // Un flanco más con reset después de cargar el programa: la ROM síncrona lee el bundle 0 en ese flanco.
    if(reset)flanco();
    reset=0;measure_enable=1;
    repeat(cuantos)flanco();comparar_memoria();
endtask

initial begin
    logfd=$fopen("d3-eventos.csv","w");if(!logfd)$fatal(1,"no se pudo abrir evidencia");
    $fdisplay(logfd,"caso,ciclo,fase,medir,id_valid,id_pc,ex_valid,ex_pc,complete,wb_mask,ciclos,bundles,instrucciones,branch_flush,crypto_fault,redirect,target,expected_wb_pc,expected_mask,wb_we");
    if($test$plusargs("vcd"))begin
        $dumpfile("d3.vcd");$dumpvars(0,clk,reset,measure_enable,id_mask,ex_mask,wb_mask,bundle_complete,
                                     cycles,bundles,instructions,DUT.pc,DUT.id_pc,DUT.ex_pc);
    end
    #1;
    preparar(1);
    tb_section("ALU consecutivas, x0 y dependencia N+3");
    for(int i=0;i<32;i++)cargar(i,b(ai(i%24,0,i+1),0,0,0),1,0);
    cargar(32,b(ai(27,1,5),0,0,0),1,0);
    ejecutar(44);
    check("32 bundles útiles consecutivos más dependencia",instructions,33);
    check("NOP válidos también completan",bundles,41);
    check("dependencia sobre x1",DUT.REGFILE.regs[27],31);
    check("x0 se conserva y su operación sí cuenta",DUT.REGFILE.regs[0],0);

    preparar(2);tb_section("LSU, varios slots y salto no tomado");
    cargar(0,b(ai(2,0,77),0,0,0),1,0);cargar(1,b(ai(3,0,1),0,0,0),1,0);
    cargar(3,b(ai(4,0,9),ls(OP_GUARDAP,0,2,4),0,0),3,0);
    cargar(4,b(0,ls(OP_GUARDAB,0,3,5),0,0),2,0);
    cargar(5,b(0,ls(OP_CARGAI,0,5,4),0,0),2,0);
    cargar(6,b(0,ls(OP_CARGABAI,0,6,5),0,0),2,0);
    cargar(7,b(ai(0,0,9),0,br(OP_IGUALNO,0,0,32),0),5,2);
    cargar(8,b(ai(7,5,1),0,0,0),1,0);
    ejecutar(20);
    check("palabra con actualización de byte",DUT.DMEM.mem[1],333);
    check("load palabra",DUT.REGFILE.regs[5],333);check("load byte",DUT.REGFILE.regs[6],1);
    check("load N+3 alimenta ALU",DUT.REGFILE.regs[7],334);check("LSU sin omitir stores",instructions,10);

    preparar(3);tb_section("Bucle acotado, sye y syer con enlaces");
    cargar(0,b(ai(2,0,4),0,0,0),1,0);cargar(3,b(ai(2,2,-1),0,0,0),1,0);
    cargar(6,b(0,0,br(OP_MENORA,0,2,-48),0),4,4);
    cargar(7,b(0,0,jump(10,48),0),4,1);
    cargar(8,b(ai(20,0,99),0,0,0),1,0);cargar(9,b(ai(21,0,99),0,0,0),1,0);
    cargar(10,b(ai(12,0,240),0,0,0),1,0);cargar(13,b(0,0,jr(11,12,0),0),4,1);
    cargar(14,b(ai(22,0,99),0,0,0),1,0);cargar(15,b(ai(13,0,55),0,0,0),1,0);
    destino_esperado[6]=48;destino_esperado[7]=160;destino_esperado[13]=240;
    ejecutar(70);
    check("bucle termina tras cuatro decrementos",DUT.REGFILE.regs[2],0);
    check("enlace sye",DUT.REGFILE.regs[10],128);check("enlace syer",DUT.REGFILE.regs[11],224);
    check("destino syer",DUT.REGFILE.regs[13],55);
    check("jóvenes de saltos anulados",DUT.REGFILE.regs[20]|DUT.REGFILE.regs[21]|DUT.REGFILE.regs[22],0);
    check("instrucciones con saltos incluidos",instructions,13);

    preparar(4);tb_section("CRIPTO autorizado, dos salidas GPR y cuatro slots");
    cargar(0,b(0,0,0,{TYPE_CRYPTO,OP_SETPWD,16'd0,5'd0}),8,0);
    cargar(3,b(0,0,0,{TYPE_CRYPTO,OP_VCR,16'd0,5'd0}),8,0);
    cargar(6,b(0,0,0,{TYPE_CRYPTO,OP_ELL,2'd0,2'd0,5'd0,5'd0,7'd0}),8,0);
    cargar(9,b(ai(4,0,11),ls(OP_CARGAI,0,6,0),br(OP_IGUALNO,0,0,32),fsl(OP_FSL,8,0)),15,2);
    cargar(10,b(ai(7,0,6),ls(OP_GUARDAP,0,0,12),br(OP_IGUALNO,0,0,32),0),7,2);
    cargar(12,b(0,0,0,fsl(OP_FSLI,10,8)),8,0);
    cargar(13,b(0,0,0,{TYPE_CRYPTO,OP_CAMCON,16'd0,5'd1}),8,0);
    ejecutar(24);
    check("crypto representa una instrucción por slot",instructions,12);
    check("cuatro slots conservan ALU",DUT.REGFILE.regs[4],11);
    check("estado autorizado con INIT consumido",DUT.crypto_estado,1);
    check("Feistel con par y llave cero",DUT.REGFILE.regs[8]|DUT.REGFILE.regs[9]|DUT.REGFILE.regs[10]|DUT.REGFILE.regs[11],0);

    preparar(5);tb_section("Excepción cancela EX e ID, conserva WB anterior");
    DUT.DMEM.mem[1]=32'hf00d;REF.DMEM.mem[1]=32'hf00d;
    cargar(0,b(ai(2,0,77),0,0,0),1,0);
    cargar(1,b(ai(15,0,99),ls(OP_GUARDAP,0,0,4),jump(16,64),fsl(OP_FSL,18,0)),15,3);
    cargar(2,b(ai(20,0,90),0,0,0),1,0);cargar(3,b(ai(21,0,91),0,0,0),1,0);
    cargar(1023,b(0,0,jump(0,0),0),4,1);
    destino_esperado[1023]=TRAP_VECTOR;
    ejecutar(9);
    check("WB anterior sobrevivió",DUT.REGFILE.regs[2],77);
    check("EX e instrucciones jóvenes sin efectos",DUT.REGFILE.regs[15]|DUT.REGFILE.regs[16]|
          DUT.REGFILE.regs[18]|DUT.REGFILE.regs[19]|DUT.REGFILE.regs[20]|DUT.REGFILE.regs[21],0);
    check("store culpable no se publica",DUT.DMEM.mem[1],32'hf00d);
    check("una excepción real",DUT.trap_count,1);check("PC excepción",DUT.trap_pc,16);
    check("no completar bundle culpable ni burbujas",bundles,2);check("solo anterior y manejador",instructions,2);

    preparar(6);tb_section("NOP válidos, ventana tardía, pausa y reanudación");
    flanco();reset=0;
    for(int i=1;i<=20;i++)begin measure_enable=(i>=5 && i<=8)||(i>=15);flanco();end
    comparar_memoria();check("ventana suma diez ciclos",cycles,10);check("diez NOP completados",bundles,10);
    check("NOP no suma instrucciones",instructions,0);

    preparar(7);tb_section("Pausa con útiles pendientes y reset durante actividad");
    for(int i=0;i<32;i++)cargar(i,b(ai((i%24)+1,0,i+1),0,0,0),1,0);
    flanco();reset=0;
    for(int i=1;i<=20;i++)begin measure_enable=(i>=5 && i<=8)||(i>=15);flanco();end
    comparar_memoria();check("útiles solo al finalizar dentro de ventana",instructions,10);
    check("reanudar no repite eventos",bundles,10);
    reset=1;measure_enable=1;flanco();check_true("IPC queda no definido tras reset",cycles===0);
    comparar_memoria();reset=0;repeat(5)flanco();comparar_memoria();
    check("nueva época tras reset",cycles,5);check("dos completados tras llenado",bundles,2);
    check("reset no altera instrucciones posteriores",instructions,2);

    check_true("cobertura de NOP válidos",finales_nop>0);
    check_true("stores completados sin GPR",finales_store>=2);
    check_true("BRU completada sin depender de GPR",finales_bru>5);
    check_true("bundle con cuatro instrucciones",slots4>0);
    check_true("rondas cripto con dos escrituras reales",pares_crypto==2);
    check_true("excepción ejercitada",excepciones==1);
    check_true("anulaciones por ambas causas",anulados_salto>0 && anulados_fault>=2);
    check_true("completados mientras no se mide",fuera_ventana>0);
    check_true("saltos tomados y no tomados",tomados>0 && no_tomados>0);
    $display("D3 COBERTURA: NOP=%0d store=%0d BRU=%0d cuatro_slots=%0d anulados_salto=%0d anulados_fault=%0d fuera_ventana=%0d",
             finales_nop,finales_store,finales_bru,slots4,anulados_salto,anulados_fault,fuera_ventana);
    $fclose(logfd);tb_finish("tb_perf_top_d3");
end
endmodule
