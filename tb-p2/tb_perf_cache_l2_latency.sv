/* Verifica asociación y ventanas L2 con calendarios ajenos al observador.
 * Los tiempos esperados se obtienen de los flancos del estímulo, no de edades
 * internas del DUT. Cada fallo termina la simulación; el resumen cuenta checks.
 */
`timescale 1ns/1ps
module tb_perf_cache_l2_latency;
    reg clk=0, reset=1, en=1, req=0, we=0, gnt=0, valid=0;
    reg [3:0] ev=0;
    wire [13:0][63:0] c;
    integer checks=0, n;
    reg [63:0] before_count, before_service;
    always #5 clk=~clk;
    perf_cache_l2_latency #(.DEPTH(4)) DUT (
        .clk(clk),.reset(reset),.measure_enable(en),.l2_req(req),.l2_we(we),
        .l2_gnt(gnt),.l2_rvalid(valid),.ev_rd_hit(ev[0]),.ev_rd_miss(ev[1]),
        .ev_wr_hit(ev[2]),.ev_wr_miss(ev[3]),.counts(c));

    // Entradas estables desde negedge; POST #1 elimina carreras con el monitor.
    // a: 0 reposo, 1 read aceptado, 2 write aceptado, 3 oferta retenida sin grant.
    task step(input bit enabled, input integer a, input [3:0] events, input bit response);
        @(negedge clk); reset=0; en=enabled; req=(a!=0); we=(a==2);
        gnt=(a==1 || a==2); ev=events; valid=response;
        @(posedge clk); #1;
    endtask
    task check(input integer index, input [63:0] expected, input string why);
        checks++;
        if(c[index]!==expected) $fatal(1,"[FAIL] L2 %s índice=%0d real=%0d esperado=%0d",why,index,c[index],expected);
    endtask
    task restart;
        @(negedge clk); reset=1; req=1; gnt=1; ev=15; valid=1;
        @(posedge clk); #1;
        for(integer k=0;k<14;k++) check(k,0,"reset prioritario con eventos");
    endtask
    initial begin
        restart();
        // Dos lecturas y una escritura aceptadas antes de clasificarse. El primer
        // read termina 8 flancos después; el segundo 13. Esperamos H=1/M=1,
        // servicio=8/13 y ninguna falsa respuesta por el store posted.
        step(1,1,0,0); step(1,1,0,0); step(1,2,0,0);
        check(7,2,"dos lecturas pendientes"); check(8,3,"cola de clasificación");
        step(1,0,1,0); step(1,0,2,0); step(1,0,4,0);
        check(11,1,"write clasificado sin respuesta"); check(12,0,"write no completa read");
        step(1,0,0,0); step(1,0,0,0); step(1,0,0,1);
        check(0,1,"hit completo"); check(2,8,"hit de ocho flancos");
        repeat(5) step(1,0,0,0);
        step(1,0,0,1);
        check(1,1,"miss completo"); check(3,13,"miss congestionado");
        check(4,19,"espera es suma T-1"); check(7,0,"cola drenada");
        check(9,2,"lecturas aceptadas"); check(10,1,"escritura aceptada");
        check(6,0,"protocolo válido");

        // Una oferta mantenida sin grant no inicia nada. Un read que cruza la
        // pausa conserva su identidad pero no suma servicio al reanudarse.
        repeat(4) step(1,3,0,0);
        check(9,2,"nivel req sin aceptación");
        step(1,1,0,0); step(0,0,1,0);
        check(13,1,"pendiente excluida en pausa");
        step(1,0,0,1); check(5,1,"respuesta excluida tras reanudar");
        check(0,1,"pausa no contamina hits"); check(2,8,"pausa no contamina tiempo");
        step(0,1,0,0); step(0,0,2,0); step(0,0,0,1);
        check(5,2,"diagnóstico de final apagado"); check(7,0,"identidad seguida apagado");

        // Peticiones y respuestas consecutivas son operaciones distintas. Repetir
        // 32 calendarios hace girar ambos FIFO; H/M conservan su asociación aun
        // cuando se acepta otra petición en el mismo flanco que clasifica una.
        for(n=0;n<32;n++) begin
            before_count=c[0]; before_service=c[2];
            step(1,1,0,0); step(1,1,1,0); step(1,0,1,0);
            step(1,0,0,1); step(1,0,0,1);
            check(0,before_count+2,"respuestas consecutivas");
            check(2,before_service+6,"dos duraciones independientes de tres");
        end
        step(1,1,0,0); step(1,0,2,0);
        check(7,1,"corte incompleto visible"); check(1,1,"incompleto fuera de media");
        restart();

        // Controles negativos dirigidos: cada defecto produce error explícito y
        // bloquea acumulación posterior hasta reset. Un timeout no es un PASS.
        step(1,0,0,1); check(6,1,"respuesta huérfana");
        step(1,1,0,0); check(9,0,"no reasociar tras error");
        restart(); step(1,0,1,0); check(6,1,"clasificación huérfana");
        restart(); step(1,1,0,0); step(1,0,4,0); check(6,1,"tipo write para read");
        restart(); step(1,1,0,0); step(1,0,3,0); check(6,1,"doble clasificación");
        restart(); repeat(5) step(1,1,0,0); check(6,1,"overflow de clasificación");
        restart();
        for(n=0;n<4;n++) begin step(1,1,0,0); step(1,0,1,0); end
        step(1,1,0,0); step(1,0,1,0); check(6,1,"overflow de respuestas pendientes");
        $display("[PASS] tb_perf_cache_l2_latency: %0d comprobaciones; 6 controles negativos",checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"[FAIL] infraestructura L2 sin terminar"); end
endmodule
