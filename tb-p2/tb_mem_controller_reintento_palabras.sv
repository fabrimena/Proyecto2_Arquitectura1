`timescale 1ns/1ps
`default_nettype none

// Verificar la entrega de palabras durante un reintento.
// El primer intento se interrumpe despues de tres accesos.
// Antes del reintento se modifican los datos de RAM.
// Solo deben entregarse los ocho datos nuevos.

module reintento_palabras_case #(
    parameter integer MEM_DIV = 4,
    parameter integer MEM_TIMEOUT = 256
)(
    output reg finished,
    output reg passed
);

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;
    reg ram_req = 1'b0;
    reg ram_we = 1'b0;
    reg [31:0] ram_addr = 32'd0;
    reg [255:0] ram_wline = 256'd0;
    reg mem_hold = 1'b0;

    wire ram_ready;
    wire [255:0] ram_rline;
    wire mem_error;

    wire ram_word_valid;
    wire [31:0] ram_word_data;
    wire [2:0] ram_word_index;

    wire req_accept;
    wire req_we_accepted;
    wire transfer_busy;

    wire timeout_event;
    wire error_event;

    wire clk_mem;
    wire [13:0] mem_word_addr;
    wire [31:0] mem_word_wdata;
    wire mem_word_we;
    wire [31:0] mem_word_rdata;

    reg [31:0] memory [0:16383];
    reg [255:0] expected_line;

    integer i;
    integer phase;
    integer cycle_count;
    integer last_word_cycle;
    integer word_count;
    integer timeout_count;
    integer error_count;

    reg response_seen;

    // Datos del primer intento.
    function [31:0] old_word;
        input integer index;
        begin
            old_word = 32'hA5000000 + index;
        end
    endfunction

    // Datos diferentes para el reintento.
    function [31:0] new_word;
        input integer index;
        begin
            new_word =
                32'hB6000000 + MEM_DIV * 256 + index;
        end
    endfunction

    // Modelo de RAM de 64 KB.
    assign mem_word_rdata = memory[mem_word_addr];

    always @(posedge clk_mem) begin
        if (mem_word_we)
            memory[mem_word_addr] <= mem_word_wdata;
    end

    mem_controller #(
        .MEM_DIV(MEM_DIV),
        .MEM_TIMEOUT(MEM_TIMEOUT)
    ) DUT (
        .clk(clk),
        .reset(reset),

        .ram_req(ram_req),
        .ram_we(ram_we),
        .ram_addr(ram_addr),
        .ram_wline(ram_wline),

        .ram_ready(ram_ready),
        .ram_rline(ram_rline),
        .mem_error(mem_error),

        .ram_word_valid(ram_word_valid),
        .ram_word_data(ram_word_data),
        .ram_word_index(ram_word_index),

        .req_accept(req_accept),
        .req_we_accepted(req_we_accepted),
        .transfer_busy(transfer_busy),

        .timeout_event(timeout_event),
        .error_event(error_event),

        .mem_hold(mem_hold),
        .clk_mem(clk_mem),

        .mem_word_addr(mem_word_addr),
        .mem_word_wdata(mem_word_wdata),
        .mem_word_we(mem_word_we),
        .mem_word_rdata(mem_word_rdata)
    );

    // Supervisar los timeouts y las entregas.
    // Se observa despues del flanco para leer los valores
    // actualizados mediante asignaciones no bloqueantes.

    always @(posedge clk) begin
        #1;

        if (!reset) begin

            if (timeout_event)
                timeout_count = timeout_count + 1;

            if (error_event)
                error_count = error_count + 1;

            // Fase 1: observar exclusivamente el reintento.
            if (phase == 1) begin

                cycle_count = cycle_count + 1;

                if (ram_word_valid) begin

                    // No deben entregarse mas de ocho palabras.
                    if (word_count >= 8) begin
                        $display(
                            "[FAIL] DIV=%0d palabra duplicada",
                            MEM_DIV
                        );
                        $fatal(1);
                    end

                    // Comprobar el orden de las palabras.
                    if (ram_word_index !== word_count[2:0]) begin
                        $display(
                            "[FAIL] DIV=%0d indice=%0d esperado=%0d",
                            MEM_DIV,
                            ram_word_index,
                            word_count
                        );
                        $fatal(1);
                    end

                    // Todos los datos deben pertenecer al reintento.
                    if (ram_word_data !== new_word(word_count)) begin
                        $display(
                            "[FAIL] DIV=%0d dato=%h esperado=%h",
                            MEM_DIV,
                            ram_word_data,
                            new_word(word_count)
                        );
                        $fatal(1);
                    end

                    // Cada palabra posterior debe llegar
                    // exactamente MEM_DIV ciclos despues.
                    if (word_count > 0) begin

                        if ((cycle_count - last_word_cycle)
                            != MEM_DIV) begin

                            $display(
                                "[FAIL] DIV=%0d intervalo=%0d esperado=%0d",
                                MEM_DIV,
                                cycle_count - last_word_cycle,
                                MEM_DIV
                            );

                            $fatal(1);
                        end
                    end

                    last_word_cycle = cycle_count;
                    word_count = word_count + 1;

                end

                // No se permite confirmar una linea incompleta.
                if (ram_ready) begin

                    if (word_count != 8) begin
                        $display(
                            "[FAIL] DIV=%0d ready con %0d palabras",
                            MEM_DIV,
                            word_count
                        );
                        $fatal(1);
                    end

                    if (ram_rline !== expected_line) begin
                        $display(
                            "[FAIL] DIV=%0d linea incorrecta",
                            MEM_DIV
                        );
                        $fatal(1);
                    end

                    if (mem_error) begin
                        $display(
                            "[FAIL] DIV=%0d error inesperado",
                            MEM_DIV
                        );
                        $fatal(1);
                    end

                    response_seen = 1'b1;
                    phase = 2;

                end
            end

            // Despues de la respuesta no puede haber
            // otra entrega ni una confirmacion duplicada.
            else if (phase == 2) begin

                if (ram_word_valid || ram_ready) begin
                    $display(
                        "[FAIL] DIV=%0d respuesta duplicada",
                        MEM_DIV
                    );
                    $fatal(1);
                end
            end

        end
    end

    initial begin

        finished = 1'b0;
        passed = 1'b0;

        phase = 0;
        cycle_count = 0;
        last_word_cycle = 0;
        word_count = 0;
        timeout_count = 0;
        error_count = 0;
        response_seen = 1'b0;

        expected_line = 256'd0;

        // Inicializar RAM.
        for (i = 0; i < 16384; i = i + 1)
            memory[i] = 32'd0;

        // Preparar la primera version de los datos.
        for (i = 0; i < 8; i = i + 1)
            memory[64 + i] = old_word(i);

        // Inicializar el controlador.
        repeat (5) @(negedge clk);
        reset = 1'b0;

        // Iniciar una lectura de linea.
        @(negedge clk);

        ram_req = 1'b1;
        ram_we = 1'b0;
        ram_addr = 32'h00000100;
        ram_wline = 256'd0;

        // Esperar hasta que RAM haya capturado tres palabras.
        // word_index=3 indica que las primeras tres
        // transferencias fisicas ya fueron procesadas.
        wait (
            DUT.mem_state == 2'd1 &&
            DUT.word_index == 3'd3
        );

        // Detener RAM antes de la cuarta palabra.
        @(negedge clk);
        mem_hold = 1'b1;

        $display(
            "[PASS] DIV=%0d primer intento interrumpido",
            MEM_DIV
        );

        // Esperar el primer timeout.
        wait (timeout_count == 1);

        if (mem_error || error_count != 0) begin
            $display(
                "[FAIL] DIV=%0d error antes del reintento",
                MEM_DIV
            );
            $fatal(1);
        end

        if (!DUT.retry_used) begin
            $display(
                "[FAIL] DIV=%0d reintento no activado",
                MEM_DIV
            );
            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d primer timeout y reintento",
            MEM_DIV
        );

        // Cambiar los datos mientras RAM esta detenida.
        // Esto permite identificar una lectura obsoleta
        // del intento anterior.
        @(negedge clk);

        for (i = 0; i < 8; i = i + 1) begin
            memory[64 + i] = new_word(i);
            expected_line[i * 32 +: 32] = new_word(i);
        end

        // Preparar el monitor para las ocho palabras
        // correspondientes exclusivamente al reintento.
        word_count = 0;
        cycle_count = 0;
        last_word_cycle = 0;
        phase = 1;

        // Permitir que el segundo intento acceda a RAM.
        mem_hold = 1'b0;

        // Esperar la finalizacion correcta.
        wait (response_seen);

        @(negedge clk);
        ram_req = 1'b0;

        // Observar algunos ciclos adicionales para comprobar
        // que no aparezcan respuestas duplicadas.
        repeat (15) @(negedge clk);

        if (timeout_count != 1 ||
            error_count != 0 ||
            word_count != 8 ||
            !response_seen) begin

            $display(
                "[FAIL] DIV=%0d resumen incorrecto",
                MEM_DIV
            );

            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d ocho palabras nuevas y orden correcto",
            MEM_DIV
        );

        $display(
            "[PASS] DIV=%0d cadencia de %0d ciclos",
            MEM_DIV,
            MEM_DIV
        );

        $display(
            "[PASS] DIV=%0d sin respuestas duplicadas",
            MEM_DIV
        );

        passed = 1'b1;
        finished = 1'b1;

    end

    // Limite de tiempo para detectar bloqueos.
    initial begin
        #20000;

        if (!finished) begin
            $display(
                "[FAIL] DIV=%0d simulacion bloqueada",
                MEM_DIV
            );
            $fatal(1);
        end
    end

endmodule


module tb_mem_controller_reintento_palabras;

    wire f2, f4, f5;
    wire p2, p4, p5;

    reintento_palabras_case #(
        .MEM_DIV(2)
    ) case2 (
        .finished(f2),
        .passed(p2)
    );

    reintento_palabras_case #(
        .MEM_DIV(4)
    ) case4 (
        .finished(f4),
        .passed(p4)
    );

    reintento_palabras_case #(
        .MEM_DIV(5)
    ) case5 (
        .finished(f5),
        .passed(p5)
    );

    initial begin

        wait (f2 && f4 && f5);

        if (p2 && p4 && p5) begin
            $display(
                "[PASS] tb_mem_controller_reintento_palabras"
            );
        end else begin
            $display(
                "[FAIL] tb_mem_controller_reintento_palabras"
            );

            $fatal(1);
        end

        $finish;

    end

endmodule

`default_nettype wire