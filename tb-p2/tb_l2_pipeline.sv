`timescale 1ns/1ps

/*
================================================================================
 Testbench: tb_l2_pipeline

 Descripción:
 ------------------------------------------------------------------------------
 Prueba la L2 segmentada con peticiones seguidas, que las pruebas de la L2
 bloqueante no hacen (esperan a que la L2 quede libre antes de cada una).
 Dos copias, una exclusiva y una NINE, cada una con un nivel inferior de
 prueba (RAM con latencia al azar y eviction buffer que a veces no acepta).

 Casos:
   A. 24 escrituras de línea completa a conjuntos distintos se aceptan una
      por ciclo (la versión bloqueante necesita 3 ciclos por escritura).
   B. Una lectura aceptada en el ciclo siguiente a una escritura del mismo
      conjunto devuelve el dato recién escrito (S2 espera a S3).
   C. 3000 peticiones al azar, mandadas apenas hay permiso, sobre 18 líneas de
      3 conjuntos (hay aciertos, fallos, desalojos sucios y riesgos entre
      etapas). Cada lectura se compara con un modelo de la memoria:
        - NINE: lecturas y escrituras (completas y parciales) de cualquier línea.
        - Exclusiva: como la L1-D: se lee una línea que no se tiene y después
          se devuelve completa (sucia si se modificó). En exclusiva, una
          línea que estaba sucia tiene que llegar sucia (l2_rdirty).
      Las respuestas salen en orden.
   D. Vaciado al final: la RAM queda igual al modelo (en exclusiva, salvo
      las líneas que tiene el "núcleo").
================================================================================
*/

`include "cache_defs.sv"


module l2_pipe_env #(
    parameter logic [1:0] INCL = INCL_EXCLUSIVE,
    parameter int         SEED = 1
) (
    input  logic clk,
    input  logic reset
);

localparam logic EXCL = (INCL == INCL_EXCLUSIVE);

// ---------------------------------------------------------------------------
// L2 y su nivel inferior de prueba
// ---------------------------------------------------------------------------

logic                   l2_req = 1'b0, l2_we = 1'b0, l2_wdirty = 1'b0;
logic [31:0]            l2_addr = '0;
logic [LINE_W-1:0]      l2_wline = '0;
logic [LINE_MASK_W-1:0] l2_be = '0;
logic                   l2_gnt, l2_rvalid, l2_rdirty, idle;
logic [LINE_W-1:0]      l2_rline;

logic                   evict_valid, evict_ready = 1'b1;
logic [31:0]            evict_addr;
logic [LINE_W-1:0]      evict_line;
logic                   read_req, read_ready = 1'b0;
logic [31:0]            read_addr;
logic [LINE_W-1:0]      read_line = '0;
logic                   flush_req = 1'b0, flush_done;

