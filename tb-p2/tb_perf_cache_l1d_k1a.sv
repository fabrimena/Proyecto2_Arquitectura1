/* Valida contadores y L1-D real mediante eventos dirigidos y operaciones conocidas. */
`timescale 1ns/1ps
`include "cache_defs.sv"
`define K1A_COUNTER(NAME, CLOCK, RST, ENABLE, EV, C, T) \
perf_cache_l1d NAME (.clk(CLOCK),.reset(RST),.measure_enable(ENABLE), \
    .ev_rd_hit(EV[0]), \
    .ev_rd_miss(EV[1]), \
    .ev_wr_hit(EV[2]), \
    .ev_wr_miss(EV[3]), \
    .ev_stall(EV[4]), \
    .ev_wb_full_stall(EV[5]), \
    .ev_raw_stall(EV[6]), \
    .ev_raw_forward(EV[7]), \
    .ev_wb_push(EV[8]), \
    .ev_l2_read(EV[9]), \
    .ev_l2_write(EV[10]), \
    .ev_fill(EV[11]), \
    .ev_victim_dirty(EV[12]), \
    .ev_victim_clean(EV[13]), \
    .ev_mshr_alloc(EV[14]), \
    .ev_mshr_merge(EV[15]), \
    .ev_mshr_load(EV[16]), \
    .ev_hit_under_miss(EV[17]), \
    .ev_mshr_full_stall(EV[18]), \
    .read_hits(C[0]), \
    .read_misses(C[1]), \
    .write_hits(C[2]), \
    .write_misses(C[3]), \
    .stall_cycles(C[4]), \
    .wb_full_stall_cycles(C[5]), \
    .raw_stall_cycles(C[6]), \
    .raw_forward_events(C[7]), \
    .wb_push_events(C[8]), \
    .l2_read_requests(C[9]), \
    .l2_write_requests(C[10]), \
    .read_accesses(T[0]), \
    .write_accesses(T[1]), \
    .total_accesses(T[2]), \
    .total_hits(T[3]), \
    .fill_events(C[11]), \
    .victim_dirty_events(C[12]), \
    .victim_clean_events(C[13]), \
    .mshr_alloc_events(C[14]), \
    .mshr_merge_events(C[15]), \
    .mshr_load_events(C[16]), \
    .hit_under_miss_events(C[17]), \
    .mshr_full_stall_cycles(C[18]), \
    .total_misses(T[4]));
`define K1A_CACHE(NAME, RAW_, EV, Q, ST, DONE_, RQ, WE_, A_, DATA_, BE_, WD_) \
/* Configuración histórica explícita: no depende de los defaults de José. */ \
l1d_cache #(.WRITE_POLICY(WP_WRITE_THROUGH),.INCL_POLICY(INCL_NINE), \
    .ALLOC_POLICY(AP_NO_WRITE_ALLOC),.REPL_POLICY(RP_LRU),.RAW_POLICY(RAW_), \
    .WB_DEPTH(2),.N_MSHR(1),.L2_BUS_V2(1)) NAME ( \
    .clk(clk),.reset(reset),.re(re),.we(we),.be(be),.addr(addr),.wdata(wdata),.rdata(Q),.stall(ST), \
    .flush_req(flush_req),.flush_done(DONE_),.l2_req(RQ),.l2_we(WE_),.l2_addr(A_),.l2_wline(DATA_),.l2_be(BE_), \
    .l2_gnt(gnt),.l2_rvalid(rvalid),.l2_rdirty(1'b0),.l2_wdirty(WD_),.l2_rline(rline), \
    .ev_rd_hit(EV[0]), \
    .ev_rd_miss(EV[1]), \
    .ev_wr_hit(EV[2]), \
    .ev_wr_miss(EV[3]), \
    .ev_stall(EV[4]), \
    .ev_wb_full_stall(EV[5]), \
    .ev_raw_stall(EV[6]), \
    .ev_raw_forward(EV[7]), \
    .ev_wb_push(EV[8]), \
    .ev_l2_read(EV[9]), \
    .ev_l2_write(EV[10]), \
    .ev_fill(EV[11]), \
    .ev_victim_dirty(EV[12]), \
    .ev_victim_clean(EV[13]), \
    .ev_mshr_alloc(EV[14]), \
    .ev_mshr_merge(EV[15]), \
    .ev_mshr_load(EV[16]), \
    .ev_hit_under_miss(EV[17]), \
    .ev_mshr_full_stall(EV[18]));


/* Dos cachés originales reciben el mismo estímulo; solo una tiene consumidor.
 * La referencia conoce las operaciones, dos entradas FIFO públicas y el contrato
 * de respuesta de ocho esperas. Nunca consulta registros privados de L1-D. */
module k1a_real #(parameter RAW = RAW_FORWARD)(input logic go, output logic done);
    logic clk=0, reset=1, metric_reset=0, enable=1;
    logic re=0,we=0,flush_req=0,rvalid=0,gnt=0;
    wire wd,wds;
    logic [3:0] be=15;
    logic [31:0] addr=0,wdata=0,q,qs,la,las;
    logic [255:0] rline=0,wl,wls;
    logic [31:0] mask,masks;
    wire [18:0] ev,shadow_ev;
    logic [18:0] diagnostic;
    wire st,sts,fd,fds,rq,rqs,lwe,lwes;
    wire [63:0] c[0:18],t[0:4];
    wire crst=reset|metric_reset;
    wire cen=enable | (mutation==7);
    `K1A_CACHE(CACHE,RAW,ev,q,st,fd,rq,lwe,la,wl,mask,wd)
    `K1A_CACHE(SHADOW,RAW,shadow_ev,qs,sts,fds,rqs,lwes,las,wls,masks,wds)
    `K1A_COUNTER(COUNTERS,clk,crst,cen,diagnostic,c,t)

    integer mutation=0,cycle=0,checks=0,nq=0,age=0,steps=0;
    integer operations=0,service=0,waits=0,starts_rd=0,starts_wr=0;
    integer completed_rd=0,completed_wr=0,observed_hits=0,observed_misses=0;
    integer trace;
    logic busy=0,buswrite=0,expected_miss=0,finished=0;
    logic [31:0] busaddr=0;
    logic [255:0] busdata=0;
    logic [31:0] busmask=0;
    logic [31:0] qa[0:1],qm[0:1];
    logic [255:0] qd[0:1];
    logic [31:0] memory[0:16383],gold[0:16383];
    logic [63:0] expected[0:18];
    logic [18:0] previous=0;

    // Las mutaciones solo afectan entradas diagnósticas del consumidor. La
    // referencia y ambas cachés siguen recibiendo exactamente el caso nominal.
    always @* begin
        diagnostic=ev;
        case (mutation)
            1: begin diagnostic[0]=0; diagnostic[1]=ev[1]|ev[0]; end
            2: diagnostic[1]=ev[1]|previous[1];
            3: diagnostic[0]=0;
            4: diagnostic[4]=0;
            5: diagnostic[4]=ev[4]|previous[4];
            6: begin diagnostic[0]=ev[0]|ev[2]; diagnostic[1]=ev[1]|ev[3];
                     diagnostic[2]=0; diagnostic[3]=0; end
            8: diagnostic[0]=ev[0]|ev[9]|ev[10];
            9: diagnostic[7]=0;
            default: begin end
        endcase
    end

    task automatic check(input logic ok,input string why);
        begin
            checks++;
            if (ok !== 1'b1)
                $fatal(1,"K1A divergencia RAW=%0d ciclo=%0d mutacion=%0d: %s",RAW,cycle,mutation,why);
        end
    endtask

    /* Muestreo PRE: los eventos combinacionales describen el flanco que viene.
     * POST: se contrastan los diecinueve acumulados y cinco sumas tras sus NBA.
     * La cola de referencia contiene stores aceptados, no señales de WBUF. */
    task automatic tick;
        logic pending,fill,complete,start_read,start_write,pop;
        logic [18:0] want;
        logic [31:0] target,expected_data;
        integer i,j,k;
        begin
            #2;
            cycle++;
            want=0;
            finished=0;
            pending=0;
            for(i=0;i<nq;i++) if(qa[i]==(addr&32'hffe0)) pending=1;
            fill=busy && rvalid && !buswrite;
            complete=(re||we) && (re ? (!expected_miss||fill) : nq<2);
            start_read=!busy && re && expected_miss && !(RAW==RAW_STALL && pending);
            start_write=!busy && !start_read && nq>0;
            // Aceptar no equivale a responder: la lectura se acepta ahora y
            // responde ocho flancos después. El drenado espera ocho flancos
            // antes del grant para conservar la presión original sobre WBUF.
            gnt=start_read || (busy && buswrite && age==8);
            #1;
            pop=busy && gnt && buswrite;
            if (!reset) begin
                // Hit/miss viene del guion dirigido y la geometría: el modelo
                // no vuelve a calcular etiquetas ni reproduce la política LRU.
                if(complete) want[re ? (expected_miss?1:0) : (expected_miss?3:2)]=1;
                want[4]=(re||we)&&!complete;
                want[5]=we&&!complete&&nq==2;
                want[6]=want[4]&&re&&expected_miss&&RAW==RAW_STALL&&pending&&!busy;
                want[7]=fill&&RAW==RAW_FORWARD&&pending;
                want[8]=complete&&we;
                want[9]=start_read;
                want[10]=start_write;
                want[11]=fill;
                check(ev===want,$sformatf("eventos productor: esperado=%b observado=%b",want,ev));
                check(st===want[4],"stall contra finalización esperada");
                check({q,st,fd,rq,lwe,la,wl,mask,wd,ev} ===
                      {qs,sts,fds,rqs,lwes,las,wls,masks,wds,shadow_ev},"pasividad: salidas públicas distintas");
                check(rq===((busy&&buswrite)||start_read||start_write),"presencia de transacción L2");
                check(!wd,"write-through siempre transmite dirty=0");
                if(rq) begin
                    target=busy?busaddr:(start_read?(addr&32'hffe0):qa[0]);
                    check(la===target && lwe===(busy?buswrite:start_write),"tipo/dirección L2 retenidos");
                    if(lwe) begin
                        check(mask===(busy?busmask:qm[0]),"máscara de escritura L2");
                        check(wl===(busy?busdata:qd[0]),"datos de escritura L2");
                    end else check(mask===0,"lectura sin byte enables de escritura");
                end
                if(complete&&re) begin
                    expected_data=gold[(addr&32'hffff)>>2];
                    check(q===expected_data,$sformatf("dato de lectura %h esperado %h observado %h",addr,expected_data,q));
                end
                // Las expectativas se incrementan con el guion/protocolo de
                // referencia, nunca con ev ni con los resultados del DUT.
                if(!metric_reset && enable)
                    for(i=0;i<19;i++) if(want[i]) expected[i]++;
                starts_rd+=start_read;
                starts_wr+=start_write;
                finished=complete;
                if(complete) begin
                    operations++;
                    completed_rd+=re;
                    completed_wr+=we;
                    observed_hits+=!expected_miss;
                    observed_misses+=expected_miss;
                end
                $fdisplay(trace,"%0d,%0d,%h,%0d,%0d,%0d,%0d,%b,%b,%0d,%0d,%0d,%0d,%0d",RAW,cycle,addr,re,we,expected_miss,enable,want,ev,nq,busy,rvalid,complete,metric_reset);
            end
            if(crst) for(i=0;i<19;i++) expected[i]=0;
            clk=1;
            #1;
            for(i=0;i<19;i++)
                check(c[i]===expected[i],$sformatf("contador[%0d] esperado=%0d observado=%0d",i,expected[i],c[i]));
            check(t[0]===expected[0]+expected[1],"total lecturas");
            check(t[1]===expected[2]+expected[3],"total escrituras");
            check(t[2]===expected[0]+expected[1]+expected[2]+expected[3],"total accesos");
            check(t[3]===expected[0]+expected[2],"total hits");
            check(t[4]===expected[1]+expected[3],"total misses");
            check(t[3]+t[4]===t[2],"partición hits/misses");

            // Bus v2: solo las lecturas generan rvalid. Las escrituras se
            // aplican al consumir grant, sin fabricar respuesta de lectura.
            if(reset) begin
                busy=0; rvalid=0; gnt=0; nq=0; age=0; previous=0;
            end else begin
                previous=want;
                if(pop) begin
                    for(j=0;j<8;j++) for(k=0;k<4;k++) if(busmask[j*4+k])
                        memory[(busaddr>>2)+j][k*8+:8]=busdata[(j*4+k)*8+:8];
                    busy=0;
                end else if(busy && !buswrite) begin
                    if(rvalid) begin rvalid=0; busy=0; end
                    else begin
                        if(age==7) begin
                            for(j=0;j<8;j++) rline[j*32+:32]=memory[(busaddr>>2)+j];
                            rvalid=1;
                        end
                        age++;
                    end
                end else if(busy) age++;
                else if(start_read||start_write) begin
                    busy=1; buswrite=start_write; age=1;
                    busaddr=start_read?(addr&32'hffe0):qa[0];
                    busdata=start_write?qd[0]:0;
                    busmask=start_write?qm[0]:0;
                end
                // El pop de escritura corresponde al grant consumido. Con FIFO
                // llena, un pop no habilita el push previo.
                if(pop) begin qa[0]=qa[1]; qm[0]=qm[1]; qd[0]=qd[1]; nq--; end
                if(complete&&we) begin
                    qa[nq]=addr&32'hffe0;
                    qm[nq]={28'd0,be}<<(((addr>>2)&7)*4);
                    qd[nq]={8{wdata}};
                    nq++;
                    for(k=0;k<4;k++) if(be[k]) gold[(addr&32'hffff)>>2][k*8+:8]=wdata[k*8+:8];
                end
            end
            #1; clk=0; #1;
        end
    endtask

    /* policy: 0 ventana completa, 1 inicio tardío/reanudación antes del fill,
     * 2 pausa intermedia, 3 totalmente deshabilitada. Se conservan los datos
     * de la petición hasta su finalización, aunque cambie la ventana. */
    task automatic access(input logic load,input logic [31:0] a,input logic miss,
                          input logic [31:0] data,input logic [3:0] bytes_,
                          input integer policy,input integer exact_stalls,input string label_);
        integer n,stalls_;
        begin
            re=load; we=!load; addr=a; expected_miss=miss; wdata=data; be=bytes_;
            n=0; stalls_=0; finished=0;
            while(!finished && n<100) begin
                case(policy)
                    1: enable=n>=4;
                    2: enable=!(n>=2 && n<=4);
                    3: enable=0;
                    default: enable=1;
                endcase
                tick;
                if(!finished) stalls_++;
                n++;
            end
            check(finished,"timeout de acceso");
            if(exact_stalls>=0) check(stalls_==exact_stalls,$sformatf("%s: esperas esperadas %0d observadas %0d",label_,exact_stalls,stalls_));
            service+=n; waits+=stalls_;
            $display("K1A acceso RAW=%0d %s direccion=%h tipo=%s miss=%0d policy=%0d servicio=%0d stalls=%0d",RAW,label_,a,load?"read":"write",miss,policy,n,stalls_);
            re=0; we=0; enable=1;
        end
    endtask

    task automatic drain;
        integer n,i;
        logic [63:0] accesses_before;
        begin
            re=0; we=0; flush_req=1; n=0;
            accesses_before=t[2];
            while(!fd && n<100) begin tick; n++; end
            check(fd && nq==0 && !busy,"flush vacía stores y bus");
            check(t[2]===accesses_before,"flush no inventa accesos demandados");
            for(i=0;i<16384;i++) check(memory[i]===gold[i],"memoria después de flush");
            flush_req=0; tick;
        end
    endtask

    // Tasas de la ventana real: 19 finalizaciones medidas, 11 hits y 8
    // misses; las dos finalizaciones con ventana apagada quedan excluidas.
    task automatic real_rate(input logic [63:0] num,input logic [63:0] den,
                             input real wanted,input string label_);
        real ratio,delta;
        begin
            check(den!=0,"ventana real con denominador conocido no nulo");
            ratio=real'(num)/real'(den);
            delta=ratio-wanted; if(delta<0.0) delta=-delta;
            check(delta<1.0e-12,label_);
            $display("K1A tasa real RAW=%0d %s=%0.12f",RAW,label_,ratio);
        end
    endtask

    integer i;
    real mean_service;
    initial begin
        done=0;
        wait(go);
        if(!$value$plusargs("MUTATION=%d",mutation)) mutation=0;
        if(RAW==RAW_FORWARD) trace=$fopen("k1a-forward.csv","w");
        else trace=$fopen("k1a-stall.csv","w");
        check(trace!=0,"abrir traza externa de flancos");
        $fdisplay(trace,"raw,cycle,address,re,we,initial_miss,enable,expected_events,actual_events,queued,busy,rvalid,complete,metric_reset");
        for(i=0;i<16384;i++) begin memory[i]=32'h92100000^i; gold[i]=memory[i]; end
        for(i=0;i<19;i++) expected[i]=0;
        tick; reset=0; tick;
        // A, B y C comparten conjunto 5. A/B/A/C conserva A y desaloja B
        // por LRU de dos vías; no se modela internamente el reemplazo.
        access(1,32'h08ac,1,0,15,0,8,"cold-A");
        access(1,32'h08ac,0,0,15,0,0,"repeat-A");
        access(1,32'h08bc,0,0,15,0,0,"same-line-word7");
        access(1,32'h10ac,1,0,15,0,8,"conflict-B");
        access(1,32'h08ac,0,0,15,0,0,"touch-A");
        access(1,32'h18ac,1,0,15,0,8,"conflict-C");
        access(1,32'h08ac,0,0,15,0,0,"A-survives");
        access(1,32'h10ac,1,0,15,0,8,"B-evicted");
        // Store residente y byte selectivo: la CPU y la memoria de respuesta
        // se comprueban independientemente, además del evento hit de escritura.
        access(0,32'h08ac,0,32'h12345678,15,0,0,"store-hit");
        access(0,32'h08ac,0,32'h00aa0000,4'b0100,0,0,"store-byte-hit");
        drain;
        access(1,32'h08ac,0,0,15,0,0,"read-written-word");
        // Store NWA seguido inmediatamente por lectura: FWD sirve el dato
        // pendiente; STALL debe drenar antes de leer la línea.
        access(0,32'h3024,1,32'hdecaf123,15,0,0,"store-NWA");
        access(1,32'h3024,1,0,15,0,RAW==RAW_FORWARD?8:17,"RAW-read");
        drain;
        // El tercer store se presenta con dos entradas ocupadas. El bus ya
        // está drenando y no ofrece espacio hasta después de consumir rvalid.
        access(0,32'h08ac,0,32'h11111111,15,0,0,"full-1");
        access(0,32'h08ac,0,32'h22222222,15,0,0,"full-2");
        access(0,32'h08ac,0,32'h33333333,15,0,8,"full-3");
        drain;
        // Ventanas que cortan una espera: finalización y latencia completa
        // son magnitudes distintas. El prefijo se contrasta en cada flanco.
        access(1,32'h4024,1,0,15,1,8,"late-start");
        access(1,32'h4824,1,0,15,2,8,"pause-resume-miss");
        access(1,32'h4824,0,0,15,3,0,"disabled-hit");
        access(1,32'h5024,1,0,15,3,8,"disabled-miss");
        access(0,32'h4824,0,32'h01020304,15,0,0,"WB-before-pause");
        enable=0; repeat(4) tick; enable=1;
        drain;
        // Referencia cerrada adicional al prefijo: 12 lecturas medidas
        // (5H/7M) y 7 stores (6H/1M). Solo seis inicios de cada tipo L2
        // caen dentro de la ventana; las peticiones siguen fuera de ella.
        check(c[0]===5 && c[1]===7 && c[2]===6 && c[3]===1,"clasificación final de ventana conocida");
        check(c[4]===(RAW==RAW_FORWARD?64'd57:64'd66) && c[5]===8,"esperas de ventana conocida");
        check(c[6]===(RAW==RAW_FORWARD?64'd0:64'd1) && c[7]===(RAW==RAW_FORWARD?64'd1:64'd0),"RAW según política seleccionada");
        check(c[8]===7 && c[9]===6 && c[10]===6,"push y tráfico medido frente a guion");
        real_rate(t[3],t[2],11.0/19.0,"hit");
        real_rate(t[4],t[2],8.0/19.0,"miss");
        real_rate(c[0],t[0],5.0/12.0,"read-hit");
        real_rate(c[1],t[0],7.0/12.0,"read-miss");
        real_rate(c[2],t[1],6.0/7.0,"write-hit");
        real_rate(c[3],t[1],1.0/7.0,"write-miss");
        // Reset SOLO del consumidor con el productor a mitad de un miss:
        // no cancela la lectura ni altera el reloj o el protocolo de caché.
        re=1; addr=32'h6024; expected_miss=1;
        tick; metric_reset=1; tick; metric_reset=0;
        finished=0; steps=0;
        while(!finished && steps<20) begin tick; steps++; end
        check(finished,"lectura pendiente sobrevive reset de métricas");
        re=0;
        drain;
        check(starts_rd==9 && starts_wr==7,"totales físicos de solicitudes del guion");
        check(completed_rd==15 && completed_wr==7,"operaciones físicas del guion");
        check(observed_misses==10 && observed_hits==12,"clasificaciones físicas del guion");
        $display("K1A REAL RAW=%0d checks=%0d read_starts=%0d write_starts=%0d reads=%0d writes=%0d hits=%0d misses=%0d",RAW,checks,starts_rd,starts_wr,completed_rd,completed_wr,observed_hits,observed_misses);
        // La media excluye flush e inactividad y cubre los access() completos.
        // No representa AMAT de una jerarquía con L2 real o memoria principal.
        mean_service=real'(service)/(completed_rd+completed_wr-1);
        $display("K1A latencia observada RAW=%0d servicio=%0d esperas=%0d media=%0.12f (no AMAT)",RAW,service,waits,mean_service);
        $fclose(trace);
        done=1;
    end
endmodule

/* Guiones WB/exclusiva independientes del controlador: cada tick declara sus
 * eventos esperados. El respondedor manual solo entrega las líneas indicadas
 * por el guion; no reproduce tags, reemplazo ni máquinas de estados de L1-D. */
module k1a2_extended #(parameter integer NM=2)(input logic go,output logic done);
    localparam [18:0] RH=19'b1, RM=19'b1<<1, WH=19'b1<<2, WM=19'b1<<3,
        ST=19'b1<<4, PUSH=19'b1<<8, RD=19'b1<<9, WR=19'b1<<10,
        FILL=19'b1<<11, VD=19'b1<<12, VC=19'b1<<13, AL=19'b1<<14,
        MERGE=19'b1<<15, ML=19'b1<<16, HUM=19'b1<<17, FULL=19'b1<<18;
    logic clk=0,reset=1,metric_reset=0,enable=1;
    logic re=0,we=0,fr=0,gnt=1,rv=0,rdirty=0;
    logic [31:0] addr=0,data=0;
    logic [3:0] be=15;
    logic [255:0] line_=0;
    wire [18:0] ev,sev;
    logic [18:0] diag,previous=0;
    wire [63:0] c[0:18],t[0:4];
    logic [63:0] expected[0:18];
    wire [31:0] q,sq,la,sla,mask,smask;
    wire [255:0] wl,swl;
    wire stall,sstall,fd,sfd,rq,srq,lwe,slwe,wd,swd;
    integer checks=0,cycle=0,mutation=0,trace;
    logic held=0,pending=0;
    logic [31:0] heldaddr=0,pendingaddr=0;
    logic heldwe=0,helddirty=0;
    logic [255:0] heldline=0;
    logic [31:0] heldmask=0;
    logic [31:0] memory[0:16383],gold[0:16383];
    wire crst=reset|metric_reset;
    wire cen=enable|(mutation==15);
    // Los parámetros se fijan también en la sombra. RAW_FORWARD no permite
    // forwarding en exclusiva: la espera obligatoria la decide el productor.
`define K1A2_WB(NAME,E,Q,S,D,R,W,A,L,B,V) \
    l1d_cache #(.WRITE_POLICY(WP_WRITE_BACK),.INCL_POLICY(INCL_EXCLUSIVE), \
        .ALLOC_POLICY(AP_WRITE_ALLOC),.REPL_POLICY(RP_LRU),.RAW_POLICY(RAW_FORWARD), \
        .WB_DEPTH(2),.N_MSHR(NM),.L2_BUS_V2(1)) NAME ( \
        .clk(clk),.reset(reset),.re(re),.we(we),.be(be),.addr(addr),.wdata(data),.rdata(Q),.stall(S), \
        .flush_req(fr),.flush_done(D),.l2_req(R),.l2_we(W),.l2_addr(A),.l2_wline(L),.l2_be(B),.l2_wdirty(V), \
        .l2_gnt(gnt),.l2_rvalid(rv),.l2_rdirty(rdirty),.l2_rline(line_), \
        .ev_rd_hit(E[0]),.ev_rd_miss(E[1]),.ev_wr_hit(E[2]),.ev_wr_miss(E[3]), \
        .ev_stall(E[4]),.ev_wb_full_stall(E[5]),.ev_raw_stall(E[6]),.ev_raw_forward(E[7]), \
        .ev_wb_push(E[8]),.ev_l2_read(E[9]),.ev_l2_write(E[10]),.ev_fill(E[11]), \
        .ev_victim_dirty(E[12]),.ev_victim_clean(E[13]),.ev_mshr_alloc(E[14]), \
        .ev_mshr_merge(E[15]),.ev_mshr_load(E[16]),.ev_hit_under_miss(E[17]),.ev_mshr_full_stall(E[18]));
    `K1A2_WB(CACHE,ev,q,stall,fd,rq,lwe,la,wl,mask,wd)
    `K1A2_WB(SHADOW,sev,sq,sstall,sfd,srq,slwe,sla,swl,smask,swd)
    `K1A_COUNTER(COUNTERS,clk,crst,cen,diag,c,t)
`undef K1A2_WB

    // Solo las entradas del consumidor cambian en los controles negativos.
    always @* begin
        diag=ev;
        case(mutation)
            10: diag[14]=ev[14]|previous[14];
            11: diag[15]=0;
            12: diag[11]=0;
            13: begin diag[12]=0; diag[13]=ev[13]|ev[12]; end
            14: diag[18]=ev[18]|previous[18];
            default: begin end
        endcase
    end
    task automatic check(input logic ok,input string why);
        begin
            checks++;
            if(ok!==1'b1) $fatal(1,"K1A2 NM=%0d ciclo=%0d mutacion=%0d: %s",NM,cycle,mutation,why);
        end
    endtask

    /* target y dirty indican la transacción conocida que debe comenzar. Una
     * petición retenida se compara hasta su grant; las lecturas aceptadas se
     * recuerdan por separado hasta rvalid. Las escrituras no generan respuesta. */
    task automatic tick(input logic [18:0] want,input logic [31:0] target=0,input logic dirty=0);
        integer i,j;
        logic request_,write_;
        begin
            #2; cycle++;
            if(!reset) begin
                check(ev===want,$sformatf("eventos esperado=%b observado=%b",want,ev));
                check({q,stall,fd,rq,lwe,la,wl,mask,wd,ev}===
                      {sq,sstall,sfd,srq,slwe,sla,swl,smask,swd,sev},"pasividad de caché sombra");
                check(stall===want[4],"stall esperado del guion");
                request_=held||want[9]||want[10];
                check(rq===request_,"solicitud pública esperada");
                if(held) begin
                    check({lwe,la,mask,wd}==={heldwe,heldaddr,heldmask,helddirty},"petición estable hasta grant");
                    // Los datos solo tienen significado en una escritura.
                    if(heldwe) check(wl===heldline,"línea retenida antes del grant");
                end else if(request_) begin
                    check(la===target && lwe===want[10],"tipo y dirección al iniciar");
                    check(wd===dirty,"dirty al iniciar");
                    check(mask===(want[10]?32'hffffffff:32'd0),"máscara de la transacción");
                    if(want[10]) for(i=0;i<8;i++)
                        check(wl[i*32+:32]===gold[(target>>2)+i],"bytes de víctima/flush frente a CPU");
                end
                check(rv===want[11],"una respuesta de lectura por llenado");
                if(rv) check(pending,"respuesta solo después de aceptación");
                if(want[0]||want[1]) check(q===gold[addr[15:2]],"dato de carga frente a referencia");
                if(!metric_reset&&enable) for(i=0;i<19;i++) if(want[i]) expected[i]++;
                // Persistencia observable: solo al grant de una escritura.
                if(rq&&gnt&&lwe) for(i=0;i<32;i++) if(mask[i])
                    memory[(la>>2)+i/4][8*(i%4)+:8]=wl[8*i+:8];
                if(rv) pending=0;
                if(rq&&gnt&&!lwe) begin
                    check(!pending,"no se acepta dos veces la misma lectura");
                    pending=1; pendingaddr=la;
                end
                if(!held && request_) begin
                    heldaddr=target; heldwe=want[10]; heldmask=mask; helddirty=dirty; heldline=wl;
                end
                held=request_&&!gnt;
            end
            // La traza conserva el mismo muestreo PRE usado por las aserciones.
            $fdisplay(trace,"%0d,%0d,%h,%h,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%0d,%h,%h",NM,cycle,addr,want,ev,enable,metric_reset,gnt,rv,rdirty,rq,lwe,la,wd,mask,wl);
            if(crst) for(i=0;i<19;i++) expected[i]=0;
            clk=1; #1;
            for(i=0;i<19;i++) check(c[i]===expected[i],$sformatf("contador[%0d] esperado=%0d observado=%0d",i,expected[i],c[i]));
            check(t[0]===expected[0]+expected[1],"lecturas anteriores conservadas");
            check(t[1]===expected[2]+expected[3],"escrituras anteriores conservadas");
            check(t[2]===expected[0]+expected[1]+expected[2]+expected[3],"total sin sumar MSHR/fills/víctimas");
            check(t[3]===expected[0]+expected[2] && t[4]===expected[1]+expected[3],"totales hit/miss anteriores");
            previous=want;
            if(reset) begin held=0; pending=0; previous=0; end
            #1; clk=0; #1;
        end
    endtask

    task automatic respond(input logic [18:0] want,input logic dirty=0);
        integer i;
        begin
            check(pending,"hay una lectura conocida pendiente");
            for(i=0;i<8;i++) line_[i*32+:32]=memory[(pendingaddr>>2)+i];
            rdirty=dirty; rv=1; tick(want); rv=0; rdirty=0;
        end
    endtask

    // Para escenarios de reemplazo se dejan ocho esperas desde el grant;
    // una lectura limpia o sucia entrante produce un único fill al responder.
    task automatic load_cold(input logic [31:0] a,input logic [18:0] victim=0,input logic dirty=0);
        begin
            re=1; we=0; addr=a;
            tick(ST|RD,a&32'hffe0);
            repeat(7) tick(ST);
            respond(RM|FILL|victim,dirty);
            re=0;
        end
    endtask

    task automatic store_hit(input logic [31:0] a,input logic [31:0] d,input logic [18:0] extra=0);
        begin
            addr=a; re=0; we=1; data=d; be=15;
            gold[a>>2]=d;
            tick(WH|extra); we=0;
        end
    endtask

    // Un guion nuevo arranca con caché vacía. La memoria no cambia al reset
    // del consumidor; aquí el reset común se reserva para separar escenarios.
    task automatic fresh;
        integer i;
        begin
            reset=1; re=0; we=0; fr=0; rv=0; enable=1; metric_reset=0; gnt=1;
            for(i=0;i<16384;i++) begin memory[i]=32'h98100000^i; gold[i]=memory[i]; end
            tick(0); reset=0;
        end
    endtask

    integer i,j;
    logic [31:0] a;
    initial begin
        done=0; wait(go);
        if(!$value$plusargs("MUTATION=%d",mutation)) mutation=0;
        trace=$fopen($sformatf("k1a2-mshr-%0d.csv",NM),"w");
        check(trace!=0,"abrir traza de eventos nuevos");
        $fdisplay(trace,"capacity,cycle,address,expected_events,actual_events,enable,metric_reset,gnt,rvalid,rdirty,req,we,l2_addr,wdirty,byte_enable,wline");
        for(i=0;i<19;i++) expected[i]=0;
        fresh;
        // A/B/C/D comparten conjunto 5. A se ensucia, C desaloja A y D
        // desaloja B limpia. Los dirty bits viajan con cada víctima, no son
        // inferidos por el consumidor a partir de los datos.
        load_cold(32'h08a0);
        store_hit(32'h08a0,32'h12345678);
        load_cold(32'h10a0);
        load_cold(32'h18a0,PUSH|VD);
        // Retención de escritura con gnt apagado: solo el primer ciclo
        // presenta ev_l2_write; dirección, máscara, datos y dirty se mantienen.
        gnt=0; tick(WR,32'h08a0,1); repeat(3) tick(0);
        gnt=1; tick(0);
        load_cold(32'h20a0,PUSH|VC);
        tick(WR,32'h10a0,0);
        // l2_rdirty=1 debe sobrevivir al siguiente reemplazo aunque la CPU
        // nunca haga store en la línea: E entra sucia y G la desaloja.
        load_cold(32'h28a0,PUSH|VC,1); tick(WR,32'h18a0,0);
        load_cold(32'h30a0,PUSH|VC); tick(WR,32'h20a0,0);
        load_cold(32'h38a0,PUSH|VD); tick(WR,32'h28a0,1);
        check(c[11]===7 && c[12]===2 && c[13]===3,"fills y víctimas del guion LRU");
        // Store miss con NM=1 bloquea; con NM>=2 se retira antes del fill.
        fresh;
        if(NM==1) begin
            addr=32'h0940; we=1; data=32'haaaa0001; gold[addr>>2]=data;
            tick(ST|RD,32'h0940); repeat(7) tick(ST);
            respond(WM|FILL); we=0;
            check(c[14]===0 && c[4]===8,"NM=1 es bloqueante sin reserva MSHR");
        end else begin
            // H reside en conjunto 20; X en conjunto 10 entra primero al
            // MSHR. Las operaciones siguientes suceden antes de su respuesta.
            load_cold(32'h1280);
            addr=32'h0940; we=1; data=32'haaaa0001; gold[addr>>2]=data;
            tick(WM|AL); we=0;
            addr=32'h0944; we=1; data=32'hbbbb0002; gold[addr>>2]=data;
            tick(WM|MERGE|RD,32'h0940); we=0;
            addr=32'h0940; re=1; tick(RM|ML); re=0;
            addr=32'h1280; re=1; tick(RH|HUM); re=0;
            store_hit(32'h1284,32'hcccc0003,HUM);
            tick(0); tick(0); tick(0); tick(0);
            respond(FILL);
            addr=32'h0944; re=1; tick(RH); re=0;
            check(c[14]===1 && c[15]===1 && c[16]===1 && c[17]===2,"reserva, mezcla, carga MSHR y dos hits bajo miss");
        end
        // Otra escena llena exactamente NM reservas. La respuesta se demora
        // deliberadamente hasta comprobar tres ciclos con MSHR llenos; el
        // flanco de fill también bloquea al store por el puerto único, pero
        // NO activa la causa MSHR lleno. Capacidad no equivale a latencia.
        if(NM>=2) begin
            fresh;
            for(i=0;i<NM;i++) begin
                addr=32'h0a00+i*32; we=1; data=32'h55550000+i; gold[addr>>2]=data;
                tick(WM|AL|(i==1?RD:0),i==1?32'h0a00:0); we=0;
            end
            addr=32'h0a00+NM*32; we=1; data=32'h77770000; gold[addr>>2]=data;
            repeat(3) tick(ST|FULL);
            respond(ST|FILL);
            tick(WM|AL|RD,32'h0a20); we=0;
            check(c[18]===3 && c[4]===4,"tres stalls de capacidad más uno de fill, sin duplicación");
            // Completar en orden todos los stores aceptados, sin acceder a
            // colas privadas. Cada línea usa un conjunto vacío distinto.
            for(i=1;i<=NM;i++) begin
                respond(FILL);
                if(i<NM) tick(RD,32'h0a00+(i+1)*32);
            end
            for(i=0;i<=NM;i++) begin addr=32'h0a00+i*32; re=1; tick(RH); re=0; end
            check(c[14]==NM+1 && c[11]==NM+1,"reservas/fills únicos de la ráfaga");
        end
        // Flush de líneas conocidas, después de drenar MSHR. Los stores de
        // esta escena llenaron siempre la vía 0: el recorrido público pasa
        // por conjunto*2. El guion fija en qué flanco aparece cada push.
        // Con NM=1 hay una línea sucia en conjunto 10; con 2/4 están en 16..NM+16.
        fr=1; tick(0);
        for(j=0;j<128;j++) begin
            if(NM==1) begin
                if(j==20) tick(PUSH);
                else if(j==21) tick(WR,32'h0940,1);
                else tick(0);
            end else begin
                if(j>=32 && j<=32+2*NM && j%2==0) tick(PUSH);
                else if(j>=33 && j<=33+2*NM && j%2==1)
                    tick(WR,32'h0a00+((j-33)/2)*32,1);
                else tick(0);
            end
        end
        tick(0); tick(0); check(fd,"flush termina sin accesos ficticios");
        fr=0; tick(0);
        for(i=0;i<16384;i++) check(memory[i]===gold[i],"memoria completa después de flush exclusivo");
        // En exclusiva, la línea sucia vaciada debe volver como miss público.
        // También se verifica una ventana apagada y reset de nuevos contadores.
        enable=0; load_cold(NM==1?32'h0940:32'h0a00);
        enable=1; metric_reset=1; tick(0); metric_reset=0;
        for(i=0;i<19;i++) check(c[i]===0,"reset completo tras nuevos eventos reales");
        $display("[PASS] K1A2 NM=%0d: %0d verificaciones",NM,checks);
        $fclose(trace); done=1;
    end
endmodule

/* Los casos sintéticos separan acumulación del contrato del productor. Incluso
 * causas coincidentes deben acumularse sin prioridad; sus sumas no son stalls. */
module tb_perf_cache_l1d_k1a;
    logic clk=0,reset=1,enable=1;
    integer mutation=0;
    logic reset_negative_active=0;
    // El control negativo 16 omite el reset únicamente en una escena donde
    // solo fill_events es no nulo, para detectar el borrado de eventos nuevos.
    wire unit_reset=reset && !(mutation==16 && reset_negative_active);
    logic [18:0] ev=0;
    wire [63:0] c[0:18],t[0:4];
    logic [63:0] expected[0:18];
    integer checks=0,i,j;
    logic go_f=0,go_s=0;
    logic go_1=0,go_2=0,go_4=0;
    wire done_1,done_2,done_4;
    k1a2_extended #(.NM(1)) ext1(go_1,done_1);
    k1a2_extended #(.NM(2)) ext2(go_2,done_2);
    k1a2_extended #(.NM(4)) ext4(go_4,done_4);
    wire done_f,done_s;
    k1a_real #(.RAW(RAW_FORWARD)) forward_case(go_f,done_f);
    k1a_real #(.RAW(RAW_STALL)) stall_case(go_s,done_s);
    `K1A_COUNTER(UNIT,clk,unit_reset,enable,ev,c,t)

    task automatic check(input logic ok,input string why);
        begin checks++; if(ok!==1'b1) $fatal(1,"K1A sintético: %s",why); end
    endtask
    task automatic step(input logic rst,input logic en,input logic [18:0] events_);
        integer k;
        begin
            reset=rst; enable=en; ev=events_;
            if(rst) for(k=0;k<19;k++) expected[k]=0;
            else if(en) for(k=0;k<19;k++) if(events_[k]) expected[k]++;
            #3; clk=1; #1;
            for(k=0;k<19;k++) check(c[k]===expected[k],$sformatf("contador[%0d]",k));
            check(t[0]===expected[0]+expected[1],"lecturas derivadas");
            check(t[1]===expected[2]+expected[3],"escrituras derivadas");
            check(t[2]===expected[0]+expected[1]+expected[2]+expected[3],"accesos derivados");
            check(t[3]===expected[0]+expected[2],"hits derivados");
            check(t[4]===expected[1]+expected[3],"misses derivados");
            #1; clk=0; #1;
        end
    endtask

    // Cocientes reales con referencia explícita. No se usa división entera
    // ni se convierte una ventana sin accesos en una tasa igual a cero.
    task automatic rate(input logic [63:0] numerator,input logic [63:0] denominator,
                        input real wanted,input string label_);
        real value_,difference;
        begin
            if(denominator==0) begin
                $display("K1A tasa %s: NO DEFINIDO",label_);
                check(wanted<0.0,"denominador cero declarado indefinido");
            end else begin
                value_=real'(numerator)/real'(denominator);
                difference=value_-wanted;
                if(difference<0.0) difference=-difference;
                check(difference<1.0e-12,label_);
                $display("K1A tasa %s: %.12f",label_,value_);
            end
        end
    endtask

    task automatic preload(input integer index_,input logic [63:0] value_);
        begin
            // Acceso de prueba exclusivo a registros del consumidor, sin force
            // ni lecturas del estado privado de caché. Evita simular 2^64 ciclos.
            case(index_)
                0: UNIT.read_hits=value_;
                1: UNIT.read_misses=value_;
                2: UNIT.write_hits=value_;
                3: UNIT.write_misses=value_;
                4: UNIT.stall_cycles=value_;
                5: UNIT.wb_full_stall_cycles=value_;
                6: UNIT.raw_stall_cycles=value_;
                7: UNIT.raw_forward_events=value_;
                8: UNIT.wb_push_events=value_;
                9: UNIT.l2_read_requests=value_;
                10: UNIT.l2_write_requests=value_;
                11: UNIT.fill_events=value_;
                12: UNIT.victim_dirty_events=value_;
                13: UNIT.victim_clean_events=value_;
                14: UNIT.mshr_alloc_events=value_;
                15: UNIT.mshr_merge_events=value_;
                16: UNIT.mshr_load_events=value_;
                17: UNIT.hit_under_miss_events=value_;
                18: UNIT.mshr_full_stall_cycles=value_;


            endcase
            expected[index_]=value_;
        end
    endtask

    initial begin
        if($test$plusargs("VCD")) begin
            $dumpfile("tb_perf_cache_l1d_k1a.vcd");
            $dumpvars(0,tb_perf_cache_l1d_k1a);
        end
        if(!$value$plusargs("MUTATION=%d",mutation)) mutation=0;
        for(i=0;i<19;i++) expected[i]=0;
        // Un fill aislado prueba reset de los nuevos acumuladores sin que
        // un contador antiguo enmascare la primera divergencia del control 16.
        step(1,1,0); step(0,1,19'b1<<11);
        reset_negative_active=1; step(1,1,0); reset_negative_active=0;
        // Reset con todos los eventos activos y habilitación; prioridad total.
        step(1,1,'1);
        rate(t[3],t[2],-1.0,"empty-hit");
        rate(t[4],t[2],-1.0,"empty-miss");
        rate(c[0],t[0],-1.0,"empty-read-hit");
        rate(c[1],t[0],-1.0,"empty-read-miss");
        rate(c[2],t[1],-1.0,"empty-write-hit");
        rate(c[3],t[1],-1.0,"empty-write-miss");
        step(0,1,0);
        // Diecinueve eventos individuales, repetidos sin separar niveles activos.
        for(i=0;i<19;i++) begin step(0,1,19'b1<<i); step(0,1,19'b1<<i); end
        step(0,0,'1); step(0,0,0); step(0,1,0);
        step(0,1,11'b10100000100); // store hit + push + drenado independiente.
        step(0,1,11'b00001110000); // causas de espera sintéticas coincidentes.
        step(1,0,'1); // Reset también opera cuando la ventana está deshabilitada.
        // Store miss no bloqueante: demanda, reserva e inicio pertenecen
        // a magnitudes independientes. Un stall MSHR se observa también
        // en el total sin sumarlo otra vez al contador de ciclos de espera.
        step(0,1,(19'b1<<3)|(19'b1<<14)|(19'b1<<9));
        step(0,1,(19'b1<<4)|(19'b1<<18));
        step(0,0,'1); step(0,1,0); step(1,1,'1);
        // Dataset explícito: lecturas 3H/1M, escrituras 1H/3M, total 4H/4M.
        repeat(3) step(0,1,1); step(0,1,2);
        step(0,1,4); repeat(3) step(0,1,8);
        check(t[2]===8 && t[3]===4 && t[4]===4,"dataset de tasas conocido");
        rate(t[3],t[2],0.5,"hit"); rate(t[4],t[2],0.5,"miss");
        rate(c[0],t[0],0.75,"read-hit"); rate(c[1],t[0],0.25,"read-miss");
        rate(c[2],t[1],0.25,"write-hit"); rate(c[3],t[1],0.75,"write-miss");
        check(real'(t[3])/real'(t[2])+real'(t[4])/real'(t[2])==1.0,"tasas complementarias");
        // Acarreo de 32 a 33 bits y vuelta de 64 bits en TODOS los acumuladores.
        for(i=0;i<19;i++) begin
            step(1,1,0);
            preload(i,64'hffffffff); step(0,1,19'b1<<i);
            check(c[i]===64'h100000000,"acarreo más allá de 32 bits");
            preload(i,64'hffffffffffffffff); step(0,1,19'b1<<i);
            check(c[i]===0,"overflow módulo 2^64");
        end
        // Los totales combinacionales también tienen ancho fijo y desbordan.
        step(1,1,0); preload(0,64'hffffffffffffffff); preload(1,1);
        step(0,1,0); check(t[0]===0 && t[2]===0,"overflow de totales derivados");
        go_f=1; wait(done_f); go_s=1; wait(done_s);
        go_1=1; wait(done_1); go_2=1; wait(done_2); go_4=1; wait(done_4);
        $display("[PASS] tb_perf_cache_l1d_k1a: %0d verificaciones",checks+forward_case.checks+stall_case.checks+ext1.checks+ext2.checks+ext4.checks);
        $finish;
    end
    initial begin #200000; $fatal(1,"K1A timeout global"); end
endmodule
`undef K1A_COUNTER
`undef K1A_CACHE
