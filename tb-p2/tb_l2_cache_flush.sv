/*
================================================================================
 Testbench: tb_l2_cache_flush
================================================================================
 Descripción:
 ------------------------------------------------------------------------------
 Comprueba el VACÍADO de líneas sucias de la caché L2 (rtl-p2/l2_cache.sv),
 conectada al eviction buffer REAL (rtl-p2/eviction_buffer.sv) y al controlador
 de memoria REAL (rtl-p2/mem_controller.sv), con la memoria principal simulada.

 Qué se comprueba:
   1. Con cuatro líneas sucias en la L2, la RAM todavía no tiene nada: la L2
      es write-back y una línea solo baja a la memoria cuando sale sucia de
      la L2.
   2. Al pedir el vaciado, la L2 deja de aceptar peticiones (el núcleo queda
      detenido) y baja sus líneas sucias al eviction buffer, una por una.
   3. flush_done se levanta cuando las líneas sucias de la L2 ya están en la
      RAM, y se mantiene mientras flush_req siga en alto (la misma convención
      que usa la L1-D en l1d_cache.sv).
   4. La RAM tiene el contenido final de las líneas vaciadas.
   5. Al bajar flush_req, la L2 vuelve a estar libre y a aceptar peticiones.
   6. Las copias de la L2 quedan limpias: al releer una de ellas, el bus la
      entrega con l2_rdirty = 0.
   7. Un segundo vaciado con una línea nueva también la baja a la RAM.

 El contrato con el nivel de arriba (el que cablea esto es issue #27) es que
 el pedido de vaciado de la L2 sube DESPUÉS de que la L1-D haya terminado su
 propio vaciado. Aquí se ejercita solo la L2, que es lo que le toca a este
 bloque.

 Uso: make tb_l2_cache_flush
================================================================================
*/

`timescale 1ns/1ps

`include "cache_defs.sv"