l2_cache #(.INCL_POLICY(INCL)) DUT (
    .clk(clk), .reset(reset),
    .l2_req(l2_req), .l2_we(l2_we), .l2_addr(l2_addr), .l2_wline(l2_wline), .l2_be(l2_be),
    .l2_wdirty(l2_wdirty), .l2_gnt(l2_gnt), .l2_rvalid(l2_rvalid), .l2_rline(l2_rline),
    .l2_rdirty(l2_rdirty), .idle(idle),
    .evict_valid(evict_valid), .evict_addr(evict_addr), .evict_line(evict_line), .evict_ready(evict_ready),
    .read_req(read_req), .read_addr(read_addr), .read_ready(read_ready), .read_line(read_line),
    .read_forwarded(1'b0),
    .flush_req(flush_req), .flush_done(flush_done), .lower_drained(1'b1),
    .ev_l2_rd_hit(), .ev_l2_rd_miss(), .ev_l2_wr_hit(), .ev_l2_wr_miss(), .ev_l2_fill(),
    .ev_l2_evict(), .ev_l2_writeback(), .ev_l2_invalid(), .ev_l2_read_req(), .ev_l2_write_req()
);

// Líneas de la prueba al azar: 3 conjuntos x 6 etiquetas (más que las 4 vías)
localparam int NL = 18;

function automatic logic [31:0] line_addr(input int i);
    logic [L2_INDEX_W-1:0] sets [0:2];
    sets[0] = 7'd5; sets[1] = 7'd6; sets[2] = 7'd77;
    return {16'b0, 4'(i % 6), sets[i / 6], 5'b0};
endfunction

// Modelo de la memoria (lo que el sistema L2 + RAM debería devolver)
logic [LINE_W-1:0] gold      [0:2047];
logic              gold_dirty[0:2047];      // exclusiva: la línea debe volver sucia
logic              held      [0:2047];      // exclusiva: la tiene el "núcleo"
logic [LINE_W-1:0] held_line [0:2047];
logic              in_flight [0:2047];      // exclusiva: lectura aceptada sin respuesta
logic              ev_seen = 1'b0;
logic [10:0]       ev_seen_line;
int errors = 0, reads_checked = 0, accepted = 0;
int first_acc = -1, last_acc = -1, cycle = 0;

// RAM del nivel inferior (por línea, índice addr[15:5])
logic [LINE_W-1:0] ram [0:2047];
int                rd_wait = -1;
logic [31:0]       rd_addr_q;
int                seed = SEED;

initial for (int i = 0; i < 2048; i++) ram[i] = {8{32'(i * 32'h0101_0101)}};

always @(posedge clk) begin
    read_ready <= 1'b0;
    if (!reset) begin
        if (evict_valid && evict_ready) begin
            ram[evict_addr[15:5]] = evict_line;
            ev_seen_line          = evict_addr[15:5];
            ev_seen               = 1'b1;
        end
        if (read_req) begin
            if (rd_wait >= 0) begin                // una sola lectura pendiente
                errors++;
                $display("  %s: dos lecturas pendientes en el nivel inferior", EXCL ? "EXCL" : "NINE");
            end
            rd_wait   = 3 + ($urandom(seed) % 18);
            rd_addr_q = read_addr;
        end
        else if (rd_wait > 0)
            rd_wait--;
        else if (rd_wait == 0) begin
            read_ready <= 1'b1;
            read_line  <= ram[rd_addr_q[15:5]];
            rd_wait     = -1;
        end
        evict_ready <= ($urandom(seed) % 4) != 0;
    end
end

// ---------------------------------------------------------------------------
// Modelo de la memoria
// ---------------------------------------------------------------------------

initial for (int i = 0; i < 2048; i++) begin
    gold[i] = {8{32'(i * 32'h0101_0101)}};
    gold_dirty[i] = 1'b0; held[i] = 1'b0; held_line[i] = '0; in_flight[i] = 1'b0;
end

// Lecturas en vuelo, en orden
logic [LINE_W-1:0] exp_q   [$];
logic              expd_q  [$];
int                expl_q  [$];

always @(posedge clk) if (!reset) cycle++;

// Un desalojo de la L2 deja la línea igual que la RAM: ya no es "sucia"
always @(negedge clk) if (ev_seen) begin
    gold_dirty[ev_seen_line] = 1'b0;
    ev_seen = 1'b0;
end

