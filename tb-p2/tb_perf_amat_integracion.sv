/* Contrasta tiempos con un diario externo de señales públicas de la jerarquía.
 * Reutiliza SIN modificar el driver histórico: stores/load, exclusividad/NINE,
 * DIV2/4, modelo, pausa, línea sucia, flush y comparación de las 16384 palabras.
 * El oráculo conserva todo el calendario y consulta la habilitación pasada;
 * no reproduce los FIFO circulares ni los bits de elegibilidad del observador.
 */
`timescale 1ns/1ps
`include "tb_perf_integracion_hierarquia.sv"
module perf_amat_integration_case #(parameter integer INCL=2,MODEL=0,DIV=4)(output wire done);
    perf_hier_env #(.INCL(INCL),.MODEL(MODEL),.DIV(DIV)) DRIVER(.done(done));
    wire clk=DRIVER.clk, reset=DRIVER.reset, en=DRIVER.en;
    wire req=DRIVER.g[0].H.l2_req, grant=DRIVER.g[0].H.l2_gnt;
    wire write_op=DRIVER.g[0].H.l2_we, response=DRIVER.g[0].H.l2_rvalid;
    wire [3:0] events=DRIVER.g[0].H.perf_l2_events[3:0];
    wire accept_ram=DRIVER.g[0].H.mc_accept, write_ram=DRIVER.g[0].H.mc_write;
    wire ready_ram=DRIVER.g[0].H.mc_ready;
    wire [13:0][63:0] l2=DRIVER.g[0].H.perf_l2_latency;
    wire [21:0][63:0] ram=DRIVER.g[0].H.perf_ram_latency;
    reg enabled_at[0:99999], writes[0:4095], hits[0:4095], finished[0:4095];
    integer accepted_at[0:4095], classified=0, accepted=0, next_response=0, epoch=0;
    integer read_accepted=0, write_accepted=0, write_classified=0, responses=0;
    integer ram_start=0, ram_accepts=0, ram_finals=0, duration, which, checks=0;
    reg ram_write=0, ram_pending=0, whole;
    reg [13:0][63:0] expected_l2='0;
    reg [21:0][63:0] expected_ram='0;

    // El diario pregunta por TODOS los flancos del intervalo, incluidos extremos.
    // Esto detecta una pausa olvidada por el monitor aun después de reanudar.
    function automatic bit full_window(input integer first,input integer last);
        full_window=1;
        for(integer t=first;t<=last;t++) if(!enabled_at[t]) full_window=0;
    endfunction
    always @(posedge clk) begin
        if(reset) begin
            epoch=0;classified=0;accepted=0;next_response=0;read_accepted=0;
            write_accepted=0;write_classified=0;responses=0;
            ram_start=0;ram_accepts=0;ram_finals=0;ram_pending=0;
            expected_l2='0;expected_ram='0;
        end else begin
            if(epoch>=100000) $fatal(1,"[FAIL] diario temporal agotado");
            enabled_at[epoch]=en;
            if(!MODEL) begin
                if(|events) begin
                    if(classified>=accepted || writes[classified]!=(|events[3:2]))
                        $fatal(1,"[FAIL] clasificación pública fuera de orden");
                    hits[classified]=events[0];
                    if(writes[classified]) write_classified++;
                    classified++;
                end
                if(response) begin
                    // El historial lineal salta escrituras posted, sin una cola
                    // auxiliar de respuestas que replique el diseño bajo prueba.
                    while(next_response<accepted && writes[next_response]) next_response++;
                    if(next_response>=classified) $fatal(1,"[FAIL] respuesta sin clasificación");
                    duration=epoch-accepted_at[next_response];
                    whole=full_window(accepted_at[next_response],epoch);
                    if(whole) begin
                        which=hits[next_response]?0:1;
                        expected_l2[which]++;
                        expected_l2[which+2]=expected_l2[which+2]+duration;
                        expected_l2[4]=expected_l2[4]+duration-1;
                    end else expected_l2[5]++;
                    finished[next_response]=1;next_response++;responses++;
                end
                if(req && grant) begin
                    if(accepted>=4096) $fatal(1,"[FAIL] diario de solicitudes agotado");
                    accepted_at[accepted]=epoch;writes[accepted]=write_op;
                    hits[accepted]=0;finished[accepted]=0;accepted++;
                    if(write_op) write_accepted++;else read_accepted++;
                end
                expected_l2[7]=read_accepted-responses;
                expected_l2[8]=accepted-classified;expected_l2[9]=read_accepted;
                expected_l2[10]=write_accepted;expected_l2[11]=write_classified;
                expected_l2[12]=responses;expected_l2[13]=0;
                for(integer k=0;k<accepted;k++)
                    if(!writes[k] && !finished[k] && !full_window(accepted_at[k],epoch))
                        expected_l2[13]++;
                // El MC admite solo una transferencia; el diario fecha el éxito
                // público. No emplea busy ni TMEM para obtener el oráculo.
                if(ready_ram) begin
                    if(!ram_pending) $fatal(1,"[FAIL] éxito RAM huérfano");
                    duration=epoch-ram_start;whole=full_window(ram_start,epoch);
                    if(whole) begin
                        which=ram_write?1:0;expected_ram[which]++;
                        expected_ram[which+2]=expected_ram[which+2]+duration;
                        expected_ram[4]=expected_ram[4]+duration-1;
                    end else expected_ram[7]++;
                    ram_finals++;ram_pending=0;
                    expected_ram[18]=duration;expected_ram[19]=ram_write;
                    expected_ram[20]=ram_start;expected_ram[21]=epoch;
                end
                if(accept_ram) begin
                    if(ram_pending) $fatal(1,"[FAIL] RAM acepta dos pendientes");
                    ram_start=epoch;ram_write=write_ram;ram_pending=1;ram_accepts++;
                end
                if(DRIVER.g[0].H.mc_timeout || DRIVER.g[0].H.mc_error)
                    $fatal(1,"[FAIL] fallo no esperado en jerarquía sin inyección");
                expected_ram[14]=ram_pending;
                expected_ram[15]=ram_pending && full_window(ram_start,epoch);
                expected_ram[16]=ram_accepts;expected_ram[17]=ram_finals;
            end
            epoch++;
        end
        #2; checks++;
        if(l2!==expected_l2 || ram!==expected_ram) begin
            for(integer k=0;k<14;k++) if(l2[k]!==expected_l2[k])
                $display("[FAIL] diario L2 INCL=%0d DIV=%0d índice=%0d real=%0d esperado=%0d",INCL,DIV,k,l2[k],expected_l2[k]);
            for(integer k=0;k<22;k++) if(ram[k]!==expected_ram[k])
                $display("[FAIL] diario RAM índice=%0d real=%0d esperado=%0d",k,ram[k],expected_ram[k]);
            $fatal(1,"[FAIL] asociación/tiempo/ventana temporal");
        end
        if(DRIVER.g[1].H.perf_l2_latency!==0 || DRIVER.g[1].H.perf_ram_latency!==0)
            $fatal(1,"[FAIL] observadores activos con PERF_ENABLE=0");
    end
    initial begin
        wait(done);#3;
        if(!MODEL && (l2[0]==0 || l2[1]==0 || ram[0]==0 || ram[1]==0))
            $fatal(1,"[FAIL] falta cobertura hit/miss/read/write");
        $display("[PASS] diario AMAT INCL=%0d MODEL=%0d DIV=%0d: %0d checks; H/M=%0d/%0d RAM R/W=%0d/%0d excl=%0d/%0d",
            INCL,MODEL,DIV,checks,l2[0],l2[1],ram[0],ram[1],l2[5],ram[7]);
    end
endmodule
module tb_perf_amat_integracion;
    wire [3:0] done;
    perf_amat_integration_case E0(done[0]);
    perf_amat_integration_case #(.INCL(1)) E1(done[1]);
    perf_amat_integration_case #(.DIV(2)) E2(done[2]);
    perf_amat_integration_case #(.MODEL(1)) E3(done[3]);
    initial begin wait(&done);#5;$display("[PASS] tb_perf_amat_integracion: diario independiente, cuatro configuraciones y pasividad");$finish;end
    initial begin #20000000;$fatal(1,"[FAIL] infraestructura integración AMAT sin terminar");end
endmodule
