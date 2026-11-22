/*
 * tb_perf_integracion_top: integración real de métricas #7/#8/#26.
 * Entradas: programas ISA, máscaras/control declarados y memorias preparadas.
 * Salidas: aserciones, CSV de métricas y diagnóstico de primera divergencia.
 * Cada configuración ejecuta CPU instrumentada y SHADOW con PERF_ENABLE=0,
 * con el mismo reloj/reset/ventana/flush. La sombra prueba pasividad; no es el
 * oráculo de instrucciones, validez, clases ni datos finales del programa.
 *
 * El modelo por identidades desplaza IF/ID/EX/WB en avances efectivos y aplica
 * saltos/excepción conocidos. Los eventos públicos PRE de L1-D son el contrato
 * de K1-A; K1-B se contrasta por fechas de la demanda arbitrada y pausas, sin
 * consultar sus acumulados ni privados de caché. Las clases dirigidas iniciales
 * se fijan por geometría/operaciones; otras admiten hit o miss sin inventar LRU.
 *
 * Los flancos manuales separan estímulo, PRE y POST-NBA. Solo se precargan IMEM
 * y DMEM durante reset; no se fuerza pipeline, bóveda ni contadores. El banco
 * compara modos a igual avance y compara instrumentación al mismo tiempo exacto.
 * La L2 sigue siendo l2_model: no certifica AMAT, L2 real, HALT ni instrucciones
 * D18. +VCD selecciona solo observación pública; los archivos pertenecen al cwd
 * externo de simulación. Los bucles acotados y watchdog convierten timeout en FAIL.
 */