// Respuestas: en orden y con el dato del modelo
always @(negedge clk) begin
    if (!reset && l2_rvalid) begin
        if (exp_q.size() == 0) begin
            errors++;
            $display("  %s: respuesta sin lectura pendiente (t=%0t)", EXCL ? "EXCL" : "NINE", $time);
        end
        else begin
            logic [LINE_W-1:0] e; logic ed; int ln;
            e = exp_q.pop_front(); ed = expd_q.pop_front(); ln = expl_q.pop_front();
            if (l2_rline !== e) begin
                errors++;
                if (errors < 5) $display("  %s: lectura de 0x%04h con dato distinto", EXCL ? "EXCL" : "NINE", ln * 32);
            end
            // Sucia según el modelo en el momento de la respuesta: una petición
            // anterior pudo desalojarla a la RAM antes de que la L2 la mirara
            if (EXCL && gold_dirty[ln] && l2_rdirty !== 1'b1) begin
                errors++;
                $display("  EXCL: la línea 0x%04h tenía que volver sucia (t=%0t)", ln * 32, $time);
            end
            reads_checked++;
            if (EXCL) begin
                held[ln] = 1'b1;
                held_line[ln] = l2_rline;
            end
        end
    end
end

// Aceptación: el modelo se actualiza en el orden en que la L2 acepta
always @(posedge clk) begin
    if (!reset && l2_req && l2_gnt) begin
        int ln;
        ln = l2_addr[15:5];
        accepted++;
        if (first_acc < 0) first_acc = cycle;
        last_acc = cycle;
        if (!l2_we) begin
            exp_q.push_back(gold[ln]);
            expd_q.push_back(gold_dirty[ln]);
            expl_q.push_back(ln);
        end
        else begin
            for (int b = 0; b < LINE_BYTES; b++)
                if (l2_be[b]) gold[ln][8*b +: 8] = l2_wline[8*b +: 8];
            if (EXCL) begin
                gold_dirty[ln] = gold_dirty[ln] | l2_wdirty;
                held[ln]       = 1'b0;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Pedidos
// ---------------------------------------------------------------------------

// Manda una petición en el próximo flanco y espera la aceptación
task automatic issue(input logic we, input logic [31:0] addr, input logic [LINE_W-1:0] wl,
                     input logic [LINE_MASK_W-1:0] be, input logic wd);
    @(negedge clk);
    l2_req = 1'b1; l2_we = we; l2_addr = addr; l2_wline = wl; l2_be = be; l2_wdirty = wd;
    @(posedge clk);
    while (!l2_gnt) @(posedge clk);
    #1;
    @(negedge clk);
    l2_req = 1'b0;
endtask

function automatic logic [LINE_W-1:0] rnd_line();
    logic [LINE_W-1:0] l;
    for (int w = 0; w < 8; w++) l[32*w +: 32] = $urandom(seed);
    return l;
endfunction

int  phaseA_cycles = -1;
logic [LINE_W-1:0] b_line;
int  b_gap = -1;
bit  done = 0;

initial begin
    int acc0, c0;

    @(negedge reset);
    repeat (3) @(negedge clk);

    // ---- A. 24 escrituras de línea completa seguidas, conjuntos 10..33 ----
    acc0 = accepted;
    @(negedge clk);
    for (int i = 0; i < 24; i++) begin
        l2_req = 1'b1; l2_we = 1'b1; l2_addr = {16'b0, 4'd1, 7'(10 + i), 5'b0};
        l2_wline = rnd_line(); l2_be = '1; l2_wdirty = 1'b1;
        @(posedge clk);
        while (!l2_gnt) @(posedge clk);
        @(negedge clk);
    end
    l2_req = 1'b0;
    phaseA_cycles = last_acc - first_acc + 1;
    wait (idle); repeat (2) @(negedge clk);

    // ---- B. Lectura del mismo conjunto justo después de una escritura ----
    // (en exclusiva: la línea 0x1xA0 se escribe y se vuelve a pedir)
    b_line = rnd_line();
    @(negedge clk);
    l2_req = 1'b1; l2_we = 1'b1; l2_addr = {16'b0, 4'd2, 7'd40, 5'b0};
    l2_wline = b_line; l2_be = '1; l2_wdirty = 1'b1;
    @(posedge clk); while (!l2_gnt) @(posedge clk);
    c0 = cycle;
    @(negedge clk);
    l2_we = 1'b0; l2_be = '0;                 // misma línea, ahora lectura
    @(posedge clk); while (!l2_gnt) @(posedge clk);
    b_gap = cycle - c0;
    @(negedge clk);
    l2_req = 1'b0;
    wait (idle); repeat (2) @(negedge clk);
    // la línea quedó en el "núcleo" (exclusiva); devolverla para el caso C
    if (EXCL) issue(1'b1, {16'b0, 4'd2, 7'd40, 5'b0}, held_line[{4'd2, 7'd40}], '1, 1'b1);
    wait (idle); repeat (2) @(negedge clk);

    // ---- C. Peticiones al azar, mandadas apenas hay permiso ----
    for (int k = 0; k < 3000; k++) begin
        int i, ln;
        bit skip;
        logic we;
        logic [LINE_MASK_W-1:0] be;
        logic [LINE_W-1:0] wl;

        @(negedge clk);
        skip = (($urandom(seed) % 5) == 0);      // a veces un ciclo sin pedido
        i    = $urandom(seed) % NL;
        ln   = line_addr(i) >> 5;
        we   = 1'b0; be = '0; wl = '0;

        if (!skip) begin
            if (EXCL) begin
                if (held[ln]) begin               // devolverla (víctima de la "L1-D")
                    we = 1'b1; be = '1;
                    wl = ($urandom(seed) % 2) ? rnd_line() : held_line[ln];
                end
                else if (in_flight[ln] || exp_q.size() > 0)
                    skip = 1;                     // como la L1-D: una lectura a la vez
            end
            else begin
                we = $urandom(seed) % 2;
                be = we ? (($urandom(seed) % 3 == 0) ? LINE_MASK_W'($urandom(seed)) : '1) : '0;
                wl = rnd_line();
            end
        end

        if (skip)
            l2_req = 1'b0;
        else begin
            l2_req = 1'b1; l2_we = we; l2_addr = line_addr(i); l2_wline = wl; l2_be = be;
            l2_wdirty = we && (!EXCL || wl !== held_line[ln] || gold_dirty[ln]);
            @(posedge clk);
            while (!l2_gnt) @(posedge clk);
            if (EXCL && !we) in_flight[ln] = 1'b1;
            if (EXCL &&  we) held[ln] = 1'b0;     // ya no se puede devolver dos veces
            #1;
        end
        // la respuesta libera in_flight
        for (int z = 0; z < 2048; z++) if (in_flight[z] && held[z]) in_flight[z] = 1'b0;
    end
    @(negedge clk);
    l2_req = 1'b0;
    wait (idle && exp_q.size() == 0);
    for (int z = 0; z < 2048; z++) in_flight[z] = 1'b0;
    repeat (3) @(negedge clk);

    // ---- D. Vaciado ----
    flush_req = 1'b1;
    wait (flush_done);
    @(negedge clk);
    flush_req = 1'b0;
    repeat (3) @(negedge clk);
    for (int i = 0; i < 2048; i++)
        if (!(EXCL && held[i]) && ram[i] !== gold[i]) begin
            errors++;
            if (errors < 5) $display("  %s: RAM distinta en la línea 0x%04h", EXCL ? "EXCL" : "NINE", i * 32);
        end
    done = 1;
end

endmodule


module tb_l2_pipeline;

`include "tb_utils.svh"

logic clk = 1'b0;
logic reset = 1'b1;

always #5 clk = ~clk;

l2_pipe_env #(.INCL(INCL_EXCLUSIVE), .SEED(7))  EX (.clk(clk), .reset(reset));
l2_pipe_env #(.INCL(INCL_NINE),      .SEED(11)) NI (.clk(clk), .reset(reset));

initial begin
    $dumpfile("tb_l2_pipeline.vcd");
    $dumpvars(0, tb_l2_pipeline);
    $dumpoff;
    repeat (3) @(negedge clk);
    reset = 1'b0;

    wait (EX.done && NI.done);

    tb_section("A. Una escritura por ciclo");
    check("exclusiva: 24 escrituras en 24 ciclos", EX.phaseA_cycles, 24);
    check("NINE: 24 escrituras en 24 ciclos", NI.phaseA_cycles, 24);

    tb_section("B. Lectura en el ciclo siguiente a una escritura del mismo conjunto");
    check("exclusiva: aceptada 1 ciclo después", EX.b_gap, 1);
    check("NINE: aceptada 1 ciclo después", NI.b_gap, 1);

    tb_section("C y D. Peticiones seguidas al azar y vaciado");
    check_true("exclusiva: lecturas comparadas", EX.reads_checked > 150);
    check_true("NINE: lecturas comparadas", NI.reads_checked > 600);
    check("exclusiva: errores (datos, orden, l2_rdirty o RAM)", EX.errors, 0);
    check("NINE: errores (datos, orden o RAM)", NI.errors, 0);
    $display("    exclusiva: %0d peticiones, %0d lecturas comparadas; NINE: %0d y %0d",
             EX.accepted, EX.reads_checked, NI.accepted, NI.reads_checked);

    tb_finish("tb_l2_pipeline");
end

initial begin
    #20ms;
    $fatal(1, "[FAIL] tb_l2_pipeline: timeout");
end

endmodule
