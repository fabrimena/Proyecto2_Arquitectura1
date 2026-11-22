`timescale 1ns/1ps
`default_nettype none

// Prueba del controlador en tres frecuencias de memoria.
// Cada caso usa RAM de 64 KB con lectura combinacional y escritura sincrona.
module mem_controller_case #(
    parameter integer MEM_DIV = 4,
    parameter integer TMEM = 25 + 7*MEM_DIV
) (
    output reg finished
);
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;
    reg ram_req = 0;
    reg ram_we = 0;
    reg [31:0] ram_addr = 0;
    reg [255:0] ram_wline = 0;
    reg mem_hold = 0;
    wire ram_ready;
    wire [255:0] ram_rline;
    wire mem_error;
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
    integer i;
    integer cycles;
    integer timeouts;
    integer errors;
    integer accepts;
    reg [255:0] expected_line;

    assign mem_word_rdata = memory[mem_word_addr];
    always @(posedge clk_mem) begin
        if (mem_word_we)
            memory[mem_word_addr] <= mem_word_wdata;
    end

    mem_controller #(.MEM_DIV(MEM_DIV), .TMEM(TMEM)) DUT (
        .clk(clk), .reset(reset), .ram_req(ram_req), .ram_we(ram_we),
        .ram_addr(ram_addr), .ram_wline(ram_wline), .ram_ready(ram_ready),
        .ram_rline(ram_rline), .mem_error(mem_error),
        .req_accept(req_accept), .req_we_accepted(req_we_accepted),
        .transfer_busy(transfer_busy), .timeout_event(timeout_event),
        .error_event(error_event), .mem_hold(mem_hold),
        .clk_mem(clk_mem), .mem_word_addr(mem_word_addr),
        .mem_word_wdata(mem_word_wdata), .mem_word_we(mem_word_we),
        .mem_word_rdata(mem_word_rdata)
    );

    always @(posedge clk) begin
        if (!reset) begin
            if (timeout_event) timeouts <= timeouts + 1;
            if (error_event) errors <= errors + 1;
            if (req_accept) accepts <= accepts + 1;
        end
    end

    // Mantiene ram_req hasta la respuesta y mide flancos del procesador.
    task do_transaction;
        input wr;
        input [31:0] address;
        input [255:0] line;
        input integer expected_cycles;
        begin
            @(negedge clk);
            ram_req = 1;
            ram_we = wr;
            ram_addr = address;
            ram_wline = line;
            @(posedge clk); #1;
            cycles = 0;
            while (!ram_ready && !mem_error && cycles < 1000) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
                
            end
            if (mem_error || !ram_ready || cycles != expected_cycles) begin
                $display("[FAIL] MEM_DIV=%0d transaccion: ciclos=%0d esperado=%0d error=%b",
                         MEM_DIV, cycles, expected_cycles, mem_error);
                $fatal(1);
            end
            @(negedge clk);
            ram_req = 0;
            ram_we = 0;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        finished = 0;
        timeouts = 0;
        errors = 0;
        accepts = 0;
        expected_line = 0;
        for (i = 0; i < 16384; i = i + 1)
            memory[i] = 0;
        for (i = 0; i < 8; i = i + 1) begin
            memory[64+i] = 32'hABCD0000 + i;
            expected_line[i*32 +: 32] = 32'hABCD0000 + i;
        end
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        do_transaction(0, 32'h100, 0, TMEM);
        if (ram_rline !== expected_line) begin
            $display("[FAIL] MEM_DIV=%0d datos de lectura", MEM_DIV);
            $fatal(1);
        end

        for (i = 0; i < 8; i = i + 1)
            expected_line[i*32 +: 32] = 32'h12340000 + i;
        do_transaction(1, 32'h120, expected_line, TMEM);
        for (i = 0; i < 8; i = i + 1) begin
            if (memory[72+i] !== 32'h12340000 + i) begin
                $display("[FAIL] MEM_DIV=%0d escritura palabra %0d", MEM_DIV, i);
                $fatal(1);
            end
        end
        do_transaction(0, 32'h120, 0, TMEM);
        if (ram_rline !== expected_line) begin
            $display("[FAIL] MEM_DIV=%0d lectura posterior a escritura", MEM_DIV);
            $fatal(1);
        end

        // Sin respuesta, se esperan dos timeouts y un error final.
        @(negedge clk);
        mem_hold = 1;
        ram_req = 1;
        ram_we = 0;
        ram_addr = 32'h200;
        @(posedge clk); #1;
        cycles = 0;
        while (!mem_error && cycles < 600) begin
            @(posedge clk); #1;
            cycles = cycles + 1;
        end
        if (!mem_error || cycles != 512) begin
            $display("[FAIL] MEM_DIV=%0d timeout: ciclos=%0d error=%b", MEM_DIV, cycles, mem_error);
            $fatal(1);
        end
        @(negedge clk);
        ram_req = 0;
        @(posedge clk); #1;
        @(negedge clk);
        mem_hold = 0;
        if (accepts != 4 || timeouts != 2 || errors != 1) begin
            $display("[FAIL] MEM_DIV=%0d eventos: req=%0d timeout=%0d error=%0d",
                     MEM_DIV, accepts, timeouts, errors);
            $fatal(1);
        end
        $display("[PASS] tb_mem_controller MEM_DIV=%0d TMEM=%0d", MEM_DIV, TMEM);
        finished = 1;
    end
endmodule

module tb_mem_controller;
    wire done2, done4, done5;
    mem_controller_case #(.MEM_DIV(2)) case2 (.finished(done2));
    mem_controller_case #(.MEM_DIV(4)) case4 (.finished(done4));
    mem_controller_case #(.MEM_DIV(5)) case5 (.finished(done5));
    initial begin
        wait(done2 && done4 && done5);
        $display("[PASS] tb_mem_controller");
        $finish;
    end
endmodule

`default_nettype wire
