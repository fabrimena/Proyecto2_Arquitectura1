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
    .total_misses(T[4]));
`define K1A_CACHE(NAME, RAW_, EV, Q, ST, DONE_, RQ, WE_, A_, DATA_, BE_) \
l1d_cache #(.ALLOC_POLICY(AP_NO_WRITE_ALLOC),.REPL_POLICY(RP_LRU),.RAW_POLICY(RAW_),.WB_DEPTH(2)) NAME ( \
    .clk(clk),.reset(reset),.re(re),.we(we),.be(be),.addr(addr),.wdata(wdata),.rdata(Q),.stall(ST), \
    .flush_req(flush_req),.flush_done(DONE_),.l2_req(RQ),.l2_we(WE_),.l2_addr(A_),.l2_wline(DATA_),.l2_be(BE_), \
    .l2_ready(ready),.l2_rline(rline), \
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
    .ev_l2_write(EV[10]));


/* Dos cachés originales reciben el mismo estímulo; solo una tiene consumidor.
 * La referencia conoce las operaciones, dos entradas FIFO públicas y el contrato
 * de respuesta de ocho esperas. Nunca consulta registros privados de L1-D. */
module k1a_real #(parameter RAW = RAW_FORWARD)(input logic go, output logic done);
    logic clk=0, reset=1, metric_reset=0, enable=1;
    logic re=0,we=0,flush_req=0,ready=0;
    logic [3:0] be=15;
    logic [31:0] addr=0,wdata=0,q,qs,la,las;
    logic [255:0] rline=0,wl,wls;
    logic [31:0] mask,masks;
    wire [10:0] ev,shadow_ev;
    logic [10:0] diagnostic;
    wire st,sts,fd,fds,rq,rqs,lwe,lwes;
    wire [63:0] c[0:10],t[0:4];
    wire crst=reset|metric_reset;
    wire cen=enable | (mutation==7);
    `K1A_CACHE(CACHE,RAW,ev,q,st,fd,rq,lwe,la,wl,mask)
    `K1A_CACHE(SHADOW,RAW,shadow_ev,qs,sts,fds,rqs,lwes,las,wls,masks)
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
    logic [63:0] expected[0:10];
    logic [10:0] previous=0;

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
     * POST: se contrastan los once acumulados y cinco sumas tras sus NBA.
     * La cola de referencia contiene stores aceptados, no señales de WBUF. */
    task automatic tick;
        logic pending,fill,complete,start_read,start_write,pop;
        logic [10:0] want;
        logic [31:0] target,expected_data;
        integer i,j,k;
        begin
            #2;
            cycle++;
            want=0;
            finished=0;
            pending=0;
            for(i=0;i<nq;i++) if(qa[i]==(addr&32'hffe0)) pending=1;
            fill=busy && ready && !buswrite;
            complete=(re||we) && (re ? (!expected_miss||fill) : nq<2);
            start_read=!busy && re && expected_miss && !(RAW==RAW_STALL && pending);
            start_write=!busy && !start_read && nq>0;
            pop=busy && ready && buswrite;
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
                check(ev===want,$sformatf("eventos productor: esperado=%b observado=%b",want,ev));
                check(st===want[4],"stall contra finalización esperada");
                check({q,st,fd,rq,lwe,la,wl,mask,ev} ===
                      {qs,sts,fds,rqs,lwes,las,wls,masks,shadow_ev},"pasividad: salidas públicas distintas");
                check(rq===(busy||start_read||start_write),"presencia de transacción L2");
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
                    for(i=0;i<11;i++) if(want[i]) expected[i]++;
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
                $fdisplay(trace,"%0d,%0d,%h,%0d,%0d,%0d,%0d,%b,%b,%0d,%0d,%0d,%0d,%0d",RAW,cycle,addr,re,we,expected_miss,enable,want,ev,nq,busy,ready,complete,metric_reset);
            end
            if(crst) for(i=0;i<11;i++) expected[i]=0;
            clk=1;
            #1;
            for(i=0;i<11;i++)
                check(c[i]===expected[i],$sformatf("contador[%0d] esperado=%0d observado=%0d",i,expected[i],c[i]));
            check(t[0]===expected[0]+expected[1],"total lecturas");
            check(t[1]===expected[2]+expected[3],"total escrituras");
            check(t[2]===expected[0]+expected[1]+expected[2]+expected[3],"total accesos");
            check(t[3]===expected[0]+expected[2],"total hits");
            check(t[4]===expected[1]+expected[3],"total misses");
            check(t[3]+t[4]===t[2],"partición hits/misses");

            // Respuesta mínima registrada: ocho flancos de espera en una
            // solicitud nueva. No hay tags, reemplazo ni políticas de L2.
            if(reset) begin
                busy=0; ready=0; nq=0; age=0; previous=0;
            end else begin
                previous=want;
                if(busy) begin
                    if(ready) begin ready=0; busy=0; end
                    else begin
                        if(age==7) begin
                            for(j=0;j<8;j++) begin
                                if(buswrite) begin
                                    for(k=0;k<4;k++) if(busmask[j*4+k])
                                        memory[(busaddr>>2)+j][k*8+:8]=busdata[(j*4+k)*8+:8];
                                end else rline[j*32+:32]=memory[(busaddr>>2)+j];
                            end
                            ready=1;
                        end
                        age++;
                    end
                end else if(start_read||start_write) begin
                    busy=1; buswrite=start_write; age=1;
                    busaddr=start_read?(addr&32'hffe0):qa[0];
                    busdata=start_write?qd[0]:0;
                    busmask=start_write?qm[0]:0;
                end
                // El pop corresponde al ready consumido, no a la generación
                // de ready. Con FIFO llena, un pop no habilita el push previo.
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
        $fdisplay(trace,"raw,cycle,address,re,we,initial_miss,enable,expected_events,actual_events,queued,busy,ready,complete,metric_reset");
        for(i=0;i<16384;i++) begin memory[i]=32'h92100000^i; gold[i]=memory[i]; end
        for(i=0;i<11;i++) expected[i]=0;
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
        // está drenando y no ofrece espacio hasta después de consumir ready.
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

/* Los casos sintéticos separan acumulación del contrato del productor. Incluso
 * causas coincidentes deben acumularse sin prioridad; sus sumas no son stalls. */
module tb_perf_cache_l1d_k1a;
    logic clk=0,reset=1,enable=1;
    logic [10:0] ev=0;
    wire [63:0] c[0:10],t[0:4];
    logic [63:0] expected[0:10];
    integer checks=0,i,j;
    logic go_f=0,go_s=0;
    wire done_f,done_s;
    k1a_real #(.RAW(RAW_FORWARD)) forward_case(go_f,done_f);
    k1a_real #(.RAW(RAW_STALL)) stall_case(go_s,done_s);
    `K1A_COUNTER(UNIT,clk,reset,enable,ev,c,t)

    task automatic check(input logic ok,input string why);
        begin checks++; if(ok!==1'b1) $fatal(1,"K1A sintético: %s",why); end
    endtask
    task automatic step(input logic rst,input logic en,input logic [10:0] events_);
        integer k;
        begin
            reset=rst; enable=en; ev=events_;
            if(rst) for(k=0;k<11;k++) expected[k]=0;
            else if(en) for(k=0;k<11;k++) if(events_[k]) expected[k]++;
            #3; clk=1; #1;
            for(k=0;k<11;k++) check(c[k]===expected[k],$sformatf("contador %0d",k));
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

            endcase
            expected[index_]=value_;
        end
    endtask

    initial begin
        if($test$plusargs("VCD")) begin
            $dumpfile("tb_perf_cache_l1d_k1a.vcd");
            $dumpvars(0,tb_perf_cache_l1d_k1a);
        end
        for(i=0;i<11;i++) expected[i]=0;
        // Reset con todos los eventos activos y habilitación; prioridad total.
        step(1,1,'1);
        rate(t[3],t[2],-1.0,"empty-hit");
        rate(t[4],t[2],-1.0,"empty-miss");
        rate(c[0],t[0],-1.0,"empty-read-hit");
        rate(c[1],t[0],-1.0,"empty-read-miss");
        rate(c[2],t[1],-1.0,"empty-write-hit");
        rate(c[3],t[1],-1.0,"empty-write-miss");
        step(0,1,0);
        // Once eventos individuales, repetidos sin separar niveles activos.
        for(i=0;i<11;i++) begin step(0,1,11'b1<<i); step(0,1,11'b1<<i); end
        step(0,0,'1); step(0,0,0); step(0,1,0);
        step(0,1,11'b10100000100); // store hit + push + drenado independiente.
        step(0,1,11'b00001110000); // causas de espera sintéticas coincidentes.
        step(1,0,'1); // Reset también opera cuando la ventana está deshabilitada.
        // Dataset explícito: lecturas 3H/1M, escrituras 1H/3M, total 4H/4M.
        repeat(3) step(0,1,1); step(0,1,2);
        step(0,1,4); repeat(3) step(0,1,8);
        check(t[2]===8 && t[3]===4 && t[4]===4,"dataset de tasas conocido");
        rate(t[3],t[2],0.5,"hit"); rate(t[4],t[2],0.5,"miss");
        rate(c[0],t[0],0.75,"read-hit"); rate(c[1],t[0],0.25,"read-miss");
        rate(c[2],t[1],0.25,"write-hit"); rate(c[3],t[1],0.75,"write-miss");
        check(real'(t[3])/real'(t[2])+real'(t[4])/real'(t[2])==1.0,"tasas complementarias");
        // Acarreo de 32 a 33 bits y vuelta de 64 bits en TODOS los acumuladores.
        for(i=0;i<11;i++) begin
            step(1,1,0);
            preload(i,64'hffffffff); step(0,1,11'b1<<i);
            check(c[i]===64'h100000000,"acarreo más allá de 32 bits");
            preload(i,64'hffffffffffffffff); step(0,1,11'b1<<i);
            check(c[i]===0,"overflow módulo 2^64");
        end
        // Los totales combinacionales también tienen ancho fijo y desbordan.
        step(1,1,0); preload(0,64'hffffffffffffffff); preload(1,1);
        step(0,1,0); check(t[0]===0 && t[2]===0,"overflow de totales derivados");
        go_f=1; wait(done_f); go_s=1; wait(done_s);
        $display("[PASS] tb_perf_cache_l1d_k1a: %0d verificaciones",checks+forward_case.checks+stall_case.checks);
        $finish;
    end
    initial begin #200000; $fatal(1,"K1A timeout global"); end
endmodule
`undef K1A_COUNTER
`undef K1A_CACHE
