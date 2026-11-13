/*
 * tb_perf_cache_l1d_k1b: dos niveles independientes para el servicio de L1-D.
 * La unidad recibe guiones temporales; las cachés reales reciben demandas y
 * respuestas públicas con WB/EXCLUSIVA/WA/LRU, WBUF4 y MSHR 1, 2 y 4.
 * Otra pareja usa l2_model y DMEM de 64 KiB para probar el modelo vigente.
 *
 * K1-A conserva sus propios tests; aquí no se altera su código. Cada pareja
 * CACHE/SHADOW recibe el mismo estímulo, sin retorno desde las métricas.
 * Los eventos de demanda se contrastan con clases declaradas por operación;
 * el servicio esperado procede de fechas o de guiones de espera explícitos.
 * Ninguna expectativa consulta etiquetas, colas o estados privados de L1-D.
 * El modelo temporal no acredita dos cachés exclusivas ni AMAT definitivo.
 *
 * El reloj manual deja entradas estables PRE y verifica resultados POST-NBA.
 * Las tareas acotan todos los bucles; el watchdog global evita un banco colgado.
 * +VCD genera ondas públicas en el directorio externo de ejecución.
 */
`timescale 1ns/1ps
`include "cache_defs.sv"

/* Comparador común, sin reloj propio. El guion externo declara operaciones
 * completas y tiempos esperados; el probe nunca reconstruye los desde el DUT.
 * Guarda únicamente sumas de referencia y compara los 64 bits, particiones y
 * ausencia de X/Z. Las tareas no avanzan el reloj: las invoca el dueño del guion.
 */
