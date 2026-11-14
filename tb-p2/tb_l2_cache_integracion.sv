/*
================================================================================
 Testbench: tb_l2_cache_integracion
================================================================================
 Descripción:
 ------------------------------------------------------------------------------
 Comprueba la caché L2 (rtl-p2/l2_cache.sv) conectada al eviction buffer REAL
 (rtl-p2/eviction_buffer.sv) y al controlador de memoria REAL
 (rtl-p2/mem_controller.sv), con la memoria principal simulada.

 Esta es la conexión que exige la asignación de tareas ("Conectar la L2 con la
 L1-D, el eviction buffer y el controlador de RAM"). La L2 habla con el buffer
 sin adaptadores: los nombres de las señales son los del buffer.

 Se comprueba:
   1. Fallo de lectura: la L2 pide la línea al buffer, el buffer la pide a la
      RAM y la línea vuelve correctly. La latencia es la del camino real
      (8 + Tmem más el retardo del buffer).
   2. Write-back: una línea sucia desalojada por la L2 llega al buffer y
      termina en la RAM con los datos correctos.
   3. Reenvío (forwarding): con la RAM retenida (mem_hold), la línea sucia se
      queda pendiente en el buffer. Cuando la L2 la vuelve a pedir, el buffer se
      la reenvía marcada como sucia y la L2 la entrega con l2_rdirty = 1. Al
      soltar la RAM, la línea termina en la memoria.

 Uso: make tb_l2_cache_integracion
================================================================================
*/

`timescale 1ns/1ps

`include "cache_defs.sv"

module tb_l2_cache_integracion;

