`timescale 1ns/1ps
`default_nettype none

// Pruebas de los contadores de memoria principal.
// Las entradas se actualizan en el flanco negativo y se verifican
// despues del flanco positivo para evitar carreras de simulacion.
// Cada llamada a tick representa exactamente un ciclo medido o pausado.
module tb_perf_memory;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic reset = 1'b1;
    logic clear = 1'b0;
    logic measure_enable = 1'b0;
    logic req_accept = 1'b0;
    logic req_we = 1'b0;
    logic transfer_busy = 1'b0;
    logic timeout_event = 1'b0;
    logic error_event = 1'b0;

    wire [63:0] read_accesses;
    wire [63:0] write_accesses;
    wire [63:0] transfer_cycles;
    wire [63:0] total_cycles;
    wire [63:0] timeout_count;
    wire [63:0] error_count;

    perf_memory DUT (
        .clk(clk),
        .reset(reset),
        .clear(clear),
        .measure_enable(measure_enable),
        .req_accept(req_accept),
        .req_we(req_we),
        .transfer_busy(transfer_busy),
        .timeout_event(timeout_event),
        .error_event(error_event),
        .read_accesses(read_accesses),
        .write_accesses(write_accesses),
        .transfer_cycles(transfer_cycles),
        .total_cycles(total_cycles),
        .timeout_count(timeout_count),
        .error_count(error_count)
    );

    // Configura todos los estimulos antes del flanco en que se cuentan.
    // enable_value=0 excluye ese ciclo de todas las metricas.
    // clear_value=1 borra los contadores y tiene prioridad sobre el conteo.
    task tick;
        input enable_value;
        input clear_value;
        input accept_value;
        input we_value;
        input busy_value;
        input timeout_value;
        input error_value;

        begin
            @(negedge clk);

            measure_enable = enable_value;
            clear = clear_value;
            req_accept = accept_value;
            req_we = we_value;
            transfer_busy = busy_value;
            timeout_event = timeout_value;
            error_event = error_value;

            @(posedge clk);
            #1;
        end
    endtask

    integer i;

    initial begin

        // Mantener reset activo durante dos ciclos.
        // La medicion permanece desactivada al salir del reset.
        repeat (2) @(posedge clk);
        #1;
        reset = 1'b0;

        // Simular una lectura de memoria durante 53 ciclos.
        // La solicitud se acepta solamente durante el primer ciclo.
        // La transferencia permanece ocupada durante los 53 ciclos.
        for (i = 0; i < 53; i = i + 1) begin
            tick(
                1'b1,
                1'b0,
                i == 0,
                1'b0,
                1'b1,
                1'b0,
                1'b0
            );
        end

        // Verificar que se registro una lectura.
        // Los ciclos de transferencia y los ciclos totales deben ser 53.
        if (read_accesses !== 64'd1 ||
            transfer_cycles !== 64'd53 ||
            total_cycles !== 64'd53) begin

            $display("[FAIL] Conteo de lectura y transferencia de 53 ciclos");

            $display("Lecturas: esperado=1, obtenido=%0d",
                     read_accesses);

            $display("Transferencia: esperado=53, obtenido=%0d",
                     transfer_cycles);

            $display("Ciclos totales: esperado=53, obtenido=%0d",
                     total_cycles);

            $fatal(1);
        end

        // Simular una escritura durante dos ciclos.
        // Solamente el primer ciclo acepta una nueva solicitud.
        tick(
            1'b1,
            1'b0,
            1'b1,
            1'b1,
            1'b1,
            1'b0,
            1'b0
        );

        // Durante el segundo ciclo ocurre un evento de timeout.
        tick(
            1'b1,
            1'b0,
            1'b0,
            1'b1,
            1'b1,
            1'b1,
            1'b0
        );

        // Verificar la escritura y el timeout.
        if (write_accesses !== 64'd1 ||
            transfer_cycles !== 64'd55 ||
            total_cycles !== 64'd55 ||
            timeout_count !== 64'd1) begin

            $display("[FAIL] Escritura o timeout");

            $display("Escrituras=%0d, transferencia=%0d, totales=%0d, timeout=%0d",
                     write_accesses,
                     transfer_cycles,
                     total_cycles,
                     timeout_count);

            $fatal(1);
        end

        // Pausar las mediciones.
        // Aunque existan eventos activos, los contadores no deben cambiar.
        tick(
            1'b0,
            1'b0,
            1'b1,
            1'b0,
            1'b1,
            1'b1,
            1'b1
        );

        // Verificar que los contadores permanecieron sin cambios.
        if (read_accesses !== 64'd1 ||
            timeout_count !== 64'd1 ||
            error_count !== 64'd0 ||
            total_cycles !== 64'd55) begin

            $display("[FAIL] Pausa de medicion");
            $fatal(1);
        end

        // Reanudar las mediciones.
        // Simular un evento de error durante un ciclo.
        tick(
            1'b1,
            1'b0,
            1'b0,
            1'b0,
            1'b0,
            1'b0,
            1'b1
        );

        // Verificar que el error fue registrado.
        if (error_count !== 64'd1 ||
            total_cycles !== 64'd56) begin

            $display("[FAIL] Conteo de error");

            $display("Errores=%0d, totales=%0d",
                     error_count,
                     total_cycles);

            $fatal(1);
        end

        // Limpiar todos los contadores.
        // La limpieza debe tener prioridad sobre los eventos activos.
        tick(
            1'b1,
            1'b1,
            1'b1,
            1'b1,
            1'b1,
            1'b1,
            1'b1
        );

        // Verificar que todos los contadores regresaron a cero.
        if (read_accesses !== 64'd0 ||
            write_accesses !== 64'd0 ||
            transfer_cycles !== 64'd0 ||
            total_cycles !== 64'd0 ||
            timeout_count !== 64'd0 ||
            error_count !== 64'd0) begin

            $display("[FAIL] Limpieza de contadores");
            $fatal(1);
        end

        // Todas las pruebas finalizaron correctamente.
        $display("[PASS] tb_perf_memory");
        $finish;
    end

endmodule

`default_nettype wire