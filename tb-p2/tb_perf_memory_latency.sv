/* Comprueba cohortes RAM con el controlador real y un gemelo sin observador.
 * Cada trabajador usa clk general y fecha señales públicas PRE; los oráculos
 * nominales y los tipos del guion son independientes de los registros del DUT.
 */
`timescale 1ns/1ps
module perf_ram_latency_case #(parameter integer DIV=4)(output reg done=0);
    reg clk=0, reset=1, en=1, req=0, we=0, hold_mem=0;
    wire ready, error_level, accept, accepted_write, busy, timeout_ev, error_ev;
    wire shadow_ready, shadow_error, shadow_clk, mem_clk;
    wire [255:0] rline, shadow_line;
    wire [13:0] word_addr, shadow_addr;
    wire [31:0] word_data, shadow_data;
    wire word_we, shadow_we;
    wire [21:0][63:0] c;
    integer checks=0, edges=0, start_edge, finish_edge, observed_timeouts;
    integer expected_duration;
    always #5 clk=~clk;
    mem_controller #(.MEM_DIV(DIV)) MC (
        .clk(clk),.reset(reset),.ram_req(req),.ram_we(we),.ram_addr(32'h100),
        .ram_wline(256'h1234),.ram_ready(ready),.ram_rline(rline),.mem_error(error_level),
        .mem_hold(hold_mem),.clk_mem(mem_clk),.mem_word_addr(word_addr),
        .mem_word_wdata(word_data),.mem_word_we(word_we),.mem_word_rdata(32'habcd),
        .req_accept(accept),.req_we_accepted(accepted_write),.transfer_busy(busy),
        .timeout_event(timeout_ev),.error_event(error_ev));
    mem_controller #(.MEM_DIV(DIV)) SHADOW (
        .clk(clk),.reset(reset),.ram_req(req),.ram_we(we),.ram_addr(32'h100),
        .ram_wline(256'h1234),.ram_ready(shadow_ready),.ram_rline(shadow_line),.mem_error(shadow_error),
        .mem_hold(hold_mem),.clk_mem(shadow_clk),.mem_word_addr(shadow_addr),
        .mem_word_wdata(shadow_data),.mem_word_we(shadow_we),.mem_word_rdata(32'habcd),
        .req_accept(),.req_we_accepted(),.transfer_busy(),.timeout_event(),.error_event());
    perf_memory_latency DUT (.clk(clk),.reset(reset),.measure_enable(en),
        .req_accept(accept),.req_we_accepted(accepted_write),.transfer_busy(busy),
        .ram_ready(ready),.timeout_event(timeout_ev),.error_event(error_ev),.counts(c));

    // Fechas externas de aceptación y consumo. El espejo acredita ciclo a ciclo
    // que conectar observación no cambia CDC, datos, escritura ni respuesta.
    always @(posedge clk) begin
        edges=edges+1;
        if(!reset) begin
            if(accept) begin start_edge=edges; observed_timeouts=0; end
            if(timeout_ev) observed_timeouts=observed_timeouts+1;
            if(ready || error_ev) finish_edge=edges;
        end
        #1;
        checks++;
        if({ready,error_level,mem_clk,word_addr,word_data,word_we,rline} !==
           {shadow_ready,shadow_error,shadow_clk,shadow_addr,shadow_data,shadow_we,shadow_line})
            $fatal(1,"[FAIL] pasividad RAM DIV=%0d",DIV);
    end
    task check(input integer index,input [63:0] expected,input string why);
        checks++;
        if(c[index]!==expected) $fatal(1,"[FAIL] RAM DIV=%0d %s índice=%0d real=%0d esperado=%0d",DIV,why,index,c[index],expected);
    endtask
    // Cada operación parte de CPU_IDLE. Se mantiene req hasta la respuesta y se
    // retira durante RELEASE. fault=1 libera hold tras el primer timeout;
    // fault=2 lo conserva hasta fracaso. pause=1 atraviesa una pausa de un flanco.
    task transaction(input bit write_op,input integer fault,input bit pause_window);
        @(negedge clk); req=1; we=write_op; hold_mem=(fault!=0);
        if(pause_window) begin
            repeat(3) @(negedge clk);
            en=0; @(negedge clk); en=1;
        end
        if(fault==1) begin wait(timeout_ev); @(negedge clk); hold_mem=0; end
        wait(ready || error_ev);
        @(posedge clk); #2;
        expected_duration=finish_edge-start_edge;
        check(18,expected_duration,"fecha independiente de finalización");
        check(19,write_op,"tipo conservado");
        if(fault==0) check(18,26+7*DIV,"consumo público un flanco después de TMEM");
        if(fault==1) begin
            if(observed_timeouts!=1 || expected_duration<=256)
                $fatal(1,"[FAIL] reintento real no observado");
        end
        if(fault==2 && observed_timeouts!=2) $fatal(1,"[FAIL] faltan dos timeouts reales");
        @(negedge clk); req=0; hold_mem=0;
        repeat(12) @(negedge clk);
    endtask
    initial begin
        repeat(3) @(negedge clk); reset=0;
        // Read y write normales: 40 flancos DIV2 / 54 DIV4. El éxito de write es
        // respuesta del controlador, no aceptación temprana del store del núcleo.
        transaction(0,0,0); check(0,1,"read completo"); check(2,26+7*DIV,"servicio read");
        transaction(1,0,0); check(1,1,"write completo"); check(3,26+7*DIV,"servicio write");
        // Reintento exitoso: una sola aceptación y duración completa, incluido
        // timeout. Fracaso final separado: no aumenta la media de éxitos.
        transaction(0,1,0); check(0,2,"éxito tras retry"); check(9,1,"timeout exitoso"); check(11,1,"retry exitoso");
        transaction(1,2,0); check(5,1,"fallo definitivo"); check(10,2,"timeouts fallidos");
        check(12,1,"un retry, no dos"); check(1,1,"fallo no suma éxito");
        check(6,expected_duration,"servicio fallido separado");
        // La pausa invalida solo la cohorte; la respuesta conserva identidad.
        transaction(0,0,1); check(7,1,"éxito excluido por pausa"); check(0,2,"read excluido no duplica");
        check(13,0,"protocolo válido"); check(16,5,"aceptaciones reales"); check(17,5,"finales reales");
        check(14,0,"sin pendiente");
        $display("[PASS] RAM real DIV=%0d: %0d comprobaciones; normal/retry/error/pausa/pasividad",DIV,checks);
        done=1;
    end
endmodule

module tb_perf_memory_latency;
    wire done2,done4;
    perf_ram_latency_case #(.DIV(2)) C2(done2);
    perf_ram_latency_case #(.DIV(4)) C4(done4);
    // Productor dirigido adicional: provoca incoherencias que el MC real nunca
    // debe emitir. Se exige diagnóstico explícito, no un resultado numérico útil.
    reg clk=0,reset=1,en=1,a=0,w=0,r=0,t=0,e=0;
    wire [21:0][63:0] c;
    integer checks=0;
    reg unit_done=0;
    always #5 clk=~clk;
    perf_memory_latency U(.clk(clk),.reset(reset),.measure_enable(en),.req_accept(a),
        .req_we_accepted(w),.transfer_busy(1'b0),.ram_ready(r),.timeout_event(t),.error_event(e),.counts(c));
    task step(input bit rst,input bit accept_op,input bit write_op,input bit response,input bit timeout_op,input bit error_op);
        @(negedge clk); reset=rst;a=accept_op;w=write_op;r=response;t=timeout_op;e=error_op;
        @(posedge clk); #1;
    endtask
    task check(input integer index,input [63:0] expected,input string why);
        checks++;
        if(c[index]!==expected) $fatal(1,"[FAIL] RAM unit %s índice=%0d real=%0d esperado=%0d",why,index,c[index],expected);
    endtask
    initial begin
        // Reset prioritario borra aun con todos los eventos; una transacción al
        // corte queda pendiente y no es éxito. Pausar la excluye al reanudar.
        step(1,1,1,1,1,1);
        for(integer k=0;k<22;k++) check(k,0,"reset prioritario");
        step(0,1,0,0,0,0); step(0,0,0,0,0,0);
        check(14,1,"incompleta al corte");check(0,0,"incompleta fuera de media");
        en=0;step(0,0,0,0,0,0);check(15,0,"pausa invalida");
        en=1;step(0,0,0,1,0,0);check(7,1,"final excluido");
        // Cuatro familias de defectos: final huérfano, aceptación duplicada,
        // tipo sin aceptación y éxito/error simultáneos. Todos deben rechazarse.
        step(1,0,0,0,0,0);step(0,0,0,1,0,0);check(13,1,"respuesta huérfana");
        step(0,1,0,0,0,0);check(16,0,"seguimiento bloqueado tras error");
        step(1,0,0,0,0,0);step(0,1,0,0,0,0);step(0,1,0,0,0,0);check(13,1,"aceptación duplicada");
        step(1,0,0,0,0,0);step(0,0,1,0,0,0);check(13,1,"write sin accept");
        step(1,0,0,0,0,0);step(0,1,0,0,0,0);step(0,0,0,1,0,1);check(13,1,"éxito y error");
        // Un fallo que atraviesa pausa permanece fuera de medias y conserva
        // diagnóstico; no se transforma en timeout sin fin ni éxito artificial.
        step(1,0,0,0,0,0);en=0;step(0,1,1,0,0,0);step(0,0,0,0,1,1);
        check(8,1,"fallo excluido");check(5,0,"fallo apagado no suma cohorte");
        unit_done=1;
    end
    initial begin
        wait(done2 && done4 && unit_done);
        $display("[PASS] tb_perf_memory_latency: %0d checks dirigidos; 4 controles negativos",checks);$finish;
    end
    initial begin #100000; $fatal(1,"[FAIL] infraestructura RAM sin terminar"); end
endmodule