module tb_l2_cache_flush;

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
    // Vaciado (D16)
    // ------------------------------------------------------------------

    logic                   flush_req     = 1'b0;
    logic                   flush_done;
    logic                   lower_drained;

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
        .read_forwarded(read_forwarded),

        .flush_req(flush_req),
        .flush_done(flush_done),
        .lower_drained(lower_drained)
    );

    // El nivel inferior está drenado cuando el buffer no tiene nada
    // pendiente: ni líneas en la FIFO ni una transferencia en curso.
    // Esta es la conexión que hará el cableado de mem_hierarchy.sv
    // (issue #27).
    assign lower_drained = !busy;

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
    //
    // Las cuatro direcciones comparten el conjunto 0x10 (las cuatro vías) y
    // se distinguen por la etiqueta: así las cuatro líneas sucias caben en la
    // L2 sin desalojo previo y el vaciado tiene que bajarlas todas.

    localparam logic [31:0] ADDR_A = 32'h0000_0200;   // conjunto 0x10, etiqueta 0
    localparam logic [31:0] ADDR_B = 32'h0000_1200;   // conjunto 0x10, etiqueta 1
    localparam logic [31:0] ADDR_C = 32'h0000_2200;   // conjunto 0x10, etiqueta 2
    localparam logic [31:0] ADDR_D = 32'h0000_3200;   // conjunto 0x10, etiqueta 3

    localparam logic [LINE_MASK_W-1:0] BE_ALL = {LINE_MASK_W{1'b1}};

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

    // Un segundo patrón, para el segundo vaciado: si se usara el mismo, la
    // comprobación de la RAM no distinguiría un vaciado que no hace nada de
    // uno que sí escribe.
    function automatic logic [LINE_W-1:0] rewritten_pattern(input logic [31:0] addr);

        logic [LINE_W-1:0] r;
        integer j;

        begin
            r = '0;
            for (j = 0; j < LINE_WORDS; j = j + 1)
                r[32*j +: 32] = 32'h5A5A_0000 + addr[15:5]*8 + j;
            rewritten_pattern = r;
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

    // Espera a que la L2 avise que terminó el vaciado.
    task automatic wait_flush_done;

        integer guard;

        begin
            guard = 0;
            while (!flush_done && guard < 20000) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end

            if (guard >= 20000) begin
                tb_errors++;
                $display("  [FAIL] timeout esperando flush_done");
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

    // Una lectura por el bus versión 2.
    task automatic do_read(input  logic [31:0] addr,
                           output logic [LINE_W-1:0] rline,
                           output logic         rdirty);

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

            guard = 0;
            while (!l2_rvalid && guard < 4000) begin
                @(posedge clk); #1;
                guard = guard + 1;
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


    // ======================================================================
    // Secuencia de pruebas
    // ======================================================================

    logic [LINE_W-1:0] line;
    logic [LINE_W-1:0] pat;
    logic              dirty;
    integer            guard;
    integer            cycles;

    initial begin

        $dumpfile("tb_l2_cache_flush.vcd");
        $dumpvars(0, tb_l2_cache_flush);

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
        check("no hay aviso de vaciado", flush_done, 32'd0);

        // ------------------------------------------------------------------
        tb_section("1. Cuatro líneas sucias en la L2 (todavía no en la RAM)");
        // ------------------------------------------------------------------
        //
        // La L2 es write-back: las líneas escribidas se quedan en la caché y
        // la RAM no cambia hasta que la línea salga sucia de la L2.

        do_write(ADDR_A, written_pattern(ADDR_A), BE_ALL, 1'b1);   // vía 0
        do_write(ADDR_B, written_pattern(ADDR_B), BE_ALL, 1'b1);   // vía 1
        do_write(ADDR_C, written_pattern(ADDR_C), BE_ALL, 1'b1);   // vía 2
        do_write(ADDR_D, written_pattern(ADDR_D), BE_ALL, 1'b1);   // vía 3

        check_true("la RAM todavía no tiene la línea A",
                   memory[ADDR_A[15:2]] == 32'hC0DE0000 + ADDR_A[15:2]);
        check_true("la RAM todavía no tiene la línea D",
                   memory[ADDR_D[15:2]] == 32'hC0DE0000 + ADDR_D[15:2]);
        check_true("el buffer está vacío", empty);

        // ------------------------------------------------------------------
        tb_section("2. El vaciado baja las líneas sucias a la RAM");
        // ------------------------------------------------------------------

        @(negedge clk);
        flush_req = 1'b1;

        // La L2 deja de aceptar peticiones: el núcleo queda detenido.
        repeat (4) @(posedge clk); #1;
        check("la L2 no acepta peticiones durante el vaciado", l2_gnt, 32'd0);
        check("todavía no ha terminado", flush_done, 32'd0);

        wait_flush_done();

        check_true("la L2 avisó que terminó", flush_done);

        // El aviso se mantiene mientras flush_req siga en alto (como en la
        // L1-D).
        repeat (5) @(posedge clk); #1;
        check_true("el aviso se mantiene con flush_req en alto", flush_done);

        check_true("no hubo error de memoria", !ram_error);
        check_true("el buffer quedó vacío", empty);

        check_ram_line("la línea A vaciada llegó a la RAM",
                       ADDR_A, written_pattern(ADDR_A));
        check_ram_line("la línea B vaciada llegó a la RAM",
                       ADDR_B, written_pattern(ADDR_B));
        check_ram_line("la línea C vaciada llegó a la RAM",
                       ADDR_C, written_pattern(ADDR_C));
        check_ram_line("la línea D vaciada llegó a la RAM",
                       ADDR_D, written_pattern(ADDR_D));

        // ------------------------------------------------------------------
        tb_section("3. Al bajar flush_req la L2 vuelve a estar libre");
        // ------------------------------------------------------------------
        //
        // Igual que la L1-D, la L2 se queda detenida hasta que flush_req baja:
        // el aviso de que terminó es un nivel, y el pedido se mantiene hasta
        // que quien lo pide ya no lo necesita.

        @(negedge clk);
        flush_req = 1'b0;

        repeat (4) @(posedge clk); #1;

        check_true("la L2 vuelve a estar libre", idle);
        check("la L2 vuelve a aceptar peticiones", l2_gnt, 32'd1);
        check("ya no hay aviso de vaciado", flush_done, 32'd0);

        // ------------------------------------------------------------------
        tb_section("4. Las copias de la L2 quedan limpias");
        // ------------------------------------------------------------------
        //
        // La línea que se vació ya está en la RAM, así que la copia de la L2
        // pasa a estar limpia: al releerla, el bus la entrega con l2_rdirty
        // en 0 (en exclusiva, además, la línea se mueve a la L1-D).

        do_read(ADDR_A, line, dirty);

        check_line("la línea releída es la que se escribió",
                   line, written_pattern(ADDR_A));
        check("la línea vaciada se entrega limpia", dirty, 32'd0);

        // ------------------------------------------------------------------
        tb_section("5. Un segundo vaciado con una línea nueva");
        // ------------------------------------------------------------------
        //
        // La L2 sigue funcionando: una escritura nueva la deja sucia y el
        // siguiente vaciado la baja a la RAM.

        do_write(ADDR_C, rewritten_pattern(ADDR_C), BE_ALL, 1'b1);

        pat = written_pattern(ADDR_C);
        check_true("la RAM todavía tiene la versión anterior de la línea",
                   memory[ADDR_C[15:2]] == pat[31:0]);

        @(negedge clk);
        flush_req = 1'b1;

        wait_flush_done();

        check_true("la L2 avisó que terminó", flush_done);
        check_ram_line("la línea nueva también bajó a la RAM",
                       ADDR_C, rewritten_pattern(ADDR_C));

        @(negedge clk);
        flush_req = 1'b0;

        repeat (4) @(posedge clk); #1;

        check_true("la L2 vuelve a estar libre", idle);

        tb_finish("tb_l2_cache_flush");
    end

endmodule
