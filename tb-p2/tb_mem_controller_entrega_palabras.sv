`timescale 1ns/1ps
`default_nettype none

// Comprueba la entrega de ocho palabras a CPU en 25 + i*MEM_DIV.
// Comprueba el contenido y la respuesta de linea completa en TMEM.
module entrega_palabras_case #(
    parameter integer MEM_DIV = 4,
    parameter integer TMEM = 25 + 7 * MEM_DIV
)(output reg finished, output reg passed);
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;
    reg ram_req = 1'b0;
    reg ram_we = 1'b0;
    reg [31:0] ram_addr = 0;
    reg [255:0] ram_wline = 0;
    reg mem_hold = 1'b0;
    wire ram_ready;
    wire [255:0] ram_rline;
    wire mem_error;
    wire ram_word_valid;
    wire [31:0] ram_word_data;
    wire [2:0] ram_word_index;
    wire req_accept, req_we_accepted, transfer_busy;
    wire timeout_event, error_event;
    wire clk_mem;
    wire [13:0] mem_word_addr;
    wire [31:0] mem_word_wdata;
    wire mem_word_we;
    wire [31:0] mem_word_rdata;

    reg [31:0] memory [0:16383];
    reg [255:0] expected_line;
    integer word_count;
    integer cycle_count;
    integer i;
    integer errors;

    assign mem_word_rdata = memory[mem_word_addr];
    always @(posedge clk_mem)
        if (mem_word_we)
            memory[mem_word_addr] <= mem_word_wdata;

    mem_controller #(.MEM_DIV(MEM_DIV), .TMEM(TMEM)) DUT (
        .clk(clk), .reset(reset),
        .ram_req(ram_req), .ram_we(ram_we),
        .ram_addr(ram_addr), .ram_wline(ram_wline),
        .ram_ready(ram_ready), .ram_rline(ram_rline),
        .mem_error(mem_error),
        .ram_word_valid(ram_word_valid),
        .ram_word_data(ram_word_data),
        .ram_word_index(ram_word_index),
        .req_accept(req_accept), .req_we_accepted(req_we_accepted),
        .transfer_busy(transfer_busy),
        .timeout_event(timeout_event), .error_event(error_event),
        .mem_hold(mem_hold), .clk_mem(clk_mem),
        .mem_word_addr(mem_word_addr),
        .mem_word_wdata(mem_word_wdata), .mem_word_we(mem_word_we),
        .mem_word_rdata(mem_word_rdata)
    );

    initial begin
        finished = 1'b0;
        passed = 1'b0;
        word_count = 0;
        cycle_count = 0;
        errors = 0;
        expected_line = 0;
        for (i = 0; i < 16384; i = i + 1)
            memory[i] = 0;
        for (i = 0; i < 8; i = i + 1) begin
            memory[64+i] = 32'hABCD0000 + i;
            expected_line[i*32 +: 32] = 32'hABCD0000 + i;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        @(negedge clk);
        ram_req = 1'b1;
        ram_addr = 32'h100;

        // El flanco de aceptacion se considera ciclo cero.
        @(posedge clk);
        #1;
        cycle_count = 0;
        while (!ram_ready && !mem_error && cycle_count < 600) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
            if (ram_word_valid) begin
                if (word_count >= 8) begin
                    errors = errors + 1;
                    $display("[FAIL] DIV=%0d palabras extra", MEM_DIV);
                end else begin
                    if (cycle_count != 25 + word_count * MEM_DIV ||
                        ram_word_index !== word_count[2:0] ||
                        ram_word_data !== (32'hABCD0000 + word_count)) begin
                        errors = errors + 1;
                        $display("[FAIL] DIV=%0d palabra=%0d ciclo=%0d dato=%h indice=%0d",
                                 MEM_DIV, word_count, cycle_count,
                                 ram_word_data, ram_word_index);
                    end
                end
                word_count = word_count + 1;
            end
        end

        if (word_count != 8 || cycle_count != TMEM ||
            !ram_ready || mem_error || ram_rline !== expected_line) begin
            errors = errors + 1;
            $display("[FAIL] DIV=%0d final palabras=%0d ciclos=%0d ready=%b error=%b",
                     MEM_DIV, word_count, cycle_count, ram_ready, mem_error);
        end
        if (errors == 0) begin
            passed = 1'b1;
            $display("[PASS] DIV=%0d llegada de palabras y TMEM", MEM_DIV);
        end
        finished = 1'b1;
    end
endmodule

module tb_mem_controller_entrega_palabras;
    wire f2, f4, f5;
    wire p2, p4, p5;
    entrega_palabras_case #(.MEM_DIV(2)) case2 (.finished(f2), .passed(p2));
    entrega_palabras_case #(.MEM_DIV(4)) case4 (.finished(f4), .passed(p4));
    entrega_palabras_case #(.MEM_DIV(5)) case5 (.finished(f5), .passed(p5));
    initial begin
        wait(f2 && f4 && f5);
        if (p2 && p4 && p5)
            $display("[PASS] tb_mem_controller_entrega_palabras");
        else begin
            $display("[FAIL] tb_mem_controller_entrega_palabras");
            $fatal(1);
        end
        $finish;
    end
endmodule
`default_nettype wire
