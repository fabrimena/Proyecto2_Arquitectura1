`timescale 1ns/1ps
`default_nettype none

// Verifica el esquema de precarga y el ritmo fisico del burst
// y el protocolo de timeout con un solo reintento.
// No reemplaza la prueba estricta de primera palabra.
module mem_controller_prefetch_case #(
    parameter integer MEM_DIV = 4,
    parameter integer TMEM = 25 + 7 * MEM_DIV
) (
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

    integer cpu_clock_count = 0;
    integer start_clock;
    integer beat_count;
    integer beat_cycles [0:7];
    integer beat_indices [0:7];
    integer i;
    integer elapsed;
    integer timeout_count;
    integer error_count;
    integer retry_count;
    reg previous_req_toggle;
    reg monitor_burst = 1'b0;
    reg [255:0] expected_line;
    reg burst_ok;
    reg retry_ok;

    assign mem_word_rdata = memory[mem_word_addr];

    // La RAM escribe una palabra por flanco de su propio reloj.
    always @(posedge clk_mem) begin
        if (mem_word_we)
            memory[mem_word_addr] <= mem_word_wdata;
    end

    // Cuenta ciclos del procesador sin utilizar el reloj detenido del nucleo.
    always @(posedge clk)
        cpu_clock_count <= cpu_clock_count + 1;

    // Observa las palabras realmente atendidas por la maquina de memoria.
    // No confunde la respuesta de linea de 256 bits con el bus de 32 bits.
    // Este monitor utiliza estados internos solo para verificacion aislada.
    always @(posedge clk_mem) begin
        if (monitor_burst && !mem_hold &&
            DUT.mem_state == 2'd1 &&
            DUT.req_sync2 == DUT.req_seen) begin
            if (beat_count < 8) begin
                beat_cycles[beat_count] = cpu_clock_count - start_clock;
                beat_indices[beat_count] = DUT.word_index;
            end
            beat_count = beat_count + 1;
        end
    end

    mem_controller #(.MEM_DIV(MEM_DIV), .TMEM(TMEM)) DUT (
        .clk(clk), .reset(reset), .ram_req(ram_req), .ram_we(ram_we),
        .ram_addr(ram_addr), .ram_wline(ram_wline),
        .ram_ready(ram_ready), .ram_rline(ram_rline),
        .mem_error(mem_error), .req_accept(req_accept),
        .req_we_accepted(req_we_accepted),
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
        burst_ok = 1'b1;
        retry_ok = 1'b1;
        beat_count = 0;
        expected_line = 256'd0;
        for (i = 0; i < 16384; i = i + 1)
            memory[i] = 32'd0;
        for (i = 0; i < 8; i = i + 1) begin
            memory[64+i] = 32'hCAFE0000 + i;
            expected_line[i*32 +: 32] = 32'hCAFE0000 + i;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Registra el inicio desde el flanco que acepta la solicitud.
        @(negedge clk);
        ram_req = 1'b1;
        ram_we = 1'b0;
        ram_addr = 32'h00000100;
        @(posedge clk);
        #1;
        start_clock = cpu_clock_count;
        monitor_burst = 1'b1;
        elapsed = 0;
        while (!ram_ready && !mem_error && elapsed < 600) begin
            @(posedge clk);
            #1;
            elapsed = elapsed + 1;
        end
        monitor_burst = 1'b0;

        if (mem_error || !ram_ready || elapsed != TMEM ||
            ram_rline !== expected_line) begin
            burst_ok = 1'b0;
            $display("[FAIL] DIV=%0d respuesta: ciclos=%0d esperado=%0d error=%b",
                     MEM_DIV, elapsed, TMEM, mem_error);
        end
        if (beat_count != 8) begin
            burst_ok = 1'b0;
            $display("[FAIL] DIV=%0d cantidad de palabras: %0d esperado=8",
                     MEM_DIV, beat_count);
        end
        for (i = 0; i < 8; i = i + 1) begin
            if (i < beat_count) begin
                // En el controlador con precarga el acceso fisico
                // debe terminar antes de la fecha de entrega nominal.
                // Esta prueba NO demuestra que la palabra llegue a CPU
                // en el ciclo 25: la interfaz publica solo da la linea
                // completa mediante ram_ready.
                if (beat_indices[i] != i ||
                    beat_cycles[i] > (25 + i * MEM_DIV)) begin
                    burst_ok = 1'b0;
                    $display("[FAIL] DIV=%0d palabra=%0d indice=%0d ciclo=%0d limite=%0d",
                             MEM_DIV, i, beat_indices[i], beat_cycles[i],
                             25 + i * MEM_DIV);
                end
                if (i > 0 &&
                    (beat_cycles[i] - beat_cycles[i-1]) != MEM_DIV) begin
                    burst_ok = 1'b0;
                    $display("[FAIL] DIV=%0d separacion entre palabras %0d y %0d: %0d esperado=%0d",
                             MEM_DIV, i-1, i,
                             beat_cycles[i] - beat_cycles[i-1], MEM_DIV);
                end
            end
        end
        if (burst_ok)
            $display("[PASS] DIV=%0d precarga, ritmo del burst y datos", MEM_DIV);

        // Deja terminar el protocolo anterior antes de iniciar el timeout.
        @(negedge clk);
        ram_req = 1'b0;
        repeat (3) @(posedge clk);

        // Una RAM trabada no debe confirmar ninguna transferencia.
        // Se espera un timeout al ciclo 256 y otro al ciclo 512.
        @(negedge clk);
        mem_hold = 1'b1;
        ram_req = 1'b1;
        ram_we = 1'b0;
        ram_addr = 32'h00000200;
        @(posedge clk);
        #1;
        elapsed = 0;
        timeout_count = 0;
        error_count = 0;
        retry_count = 0;
        previous_req_toggle = DUT.req_toggle;
        while (!mem_error && elapsed < 530) begin
            @(posedge clk);
            #1;
            elapsed = elapsed + 1;
            if (DUT.req_toggle != previous_req_toggle) begin
                retry_count = retry_count + 1;
                previous_req_toggle = DUT.req_toggle;
            end
            if (timeout_event) begin
                timeout_count = timeout_count + 1;
                if (elapsed != timeout_count * 256) begin
                    retry_ok = 1'b0;
                    $display("[FAIL] DIV=%0d timeout=%0d ciclo=%0d esperado=%0d",
                             MEM_DIV, timeout_count, elapsed, timeout_count * 256);
                end
            end
            if (error_event)
                error_count = error_count + 1;
            if (DUT.addr_saved !== 32'h00000200 || DUT.we_saved !== 1'b0) begin
                retry_ok = 1'b0;
                $display("[FAIL] DIV=%0d solicitud alterada durante reintento", MEM_DIV);
            end
        end
        if (!mem_error || ram_ready || elapsed != 512 ||
            timeout_count != 2 || retry_count != 1 || error_count != 1) begin
            retry_ok = 1'b0;
            $display("[FAIL] DIV=%0d reintentos: ciclos=%0d timeouts=%0d reintentos=%0d errores=%0d",
                     MEM_DIV, elapsed, timeout_count, retry_count, error_count);
        end
        if (retry_ok)
            $display("[PASS] DIV=%0d timeout y reintento", MEM_DIV);

        @(negedge clk);
        ram_req = 1'b0;
        mem_hold = 1'b0;
        passed = burst_ok && retry_ok;
        finished = 1'b1;
    end
endmodule

module tb_mem_controller_prefetch_verificacion;
    wire done2, done4, done5;
    wire pass2, pass4, pass5;

    mem_controller_prefetch_case #(.MEM_DIV(2)) case2 (
        .finished(done2), .passed(pass2)
    );
    mem_controller_prefetch_case #(.MEM_DIV(4)) case4 (
        .finished(done4), .passed(pass4)
    );
    mem_controller_prefetch_case #(.MEM_DIV(5)) case5 (
        .finished(done5), .passed(pass5)
    );

    initial begin
        wait(done2 && done4 && done5);
        if (pass2 && pass4 && pass5)
            $display("[PASS] tb_mem_controller_prefetch_verificacion");
        else begin
            $display("[FAIL] tb_mem_controller_prefetch_verificacion");
            $fatal(1);
        end
        $finish;
    end
endmodule

`default_nettype wire