module k1b_probe(input logic clk, reset, enable, re, we, stall,
                 input logic [3:0] events);
    // c/s/w tienen exactamente las clases públicas RH/RM/WH/WM del monitor.
    wire [3:0][63:0] c,s,w;
    wire [63:0] total,reads,writes,hits,misses,service,waits,zero,excluded,errors,age;
    wire pending,eligible;
    logic [63:0] ec[0:3],es[0:3],ew[0:3];
    logic [63:0] ez=0,ee=0,ep=0;
    integer checks=0;
    perf_cache_l1d_latency DUT(.clk(clk),.reset(reset),.measure_enable(enable),
        .re(re),.we(we),.stall(stall),.ev_rd_hit(events[0]),.ev_rd_miss(events[1]),
        .ev_wr_hit(events[2]),.ev_wr_miss(events[3]),
        .completed_by_class(c),.service_by_class(s),.wait_by_class(w),
        .completed_accesses(total),.completed_reads(reads),.completed_writes(writes),
        .completed_hits(hits),.completed_misses(misses),.service_cycles(service),
        .wait_cycles(waits),.no_wait_accesses(zero),.excluded_accesses(excluded),
        .protocol_errors(errors),.pending(pending),.pending_eligible(eligible),
        .pending_wait_cycles(age));

    // Un fallo detiene en el primer desacuerdo e identifica jerarquía y razón.
    // El contador refleja aserciones ejecutadas, no programas ni casos distintos.
    task automatic check(input logic ok,input string why);
        begin
            checks++;
            if(ok!==1'b1) $fatal(1,"K1B_FIRST_DIVERGENCE %m t=%0t %s",$time,why);
        end
    endtask

    // Nueva época de referencia: solo borra el modelo de sumas del banco.
    // El guion debe acompañarla con un flanco de reset real del consumidor.
    task automatic clear_expected;
        begin
            for(integer k=0;k<4;k++) begin ec[k]=0; es[k]=0; ew[k]=0; end
            ez=0; ee=0; ep=0;
        end
    endtask

    // cls y nwait proceden del caso conocido, nunca de c/s/w. Una operación
    // parcial terminada habilitada se excluye; con ventana apagada no suma nada.
    task automatic completion_expected(input integer cls,input logic [63:0] nwait,
                                         input logic whole,input logic en);
        begin
            if(whole) begin
                ec[cls]++; es[cls]+=nwait+64'd1; ew[cls]+=nwait;
                if(nwait==0) ez++;
            end else if(en) ee++;
        end
    endtask

    // Se invoca tras NBA. Las igualdades modulares son válidas también tras
    // overflow; no se afirma service>=total una vez que hayan desbordado.
    task automatic verify;
        begin
            for(integer k=0;k<4;k++) begin
                check(c[k]===ec[k],$sformatf("cantidad clase=%0d esperada=%0d observada=%0d",k,ec[k],c[k]));
                check(s[k]===es[k],$sformatf("servicio clase=%0d esperado=%0d observado=%0d",k,es[k],s[k]));
                check(w[k]===ew[k],$sformatf("espera clase=%0d esperada=%0d observada=%0d",k,ew[k],w[k]));
                check(s[k]===c[k]+w[k],"servicio = accesos + espera por clase, módulo 2^64");
            end
            check(reads===ec[0]+ec[1] && writes===ec[2]+ec[3],"partición lecturas/stores");
            check(hits===ec[0]+ec[2] && misses===ec[1]+ec[3],"partición hit/miss");
            check(total===reads+writes && total===hits+misses,"total de la misma cohorte");
            check(service===es[0]+es[1]+es[2]+es[3],"suma de servicio");
            check(waits===ew[0]+ew[1]+ew[2]+ew[3],"suma de espera");
            check(service===total+waits,"identidad modular global");
            check(zero===ez && excluded===ee && errors===ep,"sin espera, excluidos y diagnóstico");
            check((^{c,s,w,total,service,waits,zero,excluded,errors,pending,eligible,age})!==1'bx,
                  "resultados conocidos después del primer reset");
        end
    endtask

    // El cociente real pertenece al reporte, no al hardware. Num/den usan la
    // misma cohorte de servicio; den=0 imprime N/D y nunca ejecuta la división.
    task automatic mean(input logic [63:0] num,den,input real wanted,input string label_);
        real value_,delta;
        begin
            if(den==0) begin
                check(wanted<0.0,"media vacía declarada N/D");
                $display("K1B MEDIA %m %s=N/D",label_);
            end else begin
                value_=real'(num)/real'(den); delta=value_-wanted;
                if(delta<0.0) delta=-delta;
                check(delta<1.0e-12,"media real frente a guion analítico");
                $display("K1B MEDIA %m %s=%0.12f numerador=%0d denominador=%0d",label_,value_,num,den);
            end
        end
    endtask
    initial clear_expected;
endmodule

/* Unidad: secuencias con edades elegidas antes de la ejecución, incluidas
 * ventanas y protocolo inválido. No hay caché ni latencia L2 que interpretar.
 */
module k1b_unit(input logic go,output logic done);
    logic clk=0,reset=1,en=1,re=0,we=0,stall=0;
    logic [3:0] ev=0;
    logic background_fill=0,grant=0;
    // MUTATION=8/12 altera solo el cable diagnóstico de la unidad. Los demás
    // controles se generan en copias externas del consumidor/banco:
    // 1/2 edad -1/+1 (edad PRE); 3/4 hit/miss intercambiado (clase exacta);
    // 5/6 final duplicado/omitido y 7 retenido como nuevo (cantidad por clase);
    // 9 MSHR con ocho esperas ficticias (servicio WM); 10 parcial incluido,
    // 11 final apagado y 14 ventana ignorada (cohorte completa y exclusiones);
    // 13 reset apagado omitido (época cero); 15 evento retrasado y 16 doble
    // clase (diagnóstico y cantidades). Cada defecto debe producir la primera
    // aserción K1B_FIRST_DIVERGENCE; no se muta el oráculo ni la caché protegida.
    integer mutation=0,cycle=0,random_begin;
    integer physical_classes[0:3];
    wire [3:0] diag=(mutation==8 && background_fill)?4'b0001:
                    (mutation==12 && grant)?4'b0010:ev;
    k1b_probe P(clk,reset,en,re,we,stall,diag);

    // Un paso fija toda la entrada, consume un posedge y comprueba POST, tanto
    // los acumulados como la identidad pendiente declarada por el escenario.
    // No cambia la referencia de operaciones: esa decisión ocurre en el guion.
    task automatic step(input logic rst,enable_,rd,wr,st,input logic [3:0] events_,
                        input logic pend,elig,input logic [63:0] age_);
        begin
            reset=rst; en=enable_; re=rd; we=wr; stall=st; ev=events_;
            #3; cycle++;
            if(rst) P.clear_expected;
            clk=1; #1; P.verify;
            P.check({P.pending,P.eligible,P.age}==={pend,elig,age_},
                    $sformatf("pendiente/edad del guion ciclo=%0d",cycle));
            #1; clk=0; #1;
        end
    endtask

    // policy: 0 completa, 1 inicio apagado, 2 pausa intermedia, 3 final apagado,
    // 4 toda apagada. Cada llamada es UNA demanda aunque tenga muchos stalls.
    // nwait define el guion; no se obtiene observando el estado del monitor.
    task automatic access(input integer cls,nwait,policy);
        logic enabled_,eligible_;
        begin
            eligible_=1;
            for(integer j=0;j<nwait;j++) begin
                enabled_=!(policy==4 || (policy==1 && j==0) || (policy==2 && j==1));
                eligible_=eligible_&&enabled_;
                step(0,enabled_,cls<2,cls>=2,1,0,1,eligible_,j+1);
            end
            enabled_=!(policy==3||policy==4);
            P.completion_expected(cls,nwait,eligible_&&enabled_,enabled_);
            step(0,enabled_,cls<2,cls>=2,0,4'b1<<cls,0,0,0);
        end
    endtask

    integer seed=32'h26b1107,kind,nwait,policy;
    initial begin
        done=0; wait(go);
        if(!$value$plusargs("MUTATION=%d",mutation)) mutation=0;
        // Reset prioritario con evento, luego reposo para conocer frontera.
        // Esperamos cero y media N/D; detecta eventos consumidos en reset.
        step(1,1,1,0,0,1,0,0,0); step(0,1,0,0,0,0,0,0,0);
        P.mean(P.service,P.total,-1.0,"vacia");
        // Dataset conocido: RH1, WH1, RM4, WM1, RM2 => servicio9/5, espera4.
        // El store miss de un flanco representa aceptación no bloqueante.
        access(0,0,0); access(2,0,0); access(1,3,0); access(3,0,0); access(1,1,0);
        P.check(P.total===5 && P.service===9 && P.waits===4,"dataset 9/5");
        P.mean(P.service,P.total,1.8,"global");
        P.mean(P.s[0]+P.s[1],P.reads,7.0/3.0,"lecturas");
        P.mean(P.s[2]+P.s[3],P.writes,1.0,"stores");
        P.mean(P.s[0]+P.s[2],P.hits,1.0,"hits");
        P.mean(P.s[1]+P.s[3],P.misses,7.0/3.0,"misses");
        // Dos hits de la misma clase en flancos consecutivos mantienen el
        // evento alto sin reposo; ambos son demandas nuevas y deben sumarse.
        access(0,0,0); access(0,0,0);
        // Fill y aceptación de L2 no crean demanda. Las mutaciones 8 y 12
        // falsifican únicamente entradas del monitor: debe fallar el diagnóstico.
        background_fill=1; step(0,1,0,0,0,0,0,0,0); background_fill=0;
        // Grant durante una demanda retenida: aún no existe respuesta ni
        // finalización. El control12 fabrica un final prematuro y debe fallar.
        grant=1; step(0,1,1,0,1,0,1,1,1); grant=0;
        P.completion_expected(1,1,1,1); step(0,1,1,0,0,2,0,0,0);
        // Ventanas que cortan el inicio, centro o final. Los parciales no entran
        // a las medias, aun si reanudan antes de terminar. Luego un hit válido
        // demuestra recuperación sin volver a emitir la terminación omitida.
        for(integer pol=1;pol<=4;pol++) access(1,4,pol);
        access(0,0,0); step(0,0,0,0,0,0,0,0,0); access(2,0,0);
        // Espera larga: 257 PRE retenidos y un final, servicio258. Detecta edades
        // de 8 bits o un supuesto fijo de ocho ciclos por miss.
        access(1,257,0);
        // Reset aislado durante stall: la nueva época no conoce su inicio.
        // El final posterior se excluye; el siguiente acceso consecutivo sí entra.
        step(0,1,1,0,1,0,1,1,1); step(1,0,1,0,1,0,0,0,0);
        step(0,1,1,0,1,0,1,0,1);
        P.completion_expected(1,1,0,1); step(0,1,1,0,0,2,0,0,0);
        access(0,0,0);
        // Tras reset, incluso el primer hit inmediato es ambiguo si no hubo
        // reposo. Se excluye conservadoramente en lugar de inventar su historia.
        step(1,1,0,0,0,0,0,0,0);
        P.completion_expected(0,0,0,1); step(0,1,1,0,0,1,0,0,0); access(2,0,0);
        // Dieciséis combinaciones de eventos: solo one-hot es final válido.
        // Probamos explícitamente duplicación, evento sin demanda, tipo erróneo,
        // final durante stall, pérdida de evento y desaparición de pendiente.
        for(integer bad=1;bad<16;bad++) if((bad&(bad-1))!=0) begin
            P.ep++; step(0,1,1,0,0,4'(bad),0,0,0);
            step(0,1,0,0,0,0,0,0,0);
        end
        P.ep++; step(0,1,0,0,0,1,0,0,0); step(0,1,0,0,0,0,0,0,0);
        P.ep++; step(0,1,1,0,0,4,0,0,0); step(0,1,0,0,0,0,0,0,0);
        P.ep++; step(0,1,1,0,1,2,0,0,0); step(0,1,0,0,0,0,0,0,0);
        P.ep++; step(0,1,1,0,0,0,0,0,0); step(0,1,0,0,0,0,0,0,0);
        step(0,1,1,0,1,0,1,1,1); P.ep++; step(0,0,0,0,0,0,0,0,0);
        P.ep++; step(0,1,1,1,1,0,0,0,0); step(0,1,0,0,0,0,0,0,0);
        // Evento desconocido con demanda presente: no debe producir una
        // clasificación parcial ni propagar X a los acumuladores válidos.
        P.ep++; step(0,1,1,0,0,4'b00x1,0,0,0); step(0,1,0,0,0,0,0,0,0);
        // Pseudoaleatoriedad reproducible: varía clase, espera y corte de ventana.
        // Las longitudes se eligen ANTES de estimular, por eso no depende del DUT.
        step(1,1,0,0,0,0,0,0,0); step(0,1,0,0,0,0,0,0,0);
        $display("K1B SEMILLA unidad=0x26b1107 operaciones=128");
        random_begin=cycle;
        for(integer k=0;k<4;k++) physical_classes[k]=0;
        for(integer op=0;op<128;op++) begin
            kind=$unsigned($random(seed))%4;
            nwait=$unsigned($random(seed))%13;
            policy=$unsigned($random(seed))%5;
            physical_classes[kind]++;
            access(kind,nwait,policy);
        end
        $display("K1B ALEATORIA unidad flancos=%0d RH=%0d RM=%0d WH=%0d WM=%0d completos=%0d excluidos=%0d",
                 cycle-random_begin,physical_classes[0],physical_classes[1],physical_classes[2],physical_classes[3],P.total,P.excluded);
        $display("K1B UNIDAD ciclos=%0d completos=%0d excluidos=%0d servicio=%0d espera=%0d clases=%h",
                 cycle,P.total,P.excluded,P.service,P.waits,P.c);
        // Precargas exclusivamente del consumidor sintético: prueban acarreo
        // y wrap sin 2^64 flancos ni acceso a privados de ninguna caché.
        step(1,1,0,0,0,0,0,0,0); step(0,1,0,0,0,0,0,0,0);
        for(integer k=0;k<4;k++) begin
            P.DUT.completed_by_class[k]=64'hffffffff;
            P.DUT.service_by_class[k]=64'hffffffff;
            P.ec[k]=64'hffffffff; P.es[k]=64'hffffffff;
            access(k,0,0);
            P.check(P.c[k]===64'h100000000,"acarreo de cantidad a 33 bits");
            P.DUT.completed_by_class[k]='1; P.DUT.service_by_class[k]='1;
            P.ec[k]='1; P.es[k]='1; access(k,0,0);
            P.check(P.c[k]===0 && P.s[k]===0,"wrap de cantidad y servicio");
        end
        step(1,1,0,0,0,0,0,0,0); step(0,1,0,0,0,0,0,0,0);
        // Edad máxima seguida por un stall debe volver a cero módulo2^64.
        step(0,1,1,0,1,0,1,1,1);
        P.DUT.pending_wait_cycles='1; step(0,1,1,0,1,0,1,1,0);
        P.completion_expected(1,0,1,1); P.ez--; // Hubo espera aunque la edad haya dado la vuelta.
        step(0,1,1,0,0,2,0,0,0);
        // Los cuatro acumuladores de espera se prueban también con acarreo y
        // overflow. Precargamos servicio de forma coherente (cantidad inicial0)
        // para conservar las identidades, sin tocar el productor ni usar force.
        for(integer k=0;k<4;k++) begin
            step(1,1,0,0,0,0,0,0,0); step(0,1,0,0,0,0,0,0,0);
            P.DUT.wait_by_class[k]=64'hffffffff; P.DUT.service_by_class[k]=64'hffffffff;
            P.ew[k]=64'hffffffff; P.es[k]=64'hffffffff; access(k,1,0);
            P.check(P.w[k]===64'h100000000,"acarreo de espera a 33 bits");
            step(1,1,0,0,0,0,0,0,0); step(0,1,0,0,0,0,0,0,0);
            P.DUT.wait_by_class[k]='1; P.DUT.service_by_class[k]='1;
            P.ew[k]='1; P.es[k]='1; access(k,1,0);
            P.check(P.w[k]===0 && P.s[k]===1,"wrap espera conservando servicio=espera+cantidad");
        end
        step(1,1,0,0,0,0,0,0,0); step(0,1,0,0,0,0,0,0,0);
        P.DUT.no_wait_accesses='1; P.ez='1; access(0,0,0);
        P.check(P.zero===0,"wrap de accesos inmediatos");
        P.DUT.excluded_accesses='1; P.ee='1; access(1,3,1);
        P.check(P.excluded===0,"wrap de excluidos");
        P.DUT.protocol_errors='1; P.ep='1; P.ep++;
        step(0,1,1,0,0,0,0,0,0);
        P.check(P.errors===0,"wrap de diagnóstico");
        done=1;
    end
endmodule

// Cada expansión conecta solo puertos públicos. NM varía para comprobar el
// mismo consumidor con caché bloqueante y con reservas de stores; la principal
// es NM=2. RAW_FORWARD es explícito, pero EXCLUSIVA debe impedir ese forwarding.
`define K1B_CACHE(NAME,E,Q,S,F,R,W,A,L,B,D) \
l1d_cache #(.WRITE_POLICY(WP_WRITE_BACK),.INCL_POLICY(INCL_EXCLUSIVE), \
 .ALLOC_POLICY(AP_WRITE_ALLOC),.REPL_POLICY(RP_LRU),.RAW_POLICY(RAW_FORWARD), \
 .WB_DEPTH(4),.N_MSHR(NM),.L2_BUS_V2(1)) NAME ( \
 .clk(clk),.reset(reset),.re(re),.we(we),.be(be),.addr(addr),.wdata(data), \
 .rdata(Q),.stall(S),.flush_req(fr),.flush_done(F), \
 .l2_req(R),.l2_we(W),.l2_addr(A),.l2_wline(L),.l2_be(B),.l2_wdirty(D), \
 .l2_gnt(gnt),.l2_rvalid(rv),.l2_rdirty(rdirty),.l2_rline(line_), \
 .ev_rd_hit(E[0]), \
 .ev_rd_miss(E[1]), \
 .ev_wr_hit(E[2]), \
 .ev_wr_miss(E[3]), \
 .ev_stall(E[4]), \
 .ev_wb_full_stall(E[5]), \
 .ev_raw_stall(E[6]), \
 .ev_raw_forward(E[7]), \
 .ev_wb_push(E[8]), \
 .ev_l2_read(E[9]), \
 .ev_l2_write(E[10]), \
 .ev_fill(E[11]), \
 .ev_victim_dirty(E[12]), \
 .ev_victim_clean(E[13]), \
 .ev_mshr_alloc(E[14]), \
 .ev_mshr_merge(E[15]), \
 .ev_mshr_load(E[16]), \
 .ev_hit_under_miss(E[17]), \
 .ev_mshr_full_stall(E[18]));

/* Integración dirigida: el guion predice cada evento PRE y declara el comienzo
 * de sus demandas. La referencia de latencia resta fechas del guion; no copia
 * el contador incremental del monitor. La memoria inferior solo cambia al grant
 * de escritura; gold cambia por los stores de CPU, antes del chequeo posterior.
 */
module k1b_real #(parameter integer NM=2)(input logic go,output logic done);
    logic clk=0,reset=1,metric_reset=0,en=1,re=0,we=0,fr=0,gnt=1,rv=0,rdirty=0;
    logic [31:0] addr=0,data=0;
    logic [3:0] be=15;
    logic [255:0] line_=0;
    wire [18:0] ev,sev;
    wire [31:0] q,sq,la,sla,mask,smask;
    wire [255:0] wl,swl;
    wire stall,sstall,fd,sfd,rq,srq,lwe,slwe,wd,swd;
    wire mrst=reset|metric_reset;
    `K1B_CACHE(CACHE,ev,q,stall,fd,rq,lwe,la,wl,mask,wd)
    `K1B_CACHE(SHADOW,sev,sq,sstall,sfd,srq,slwe,sla,swl,smask,swd)
    k1b_probe P(clk,mrst,en,re,we,stall,ev[3:0]);

    localparam [18:0] RH=1,RM=2,WH=4,WM=8,ST=16,WB_FULL=32,RAW=64,
        PUSH=256,RD=512,WR=1024,FILL=2048,VD=4096,VC=8192,
        AL=16384,MERGE=32768,ML=65536,HUM=131072,FULL=262144;
    // Referencia de fechas: epoch y last_off delimitan historia no medible.
    // start_cycle lo declara begin_access, incluso si habrá muchos ticks retenidos.
    integer cycle=0,start_cycle=0,epoch=0,last_off=0,trace;
    integer total_ops=0,observed_waits=0;
    logic bus_pending=0,held=0;
    logic [31:0] pendingaddr=0,heldaddr=0,heldmask=0;
    logic heldwe=0,helddirty=0;
    logic [255:0] heldline=0;
    logic [31:0] memory[0:16383],shadow_memory[0:16383],gold[0:16383];

    // Comparación de todas las salidas públicas, tanto PRE como POST. Los datos
    // sin demanda también se comparan con igualdad de cuatro estados; los datos
    // válidos de una lectura además se contrastan contra gold sin admitir X/Z.
    task automatic passive;
        begin
            P.check({q,stall,fd,rq,lwe,la,wl,mask,wd,ev}===
                    {sq,sstall,sfd,srq,slwe,sla,swl,smask,swd,sev},
                    $sformatf("pasividad NM=%0d ciclo=%0d",NM,cycle));
        end
    endtask

    // want y compare_mask pertenecen al guion independiente. Solo en flush se
    // dejan libres eventos de mantenimiento: se exige cero demanda y se validan
    // escrituras/handshake/datos, sin reconstruir el scan privado de la caché.
    // target/dirty predicen una petición nueva cuando el guion lo declara.
    task automatic tick(input logic [18:0] want,input logic [31:0] target=0,
                        input logic dirty=0,input logic [18:0] compare_mask='1);
        integer cls;
        logic whole;
        begin
            #2; cycle++;
            if(!reset) begin
                passive;
                P.check((ev&compare_mask)===(want&compare_mask),
                    $sformatf("eventos NM=%0d ciclo=%0d esperado=%h observado=%h",NM,cycle,want,ev));
                P.check(stall===want[4],"stall PRE del guion");
                if(held) begin
                    P.check(rq && {lwe,la,mask,wd}==={heldwe,heldaddr,heldmask,helddirty},
                            "petición estable antes de grant");
                    if(heldwe) P.check(wl===heldline,"datos retenidos antes de grant");
                end else if(want[9]||want[10]) begin
                    P.check(rq && la===target && lwe===want[10],"nueva petición: dirección y tipo");
                    P.check(wd===dirty,"dirty de víctima conocida");
                end
                if(rv) P.check(bus_pending,"respuesta requiere lectura aceptada");
                if(want[0]||want[1]) P.check(q===gold[addr[15:2]],"lectura contra memoria arquitectónica");
                // Las escrituras se aplican de forma independiente en cada banco
                // inferior. gold no se deriva de datos expulsados por el productor.
                if(rq&&gnt&&lwe) begin
                    P.check(mask==='1,"víctima/flush transmite línea completa");
                    for(integer b=0;b<32;b++) if(mask[b]) begin
                        P.check(wl[8*b+:8]===gold[(la>>2)+b/4][8*(b%4)+:8],"byte de víctima/flush contra CPU");
                        memory[(la>>2)+b/4][8*(b%4)+:8]=wl[8*b+:8];
                    end
                end
                if(srq&&gnt&&slwe) for(integer b=0;b<32;b++) if(smask[b])
                    shadow_memory[(sla>>2)+b/4][8*(b%4)+:8]=swl[8*b+:8];
                if(rv) bus_pending=0;
                if(rq&&gnt&&!lwe) begin
                    P.check(!bus_pending,"una sola respuesta pendiente en bus vigente");
                    bus_pending=1; pendingaddr=la;
                end
                held=rq&&!gnt;
                if(held) begin
                    heldaddr=la; heldwe=lwe; heldmask=mask; helddirty=wd; heldline=wl;
                end
            end
            // Registro PRE: mismo instante que consume el monitor, no eventos
            // recalculados después de instalar una línea en las NBA de L1-D.
            $fdisplay(trace,"%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%h,%h,%0d,%0d,%0d,%0d,%0d",
                NM,cycle,addr,re,we,en,mrst,stall,want,ev,rq,gnt,rv,start_cycle,last_off);
            if(mrst) begin P.clear_expected; epoch=cycle; end
            else begin
                if(!en) last_off=cycle;
                if(|want[3:0]) begin
                    cls=want[0]?0:want[1]?1:want[2]?2:3;
                    whole=en && start_cycle>epoch && last_off<start_cycle;
                    P.completion_expected(cls,cycle-start_cycle,whole,en);
                    total_ops++;
                end
                observed_waits+=want[4];
            end
            clk=1; #1;
            P.verify;
            if(!reset) passive;
            P.check(P.pending===(mrst?1'b0:want[4]),"pendiente según guion PRE");
            // Tras reset aislado solo conocemos el sufijo desde epoch+1.
            // Esa edad visible no vuelve completo al acceso iniciado antes.
            if(!mrst&&want[4]) P.check(P.age===64'(cycle-(start_cycle>epoch?start_cycle:epoch+1)+1),
                                      "edad por diferencia de fechas observadas");
            if(reset) begin bus_pending=0; held=0; end
            #1; clk=0; #1;
        end
    endtask

    // Declarar inicio no avanza reloj. Solo la memoria arquitectónica de
    // referencia recibe los bytes del store; la inferior espera a su grant.
    task automatic begin_access(input logic load,input logic [31:0] a,d=0,
                                input logic [3:0] bytes_=15);
        begin
            re=load; we=!load; addr=a; data=d; be=bytes_; start_cycle=cycle+1;
            if(!load) for(integer b=0;b<4;b++) if(bytes_[b]) gold[a>>2][8*b+:8]=d[8*b+:8];
        end
    endtask

    // Respuesta elegida por el guion: solo con lectura pública ya aceptada.
    // rdirty se inyecta explícitamente para comprobar su propagación posterior;
    // no se simula una tabla de etiquetas L2 ni se afirma exclusividad global.
    task automatic respond(input logic [18:0] want,input logic dirty=0);
        begin
            P.check(bus_pending,"lectura conocida antes de responder");
            for(integer j=0;j<8;j++) line_[32*j+:32]=memory[(pendingaddr>>2)+j];
            rv=1; rdirty=dirty; tick(want); rv=0; rdirty=0;
        end
    endtask

    // Miss bloqueante conocido: ocho PRE de espera y uno de terminación.
    // victim declara la expulsión que determina el orden A/B/C del guion LRU.
    task automatic cold(input logic [31:0] a,input logic [18:0] victim=0,
                        input logic incoming_dirty=0);
        begin
            begin_access(1,a); tick(ST|RD,a&32'hffe0); repeat(7) tick(ST);
            respond(RM|FILL|victim,incoming_dirty); re=0;
        end
    endtask

    // Store hit de un flanco. extra permite un hit-under-miss explícito;
    // no se añade latencia de los MSHR que siguen trabajando en segundo plano.
    task automatic store_hit(input logic [31:0] a,d,input logic [18:0] extra=0);
        begin begin_access(0,a,d); tick(WH|extra); we=0; end
    endtask

    // Separa escenarios con reset común y memoria nueva. El reposo posterior
    // establece frontera pública antes de medir, aun con la ventana apagada.
    task automatic fresh;
        begin
            reset=1; metric_reset=0; en=1; re=0; we=0; fr=0; gnt=1; rv=0;
            for(integer j=0;j<16384;j++) begin
                memory[j]=32'hc1107000^32'(j); shadow_memory[j]=memory[j]; gold[j]=memory[j];
            end
            tick(0); reset=0; tick(0);
        end
    endtask

    // Espera acotada del flush público, sin acceder a MSHR o flags internos.
    // Con respuesta manual ya no hay lecturas pendientes al entrar aquí.
    // Dos bancos inferiores y gold deben coincidir en los 65536 bytes.
    task automatic flush_compare;
        integer n;
        logic [63:0] before_;
        begin
            P.check(!bus_pending,"drenar lecturas antes de flush dirigido");
            re=0; we=0; fr=1; gnt=1; n=0; before_=P.total;
            while(!fd&&n<400) begin tick(0,0,0,19'h1f); n++; end
            P.check(fd,"timeout del vaciado exclusivo");
            P.check(P.total===before_,"mantenimiento no agrega demandas");
            for(integer j=0;j<16384;j++) begin
                P.check(memory[j]===gold[j],"DMEM completa después de flush");
                P.check(shadow_memory[j]===gold[j],"DMEM sombra después de flush");
            end
            fr=0; tick(0);
        end
    endtask

    initial begin
        done=0; wait(go);
        trace=$fopen($sformatf("k1b-real-%0d.csv",NM),"w");
        P.check(trace!=0,"abrir traza externa");
        $fdisplay(trace,"mshr,cycle,address,re,we,enable,reset,stall,expected,observed,req,grant,rvalid,start,last_off");
        fresh;
        // A/B/C/D comparten conjunto5. A sucia sale con C; B limpia con D.
        // Demoramos el grant de la víctima sin fabricar esperas del acceso que
        // ya terminó. E entra dirty desde el inferior y debe salir dirty con G.
        cold(32'h08a0); store_hit(32'h08a0,32'h12345678);
        cold(32'h10a0); cold(32'h18a0,PUSH|VD);
        gnt=0; tick(WR,32'h08a0,1); repeat(3) tick(0); gnt=1; tick(0);
        cold(32'h20a0,PUSH|VC); tick(WR,32'h10a0,0);
        cold(32'h28a0,PUSH|VC,1); tick(WR,32'h18a0,0);
        cold(32'h30a0,PUSH|VC); tick(WR,32'h20a0,0);
        cold(32'h38a0,PUSH|VD); tick(WR,32'h28a0,1);
        P.check(P.total===8 && P.service===64 && P.waits===56,"reemplazos: siete misses de9 y un hit de1");
        flush_compare;
        $display("K1B REAL NM=%0d escena=reemplazos completos=%0d servicio=%0d espera=%0d",NM,P.total,P.service,P.waits);
        fresh;
        if(NM==1) begin
            // Sin non-blocking el store miss espera el fill: servicio9, no1.
            begin_access(0,32'h0940,32'haaaa0001); tick(ST|RD,32'h0940);
            repeat(7) tick(ST); respond(WM|FILL); we=0;
            P.check(P.service===9 && P.waits===8,"store bloqueante de nueve flancos");
        end else begin
            // H residente; X ausente reserva un MSHR y acepta un segundo store
            // a otra palabra por merge. El load completo del MSHR es miss de1.
            // H permite dos hits-under-miss; un fill con CPU ociosa no es demanda.
            cold(32'h1280);
            begin_access(0,32'h0940,32'haaaa0001); tick(WM|AL); we=0;
            begin_access(0,32'h0944,32'hbbbb0002,4'b0011); tick(WM|MERGE|RD,32'h0940); we=0;
            begin_access(1,32'h0940); tick(RM|ML); re=0;
            begin_access(1,32'h1280); tick(RH|HUM); re=0;
            store_hit(32'h1284,32'hcccc0003,HUM);
            // La segunda palabra tiene solo dos bytes escritos: el load no
            // puede salir del MSHR. Espera tres ciclos más el fill, y completa
            // después con clasificación miss inicial, aunque entonces haya hit.
            begin_access(1,32'h0944); repeat(3) tick(ST); respond(ST|FILL);
            tick(RM); re=0;
            P.check(P.total===7 && P.service===19 && P.waits===12,"MSHR parcial espera fill sin reclasificar");
        end
        flush_compare;
        if(NM>=2) begin
            // Reservas llenas: tres FULL + un ciclo de fill por puerto único.
            // Después queda sitio: el nuevo store termina con servicio5, aunque
            // el resto de llenados aún siga pendiente en la jerarquía.
            fresh;
            for(integer j=0;j<NM;j++) begin
                begin_access(0,32'h0a00+32*j,32'h55550000+32'(j));
                tick(WM|AL|(j==1?RD:0),j==1?32'h0a00:0); we=0;
            end
            begin_access(0,32'h0a00+32*NM,32'h77770000);
            repeat(3) tick(ST|FULL); respond(ST|FILL);
            tick(WM|AL|RD,32'h0a20); we=0;
            for(integer j=1;j<=NM;j++) begin
                respond(FILL); if(j<NM) tick(RD,32'h0a00+32*(j+1));
            end
            P.check(P.total===64'(NM+1) && P.waits===4 && P.service===64'(NM+5),"servicio de ráfaga por fechas");
            $display("K1B REAL NM=%0d escena=mshr-llenos completos=%0d servicio=%0d espera=%0d",NM,P.total,P.service,P.waits);
            flush_compare;
        end
        // Espera RAW EXCLUSIVA: A acaba de salir al buffer. No se hace forwarding;
        // el grant se demora y la demanda espera esos flancos más su lectura.
        fresh;
        cold(32'h08a0); cold(32'h10a0); cold(32'h18a0,PUSH|VC);
        begin_access(1,32'h08a0); gnt=0;
        tick(ST|RAW|WR,32'h08a0,0); repeat(2) tick(ST);
        gnt=1; tick(ST); tick(ST|RD,32'h08a0); repeat(7) tick(ST);
        respond(RM|FILL|PUSH|VC); re=0; tick(WR,32'h10a0,0);
        P.check(P.service===40 && P.waits===36,"RAW: tres servicios9 más servicio13");
        flush_compare;
        // Buffer lleno con cuatro víctimas limpias sin drenar. Se mantiene la
        // petición de víctima con backpressure; la quinta lectura espera espacio.
        // El evento FULL no particiona toda esa espera: req_busy inhibe su causa.
        fresh;
        cold(32'h08a0); cold(32'h10a0);
        for(integer tag=3;tag<=6;tag++) cold(32'(tag)*2048+32'ha0,PUSH|VC);
        begin_access(1,32'h38a0); gnt=0;
        tick(ST|WB_FULL|WR,32'h08a0,0); repeat(2) tick(ST);
        gnt=1; tick(ST); tick(ST|RD,32'h38a0); repeat(7) tick(ST);
        respond(RM|FILL|PUSH|VC); re=0;
        P.check(P.total===7 && P.waits===60 && P.service===67,"buffer lleno: servicio13 más seis servicios9");
        flush_compare;
        // Ventanas y reset aislado mientras la lectura pública espera respuesta.
        // Primero se pierde el inicio; después se interrumpe otro miss y se
        // reanuda antes del final. Ninguno debe contaminar las medias completas.
        fresh;
        en=0; begin_access(1,32'h4000); tick(ST|RD,32'h4000); tick(ST);
        en=1; repeat(6) tick(ST); respond(RM|FILL); re=0;
        begin_access(1,32'h4800); tick(ST|RD,32'h4800);
        en=0; tick(ST); en=1; repeat(6) tick(ST); respond(RM|FILL); re=0;
        P.check(P.total===0 && P.excluded===2,"dos accesos parciales excluidos");
        begin_access(1,32'h5000); tick(ST|RD,32'h5000);
        metric_reset=1; en=0; tick(ST); metric_reset=0; en=1;
        repeat(6) tick(ST); respond(RM|FILL); re=0;
        P.check(P.total===0 && P.excluded===1,"reset durante miss conserva época nueva limpia");
        begin_access(1,32'h5000); tick(RH); re=0;
        P.check(P.total===1 && P.service===1,"hit consecutivo después de recuperar frontera");
        flush_compare;
        // Lectura con cinco flancos sin grant y respuesta tardía: la petición
        // sostenida sigue siendo un solo acceso, servicio19 (18 de espera).
        fresh; gnt=0; begin_access(1,32'h6000);
        tick(ST|RD,32'h6000); repeat(4) tick(ST);
        gnt=1; tick(ST); repeat(12) tick(ST); respond(RM|FILL); re=0;
        P.check(P.total===1 && P.waits===18 && P.service===19,"grant separado de respuesta tardía");
        flush_compare;
        if(NM>=2) begin
            // Un hit de H coincide con el fill de X: el mantenimiento de X
            // no duplica la demanda de H ni añade su latencia de fondo.
            fresh; cold(32'h1280);
            begin_access(0,32'h7000,32'hface0000); tick(WM|AL); we=0;
            tick(RD,32'h7000); begin_access(1,32'h1280);
            respond(RH|HUM|FILL); re=0;
            P.check(P.total===3 && P.service===11 && P.waits===8,"hit y fill independiente en un mismo flanco");
            flush_compare;
            // Reset del monitor con MSHR aceptado: no cancela su llenado de
            // fondo. Ese fill no cuenta demanda en la nueva época. Luego el
            // reset común cancela las reservas del productor conforme a su RTL.
            fresh;
            begin_access(0,32'h7000,32'hface0011); tick(WM|AL); we=0;
            metric_reset=1; tick(RD,32'h7000); metric_reset=0;
            respond(FILL);
            P.check(P.total===0 && P.service===0,"fill posterior a reset no inventa demanda");
            flush_compare;
            fresh; begin_access(0,32'h7000,32'hface0022); tick(WM|AL); we=0;
            reset=1; tick(0); reset=0; tick(0);
            // No se exige persistencia de un store descartado por reset común.
            P.check(P.total===0 && !bus_pending,"reset común descarta época y reservas");
        end
        $display("K1B REAL NM=%0d ciclos=%0d operaciones_fisicas=%0d esperas_fisicas=%0d checks=%0d",NM,cycle,total_ops,observed_waits,P.checks);
        $fclose(trace); done=1;
    end
endmodule
`undef K1B_CACHE
/* Integración con el l2_model vigente, sin recrear su controlador. Dos cadenas
 * completas (L1-D, L2 provisional y DMEM) comparan salidas, protocolo y efectos.
 * Los primeros ocho loads de conjuntos distintos tienen servicio9 por contrato;
 * los 128 accesos pseudoaleatorios posteriores usan solo esas líneas residentes.
 * Su clasificación conocida y espera cero son un oráculo por construcción, no
 * una copia del reemplazo. Un store ausente demuestra MSHR con el modelo real.
 */
module k1b_model(input logic go,output logic done);
    logic clk=0,reset=1,en=1,re=0,we=0,fr=0;
    logic [31:0] addr=0,data=0;
    logic [3:0] be=15;
    wire [1:0] stall,fd,rq,lwe,wd,gnt,rv,rdirt,idle,mwe;
    wire [31:0] q[0:1],la[0:1],mask[0:1],ma[0:1],md[0:1],mq[0:1];
    wire [255:0] wl[0:1],rl[0:1];
    wire [3:0] mb[0:1];
    wire [18:0] ev[0:1];
    logic [31:0] gold[0:16383];
    integer cycle=0,seed=32'h26b1207,opclass,bytepos,trace;
    logic [31:0] a,d;
    logic [3:0] bytes_;
    for(genvar k=0;k<2;k++) begin:g
        // Parámetros idénticos y explícitos: k=0 instrumentada, k=1 sombra.
        l1d_cache #(.WRITE_POLICY(WP_WRITE_BACK),.INCL_POLICY(INCL_EXCLUSIVE),
            .ALLOC_POLICY(AP_WRITE_ALLOC),.REPL_POLICY(RP_LRU),.RAW_POLICY(RAW_FORWARD),
            .WB_DEPTH(4),.N_MSHR(2),.L2_BUS_V2(1)) CACHE(
            .clk(clk),.reset(reset),.re(re),.we(we),.be(be),.addr(addr),.wdata(data),
            .rdata(q[k]),.stall(stall[k]),.flush_req(fr),.flush_done(fd[k]),
            .l2_req(rq[k]),.l2_we(lwe[k]),.l2_addr(la[k]),.l2_wline(wl[k]),
            .l2_be(mask[k]),.l2_wdirty(wd[k]),.l2_gnt(gnt[k]),.l2_rvalid(rv[k]),
            .l2_rdirty(rdirt[k]),.l2_rline(rl[k]),
            .ev_rd_hit(ev[k][0]),
            .ev_rd_miss(ev[k][1]),
            .ev_wr_hit(ev[k][2]),
            .ev_wr_miss(ev[k][3]),
            .ev_stall(ev[k][4]),
            .ev_wb_full_stall(ev[k][5]),
            .ev_raw_stall(ev[k][6]),
            .ev_raw_forward(ev[k][7]),
            .ev_wb_push(ev[k][8]),
            .ev_l2_read(ev[k][9]),
            .ev_l2_write(ev[k][10]),
            .ev_fill(ev[k][11]),
            .ev_victim_dirty(ev[k][12]),
            .ev_victim_clean(ev[k][13]),
            .ev_mshr_alloc(ev[k][14]),
            .ev_mshr_merge(ev[k][15]),
            .ev_mshr_load(ev[k][16]),
            .ev_hit_under_miss(ev[k][17]),
            .ev_mshr_full_stall(ev[k][18]));
        l2_model L2(.clk(clk),.reset(reset),.l2_req(rq[k]),.l2_we(lwe[k]),
            .l2_addr(la[k]),.l2_wline(wl[k]),.l2_be(mask[k]),.l2_wdirty(wd[k]),
            .l2_gnt(gnt[k]),.l2_rvalid(rv[k]),.l2_rline(rl[k]),.l2_rdirty(rdirt[k]),
            .idle(idle[k]),.m_we(mwe[k]),.m_be(mb[k]),.m_addr(ma[k]),.m_wdata(md[k]),.m_rdata(mq[k]));
        memory DMEM(.clk(clk),.we(mwe[k]),.be(mb[k]),.addr(ma[k]),.wdata(md[k]),.rdata(mq[k]),
            .we_b(1'b0),.addr_b(32'd0),.wdata_b(32'd0),.rdata_b());
    end
    k1b_probe P(clk,reset,en,re,we,stall[0],ev[0][3:0]);

    // Pasividad por fase: abarca también las respuestas registradas de L2 y
    // cada escritura efectiva de palabra hacia DMEM, con sus bytes y dirección.
    task automatic passive;
        begin
            P.check({q[0],stall[0],fd[0],rq[0],lwe[0],la[0],wl[0],mask[0],wd[0],ev[0],
                     gnt[0],rv[0],rl[0],rdirt[0],idle[0],mwe[0],mb[0],ma[0],md[0]}===
                    {q[1],stall[1],fd[1],rq[1],lwe[1],la[1],wl[1],mask[1],wd[1],ev[1],
                     gnt[1],rv[1],rl[1],rdirt[1],idle[1],mwe[1],mb[1],ma[1],md[1]},
                    $sformatf("cadena l2_model/DMEM sombra ciclo=%0d",cycle));
        end
    endtask

    // Un tick espera estabilización PRE, compara el guion de demanda, aplica
    // reloj y verifica POST. Los eventos de mantenimiento no son expectativas
    // de acceso; su igualdad con sombra se revisa sin sumarlos a la cohorte.
    task automatic tick(input logic [3:0] want,input logic st);
        begin
            #3; cycle++;
            if(!reset) begin
                passive;
                P.check(ev[0][3:0]===want && stall[0]===st,"demanda conocida sobre l2_model");
                if(want[0]||want[1]) P.check(q[0]===gold[addr>>2],"lectura con L2 provisional contra gold");
            end else P.clear_expected;
            $fdisplay(trace,"%0d,%h,%0d,%0d,%0d,%h,%0d,%0d,%0d",cycle,addr,re,we,st,ev[0],rq[0],gnt[0],rv[0]);
            clk=1; #1; P.verify;
            if(!reset) passive;
            #1; clk=0; #1;
        end
    endtask

    // cls y waits_ se fijan por el conjunto inicial o residente del guion.
    // Los stores actualizan la referencia arquitectónica; el modelo inferior
    // sigue su protocolo real, sin forzar registros o señales de las cachés.
    task automatic access(input integer cls,input logic [31:0] address_,datum,
                          input logic [3:0] bytes__,input integer waits_);
        begin
            re=cls<2; we=cls>=2; addr=address_; data=datum; be=bytes__;
            if(we) for(integer b=0;b<4;b++) if(be[b]) gold[addr>>2][8*b+:8]=data[8*b+:8];
            repeat(waits_) tick(0,1);
            P.completion_expected(cls,waits_,1,1); tick(4'b1<<cls,0);
            re=0; we=0;
        end
    endtask

    integer n;
    initial begin
        done=0; wait(go);
        trace=$fopen("k1b-l2-model.csv","w"); P.check(trace!=0,"abrir traza modelo");
        $fdisplay(trace,"cycle,address,re,we,stall,events,req,grant,rvalid");
        for(integer j=0;j<16384;j++) gold[j]=0;
        tick(0,0); reset=0; tick(0,0);
        // Ocho misses sin conflicto preparan ocho líneas limpias. Cada lectura
        // acepta al inicio y responde ocho ciclos después: 72 flancos en total.
        for(integer j=0;j<8;j++) access(1,32'(j*32),0,0,8);
        P.check(P.total===8 && P.service===72 && P.waits===64,"modelo: ocho servicios de9");
        // Alternancia pseudoaleatoria reproducible de lecturas, stores de palabra
        // y stores de byte sobre residentes. Todos deben terminar en un flanco;
        // una clasificación miss o un stall aquí sería una regresión detectable.
        $display("K1B SEMILLA modelo=0x26b1207 operaciones=128");
        for(integer j=0;j<128;j++) begin
            a=32'($unsigned($random(seed))%64)*4;
            d=$random(seed); opclass=($unsigned($random(seed))%2)?0:2;
            bytepos=$unsigned($random(seed))%4;
            bytes_=($unsigned($random(seed))%2)?4'b1111:(4'b1<<bytepos);
            access(opclass,a,d,bytes_,0);
        end
        // Store ausente con MSHR libre seguido por hit-under-miss. Los 8 ciclos
        // del llenado posterior pertenecen al fondo, no al servicio del store.
        access(3,32'h4000,32'h89abcdef,15,0);
        access(0,0,0,0,0);
        P.check(P.total===138 && P.service===202 && P.waits===64,"servicio de cohorte con fondo MSHR");
        fr=1; n=0;
        while((!fd[0]||!idle[0])&&n<1000) begin tick(0,0); n++; end
        P.check(fd[0]&&idle[0],"flush y último drenado del modelo terminan");
        for(integer j=0;j<16384;j++) begin
            P.check(g[0].DMEM.mem[j]===gold[j],"65536 bytes instrumentados frente a CPU");
            P.check(g[1].DMEM.mem[j]===gold[j],"65536 bytes sombra frente a CPU");
        end
        fr=0; tick(0,0);
        P.mean(P.service,P.total,202.0/138.0,"modelo-observado-no-AMAT-definitivo");
        $display("K1B MODELO ciclos=%0d completos=%0d servicio=%0d espera=%0d clases=%h checks=%0d",
                 cycle,P.total,P.service,P.waits,P.c,P.checks);
        $fclose(trace); done=1;
    end
endmodule

/* Coordinación del banco: ejecuta guiones sin compartir estado entre casos.
 * Solo las tareas locales generan flancos. El watchdog no emite reloj ni modifica
 * al productor; un timeout es fallo explícito, nunca una aprobación parcial.
 */
module tb_perf_cache_l1d_k1b;
    logic gu=0,g1=0,g2=0,g4=0,gm=0;
    wire du,d1,d2,d4,dm;
    k1b_unit UNIT(gu,du);
    k1b_real #(.NM(1)) R1(g1,d1);
    k1b_real #(.NM(2)) R2(g2,d2);
    k1b_real #(.NM(4)) R4(g4,d4);
    k1b_model MODEL(gm,dm);
    initial begin
        if($test$plusargs("VCD")) begin
            $dumpfile("tb_perf_cache_l1d_k1b.vcd");
            $dumpvars(0,UNIT.P.DUT,R1.P.DUT,R2.P.DUT,R4.P.DUT,MODEL.P.DUT);
            $dumpvars(0,R2.clk,R2.re,R2.we,R2.stall,R2.ev,R2.gnt,R2.rv,R2.en);
        end
        gu=1; wait(du); g2=1; wait(d2); g1=1; wait(d1); g4=1; wait(d4); gm=1; wait(dm);
        $display("[PASS] tb_perf_cache_l1d_k1b: %0d verificaciones",UNIT.P.checks+R1.P.checks+R2.P.checks+R4.P.checks+MODEL.P.checks);
        $finish;
    end
    initial begin #5000000; $fatal(1,"K1B timeout global"); end
endmodule
