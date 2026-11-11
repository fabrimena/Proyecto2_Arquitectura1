`timescale 1ns/1ps
`default_nettype none

// Pruebas del cruce de dominios del controlador de memoria.
// Se comprueban tres divisores de reloj, transferencias completas
// y el timeout con un solo reintento.

module mem_controller_cdc_case #(
    parameter integer MEM_DIV = 4
) (
    output reg finished
);

    localparam integer TMEM = 25 + 7 * MEM_DIV;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;

    reg ram_req = 1'b0;
    reg ram_we = 1'b0;
    reg [31:0] ram_addr = 32'd0;
    reg [255:0] ram_wline = 256'd0;

    wire ram_ready;
    wire [255:0] ram_rline;
    wire mem_error;

    wire req_accept;
    wire req_we_accepted;
    wire transfer_busy;

    wire timeout_event;
    wire error_event;

    reg mem_hold = 1'b0;

    wire clk_mem;
    wire [13:0] mem_word_addr;
    wire [31:0] mem_word_wdata;
    wire mem_word_we;
    wire [31:0] mem_word_rdata;

    reg [31:0] memory [0:16383];

    reg [255:0] expected_line;

    integer i;
    integer cycles;
    integer writes;

    mem_controller #(
        .MEM_DIV(MEM_DIV),
        .MEM_TIMEOUT(256),
        .TMEM(TMEM)
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

    // Modelar una RAM de palabras de 32 bits.
    assign mem_word_rdata = memory[mem_word_addr];

    always @(posedge clk_mem) begin
        if (!reset && mem_word_we) begin
            memory[mem_word_addr] <= mem_word_wdata;
            writes = writes + 1;
        end
    end

    // Esperar un ciclo del procesador.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Ejecutar una transferencia y comprobar su respuesta.
    task transaction;
        input operation_we;
        input [31:0] address_value;
        input [255:0] line_value;

        begin
            @(negedge clk);

            ram_req = 1'b1;
            ram_we = operation_we;
            ram_addr = address_value;
            ram_wline = line_value;

            tick();

            cycles = 0;

            while (!ram_ready && !mem_error && cycles < 256) begin
                tick();
                cycles = cycles + 1;
            end

            if (!ram_ready || mem_error) begin
                $display(
                    "[FAIL] DIV=%0d transferencia incompleta",
                    MEM_DIV
                );
                $fatal(1);
            end

            // La respuesta debe esperar el burst y su CDC.
            if (cycles < TMEM) begin
                $display(
                    "[FAIL] DIV=%0d respuesta prematura: %0d",
                    MEM_DIV,
                    cycles
                );
                $fatal(1);
            end

            if (!operation_we && ram_rline !== line_value) begin
                $display(
                    "[FAIL] DIV=%0d datos de lectura incorrectos",
                    MEM_DIV
                );
                $fatal(1);
            end

            @(negedge clk);
            ram_req = 1'b0;

            repeat (4) tick();
        end
    endtask

    initial begin
        finished = 1'b0;

        writes = 0;
        expected_line = 256'd0;

        for (i = 0; i < 16384; i = i + 1)
            memory[i] = 32'd0;

        for (i = 0; i < 8; i = i + 1)
            expected_line[i*32 +: 32] = 32'hCAFE0000 + i;

        repeat (4) tick();

        @(negedge clk);
        reset = 1'b0;

        repeat (5) tick();

        // Escribir una linea completa en RAM.
        transaction(
            1'b1,
            32'h00000100,
            expected_line
        );

        if (writes != 8) begin
            $display(
                "[FAIL] DIV=%0d escrituras=%0d esperado=8",
                MEM_DIV,
                writes
            );
            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d escritura completa con CDC",
            MEM_DIV
        );

        // Leer nuevamente la misma linea desde RAM.
        transaction(
            1'b0,
            32'h00000100,
            expected_line
        );

        $display(
            "[PASS] DIV=%0d lectura completa con CDC",
            MEM_DIV
        );

        // Detener la memoria para provocar dos timeouts.
        @(negedge clk);
        mem_hold = 1'b1;

        ram_req = 1'b1;
        ram_we = 1'b0;
        ram_addr = 32'h00000200;

        tick();

        cycles = 0;

        while (!mem_error && cycles < 530) begin
            tick();
            cycles = cycles + 1;
        end

        if (!mem_error || cycles != 512 || ram_ready) begin
            $display(
                "[FAIL] DIV=%0d timeout: ciclos=%0d",
                MEM_DIV,
                cycles
            );
            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d timeout y reintento",
            MEM_DIV
        );

        // Retirar la solicitud y permitir la cancelacion.
        @(negedge clk);
        ram_req = 1'b0;
        mem_hold = 1'b0;

        repeat (20) tick();

        finished = 1'b1;
    end

endmodule

module tb_mem_controller_cdc;

    wire done2;
    wire done4;
    wire done5;

    mem_controller_cdc_case #(
        .MEM_DIV(2)
    ) test2 (
        .finished(done2)
    );

    mem_controller_cdc_case #(
        .MEM_DIV(4)
    ) test4 (
        .finished(done4)
    );

    mem_controller_cdc_case #(
        .MEM_DIV(5)
    ) test5 (
        .finished(done5)
    );

    initial begin
        wait(done2 && done4 && done5);

        $display("[PASS] tb_mem_controller_cdc");
        $finish;
    end

    // Limite general para detectar simulaciones bloqueadas.
    initial begin
        #200000;

        $display("[FAIL] Timeout general del test CDC");
        $fatal(1);
    end

endmodule

`default_nettype wire