`timescale 1ns/1ps
`include "isa_defs.sv"
`include "cache_defs.sv"

// Una pareja por configuración: MODE=0/1/2 y las dos ROM en modo2. La ventana
// es una entrada común de observación, nunca un permiso de ejecución del núcleo.
module perf_integracion_case #(parameter int MODE=0, SYNC=1, CFG=0)(
    input logic clk, reset, flush_req, maintenance,
    input integer scenario, policy
);
logic measuring=1;
wire flush_done, shadow_done;
top #(.MEM_MODE(MODE),.STALL_CYCLES(4),.ROM_SYNC(SYNC),.PERF_ENABLE(1)) CPU (
    .clk(clk),.reset(reset),.flush_req(flush_req),.flush_done(flush_done),
    .debug_result(),.debug_rd(),.debug_write(),.perf_measure_enable(measuring));
top #(.MEM_MODE(MODE),.STALL_CYCLES(4),.ROM_SYNC(SYNC),.PERF_ENABLE(0)) SHADOW (
    .clk(clk),.reset(reset),.flush_req(flush_req),.flush_done(shadow_done),
    .debug_result(),.debug_rd(),.debug_write(),.perf_measure_enable(measuring));

// Adaptación solo de lectura del banco. En modos sin L1-D los valores son cero,
// no hits/misses ficticios. Las referencias jerárquicas quedan en simulación.
wire [18:0] events;
wire [18:0][63:0] event_counts;
wire [4:0][63:0] access_totals;
wire cr,cw,cs,pend,elig;
wire [3:0][63:0] completed,service,waits;
wire [63:0] total,service_total,wait_total,excluded,errors,age,no_wait;
generate if(MODE==2)begin:g_cache_probe
    assign events=CPU.g_mem_cache.HIER.perf_events;
    assign event_counts=CPU.g_mem_cache.HIER.perf_event_counts;
    assign access_totals=CPU.g_mem_cache.HIER.perf_access_totals;
    assign {cr,cw,cs}={CPU.g_mem_cache.HIER.c_re,CPU.g_mem_cache.HIER.c_we,CPU.g_mem_cache.HIER.c_stall};
    assign completed=CPU.g_mem_cache.HIER.perf_completed_by_class;
    assign service=CPU.g_mem_cache.HIER.perf_service_by_class;
    assign waits=CPU.g_mem_cache.HIER.perf_wait_by_class;
    assign total=CPU.g_mem_cache.HIER.perf_completed_accesses;
    assign service_total=CPU.g_mem_cache.HIER.perf_service_cycles;
    assign wait_total=CPU.g_mem_cache.HIER.perf_wait_cycles;
    assign excluded=CPU.g_mem_cache.HIER.perf_excluded_accesses;
    assign errors=CPU.g_mem_cache.HIER.perf_protocol_errors;
    assign {pend,elig}={CPU.g_mem_cache.HIER.perf_pending,CPU.g_mem_cache.HIER.perf_pending_eligible};
    assign age=CPU.g_mem_cache.HIER.perf_pending_wait_cycles;
    assign no_wait=CPU.g_mem_cache.HIER.perf_no_wait_accesses;
end else begin:g_without_cache
    assign events=0; assign event_counts='0; assign access_totals='0;
    assign {cr,cw,cs}=0; assign completed='0; assign service='0; assign waits='0;
    assign {total,service_total,wait_total,excluded,errors,age,no_wait}='0;
    assign {pend,elig}=0;
end endgenerate

// Tablas y PC de referencia pertenecen al banco; masks/kind/targets se declaran
// al preparar cada programa. Las identidades de etapa se actualizan por avance,
// no por escrituras observadas ni por los acumulados que se están comprobando.
logic [127:0] words[0:1023];
logic [3:0] masks[0:1023];
integer kind[0:1023],visits[0:1023];
logic [31:0] targets[0:1023],gold_regs[0:31],gold_mem[0:16383];
logic [31:0] pc_ref=0,id_pc=0,ex_pc=0,wb_pc=0;
bit iv=0,xv=0,wv=0,done=0,move_,taken_,fault_,enable_,reset_;
integer cycle=0,advance=0,checks=0,fd,edge_count=0,edge_before=0;
bit rec_due[0:2047];
logic [63:0] ec=0,eb=0,ei=0,em=0,er=0;
logic [3:0][63:0] occ='0,bub='0,frozen='0,held='0;
logic [18:0][63:0] events_ref='0;
logic [3:0][63:0] cnt_ref='0,srv_ref='0,wait_ref='0;
// Fechas absolutas de la demanda arbitrada: F-S da espera y F-S+1 servicio.
// last_off prueba si una pausa cortó el intervalo. boundary exige reposo/final
// tras reset; la primera demanda no recibe elegibilidad inventada desde antes.
integer start_date=0,last_off=0,end_date=0,first_request=0;
bit boundary=0,pending_ref=0,eligible_ref=0;
logic [63:0] zero_ref=0,excluded_ref=0;
logic [31:0] saved_regs[0:31],saved_pc,saved_state,saved_traps;
integer retired_nop=0,retired_store=0,retired_four=0,crypto_pairs=0;
integer taken_count=0,false_count=0,fault_count=0,paused_stalls=0,paused_events=0;
integer partial_ends=0,consecutive=0,previous_end=0,flush_pushes=0,cache_ends=0;
integer captures=0;
logic [18:0] seen_events=0;

// Cuenta pulsos reales, no niveles POST: demuestra que el PRE core_en usado
// por las métricas decide exactamente si avanzaron los registros del núcleo.
always @(posedge CPU.core_clk) edge_count=edge_count+1;

// Una condición desconocida no aprueba. El identificador estable permite al
// ejecutor de negativos exigir su causa específica y descartar errores de sintaxis.
task automatic require_(input string tag,input logic condition);
    checks++;
    if(condition!==1'b1)begin
        $display("INTEGRACION_FIRST_DIVERGENCE tag=%s cfg=%0d scenario=%0d policy=%0d cycle=%0d advance=%0d medir=%b mover=%b pc=%h",tag,CFG,scenario,policy,cycle,advance,measuring,move_,CPU.pc);
        $fatal(1,"integración: %s",tag);
    end
endtask

// Codificadores de las palabras usadas. Reciben operandos ISA, devuelven bits
// combinacionales y no leen decoders ni resultados; los programas respetan N+3.
// bundle coloca ALU en bits bajos y CRIPTO en altos; no confunde slots con etapas.
function automatic logic [127:0] bundle(input logic [31:0] a,l,b,c);return {c,b,l,a};endfunction
// ai codifica sumai: rs/rd e inmediato signed11, sin extender operandos en el banco.
function automatic logic [31:0] ai(input int rd,rs,imm);return {TYPE_IMM,OP_SUMI,5'(rs),5'(rd),11'(imm)};endfunction
// ls recibe operación LSU y base/destino o fuente de store; off es dirección de byte.
function automatic logic [31:0] ls(input logic [3:0] op,input int base,reg_,off);return {TYPE_LSU,op,5'(base),5'(reg_),11'(off)};endfunction
// jump usa sye sin enlace x0: off relativo en bytes deja efectos GPR nulos al vaciar.
function automatic logic [31:0] jump(input int off);return {TYPE_BRU_JUMP,OP_SYE,5'd0,16'(off)};endfunction
// cond conserva los dos registros y el desplazamiento signed11 del condicional elegido.
function automatic logic [31:0] cond(input logic [3:0] op,input int a,b,off);return {TYPE_BRU_COND,op,5'(a),5'(b),11'(off)};endfunction
// crypto empaqueta setpwd/vcr/camcon; imm también codifica el registro de setpwd.
function automatic logic [31:0] crypto(input logic [3:0] op,input int address_,imm);return {TYPE_CRYPTO,op,16'(address_),5'(imm)};endfunction
// fsl prepara una operación con par destino x8/x9 y par fuente x0/x1; con llave
// y datos cero se esperan dos palabras cero, pero una sola instrucción cripto.
function automatic logic [31:0] fsl;return {TYPE_CRYPTO,OP_FSL,2'd0,2'd0,5'd8,5'd0,7'd0};endfunction
// pop suma cuatro bits con ancho int para representar cuatro; no suma escrituras GPR.
function automatic int pop(input logic [3:0] m);return int'(m[0])+int'(m[1])+int'(m[2])+int'(m[3]);endfunction

// Carga memorias iniciales y tablas independientes durante reset. m describe
// operaciones reconocidas, k=1 salto, 2 falso, 3 fault, 4 dos vueltas tomadas.
// El destino corresponde al PC en bytes; no modifica registros de ejecución.
task automatic put(input int i,input logic [127:0] word_,input logic [3:0] m,input int k=0,target_=0);
    words[i]=word_;masks[i]=m;kind[i]=k;targets[i]=32'(target_);
    CPU.IMEM.memory[i]=word_;SHADOW.IMEM.memory[i]=word_;
endtask

// Prepara cinco programas pequeños, con referencias numéricas anteriores al DUT.
// Los bucles finales no terminan la CPU: permiten vaciar sin nuevas demandas.
task automatic prepare;
    for(int i=0;i<1024;i++)put(i,0,0);
    for(int i=0;i<32;i++)gold_regs[i]=0;
    for(int i=0;i<16384;i++)begin gold_mem[i]=0;CPU.DMEM.mem[i]=0;SHADOW.DMEM.mem[i]=0;end
    gold_mem[16]=32'h400;CPU.DMEM.mem[16]=32'h400;SHADOW.DMEM.mem[16]=32'h400;
    gold_mem[20]=32'hfeedface;CPU.DMEM.mem[20]=32'hfeedface;SHADOW.DMEM.mem[20]=32'hfeedface;
    if(scenario!=0)put(40,bundle(0,0,jump(0),0),4,1,640);
    case(scenario)
        1:begin
            // Palabra77 y byte1 forman333; el load se consume N+3. El salto
            // tomado descarta ALU/store centinela; el condicional final es falso.
            put(0,bundle(ai(4,0,77),0,0,0),1);put(1,bundle(ai(3,0,1),0,0,0),1);
            put(3,bundle(0,ls(OP_GUARDAP,0,4,256),0,0),2);
            put(4,bundle(0,ls(OP_GUARDAB,0,3,257),0,0),2);
            put(5,bundle(0,ls(OP_CARGAI,0,5,256),0,0),2);
            put(6,bundle(0,ls(OP_CARGABAI,0,6,257),0,0),2);
            put(8,bundle(ai(7,5,1),0,0,0),1);
            put(9,bundle(0,0,jump(48),0),4,1,192);
            put(10,bundle(ai(20,0,99),0,0,0),1);
            put(11,bundle(0,ls(OP_GUARDAP,0,0,80),0,0),2);
            put(12,bundle(ai(10,0,5),0,0,0),1);
            put(13,bundle(0,0,cond(OP_IGUALNO,0,0,32),0),4,2);
            gold_regs[3]=1;gold_regs[4]=77;gold_regs[5]=333;gold_regs[6]=1;gold_regs[7]=334;gold_regs[10]=5;gold_mem[64]=333;
        end
        2:begin
            // 0/2048/4096 comparten conjunto0 de dos vías. H=64 es residente
            // antes de los stores: el hit inmediato posterior ocurre bajo miss.
            // Dos stores de la misma línea se fusionan y tres líneas fuerzan
            // capacidad MSHR/reemplazo; los loads finales exigen bytes correctos.
            put(0,bundle(ai(4,0,7),0,0,0),1);put(1,bundle(ai(20,0,1),0,0,0),1);
            put(4,bundle({TYPE_IMM,OP_CIZQI,5'd20,5'd20,11'd11},0,0,0),1);
            put(7,bundle({TYPE_REG,OP_SUM,5'd22,5'd20,5'd20,6'd0},0,0,0),1);
            put(8,bundle({TYPE_IMM,OP_CIZQI,5'd20,5'd23,11'd2},0,0,0),1);
            put(9,bundle({TYPE_IMM,OP_CIZQI,5'd20,5'd24,11'd3},0,0,0),1);
            put(10,bundle({TYPE_IMM,OP_CIZQI,5'd20,5'd25,11'd4},ls(OP_CARGAI,0,2,64),0,0),3);
            put(11,bundle(0,ls(OP_GUARDAP,0,4,0),0,0),2);
            put(12,bundle(0,ls(OP_GUARDAP,0,4,4),0,0),2);
            put(13,bundle(0,ls(OP_CARGAI,0,6,64),0,0),2);
            put(14,bundle(0,ls(OP_GUARDAP,20,4,0),0,0),2);
            put(15,bundle(0,ls(OP_GUARDAP,22,4,0),0,0),2);
            put(16,bundle(0,ls(OP_CARGAI,0,5,0),0,0),2);
            put(17,bundle(0,ls(OP_GUARDAB,0,4,1),0,0),2);
            put(18,bundle(0,ls(OP_CARGAI,0,7,0),0,0),2);
            put(19,bundle(0,ls(OP_CARGAI,20,8,0),0,0),2);
            put(20,bundle(0,ls(OP_CARGAI,22,9,0),0,0),2);
            // Ráfaga de misses del mismo conjunto sin reposo: las lecturas
            // tienen prioridad sobre drenado y ejercitan víctimas/WBUF lleno.
            put(21,bundle(0,ls(OP_CARGAI,23,12,0),0,0),2);
            put(22,bundle(0,ls(OP_CARGAI,24,13,0),0,0),2);
            put(23,bundle(0,ls(OP_CARGAI,25,14,0),0,0),2);
            put(24,bundle(0,ls(OP_CARGAI,20,15,0),0,0),2);
            put(25,bundle(0,ls(OP_CARGAI,22,16,0),0,0),2);
            put(26,bundle(0,ls(OP_CARGAI,0,17,0),0,0),2);
            put(27,bundle(0,ls(OP_CARGAI,23,18,0),0,0),2);
            gold_regs[15]=7;gold_regs[16]=7;gold_regs[17]='h707;
            gold_regs[23]=8192;gold_regs[24]=16384;gold_regs[25]=32768;
            gold_regs[2]='h400;gold_regs[4]=7;gold_regs[5]=7;gold_regs[6]='h400;
            gold_regs[7]='h707;gold_regs[8]=7;gold_regs[9]=7;gold_regs[20]=2048;gold_regs[22]=4096;
            gold_mem[0]='h707;gold_mem[1]=7;gold_mem[512]=7;gold_mem[1024]=7;
        end
        3:begin
            // Contraseña7, VCR7 y llave cero autorizan FSL con dos salidas0.
            // El bundle13 contiene cuatro operaciones y solo una CRIPTO.
            // camcon lee antes de A y escribe después: 7->14->28, sin repetir
            // rotaciones durante espera. El load simultáneo debe observar7.
            put(0,bundle(ai(4,0,7),0,0,0),1);
            put(3,bundle(0,0,0,crypto(OP_SETPWD,0,4)),8);
            put(4,bundle(0,ls(OP_GUARDAP,0,4,0),0,0),2);
            put(7,bundle(0,0,0,crypto(OP_VCR,0,0)),8);
            put(10,bundle(0,0,0,{TYPE_CRYPTO,OP_ELL,2'd0,2'd0,5'd0,5'd0,7'd0}),8);
            put(13,bundle(ai(10,0,11),ls(OP_GUARDAP,0,0,32),cond(OP_IGUALNO,0,0,32),fsl()),15,2);
            put(14,bundle(ai(6,0,42),0,0,0),1);
            put(17,bundle(0,ls(OP_CARGAI,0,5,0),0,crypto(OP_CAMCON,0,1)),10);
            put(18,bundle(0,ls(OP_GUARDAP,0,6,0),0,crypto(OP_CAMCON,0,1)),10);
            gold_regs[4]=7;gold_regs[5]=7;gold_regs[6]=42;gold_regs[10]=11;gold_mem[0]=28;
        end
        4:begin
            // El bucle decrementa tres veces y salta dos. FSL sin AUTH gana
            // sobre la BRU y anula ALU/store del culpable y sus dos jóvenes.
            // El manejador vuelve al índice32 y publica x30=99, sin HALT.
            put(0,bundle(ai(2,0,3),0,0,0),1);put(3,bundle(ai(2,2,-1),0,0,0),1);
            put(6,bundle(0,0,cond(OP_MENORA,0,2,-48),0),4,4,48);
            put(7,bundle(ai(20,0,99),ls(OP_GUARDAP,0,0,80),jump(32),fsl()),15,3,TRAP_VECTOR);
            put(8,bundle(ai(21,0,99),0,0,0),1);put(9,bundle(0,ls(OP_GUARDAP,0,0,80),0,0),2);
            put(1023,bundle(0,0,jump(512-TRAP_VECTOR),0),4,1,512);
            put(32,bundle(ai(30,0,99),0,0,0),1);gold_regs[30]=99;
        end
        default:begin end
    endcase
endtask

// Reinicia solo referencias propias de la época. El reloj/reset público reinicia
// CPU y módulos reales; ni ventana ni mantenimiento se usan como reset artificial.
task automatic clear_ref;
    cycle=0;advance=0;pc_ref=0;id_pc=0;ex_pc=0;wb_pc=0;iv=0;xv=0;wv=0;done=0;
    ec=0;eb=0;ei=0;em=0;er=0;occ='0;bub='0;frozen='0;held='0;events_ref='0;
    cnt_ref='0;srv_ref='0;wait_ref='0;zero_ref=0;excluded_ref=0;
    start_date=0;last_off=0;end_date=0;first_request=0;boundary=0;pending_ref=0;eligible_ref=0;
    cache_ends=0;previous_end=0;flush_pushes=0;
    for(int i=0;i<1024;i++)visits[i]=0;
    for(int i=0;i<2048;i++)rec_due[i]=0;
endtask

// Pasividad de los dos procesadores con idénticos estímulos: PRE y POST exactos,
// sin tolerancia temporal. Los datos inválidos se comparan con igualdad de cuatro
// estados; las lecturas y referencias útiles se validan además como conocidas.
task automatic passive;
    require_("passive_control",{CPU.pc,CPU.core_en,CPU.core_clk,CPU.cache_stall,CPU.branch_flush,
        CPU.crypto_fault,CPU.redirect,CPU.redirect_pc,CPU.trap_count,CPU.trap_pc,CPU.crypto_estado,flush_done}===
        {SHADOW.pc,SHADOW.core_en,SHADOW.core_clk,SHADOW.cache_stall,SHADOW.branch_flush,
        SHADOW.crypto_fault,SHADOW.redirect,SHADOW.redirect_pc,SHADOW.trap_count,SHADOW.trap_pc,SHADOW.crypto_estado,shadow_done});
    require_("passive_wb",{CPU.wb_we,CPU.wb_waddr,CPU.wb_wdata}==={SHADOW.wb_we,SHADOW.wb_waddr,SHADOW.wb_wdata});
    require_("passive_data",{CPU.mem_re,CPU.mem_we,CPU.mem_be,CPU.mem_addr,CPU.mem_wdata,CPU.mem_rdata,
        CPU.mem_re_b,CPU.crypto_mem_we,CPU.crypto_mem_addr,CPU.crypto_mem_wdata,CPU.crypto_mem_rdata,
        CPU.dmem_we,CPU.dmem_addr,CPU.dmem_be,CPU.dmem_wdata,CPU.dmem_rdata,
        CPU.dmem_we_b,CPU.dmem_addr_b,CPU.dmem_wdata_b}===
        {SHADOW.mem_re,SHADOW.mem_we,SHADOW.mem_be,SHADOW.mem_addr,SHADOW.mem_wdata,SHADOW.mem_rdata,
        SHADOW.mem_re_b,SHADOW.crypto_mem_we,SHADOW.crypto_mem_addr,SHADOW.crypto_mem_wdata,SHADOW.crypto_mem_rdata,
        SHADOW.dmem_we,SHADOW.dmem_addr,SHADOW.dmem_be,SHADOW.dmem_wdata,SHADOW.dmem_rdata,
        SHADOW.dmem_we_b,SHADOW.dmem_addr_b,SHADOW.dmem_wdata_b});
    for(int i=0;i<32;i++)require_("passive_gpr",CPU.REGFILE.regs[i]===SHADOW.REGFILE.regs[i]);
    require_("disabled_zero",SHADOW.perf_cycle_count===0 && SHADOW.perf_stage_measured_cycles===0);
endtask

// La caché y su sombra se comparan por puertos públicos, sin etiquetas/colas.
// Incluye demanda arbitrada, solicitud retenida, aceptación, respuesta y DMEM.
generate if(MODE==2)begin:g_bus
    task automatic compare_;
        require_("exclusive_configuration",CPU.g_mem_cache.HIER.L1D.INCL_POLICY===INCL_EXCLUSIVE &&
            CPU.g_mem_cache.HIER.L1D.WRITE_POLICY===WP_WRITE_BACK && CPU.g_mem_cache.HIER.L1D.ALLOC_POLICY===AP_WRITE_ALLOC &&
            CPU.g_mem_cache.HIER.L1D.REPL_POLICY===RP_LRU && CPU.g_mem_cache.HIER.L1D.WB_DEPTH==4 &&
            CPU.g_mem_cache.HIER.L1D.N_MSHR==2 && CPU.g_mem_cache.HIER.L1D.L2_BUS_V2===1'b1);
        require_("passive_l1_l2",{CPU.g_mem_cache.HIER.c_re,CPU.g_mem_cache.HIER.c_we,CPU.g_mem_cache.HIER.c_addr,
            CPU.g_mem_cache.HIER.c_be,CPU.g_mem_cache.HIER.c_wdata,CPU.g_mem_cache.HIER.c_rdata,CPU.g_mem_cache.HIER.c_stall,
            CPU.g_mem_cache.HIER.l2_req,CPU.g_mem_cache.HIER.l2_we,CPU.g_mem_cache.HIER.l2_addr,
            CPU.g_mem_cache.HIER.l2_wline,CPU.g_mem_cache.HIER.l2_be,CPU.g_mem_cache.HIER.l2_wdirty,
            CPU.g_mem_cache.HIER.l2_gnt,CPU.g_mem_cache.HIER.l2_rvalid,CPU.g_mem_cache.HIER.l2_rline,CPU.g_mem_cache.HIER.l2_rdirty,
            CPU.g_mem_cache.HIER.l2_idle,CPU.g_mem_cache.HIER.perf_events}===
            {SHADOW.g_mem_cache.HIER.c_re,SHADOW.g_mem_cache.HIER.c_we,SHADOW.g_mem_cache.HIER.c_addr,
            SHADOW.g_mem_cache.HIER.c_be,SHADOW.g_mem_cache.HIER.c_wdata,SHADOW.g_mem_cache.HIER.c_rdata,SHADOW.g_mem_cache.HIER.c_stall,
            SHADOW.g_mem_cache.HIER.l2_req,SHADOW.g_mem_cache.HIER.l2_we,SHADOW.g_mem_cache.HIER.l2_addr,
            SHADOW.g_mem_cache.HIER.l2_wline,SHADOW.g_mem_cache.HIER.l2_be,SHADOW.g_mem_cache.HIER.l2_wdirty,
            SHADOW.g_mem_cache.HIER.l2_gnt,SHADOW.g_mem_cache.HIER.l2_rvalid,SHADOW.g_mem_cache.HIER.l2_rline,SHADOW.g_mem_cache.HIER.l2_rdirty,
            SHADOW.g_mem_cache.HIER.l2_idle,SHADOW.g_mem_cache.HIER.perf_events});
        require_("disabled_cache_zero",SHADOW.g_mem_cache.HIER.perf_access_totals==='0 && SHADOW.g_mem_cache.HIER.perf_completed_accesses===0);
    endtask
end else begin:g_bus
    task automatic compare_;require_("no_cache_events",events===0 && total===0);endtask
end endgenerate

// PRE referencia la validez por admisiones y decisiones del programa. Las sumas
// se calculan antes de mirar resultados del contador. K1-A usa el evento público
// consumido por L1-D; K1-B usa fechas S/F y última pausa, no su FSM incremental.
task automatic pre;
    int ix,k,cls;bit rec,whole;logic [3:0] valid_;
    logic [31:0] old_pc;
    edge_before=edge_count;reset_=reset;move_=CPU.core_en;
    if(reset)begin clear_ref();measuring=(policy!=2);enable_=measuring;end
    else begin
        seen_events=seen_events|events;
        cycle++;if(advance+4>=2048)$fatal(1,"referencia sin capacidad");
        // Inicio tardío y pausas 7..9/16..17: la segunda corta el primer miss
        // frío de escenario2. done cierra captura; maintenance abre solo ventana
        // completa para observar flush por separado, sin cambiar el procesador.
        measuring=(!done || maintenance) && policy!=2 &&
                  (policy!=1 || (cycle>=5 && !(cycle>=7&&cycle<=9) && !(cycle>=16&&cycle<=17)));
        enable_=measuring;ix=(ex_pc>>4)&1023;k=xv?kind[ix]:0;
        taken_=(k==1 || (k==4 && visits[ix]<2));fault_=(k==3);
        rec=move_ && rec_due[advance+1];valid_={wv,xv,iv,1'b1};
        require_("validity_oracle",{CPU.perf_wb_valid,CPU.id_ex_valid,CPU.id_valid,CPU.fetch_valid}===valid_);
        require_("pc_oracle",CPU.pc===pc_ref && (!iv || CPU.id_pc===id_pc) && (!xv || CPU.ex_pc===ex_pc));
        require_("control_oracle",CPU.branch_flush===taken_ && CPU.crypto_fault===fault_);
        require_("retirement_oracle",CPU.perf_bundle_complete===(move_&&wv));
        require_("mask_oracle",CPU.perf_wb_non_nop_mask===(wv?masks[(wb_pc>>4)&1023]:4'd0));
        require_("recovery_oracle",CPU.perf_branch_recovery===rec);
        require_("stall_oracle",CPU.perf_memory_stall===!move_);
        if(!move_ && !enable_)paused_stalls++;
        if(move_ && wv)begin
            if(masks[(wb_pc>>4)&1023]==0)retired_nop++;
            if(masks[(wb_pc>>4)&1023][1] && words[(wb_pc>>4)&1023][63:57]==TYPE_LSU &&
               words[(wb_pc>>4)&1023][56:53]==OP_GUARDAP)retired_store++;
            if(masks[(wb_pc>>4)&1023]==15)retired_four++;
            if(CPU.wb_we[3]&&CPU.wb_we[4])crypto_pairs++;
        end
        if(enable_)begin
            ec++;if(!move_)em++;if(rec)er++;
            if(move_&&wv)begin eb++;ei+=pop(masks[(wb_pc>>4)&1023]);end
            for(int s=0;s<4;s++)begin
                if(valid_[s])occ[s]++;else bub[s]++;
                if(!move_)begin frozen[s]++;if(valid_[s])held[s]++;end
            end
            for(int i=0;i<19;i++)if(events[i])events_ref[i]++;
        end else if(|events[3:0])paused_events++;
        if(MODE==2)begin
            require_("cache_class_onehot",$countones(events[3:0])<=1);
            require_("cache_class_type",(!(events[0]||events[1]) || (cr&&!cw&&!cs)) &&
                (!(events[2]||events[3]) || (cw&&!cr&&!cs)));
            if(!enable_)last_off=cycle;
            if(!(cr||cw))begin boundary=1;pending_ref=0;start_date=0;eligible_ref=0;end
            else begin
                if(start_date==0)begin start_date=cycle;if(first_request==0)first_request=cycle;end
                if(|events[3:0])begin
                    cls=events[0]?0:events[1]?1:events[2]?2:3;
                    // El primer load frío de escenario2 y el load H posterior
                    // tienen clases independientes conocidas RM y RH. Los stores
                    // iniciales a líneas vacías son WM, aun antes del fill.
                    if(scenario==2 && cache_ends<6)case(cache_ends)
                        0:require_("directed_cold_class",events[3:0]===4'b0010);
                        1,2,4,5:require_("directed_store_class",events[3:0]===4'b1000);
                        3:require_("directed_resident_class",events[3:0]===4'b0001);
                    endcase
                    whole=enable_ && boundary && last_off<start_date;
                    if(whole)begin
                        cnt_ref[cls]++;srv_ref[cls]+=64'(cycle-start_date+1);wait_ref[cls]+=64'(cycle-start_date);
                        if(cycle==start_date)zero_ref++;
                    end else if(enable_)begin excluded_ref++;partial_ends++;end
                    if(previous_end==cycle-1)consecutive++;previous_end=cycle;
                    cache_ends++;pending_ref=0;eligible_ref=0;start_date=0;boundary=1;end_date=cycle;
                end else begin
                    require_("cache_wait_contract",cs && !(cr&&cw));
                    pending_ref=1;eligible_ref=boundary && last_off<start_date;
                end
            end
            if(maintenance && events[8])flush_pushes++;
        end
        if(move_)begin
            advance++;if(xv)visits[ix]++;
            if(taken_)begin taken_count++;rec_due[advance+1]=1;rec_due[advance+2]=1;end
            if(k==2 || (k==4&&!taken_))false_count++;
            if(fault_)fault_count++;
            old_pc=pc_ref;pc_ref=(taken_||fault_)?targets[ix]:pc_ref+16;
            wv=xv&&!fault_;wb_pc=ex_pc;
            xv=iv&&!taken_&&!fault_;ex_pc=id_pc;
            iv=!taken_&&!fault_;id_pc=old_pc;
        end
    end
    // La ventana elegida en PRE debe propagarse antes del flanco positivo.
    #1;passive();g_bus.compare_();
endtask

// POST compara todos los grupos; identidad service=wait+count usa unsigned64.
// El snapshot de métricas se cierra antes del mantenimiento y se imprime aparte.
task automatic post;
    require_("clock_applied",edge_count==edge_before+int'(move_));
    require_("vliw_cycles",CPU.perf_cycle_count===ec);
    require_("vliw_bundles",CPU.perf_bundle_count===eb);
    require_("vliw_instructions",CPU.perf_instruction_count===ei);
    require_("vliw_memory",CPU.perf_memory_stall_count===em);
    require_("vliw_branch",CPU.perf_branch_penalty_count===er);
    require_("stage_cycles",CPU.perf_stage_measured_cycles===ec);
    for(int s=0;s<4;s++)begin
        require_("stage_occupied",CPU.perf_stage_occupied[s]===occ[s]);
        require_("stage_bubble",CPU.perf_stage_bubbles[s]===bub[s]);
        require_("stage_frozen",CPU.perf_stage_stalls[s]===frozen[s]);
        require_("stage_held",CPU.perf_stage_stalled_occupied[s]===held[s]);
        require_("stage_partition",CPU.perf_stage_occupied[s]+CPU.perf_stage_bubbles[s]===ec);
        require_("stage_bounds",CPU.perf_stage_stalled_occupied[s]<=CPU.perf_stage_stalls[s]);
    end
    require_("k1a_events",event_counts===events_ref);
    require_("k1a_totals",access_totals[0]===events_ref[0]+events_ref[1] && access_totals[1]===events_ref[2]+events_ref[3] &&
        access_totals[2]===events_ref[0]+events_ref[1]+events_ref[2]+events_ref[3] &&
        access_totals[3]===events_ref[0]+events_ref[2] && access_totals[4]===events_ref[1]+events_ref[3]);
    require_("k1b_classes",completed===cnt_ref && service===srv_ref && waits===wait_ref);
    require_("k1b_totals",total===cnt_ref[0]+cnt_ref[1]+cnt_ref[2]+cnt_ref[3] &&
        service_total===srv_ref[0]+srv_ref[1]+srv_ref[2]+srv_ref[3] && wait_total===wait_ref[0]+wait_ref[1]+wait_ref[2]+wait_ref[3]);
    require_("k1b_aux",no_wait===zero_ref && excluded===excluded_ref && errors===0);
    require_("k1b_pending",pend===pending_ref && elig===eligible_ref && age===64'(pending_ref?cycle-start_date+1:0));
    require_("k1b_identity",service_total===wait_total+total);
    passive();g_bus.compare_();
    if(!reset && !done && advance==(scenario==0?6:80))begin
        done=1;captures++;
        for(int i=0;i<32;i++)begin saved_regs[i]=CPU.REGFILE.regs[i];require_("architectural_gpr",saved_regs[i]===gold_regs[i]);end
        saved_pc=CPU.pc;saved_state=CPU.crypto_estado;saved_traps=CPU.trap_count;
        require_("architectural_exception",CPU.trap_count===32'(scenario==4?1:0));
        if(scenario==3)require_("authorized_state",CPU.crypto_estado===1);
        if(scenario==0 && policy==0)for(int s=0;s<4;s++)require_("known_nop_dates",occ[s]===64'(6-s) && bub[s]===64'(s));
        $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",scenario,policy,MODE,ec,eb,ei,em,er,occ[0],occ[1],occ[2],occ[3],access_totals[3],access_totals[4],total,service_total,wait_total,excluded,advance);
        if(ec==0)$display("INTEGRACION IPC cfg=%0d escenario=%0d ventana=%0d N/D",CFG,scenario,policy);
        else $display("INTEGRACION IPC cfg=%0d escenario=%0d ventana=%0d instrucciones=%0d ciclos=%0d IPC=%0.9f",CFG,scenario,policy,ei,ec,real'(ei)/real'(ec));
    end
endtask

// Tras done, mantenimiento público debe persistir memoria antes de comparar.
// Se comprueban 16384 palabras frente a sombra y gold preparado, no solo hashes.
task automatic memory_check;
    require_("flush_done",flush_done && shadow_done);
    for(int i=0;i<16384;i++)begin
        require_("passive_memory_full",CPU.DMEM.mem[i]===SHADOW.DMEM.mem[i]);
        require_("architectural_memory",CPU.DMEM.mem[i]===gold_mem[i]);
    end
endtask
initial begin
    fd=$fopen($sformatf("integracion-cfg%0d.csv",CFG),"w");if(!fd)$fatal(1,"abrir CSV");
    $fdisplay(fd,"scenario,policy,mode,cycles,bundles,instructions,memory,branch,IF,ID,EX,WB,hits,misses,complete_k1b,service_k1b,wait_k1b,excluded,advances");
end
endmodule

// Coordinador sin productor ficticio: cada flanco alcanza cuatro parejas reales.
// Los más rápidos cierran su ventana al mismo avance y siguen ejecutando; sus
// snapshots guardados se comparan, no el estado corriente de distintos horizontes.
module tb_perf_integracion_top;
logic clk=0,reset=1,flush_req=0,maintenance=0;
integer scenario=0,policy=0,total_checks=0;
perf_integracion_case #(.CFG(0)) M0(clk,reset,flush_req,maintenance,scenario,policy);
perf_integracion_case #(.CFG(1),.MODE(1)) M1(clk,reset,flush_req,maintenance,scenario,policy);
perf_integracion_case #(.CFG(2),.MODE(2)) M2(clk,reset,flush_req,maintenance,scenario,policy);
perf_integracion_case #(.CFG(3),.MODE(2),.SYNC(0)) M2C(clk,reset,flush_req,maintenance,scenario,policy);

// Mantiene clk bajo durante PRE para el latch de core_en. #1 posterior al
// posedge permite que CPU y monitores publiquen NBA antes de comprobar sumas.
task automatic tick;
    clk=0;#4;M0.pre();M1.pre();M2.pre();M2C.pre();
    clk=1;#1;M0.post();M1.post();M2.post();M2C.post();clk=0;#4;
endtask

// Reinicia épocas por puertos, prepara programas y precarga ROM con reset.
// La política2 verifica reset prioritario con medición cerrada en las cuatro CPU.
task automatic start_case(input int s,p);
    reset=1;flush_req=0;maintenance=0;tick();scenario=s;policy=p;
    M0.prepare();M1.prepare();M2.prepare();M2C.prepare();tick();reset=0;
endtask

// Límite de infraestructura: alcanzar el progreso no permite saltar esperas.
// Después se comparan GPR/estado/PC capturados, con tiempo idéntico por pareja.
task automatic execute;
    int n;n=0;
    while(!(M0.done&&M1.done&&M2.done&&M2C.done)&&n<2000)begin tick();n++;end
    if(n==2000)$fatal(1,"timeout de progreso");
    for(int r=0;r<32;r++)M0.require_("cross_mode_snapshot",M0.saved_regs[r]===M1.saved_regs[r] &&
        M0.saved_regs[r]===M2.saved_regs[r] && M0.saved_regs[r]===M2C.saved_regs[r]);
    M0.require_("cross_mode_public",{M0.saved_pc,M0.saved_state,M0.saved_traps}===
        {M1.saved_pc,M1.saved_state,M1.saved_traps} && {M0.saved_pc,M0.saved_state,M0.saved_traps}===
        {M2.saved_pc,M2.saved_state,M2.saved_traps} && {M0.saved_pc,M0.saved_state,M0.saved_traps}===
        {M2C.saved_pc,M2C.saved_state,M2C.saved_traps});
endtask

// El núcleo sigue con NOP/saltos sin enlace. Mantenimiento medido solo en ventana
// completa demuestra WBUF/tráfico sin sumar demandas; no se bloquea CPU desde TB.
task automatic drain;
    int n;logic [63:0] before_;before_=M2.total;maintenance=1;flush_req=1;n=0;
    while(!(M0.flush_done&&M1.flush_done&&M2.flush_done&&M2C.flush_done)&&n<2000)begin tick();n++;end
    if(n==2000)$fatal(1,"timeout de flush");
    M0.memory_check();M1.memory_check();M2.memory_check();M2C.memory_check();
    M2.require_("maintenance_no_demand",M2.total===before_);
    flush_req=0;repeat(2)tick();maintenance=0;
endtask

initial begin
    if($test$plusargs("VCD"))begin
        $dumpfile("perf-integracion.vcd");
        $dumpvars(0,clk,reset,flush_req,maintenance,M2.measuring,M2.CPU.perf_cycle_count,
            M2.CPU.perf_bundle_count,M2.CPU.perf_instruction_count,M2.CPU.perf_wb_valid,
            M2.CPU.perf_stage_occupied,M2.events,M2.total,M2.service_total,M2.pend);
    end
    #1;
    for(int s=0;s<5;s++)for(int p=0;p<3;p++)begin start_case(s,p);execute();drain();end
    // Reset con pipeline ocupado y durante un miss pausado. El reset del núcleo
    // puede publicar un store según su contrato previo: solo se comprueba aquí
    // pasividad y borrado de métricas, sin prometer cancelación atómica de DMEM.
    start_case(2,1);begin int n;n=0;while(!M2.pend&&n<200)begin tick();n++;end
        if(n==200)$fatal(1,"no hubo pendiente para reset");end
    policy=2;reset=1;tick();reset=0;repeat(3)tick();
    start_case(1,0);repeat(8)tick();reset=1;tick();
    M0.require_("coverage_nop",M0.retired_nop>0);
    M0.require_("coverage_store",M0.retired_store>0);
    M0.require_("coverage_four_crypto",M0.retired_four>0 && M0.crypto_pairs>0);
    M0.require_("coverage_control",M0.taken_count>0 && M0.false_count>0 && M0.fault_count>0);
    M2.require_("coverage_windows",M2.paused_stalls>0 && M2.paused_events>0 && M2.partial_ends>0);
    M2.require_("coverage_consecutive",M2.consecutive>0);
    $display("INTEGRACION COBERTURA eventos=%h pausas_stall=%0d pausas_evento=%0d parciales=%0d",M2.seen_events,M2.paused_stalls,M2.paused_events,M2.partial_ends);
    total_checks=M0.checks+M1.checks+M2.checks+M2C.checks;
    $fclose(M0.fd);$fclose(M1.fd);$fclose(M2.fd);$fclose(M2C.fd);
    $display("[PASS] tb_perf_integracion_top: %0d verificaciones correctas; 60 capturas",total_checks);$finish;
end
initial begin #2000000;$fatal(1,"watchdog integración");end
endmodule