`include "tb_utils.svh"

    // ------------------------------------------------------------------
    // Memoria principal simulada: 16384 palabras de 32 bits (64 KB).
    // ------------------------------------------------------------------

    localparam integer MEM_WORDS   = 16384;
    localparam integer MEM_DIV    = 4;
    localparam integer TMEM       = 25 + 7 * MEM_DIV;
    localparam integer MEM_TIMEOUT = 256;

    logic clk   = 1'b0;
    logic reset = 1'b1;

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Bus L1-D <-> L2 (versión 2)
    // ------------------------------------------------------------------

    logic                   l2_req    = 1'b0;
    logic                   l2_we     = 1'b0;
    logic [31:0]            l2_addr   = 32'd0;
    logic [LINE_W-1:0]      l2_wline  = '0;
    logic [LINE_MASK_W-1:0] l2_be     = '0;
    logic                   l2_wdirty = 1'b0;

    logic                   l2_gnt;
    logic                   l2_rvalid;
    logic [LINE_W-1:0]      l2_rline;
    logic                   l2_rdirty;
    logic                   idle;

    // ------------------------------------------------------------------
    // Bus L2 <-> eviction buffer
    // ------------------------------------------------------------------

    logic                   evict_valid;
    logic [31:0]            evict_addr;
    logic [LINE_W-1:0]      evict_line;
    logic                   evict_ready;

    logic                   read_req;
    logic [31:0]            read_addr;
    logic                   read_ready;
    logic [LINE_W-1:0]      read_line;
    logic                   read_forwarded;

    // ------------------------------------------------------------------
    // Señales del eviction buffer
    // ------------------------------------------------------------------

    logic                   clear_write_error = 1'b0;
    logic                   empty;
    logic                   full;
    logic                   busy;
    logic [31:0]            occupancy;
    logic                   write_error_blocked;
    logic                   ev_push;
    logic                   ev_pop;
    logic                   ev_forward;
    logic                   ev_error;

    // ev_forward es un pulso de un ciclo: se guarda para poder comprobarlo
    // después de la lectura.
    logic                   forward_seen = 1'b0;

    always @(posedge clk) begin
        if (reset)
            forward_seen <= 1'b0;
        else if (ev_forward)
            forward_seen <= 1'b1;
    end

    // ------------------------------------------------------------------
    // Señales del controlador de memoria
    // ------------------------------------------------------------------

    logic                   ram_req;
    logic                   ram_we;
    logic [31:0]            ram_addr;
    logic [LINE_W-1:0]      ram_wline;
    logic                   ram_ready;
    logic [LINE_W-1:0]      ram_rline;
    logic                   ram_error;

    logic                   req_accept;
    logic                   req_we_accepted;
    logic                   transfer_busy;
    logic                   timeout_event;
    logic                   error_event;

    logic                   clk_mem;
    logic [13:0]            mem_word_addr;
    logic [31:0]            mem_word_wdata;
    logic                   mem_word_we;
    logic [31:0]            mem_word_rdata;

    // Permite retener la RAM para dejar una línea pendiente en el buffer.
    logic                   mem_hold = 1'b0;

    logic [31:0]            memory [0:MEM_WORDS-1];

    integer i;

    // ------------------------------------------------------------------
    // La caché L2 (política exclusiva, la de por defecto)
    // ------------------------------------------------------------------

    l2_cache DUT (
        .clk(clk),
        .reset(reset),

        .l2_req(l2_req),
        .l2_we(l2_we),
        .l2_addr(l2_addr),
        .l2_wline(l2_wline),
        .l2_be(l2_be),
        .l2_wdirty(l2_wdirty),

        .l2_gnt(l2_gnt),
        .l2_rvalid(l2_rvalid),
        .l2_rline(l2_rline),
        .l2_rdirty(l2_rdirty),
        .idle(idle),

        .evict_valid(evict_valid),
        .evict_addr(evict_addr),
        .evict_line(evict_line),
        .evict_ready(evict_ready),

        .read_req(read_req),
        .read_addr(read_addr),
        .read_ready(read_ready),
        .read_line(read_line),
        .read_forwarded(read_forwarded)
    );

    // ------------------------------------------------------------------
    // El eviction buffer real
    // ------------------------------------------------------------------

    eviction_buffer #(
        .EB_DEPTH(4)
    ) EB (
        .clk(clk),
        .reset(reset),

        .clear_write_error(clear_write_error),

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
        .write_error_blocked(write_error_blocked),

        .ev_push(ev_push),
        .ev_pop(ev_pop),
        .ev_forward(ev_forward),
        .ev_error(ev_error)
    );

    // ------------------------------------------------------------------
    // El controlador de memoria real
    // ------------------------------------------------------------------

    mem_controller #(
        .MEM_DIV(MEM_DIV),
        .MEM_TIMEOUT(MEM_TIMEOUT),
        .TMEM(TMEM)
    ) MC (
        .clk(clk),
        .reset(reset),

        .ram_req(ram_req),
        .ram_we(ram_we),
        .ram_addr(ram_addr),
        .ram_wline(ram_wline),

        .ram_ready(ram_ready),
        .ram_rline(ram_rline),
        .mem_error(ram_error),

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

    // La lectura de palabras de la RAM es combinacional; el controlador
    // captura cada palabra en su reloj lento.
    assign mem_word_rdata = memory[mem_word_addr];

    always @(posedge clk_mem) begin
        if (!reset && mem_word_we)
            memory[mem_word_addr] <= mem_word_wdata;
    end


    // ======================================================================
    // Direcciones y patrones
    // ======================================================================

    localparam logic [31:0] ADDR_A = 32'h0000_0200;   // conjunto 0x10, etiqueta 0
    localparam logic [31:0] ADDR_B = 32'h0000_1200;   // conjunto 0x10, etiqueta 1
    localparam logic [31:0] ADDR_C = 32'h0000_2200;   // conjunto 0x10, etiqueta 2
    localparam logic [31:0] ADDR_D = 32'h0000_3200;   // conjunto 0x10, etiqueta 3
    localparam logic [31:0] ADDR_E = 32'h0000_4200;   // conjunto 0x10, etiqueta 4

    // Otro conjunto (0x20) para la prueba de reenvío: así la línea que se
    // desaloja no se vuelve a guardar en la L2 y la lectura posterior
    // realmente falla en la L2 (y por eso la pide al buffer).
    localparam logic [31:0] ADDR_P = 32'h0000_0400;   // conjunto 0x20, etiqueta 0
    localparam logic [31:0] ADDR_Q = 32'h0000_1400;   // conjunto 0x20, etiqueta 1
    localparam logic [31:0] ADDR_R = 32'h0000_2400;   // conjunto 0x20, etiqueta 2
    localparam logic [31:0] ADDR_S = 32'h0000_3400;   // conjunto 0x20, etiqueta 3
    localparam logic [31:0] ADDR_T = 32'h0000_4400;   // conjunto 0x20, etiqueta 4

    localparam logic [LINE_MASK_W-1:0] BE_ALL = {LINE_MASK_W{1'b1}};

    // La línea que hay en la RAM: cada palabra depende de su dirección.
    function automatic logic [LINE_W-1:0] ram_pattern(input logic [31:0] addr);

        logic [LINE_W-1:0] r;
        integer base;
        integer j;

        begin
            base = addr[15:2];
            r    = '0;
            for (j = 0; j < LINE_WORDS; j = j + 1)
                r[32*j +: 32] = 32'hC0DE0000 + base + j;
            ram_pattern = r;
        end
    endfunction

    // La línea que se escribe en la L2: reconocible a simple vista.
    function automatic logic [LINE_W-1:0] written_pattern(input logic [31:0] addr);

        logic [LINE_W-1:0] r;
        integer j;

        begin
            r = '0;
            for (j = 0; j < LINE_WORDS; j = j + 1)
                r[32*j +: 32] = 32'hA5A5_0000 + addr[15:5]*8 + j;
            written_pattern = r;
        end
    endfunction


    // ======================================================================
    // Utilidades
    // ======================================================================

    task automatic check_line(input string name,
                              input logic [LINE_W-1:0] got,
                              input logic [LINE_W-1:0] exp);

        tb_checks++;

        if (got !== exp) begin
            tb_errors++;
            $display("  [FAIL] %s: obtenido=0x%064h esperado=0x%064h", name, got, exp);
        end
        else if (tb_verbose)
            $display("  [ ok ] %s", name);
    endtask

    task automatic wait_idle;

        integer guard;

        begin
            guard = 0;
            while (!idle && guard < 1000) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end

            if (guard >= 1000) begin
                tb_errors++;
                $display("  [FAIL] la L2 no vuelve a estado libre");
            end
        end
    endtask

    // Espera a que el buffer quede vacío y el controlador termine.
    task automatic wait_drain;

        integer guard;

        begin
            guard = 0;
            while ((!empty || ram_req || transfer_busy) && guard < 5000) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end

            if (guard >= 5000) begin
                tb_errors++;
                $display("  [FAIL] timeout esperando el drenado del buffer");
            end
        end
    endtask

    // Comprueba que una línea entera está en la RAM.
    task automatic check_ram_line(input string name,
                                  input logic [31:0] addr,
                                  input logic [LINE_W-1:0] expected);

        integer base;
        integer j;
        string  msg;

        begin
            base = addr[15:2];

            for (j = 0; j < LINE_WORDS; j = j + 1) begin
                msg = $sformatf("%s: palabra %0d", name, j);
                check(msg, memory[base + j], expected[32*j +: 32]);
            end
        end
    endtask

    // Una lectura por el bus versión 2.
    task automatic do_read(input  logic [31:0] addr,
                           output logic [LINE_W-1:0] rline,
                           output logic         rdirty,
                           output integer       cycles);

        integer guard;

        begin
            wait_idle();

            @(negedge clk);
            l2_req    = 1'b1;
            l2_we     = 1'b0;
            l2_addr   = addr;
            l2_be     = '0;
            l2_wline  = '0;
            l2_wdirty = 1'b0;

            @(posedge clk); #1;

            @(negedge clk);
            l2_req = 1'b0;

            cycles = 1;
            guard  = 0;

            while (!l2_rvalid && guard < 4000) begin
                @(posedge clk); #1;
                cycles = cycles + 1;
                guard  = guard + 1;
            end

            if (guard >= 4000) begin
                tb_errors++;
                $display("  [FAIL] timeout esperando la respuesta de la lectura");
            end

            rline  = l2_rline;
            rdirty = l2_rdirty;

            wait_idle();
        end
    endtask

    // Una escritura por el bus versión 2.
    task automatic do_write(input logic [31:0]           addr,
                            input logic [LINE_W-1:0]      wline,
                            input logic [LINE_MASK_W-1:0] be,
                            input logic                   wdirty);

        begin
            wait_idle();

            @(negedge clk);
            l2_req    = 1'b1;
            l2_we     = 1'b1;
            l2_addr   = addr;
            l2_wline  = wline;
            l2_be     = be;
            l2_wdirty = wdirty;

            @(posedge clk); #1;

            @(negedge clk);
            l2_req = 1'b0;

            wait_idle();
        end
    endtask


    // ======================================================================
    // Secuencia de pruebas
    // ======================================================================

    logic [LINE_W-1:0] line;
    logic              dirty;
    integer            cycles;

    initial begin

        $dumpfile("tb_l2_cache_integracion.vcd");
        $dumpvars(0, tb_l2_cache_integracion);

        // Contenido inicial de la RAM.
        for (i = 0; i < MEM_WORDS; i = i + 1)
            memory[i] = 32'hC0DE0000 + i;

        // ------------------------------------------------------------------
        tb_section("0. Reinicio");
        // ------------------------------------------------------------------

        reset = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        @(negedge clk);

        check_true("la L2 está libre", idle);
        check_true("el buffer está vacío", empty);

        // ------------------------------------------------------------------
        tb_section("1. Fallo de lectura por el eviction buffer real");
        // ------------------------------------------------------------------

        do_read(ADDR_A, line, dirty, cycles);

        check_line("la línea llega desde la RAM", line, ram_pattern(ADDR_A));
        check("la línea llega limpia", dirty, 32'd0);
        check_true("el fallo tarda al menos 8 + Tmem",
                   (cycles >= 8 + T_MEM_CYCLES));
        $display("  (el camino real por el buffer tardó %0d ciclos)", cycles);

        wait_drain();

        // ------------------------------------------------------------------
        tb_section("2. Write-back: la línea sucia desalojada baja a la RAM");
        // ------------------------------------------------------------------
        //
        // Se llenan las cuatro vías del conjunto 0x10 con líneas sucias. La
        // quinta línea no cabe: la L2 desaloja a la víctima (la vía 0) y la
        // entrega al buffer, que la drena a la RAM.

        do_write(ADDR_A, written_pattern(ADDR_A), BE_ALL, 1'b1);   // vía 0
        do_write(ADDR_B, written_pattern(ADDR_B), BE_ALL, 1'b1);   // vía 1
        do_write(ADDR_C, written_pattern(ADDR_C), BE_ALL, 1'b1);   // vía 2
        do_write(ADDR_D, written_pattern(ADDR_D), BE_ALL, 1'b1);   // vía 3

        do_write(ADDR_E, written_pattern(ADDR_E), BE_ALL, 1'b1);   // desaloja

        check_true("el buffer recibió la víctima", (occupancy >= 1) || !empty);

        wait_drain();

        check_true("el buffer quedó vacío", empty);
        check_ram_line("la línea desalojada llegó a la RAM",
                       ADDR_A, written_pattern(ADDR_A));

        // ------------------------------------------------------------------
        tb_section("3. Reenvío de una línea sucia pendiente");
        // ------------------------------------------------------------------
        //
        // Con la RAM retenida la línea desalojada se queda pendiente en el
        // buffer. Cuando la L2 la vuelve a pedir, el buffer se la reenvía y la
        // L2 la entrega marcada como sucia (l2_rdirty).
        //
        // Se usa el conjunto 0x20 para que la lectura sea un FALLO real en la
        // L2: la línea se desalojó, así que la L2 no la tiene y tiene que
        // pedírsela al buffer, que la reenvía porque la tiene pendiente.

        mem_hold = 1'b1;

        do_write(ADDR_P, written_pattern(ADDR_P), BE_ALL, 1'b1);   // vía 0
        do_write(ADDR_Q, written_pattern(ADDR_Q), BE_ALL, 1'b1);   // vía 1
        do_write(ADDR_R, written_pattern(ADDR_R), BE_ALL, 1'b1);   // vía 2
        do_write(ADDR_S, written_pattern(ADDR_S), BE_ALL, 1'b1);   // vía 3

        do_write(ADDR_T, written_pattern(ADDR_T), BE_ALL, 1'b1);   // desaloja

        check_true("la línea quedó pendiente en el buffer", !empty);

        do_read(ADDR_P, line, dirty, cycles);

        check_line("la línea reenviada es la que se escribió",
                   line, written_pattern(ADDR_P));
        check("la línea reenviada se entrega sucia", dirty, 32'd1);
        check_true("el buffer avisó del reenvío", forward_seen);
        check_true("no hubo error de memoria", !ram_error);

        // Al soltar la RAM, la línea pendiente termina en la memoria.
        mem_hold = 1'b0;

        wait_drain();

        check_true("el buffer quedó vacío", empty);
        check_ram_line("la línea reenviada terminó en la RAM",
                       ADDR_P, written_pattern(ADDR_P));

        tb_finish("tb_l2_cache_integracion");
    end

endmodule
