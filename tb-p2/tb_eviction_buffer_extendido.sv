`timescale 1ns/1ps
`default_nettype none

// Pruebas adicionales del eviction buffer.
// Se comprueban capacidades de 4, 8 y 16 entradas.
// Tambien se verifica el orden FIFO, el forwarding,
// el drenado completo y la reutilizacion circular.

module eviction_buffer_test_case #(
    parameter integer DEPTH = 4
) (
    output reg done
);

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;

    reg evict_valid = 1'b0;
    reg [31:0] evict_addr = 32'd0;
    reg [255:0] evict_line = 256'd0;
    wire evict_ready;

    reg read_req = 1'b0;
    reg [31:0] read_addr = 32'd0;

    wire read_ready;
    wire [255:0] read_line;
    wire read_forwarded;

    wire ram_req;
    wire ram_we;
    wire [31:0] ram_addr;
    wire [255:0] ram_wline;

    reg ram_ready = 1'b0;
    reg [255:0] ram_rline = 256'd0;
    reg ram_error = 1'b0;

    wire empty;
    wire full;
    wire busy;
    wire [31:0] occupancy;

    wire ev_push;
    wire ev_pop;
    wire ev_forward;
    wire ev_error;

    // Controla cuando la RAM simulada puede responder.
    reg ram_allow = 1'b0;

    // Indica que la RAM tiene una solicitud en progreso.
    reg ram_active = 1'b0;

    reg [31:0] saved_addr;
    reg [255:0] saved_line;
    reg saved_we;

    integer ram_delay;
    integer write_count;
    integer i;
    integer cycles;

    // Guarda los datos esperados para comprobar el drenado.
    reg [31:0] expected_addr [0:DEPTH+3];
    reg [255:0] expected_line [0:DEPTH+3];

    eviction_buffer #(
        .EB_DEPTH(DEPTH)
    ) DUT (
        .clk(clk),
        .reset(reset),

        // Mantener desactivada la recuperacion en estas pruebas.
        .clear_write_error(1'b0),

        // Esta salida no se utiliza en las pruebas anteriores.
        .write_error_blocked(),

        .evict_valid(evict_valid),
        .evict_addr(evict_addr),
        .evict_line(evict_line),
        .evict_ready(evict_ready),

        .read_req(read_req),
        .read_addr(read_addr),
        .read_ready(read_ready),
        .read_line(read_line),
        .read_forwarded(read_forwarded),

        .ram_req(ram_req),
        .ram_we(ram_we),
        .ram_addr(ram_addr),
        .ram_wline(ram_wline),
        .ram_ready(ram_ready),
        .ram_rline(ram_rline),
        .ram_error(ram_error),

        .empty(empty),
        .full(full),
        .busy(busy),
        .occupancy(occupancy),

        .ev_push(ev_push),
        .ev_pop(ev_pop),
        .ev_forward(ev_forward),
        .ev_error(ev_error)
    );

    // Genera una linea de ocho palabras de 32 bits.
    // Cada palabra contiene el mismo valor para facilitar
    // la comparacion de todos los bits de la linea.
    function [255:0] make_line;
        input [31:0] value;

        begin
            make_line = {8{value}};
        end
    endfunction

    // Simula el controlador de memoria principal.
    // La solicitud se captura una sola vez.
    // La respuesta se mantiene activa durante un ciclo.
    // Una nueva solicitud requiere que ram_req baje primero.
    // Cada escritura se compara contra los datos esperados.
    always @(posedge clk) begin
        if (reset) begin
            ram_ready <= 1'b0;
            ram_active <= 1'b0;
            ram_delay <= 10;

            saved_addr <= 32'd0;
            saved_line <= 256'd0;
            saved_we <= 1'b0;

            write_count <= 0;
        end else begin

            ram_ready <= 1'b0;

            if (!ram_req) begin
                ram_active <= 1'b0;
                ram_delay <= 10;
            end else if (!ram_active) begin

                ram_active <= 1'b1;

                saved_addr <= ram_addr;
                saved_line <= ram_wline;
                saved_we <= ram_we;

                ram_delay <= 10;

            end else if (ram_allow) begin

                if (ram_delay > 0) begin
                    ram_delay <= ram_delay - 1;
                end else if (ram_delay == 0) begin

                    ram_ready <= 1'b1;

                    // Evitar responder dos veces a la misma solicitud.
                    ram_delay <= -1;

                    if (saved_we) begin

                        if (saved_addr !==
                            expected_addr[write_count]) begin

                            $display(
                                "[FAIL] DEPTH=%0d direccion FIFO, escritura=%0d",
                                DEPTH,
                                write_count
                            );

                            $fatal(1);
                        end

                        if (saved_line !==
                            expected_line[write_count]) begin

                            $display(
                                "[FAIL] DEPTH=%0d datos FIFO, escritura=%0d",
                                DEPTH,
                                write_count
                            );

                            $fatal(1);
                        end

                        write_count <= write_count + 1;
                    end
                end
            end
        end
    end

    // Inserta una linea en el buffer.
    // Los estimulos se aplican antes del flanco positivo.
    task enqueue;
        input [31:0] address_value;
        input [255:0] line_value;

        begin
            @(negedge clk);

            evict_addr = address_value;
            evict_line = line_value;
            evict_valid = 1'b1;

            #1;

            if (!evict_ready) begin
                $display(
                    "[FAIL] DEPTH=%0d no acepta una linea",
                    DEPTH
                );

                $fatal(1);
            end

            @(posedge clk);
            #1;

            @(negedge clk);
            evict_valid = 1'b0;
        end
    endtask

    // Espera hasta que todas las entradas hayan sido drenadas.
    // El limite evita que una falla deje la simulacion bloqueada.
    task wait_empty;
        integer timeout_cycles;

        begin
            timeout_cycles = 0;

            while (!empty || ram_req) begin
                @(posedge clk);
                #1;

                timeout_cycles = timeout_cycles + 1;

                if (timeout_cycles > 5000) begin
                    $display(
                        "[FAIL] DEPTH=%0d timeout de drenado",
                        DEPTH
                    );

                    $fatal(1);
                end
            end
        end
    endtask

    initial begin
        done = 1'b0;

        repeat (3) @(posedge clk);
        #1;
        reset = 1'b0;

        // Comprobar el estado inicial.
        if (!empty || full || occupancy != 0) begin
            $display(
                "[FAIL] DEPTH=%0d estado inicial",
                DEPTH
            );

            $fatal(1);
        end

        // Mantener la RAM sin respuesta para llenar la FIFO.
        ram_allow = 1'b0;

        // Insertar exactamente DEPTH lineas diferentes.
        for (i = 0; i < DEPTH; i = i + 1) begin

            expected_addr[i] = 32'h00001000 + i * 32;

            expected_line[i] =
                make_line(32'hA0000000 + i);

            enqueue(
                expected_addr[i],
                expected_line[i]
            );
        end

        // Comprobar que la FIFO alcanzo su capacidad.
        if (!full || occupancy != DEPTH || evict_ready) begin
            $display(
                "[FAIL] DEPTH=%0d buffer lleno",
                DEPTH
            );

            $fatal(1);
        end

        $display(
            "[PASS] DEPTH=%0d capacidad completa",
            DEPTH
        );

        // Solicitar una linea que todavia esta pendiente.
        // Debe responder desde la FIFO sin esperar a RAM.
        @(negedge clk);

        read_addr = expected_addr[DEPTH-1];
        read_req = 1'b1;

        @(posedge clk);
        #1;

        if (!read_ready ||
            !read_forwarded ||
            read_line !== expected_line[DEPTH-1]) begin

            $display(
                "[FAIL] DEPTH=%0d forwarding",
                DEPTH
            );

            $fatal(1);
        end

        @(negedge clk);
        read_req = 1'b0;

        $display(
            "[PASS] DEPTH=%0d forwarding",
            DEPTH
        );

        // Permitir que la RAM responda.
        // Todas las lineas deben drenarse en orden FIFO.
        ram_allow = 1'b1;

        wait_empty();

        if (write_count != DEPTH) begin
            $display(
                "[FAIL] DEPTH=%0d escrituras=%0d esperado=%0d",
                DEPTH,
                write_count,
                DEPTH
            );

            $fatal(1);
        end

        $display(
            "[PASS] DEPTH=%0d drenado completo",
            DEPTH
        );

        // Volver a bloquear temporalmente la RAM.
        // Insertar nuevas lineas para comprobar que
        // los punteros pueden reutilizar la FIFO.
        ram_allow = 1'b0;

        for (i = 0; i < 2; i = i + 1) begin

            expected_addr[DEPTH+i] =
                32'h00002000 + i * 32;

            expected_line[DEPTH+i] =
                make_line(32'hB0000000 + i);

            enqueue(
                expected_addr[DEPTH+i],
                expected_line[DEPTH+i]
            );
        end

        if (occupancy != 2) begin
            $display(
                "[FAIL] DEPTH=%0d reutilizacion FIFO",
                DEPTH
            );

            $fatal(1);
        end

        // Drenar las dos lineas nuevas.
        ram_allow = 1'b1;

        wait_empty();

        if (write_count != DEPTH + 2) begin
            $display(
                "[FAIL] DEPTH=%0d punteros circulares",
                DEPTH
            );

            $fatal(1);
        end

        $display(
            "[PASS] DEPTH=%0d punteros circulares",
            DEPTH
        );

        // Confirmar que no quedan escrituras pendientes.
        if (!empty || full || occupancy != 0) begin
            $display(
                "[FAIL] DEPTH=%0d estado final",
                DEPTH
            );

            $fatal(1);
        end

        $display(
            "[PASS] DEPTH=%0d todas las pruebas",
            DEPTH
        );

        done = 1'b1;
    end

endmodule

// Ejecuta las pruebas de las tres capacidades permitidas.
// Cada instancia tiene su propio reloj y memoria simulada.
module tb_eviction_buffer_extendido;

    wire done4;
    wire done8;
    wire done16;

    eviction_buffer_test_case #(
        .DEPTH(4)
    ) case4 (
        .done(done4)
    );

    eviction_buffer_test_case #(
        .DEPTH(8)
    ) case8 (
        .done(done8)
    );

    eviction_buffer_test_case #(
        .DEPTH(16)
    ) case16 (
        .done(done16)
    );

    initial begin
        wait(done4 && done8 && done16);

        $display("[PASS] tb_eviction_buffer_extendido");
        $finish;
    end

    // Limite de seguridad para la simulacion completa.
    initial begin
        #100000;

        $display("[FAIL] Timeout general del testbench");
        $fatal(1);
    end

endmodule

`default_nettype wire