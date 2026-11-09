/*
================================================================================
 Testbench: tb_l1d_writeback

 Descripción:
 ------------------------------------------------------------------------------
 Pruebas de rtl-p2/l1d_cache.sv con write-back, la política exclusiva y el bus
 L1-D <-> L2 versión 2 (decisiones D3, D4, D5, D7, D9 y D16 de
 docs/decisiones-importantes.md; notas de clase 6.2.3, 6.2.4, 6.3.3 y 6.3.5).

 La L2 real es de Alejandro. Este archivo trae tb_l2v2_model: una L2 con el
 bus versión 2 (l2_gnt, l2_rvalid, l2_rdirty, l2_wdirty), bloqueante, que
 guarda todo lo que hay debajo de la L1-D. Para poder revisar la política
 exclusiva separa dos cosas:
   mem      lo más nuevo que hay debajo de la L1-D (la L2 o la RAM);
   ram      lo que tiene la RAM. Una línea que la L2 tiene más nueva que la
            RAM queda marcada "sucia en la L2" (l2dirty).
 Con exclusiva, una lectura MUEVE la línea: responde con l2_rdirty = l2dirty
 y la desmarca (ahora la L1-D es la que la tiene sucia).
 El modelo también revisa:
   - que la petición no cambie mientras espera l2_gnt;
   - que una víctima LIMPIA (l2_wdirty = 0) coincida con la RAM. Si la L1-D
     perdiera el bit sucio de una línea, la mandaría como limpia y una L2
     real la descartaría: aquí se nota porque no coincide con la RAM.
 Latencia: fija (acepta de inmediato y responde a los 8 ciclos) o variable
 (aceptación demorada, a veces 8 + 53 como un miss de L2).

 Todas las L1-D de este testbench usan N_MSHR = 1 (caché bloqueante): aquí
 se mide el camino del miss bloqueante (por ejemplo, el store que falla con
 write-allocate cuesta 8 ciclos). Los MSHR se prueban en tb_l1d_mshr.sv.

 Parte 1. Pruebas dirigidas (write-back + exclusiva + write-allocate + LRU,
          write buffer de 4, L2 de 8 ciclos):
   1. Miss en frío: 8 ciclos, la línea se mueve desde la L2.
   2. Store que acierta: 0 ciclos, la línea queda sucia y no va a la L2.
   3. Víctima sucia: el miss sigue costando 8 ciclos; la víctima va a la L2
      con l2_wdirty = 1.
   4. Espera de línea (D7): se vuelve a pedir la línea que está en el write
      buffer; la L1-D espera a que llegue a la L2 y después la mueve de
      vuelta con l2_rdirty = 1 (sigue sucia). Sin forwarding.
   5. Víctima limpia: con exclusiva también va a la L2 (caché víctima).
   6. Vaciado: las líneas sucias se mueven a la L2 (quedan inválidas en la
      L1-D) y la memoria queda al día.
   Durante toda la parte 1 y la 2 se revisa la exclusividad: cada vez que la
   L2 acepta una línea completa, esa línea no puede estar válida en la L1-D.

 Parte 2. Pruebas aleatorias de 8 configuraciones a la vez (tb_l1d_wb_harness),
          todas con bus versión 2, cada una contra una memoria de referencia:
   - write-back + NINE, write-back + exclusiva y write-through + NINE;
   - write-allocate y no-write-allocate, LRU, FIFO y RANDOM, forwarding y
     espera, write buffer de 2, 3, 4 y 8, latencia fija y variable.
   Se revisa cada load, la memoria después de cada vaciado, que el vaciado
   no deje líneas sucias, un evento hit/miss por acceso, y que se hayan
   ejercitado víctimas sucias, víctimas limpias y movimientos (exclusiva),
   forwarding y esperas.

 Uso: make tb_l1d_writeback
================================================================================
*/

`timescale 1ns/1ps
`include "cache_defs.sv"

// Contenido inicial de la memoria (L2, RAM y referencia)
`define INIT_WORD(i) ((32'(i) * 32'h9E37_79B9) ^ 32'h5A5A_0000)

// Las pruebas aleatorias son largas: se amplía el watchdog de tb_utils.svh
`define TB_TIMEOUT 400000000


// ############################################################################
//  Modelo de L2 con el bus versión 2 (solo para este testbench)
// ############################################################################

module tb_l2v2_model #(
    parameter bit EXCL     = 0,     // 1 = la lectura mueve la línea (exclusiva)
    parameter bit RAND_LAT = 0,     // 1 = aceptación y latencia variables
    parameter int LAT      = 8,     // ciclos desde la aceptación hasta l2_rvalid
    parameter int SEED     = 1
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         l2_req,
    input  logic         l2_we,
    input  logic         l2_wdirty,
    input  logic [31:0]  l2_addr,
    input  logic [31:0]  l2_be,
    input  logic [255:0] l2_wline,
    output logic         l2_gnt,
    output logic         l2_rvalid,
    output logic         l2_rdirty,
    output logic [255:0] l2_rline,
    output int           errors,        // errores de protocolo y víctimas limpias distintas
    output int           n_moves,       // lecturas (con exclusiva: movimientos)
    output int           n_wr_dirty,    // líneas completas recibidas sucias
    output int           n_wr_clean     // líneas completas recibidas limpias
);

logic [31:0] mem [0:16383];     // lo más nuevo debajo de la L1-D
logic [31:0] ram [0:16383];     // lo que tiene la RAM
logic        l2dirty [0:2047];  // la L2 tiene la línea más nueva que la RAM

integer i;
initial begin
    for (i = 0; i < 16384; i++) begin mem[i] = `INIT_WORD(i); ram[i] = `INIT_WORD(i); end
    for (i = 0; i < 2048; i++) l2dirty[i] = 1'b0;
end

integer      seed = SEED;
int          busy;              // ciclos que faltan para quedar libre tras una escritura
logic        rd_on;             // hay una lectura en curso
int          rd_cnt;
logic [31:0] rd_addr;
logic        prev_wait;         // en el ciclo anterior había una petición sin aceptar
logic        prev_we;
logic [31:0] prev_addr;

logic [255:0] cur;
logic         full;

always @(posedge clk) begin

    if (reset) begin
        busy <= 0; rd_on <= 0; l2_gnt <= 1; l2_rvalid <= 0; l2_rdirty <= 0;   // libre: acepta
        errors <= 0; n_moves <= 0; n_wr_dirty <= 0; n_wr_clean <= 0; prev_wait <= 0;
    end
    else begin

        // La petición tiene que mantenerse igual hasta que se acepta
        if (prev_wait && (!l2_req || l2_we !== prev_we || l2_addr !== prev_addr)) begin
            $display("  [L2] la petición cambió antes de l2_gnt (t=%0t)", $time);
            errors <= errors + 1;
        end
        prev_wait <= l2_req && !l2_gnt;
        prev_we   <= l2_we;
        prev_addr <= l2_addr;

        l2_rvalid <= 1'b0;

        // ---- Petición aceptada ------------------------------------------
        if (l2_req && l2_gnt) begin
            if (l2_addr[4:0] != 0) begin
                $display("  [L2] dirección no alineada %h", l2_addr);
                errors <= errors + 1;
            end
            if (l2_we) begin
                full = (l2_be == 32'hFFFF_FFFF);
                for (int w = 0; w < 8; w++) cur[32*w +: 32] = ram[l2_addr[15:2] + w];
                if (full && !l2_wdirty && cur !== l2_wline) begin
                    $display("  [L2] víctima limpia %h distinta de la RAM", l2_addr);
                    errors <= errors + 1;
                end
                for (int b = 0; b < 32; b++)
                    if (l2_be[b]) mem[l2_addr[15:2] + b/4][8*(b%4) +: 8] = l2_wline[8*b +: 8];
                if (l2_wdirty || !full) l2dirty[l2_addr[15:5]] = 1'b1;
                if (full && l2_wdirty)  n_wr_dirty <= n_wr_dirty + 1;
                if (full && !l2_wdirty) n_wr_clean <= n_wr_clean + 1;
                busy <= LAT + (RAND_LAT ? $unsigned($random(seed)) % 3 : 0);
            end
            else begin
                rd_on   <= 1'b1;
                rd_addr <= l2_addr;
                rd_cnt  <= LAT - 2 + (RAND_LAT ? (($unsigned($random(seed)) % 8 == 0) ? 53
                                                  : $unsigned($random(seed)) % 3) : 0);
            end
        end

        // ---- Respuesta de la lectura ------------------------------------
        if (rd_on) begin
            if (rd_cnt == 0) begin
                for (int w = 0; w < 8; w++) l2_rline[32*w +: 32] <= mem[rd_addr[15:2] + w];
                l2_rdirty <= EXCL && l2dirty[rd_addr[15:5]];
                if (EXCL) l2dirty[rd_addr[15:5]] = 1'b0;     // se movió a la L1-D
                n_moves   <= n_moves + 1;
                l2_rvalid <= 1'b1;
                rd_on     <= 1'b0;
            end
            else
                rd_cnt <= rd_cnt - 1;
        end
        else if (busy > 0)
            busy <= busy - 1;

        // ---- Aceptación (registrada): libre, y a veces demorada ----------
        l2_gnt <= !rd_on && busy <= 1 && !(l2_req && l2_gnt) &&
                  (!RAND_LAT || $unsigned($random(seed)) % 4 != 0);
    end
end

endmodule


// ############################################################################
//  Arnés de prueba aleatoria: una L1-D (bus versión 2) + su L2 + referencia
// ############################################################################

module tb_l1d_wb_harness #(
    parameter logic       WP       = WP_WRITE_BACK,
    parameter logic [1:0] INCL     = INCL_NINE,
    parameter logic       AP       = AP_WRITE_ALLOC,
    parameter logic [1:0] RP       = RP_LRU,
    parameter logic       RAW      = RAW_FORWARD,
    parameter int         DEPTH    = 4,
    parameter int         SEED     = 1,
    parameter int         N_OPS    = 3000
) (
    input  logic clk,
    input  logic reset,
    input  logic start,
    output logic done,
    output int   errors,
    output int   n_vdirty,
    output int   n_vclean,
    output int   n_rawwait,
    output int   n_fwd,
    output int   n_moves
);

logic        re, we, fr, fd, stall;
logic [3:0]  be;
logic [31:0] addr, wdata, rdata;
logic        rq, lwe, wd, gnt, rv, rdd;
logic [31:0] la, lbe;
logic [255:0] wl, rl;
int          l2_err, l2_mv, l2_wd, l2_wc;
logic        e [0:13];

l1d_cache #(.WRITE_POLICY(WP), .INCL_POLICY(INCL), .ALLOC_POLICY(AP), .REPL_POLICY(RP),
            .RAW_POLICY(RAW), .WB_DEPTH(DEPTH), .N_MSHR(1), .L2_BUS_V2(1)) DUT (
    .clk(clk), .reset(reset),
    .re(re), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata), .stall(stall),
    .flush_req(fr), .flush_done(fd),
    .l2_req(rq), .l2_we(lwe), .l2_addr(la), .l2_wline(wl), .l2_be(lbe), .l2_wdirty(wd),
    .l2_gnt(gnt), .l2_rvalid(rv), .l2_rdirty(rdd), .l2_rline(rl),
    .ev_rd_hit(e[0]), .ev_rd_miss(e[1]), .ev_wr_hit(e[2]), .ev_wr_miss(e[3]), .ev_stall(e[4]),
    .ev_wb_full_stall(e[5]), .ev_raw_stall(e[6]), .ev_raw_forward(e[7]), .ev_wb_push(e[8]),
    .ev_l2_read(e[9]), .ev_l2_write(e[10]), .ev_fill(e[11]), .ev_victim_dirty(e[12]),
    .ev_victim_clean(e[13])
);

tb_l2v2_model #(.EXCL(INCL == INCL_EXCLUSIVE), .RAND_LAT(1), .SEED(SEED + 99)) L2 (
    .clk(clk), .reset(reset), .l2_req(rq), .l2_we(lwe), .l2_wdirty(wd), .l2_addr(la),
    .l2_be(lbe), .l2_wline(wl), .l2_gnt(gnt), .l2_rvalid(rv), .l2_rdirty(rdd), .l2_rline(rl),
    .errors(l2_err), .n_moves(l2_mv), .n_wr_dirty(l2_wd), .n_wr_clean(l2_wc)
);

// Memoria de referencia
logic [31:0] gold [0:16383];
integer gi;
initial for (gi = 0; gi < 16384; gi++) gold[gi] = `INIT_WORD(gi);

int n_events, n_acc;

// Contadores y revisión de exclusividad: cuando la L2 acepta una línea
// completa, esa línea no puede seguir válida en la L1-D
logic [5:0] xs;
logic [4:0] xt;

always @(posedge clk) begin
    if (reset) begin
        n_events = 0; n_vdirty = 0; n_vclean = 0; n_rawwait = 0; n_fwd = 0;
    end
    else begin
        n_events  += e[0] + e[1] + e[2] + e[3];
        n_vdirty  += e[12];
        n_vclean  += e[13];
        n_rawwait += e[6];
        n_fwd     += e[7];
        if (INCL == INCL_EXCLUSIVE && rq && gnt && lwe && lbe == 32'hFFFF_FFFF) begin
            xs = la[10:5];
            xt = la[15:11];
            if ((DUT.ARRAYS.g_way[0].valid_bits[xs] && DUT.ARRAYS.g_way[0].tag_mem[xs] == xt) ||
                (DUT.ARRAYS.g_way[1].valid_bits[xs] && DUT.ARRAYS.g_way[1].tag_mem[xs] == xt)) begin
                $display("  [%m] exclusividad: la línea %h va a la L2 y sigue en la L1-D", la);
                errors++;
            end
        end
    end
end

integer seed = SEED;

function automatic int rnd(input int n);
    return $unsigned($random(seed)) % n;
endfunction

// Dirección aleatoria con muchos conflictos
function automatic logic [31:0] rand_addr();
    logic [4:0] t;
    logic [5:0] x;
    int r;
    r = rnd(10);
    x = (r < 4) ? 6'd0 : (r < 7) ? 6'd1 : (r < 8) ? 6'd63 : 6'(rnd(64));
    t = (rnd(8) == 0) ? 5'(rnd(32)) : 5'(rnd(4));
    return {16'h0, t, x, 3'(rnd(8)), 2'(rnd(4))};
endfunction

// Un acceso completo: lo presenta, espera stall = 0 y lo verifica
task automatic access(input logic ld, input logic [31:0] a, input logic [3:0] bs,
                      input logic [31:0] d);
    int w;
    re = ld; we = !ld; addr = a; be = bs; wdata = d;
    w = 0;
    @(negedge clk);
    while (stall && w <= 3000) begin w++; @(negedge clk); end
    if (stall) begin $display("  [%m] acceso colgado en %h", a); errors++; end
    if (ld && rdata !== gold[a[15:2]]) begin
        if (errors < 10) $display("  [%m] load %h: %h esperado %h", a, rdata, gold[a[15:2]]);
        errors++;
    end
    @(posedge clk);
    if (!ld) for (int k = 0; k < 4; k++) if (bs[k]) gold[a[15:2]][8*k +: 8] = d[8*k +: 8];
    n_acc++;
    #1;
    re = 0; we = 0;
endtask

// Vaciado: memoria igual a la referencia y ninguna línea sucia en la L1-D
task automatic flush_and_compare(input string when);
    int w, bad;
    fr = 1;
    w  = 0;
    while (!fd && w < 40000) begin @(posedge clk); #1; w++; end
    if (!fd) begin $display("  [%m] el vaciado no terminó (%s)", when); errors++; end
    bad = 0;
    for (int k = 0; k < 16384; k++)
        if (L2.mem[k] !== gold[k]) begin
            if (bad < 5) $display("  [%m] %s: mem[%h] = %h, esperado %h", when, k*4, L2.mem[k], gold[k]);
            bad++;
        end
    errors += bad;
    for (int s = 0; s < 64; s++)
        if ((DUT.ARRAYS.g_way[0].valid_bits[s] && DUT.ARRAYS.g_way[0].dirty_bits[s]) ||
            (DUT.ARRAYS.g_way[1].valid_bits[s] && DUT.ARRAYS.g_way[1].dirty_bits[s])) begin
            $display("  [%m] %s: el conjunto %0d quedó sucio", when, s);
            errors++;
        end
    fr = 0;
    @(posedge clk); #1;
endtask

task automatic random_ops(input int n);
    int k, sh;
    logic [31:0] a;
    for (int op = 0; op < n; op++) begin
        if (rnd(10) == 0) begin @(posedge clk); #1; end
        k  = rnd(10);
        a  = rand_addr();
        sh = a[1:0];
        if (k < 5)      access(1, a, 4'b0000, 0);
        else if (k < 8) access(0, a, 4'b1111, $random(seed));
        else            access(0, a, 4'b0001 << sh, ($random(seed) & 32'hFF) << (8*sh));
    end
endtask

initial begin
    re = 0; we = 0; be = 0; addr = 0; wdata = 0; fr = 0;
    done = 0; errors = 0; n_acc = 0;
    wait (start === 1'b1);
    @(posedge clk); #1;
    random_ops(N_OPS);
    flush_and_compare("tras las pruebas aleatorias");
    random_ops(N_OPS / 4);                  // la caché sigue sirviendo tras vaciar
    flush_and_compare("tras el segundo bloque");
    errors += l2_err;
    n_moves = l2_mv;
    if (n_events != n_acc) begin
        $display("  [%m] eventos hit/miss = %0d, accesos = %0d", n_events, n_acc);
        errors++;
    end
    done = 1;
end

endmodule


// ############################################################################
//  Testbench principal
// ############################################################################

module tb_l1d_writeback;

`include "tb_utils.svh"

logic clk = 1'b0;
logic reset;
always #5 clk = ~clk;


// ============================================================================
// Parte 1: DUT de las pruebas dirigidas (write-back + exclusiva)
// ============================================================================

logic        re, we, fr, fd, stall;
logic [3:0]  be;
logic [31:0] addr, wdata, rdata;
logic        rq, lwe, wd, gnt, rv, rdd;
logic [31:0] la, lbe;
logic [255:0] wl, rl;
int          l2_err, l2_mv, l2_wd, l2_wc;
logic        e [0:13];

l1d_cache #(.WRITE_POLICY(WP_WRITE_BACK), .INCL_POLICY(INCL_EXCLUSIVE),
            .ALLOC_POLICY(AP_WRITE_ALLOC), .REPL_POLICY(RP_LRU), .WB_DEPTH(4),
            .N_MSHR(1), .L2_BUS_V2(1)) DUT (
    .clk(clk), .reset(reset),
    .re(re), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata), .stall(stall),
    .flush_req(fr), .flush_done(fd),
    .l2_req(rq), .l2_we(lwe), .l2_addr(la), .l2_wline(wl), .l2_be(lbe), .l2_wdirty(wd),
    .l2_gnt(gnt), .l2_rvalid(rv), .l2_rdirty(rdd), .l2_rline(rl),
    .ev_rd_hit(e[0]), .ev_rd_miss(e[1]), .ev_wr_hit(e[2]), .ev_wr_miss(e[3]), .ev_stall(e[4]),
    .ev_wb_full_stall(e[5]), .ev_raw_stall(e[6]), .ev_raw_forward(e[7]), .ev_wb_push(e[8]),
    .ev_l2_read(e[9]), .ev_l2_write(e[10]), .ev_fill(e[11]), .ev_victim_dirty(e[12]),
    .ev_victim_clean(e[13])
);

tb_l2v2_model #(.EXCL(1), .RAND_LAT(0), .LAT(8)) L2 (
    .clk(clk), .reset(reset), .l2_req(rq), .l2_we(lwe), .l2_wdirty(wd), .l2_addr(la),
    .l2_be(lbe), .l2_wline(wl), .l2_gnt(gnt), .l2_rvalid(rv), .l2_rdirty(rdd), .l2_rline(rl),
    .errors(l2_err), .n_moves(l2_mv), .n_wr_dirty(l2_wd), .n_wr_clean(l2_wc)
);

// Contadores de eventos y revisión de exclusividad de la parte 1
int c_fill, c_vdirty, c_vclean, c_rawwait, c_fwd, x_err;
logic [5:0] xs;
logic [4:0] xt;

always @(posedge clk) begin
    if (reset) begin
        c_fill = 0; c_vdirty = 0; c_vclean = 0; c_rawwait = 0; c_fwd = 0; x_err = 0;
    end
    else begin
        c_fill    += e[11];
        c_vdirty  += e[12];
        c_vclean  += e[13];
        c_rawwait += e[6];
        c_fwd     += e[7];
        if (rq && gnt && lwe && lbe == 32'hFFFF_FFFF) begin
            xs = la[10:5];
            xt = la[15:11];
            if ((DUT.ARRAYS.g_way[0].valid_bits[xs] && DUT.ARRAYS.g_way[0].tag_mem[xs] == xt) ||
                (DUT.ARRAYS.g_way[1].valid_bits[xs] && DUT.ARRAYS.g_way[1].tag_mem[xs] == xt))
                x_err++;
        end
    end
end


// Dirección a partir de sus campos: {etiqueta, conjunto, palabra, byte}
function automatic logic [31:0] mk(input int tag, input int set, input int word);
    return {16'h0, 5'(tag), 6'(set), 3'(word), 2'b00};
endfunction

function automatic logic [31:0] init_of(input logic [31:0] a);
    return `INIT_WORD(a[15:2]);
endfunction

// ¿La línea de la dirección a está en la L1-D? y ¿está sucia?
function automatic bit in_l1(input logic [31:0] a);
    return (DUT.ARRAYS.g_way[0].valid_bits[a[10:5]] && DUT.ARRAYS.g_way[0].tag_mem[a[10:5]] == a[15:11]) ||
           (DUT.ARRAYS.g_way[1].valid_bits[a[10:5]] && DUT.ARRAYS.g_way[1].tag_mem[a[10:5]] == a[15:11]);
endfunction

function automatic bit dirty_l1(input logic [31:0] a);
    return (DUT.ARRAYS.g_way[0].valid_bits[a[10:5]] && DUT.ARRAYS.g_way[0].tag_mem[a[10:5]] == a[15:11]
            && DUT.ARRAYS.g_way[0].dirty_bits[a[10:5]]) ||
           (DUT.ARRAYS.g_way[1].valid_bits[a[10:5]] && DUT.ARRAYS.g_way[1].tag_mem[a[10:5]] == a[15:11]
            && DUT.ARRAYS.g_way[1].dirty_bits[a[10:5]]);
endfunction

// Un acceso; devuelve el dato y los ciclos de stall
task automatic do_access(input logic ld, input logic [31:0] a, input logic [3:0] bs,
                         input logic [31:0] d, output logic [31:0] q, output int stalls);
    re = ld; we = !ld; addr = a; be = bs; wdata = d;
    stalls = 0;
    @(negedge clk);
    while (stall && stalls <= 500) begin stalls++; @(negedge clk); end
    q = rdata;
    @(posedge clk); #1;
    re = 0; we = 0;
endtask

// Espera sin accesos a que el write buffer quede vacío y el bus libre
task automatic wait_drained();
    while (!(DUT.wb_empty && !DUT.port_busy && L2.busy == 0)) begin @(posedge clk); #1; end
endtask

logic [31:0] q;
int          st, k, w_before;


// ============================================================================
// Parte 2: 8 configuraciones aleatorias en paralelo, todas con bus versión 2
// ============================================================================

localparam int NH = 8;
logic start_rand;
logic hd   [NH];
int   herr [NH];
int   hvd  [NH];
int   hvc  [NH];
int   hrw  [NH];
int   hfw  [NH];
int   hmv  [NH];

`define WBH(K, X1, X2, X3, X4, X5, X6) \
    tb_l1d_wb_harness #(.WP(X1), .INCL(X2), .AP(X3), .RP(X4), .RAW(X5), .DEPTH(X6), \
                        .SEED(K*31+7)) H``K ( \
        .clk(clk), .reset(reset), .start(start_rand), .done(hd[K]), .errors(herr[K]), \
        .n_vdirty(hvd[K]), .n_vclean(hvc[K]), .n_rawwait(hrw[K]), .n_fwd(hfw[K]), \
        .n_moves(hmv[K]));

`WBH(0, WP_WRITE_BACK,    INCL_NINE,      AP_WRITE_ALLOC,    RP_LRU,    RAW_FORWARD, 4)
`WBH(1, WP_WRITE_BACK,    INCL_NINE,      AP_WRITE_ALLOC,    RP_FIFO,   RAW_STALL,   2)
`WBH(2, WP_WRITE_BACK,    INCL_EXCLUSIVE, AP_WRITE_ALLOC,    RP_LRU,    RAW_FORWARD, 4)
`WBH(3, WP_WRITE_BACK,    INCL_EXCLUSIVE, AP_WRITE_ALLOC,    RP_RANDOM, RAW_STALL,   2)
`WBH(4, WP_WRITE_BACK,    INCL_EXCLUSIVE, AP_NO_WRITE_ALLOC, RP_FIFO,   RAW_FORWARD, 8)
`WBH(5, WP_WRITE_BACK,    INCL_NINE,      AP_NO_WRITE_ALLOC, RP_RANDOM, RAW_FORWARD, 3)
`WBH(6, WP_WRITE_THROUGH, INCL_NINE,      AP_NO_WRITE_ALLOC, RP_LRU,    RAW_FORWARD, 4)
`WBH(7, WP_WRITE_THROUGH, INCL_NINE,      AP_WRITE_ALLOC,    RP_LRU,    RAW_STALL,   2)

function automatic string cfg_name(input int k);
    case (k)
        0: return "WB+NINE+WA+LRU+FWD D4";
        1: return "WB+NINE+WA+FIFO+STALL D2";
        2: return "WB+EXCL+WA+LRU D4";
        3: return "WB+EXCL+WA+RANDOM D2";
        4: return "WB+EXCL+NWA+FIFO D8";
        5: return "WB+NINE+NWA+RANDOM+FWD D3";
        6: return "WT+NINE+NWA+LRU+FWD D4";
        7: return "WT+NINE+WA+LRU+STALL D2";
        default: return "?";
    endcase
endfunction

function automatic bit is_wb(input int k);   return k <= 5; endfunction
function automatic bit is_excl(input int k); return k >= 2 && k <= 4; endfunction
function automatic bit uses_fwd(input int k); return k == 0 || k == 5 || k == 6; endfunction


// ============================================================================
// Secuencia de pruebas
// ============================================================================

int all_done;

initial begin

    $dumpfile("tb_l1d_writeback.vcd");
    $dumpvars(0, tb_l1d_writeback.DUT);
    $dumpvars(0, tb_l1d_writeback.L2);

    re = 0; we = 0; be = 0; addr = 0; wdata = 0; fr = 0;
    start_rand = 0;
    reset = 1;
    @(posedge clk); @(posedge clk); #1;
    reset = 0;


    // ------------------------------------------------------------------
    tb_section("1. Miss en frío: 8 ciclos, la línea se mueve desde la L2");
    // ------------------------------------------------------------------
    do_access(1, mk(1, 5, 3), 0, 0, q, st);           // A -> vía 0
    check("stall del miss", st, 8);
    check("dato", q, init_of(mk(1, 5, 3)));
    check("un llenado (movimiento)", c_fill, 1);
    check_true("la línea está en la L1-D y limpia", in_l1(mk(1, 5, 0)) && !dirty_l1(mk(1, 5, 0)));


    // ------------------------------------------------------------------
    tb_section("2. Store que acierta: la línea queda sucia, no va a la L2");
    // ------------------------------------------------------------------
    w_before = l2_wd + l2_wc;
    do_access(0, mk(1, 5, 3), 4'b1111, 32'hDEAD_BEEF, q, st);
    check("stall del store (hit)", st, 0);
    check_true("la línea quedó sucia", dirty_l1(mk(1, 5, 0)));
    repeat (12) @(posedge clk); #1;
    check("no se escribió nada en la L2 (write-back)", l2_wd + l2_wc, w_before);


    // ------------------------------------------------------------------
    tb_section("3. Víctima sucia: el miss sigue costando 8 ciclos");
    // ------------------------------------------------------------------
    do_access(1, mk(2, 5, 0), 0, 0, q, st);           // B -> vía 1 (A queda LRU)
    check("miss de B: 8 ciclos", st, 8);
    do_access(1, mk(3, 5, 0), 0, 0, q, st);           // C saca a A (sucia)
    check("miss de C con víctima sucia: 8 ciclos", st, 8);
    check("una víctima sucia", c_vdirty, 1);
    check_true("A ya no está en la L1-D", !in_l1(mk(1, 5, 0)));
    wait_drained();
    check("la L2 recibió A con l2_wdirty = 1", l2_wd, 1);
    check("la L2 tiene el dato nuevo de A", L2.mem[mk(1, 5, 3) >> 2], 32'hDEAD_BEEF);


    // ------------------------------------------------------------------
    tb_section("4. Espera de línea y movimiento con l2_rdirty");
    // ------------------------------------------------------------------
    // Conjunto 5: C (vía 0) y B (vía 1). Se ensucia B, se usa C (B queda
    // como la LRU) y D saca a B. Justo después se pide B: su línea todavía
    // está en el write buffer, así que la L1-D espera a que llegue a la L2
    // (D7) y después la mueve de vuelta, sucia. Al volver, B saca a C, que
    // está limpia (con exclusiva, también va a la L2).
    do_access(0, mk(2, 5, 1), 4'b1111, 32'hB0B0_0001, q, st);   // B sucia, C es la LRU
    do_access(1, mk(3, 5, 0), 0, 0, q, st);                      // usar C -> B es la LRU
    w_before = c_rawwait;
    do_access(1, mk(4, 5, 0), 0, 0, q, st);                      // D saca a B (sucia)
    check("D saca a B: víctima sucia", c_vdirty, 2);
    do_access(1, mk(2, 5, 1), 0, 0, q, st);                      // B de inmediato
    check_true("se esperó a que B llegara a la L2 (sin forwarding)", c_rawwait > w_before && c_fwd == 0);
    check_true("más de 8 ciclos por la espera", st > 8);
    check("el dato de B es el nuevo", q, 32'hB0B0_0001);
    check_true("B volvió sucia (l2_rdirty = 1)", dirty_l1(mk(2, 5, 0)));
    check("al volver, B sacó a C (limpia): víctima limpia", c_vclean, 1);


    // ------------------------------------------------------------------
    tb_section("5. Víctima limpia: con exclusiva también va a la L2");
    // ------------------------------------------------------------------
    // Conjunto 5: B (sucia, recién usada) y D (limpia). E saca a D.
    wait_drained();
    w_before = l2_wc;
    do_access(1, mk(5, 5, 0), 0, 0, q, st);
    check("E saca a D (limpia): otra víctima limpia", c_vclean, 2);
    wait_drained();
    check("la L2 recibió D con l2_wdirty = 0", l2_wc - w_before, 1);
    do_access(1, mk(4, 5, 0), 0, 0, q, st);                      // D vuelve desde la L2
    check("D vuelve: 8 ciclos", st, 8);
    check("dato de D", q, init_of(mk(4, 5, 0)));


    // ------------------------------------------------------------------
    tb_section("6. Vaciado: las líneas sucias se mueven a la L2");
    // ------------------------------------------------------------------
    do_access(0, mk(7, 40, 2), 4'b1111, 32'h1234_5678, q, st);   // miss con write-allocate
    check("store miss con write-allocate: 8 ciclos", st, 8);
    check_true("la línea del store está sucia", dirty_l1(mk(7, 40, 0)));
    fr = 1;
    k  = 0;
    while (!fd && k < 4000) begin @(posedge clk); #1; k++; end
    check_true("flush_done", fd);
    check("L2 tras el vaciado (store)", L2.mem[mk(7, 40, 2) >> 2], 32'h1234_5678);
    check("L2 tras el vaciado (B)",     L2.mem[mk(2, 5, 1) >> 2], 32'hB0B0_0001);
    check_true("la línea se movió: ya no está en la L1-D", !in_l1(mk(7, 40, 0)));
    fr = 0;
    @(posedge clk); #1;
    do_access(1, mk(7, 40, 2), 0, 0, q, st);
    check("tras el vaciado vuelve desde la L2: 8 ciclos", st, 8);
    check("y con el dato correcto", q, 32'h1234_5678);
    check("exclusividad en toda la parte 1", x_err, 0);
    check("sin errores del modelo de L2 (protocolo y víctimas limpias)", l2_err, 0);


    // ------------------------------------------------------------------
    tb_section("7. Aleatorias: 8 configuraciones con bus versión 2");
    // ------------------------------------------------------------------
    start_rand = 1;
    all_done   = 0;
    while (!all_done) begin
        @(posedge clk);
        all_done = 1;
        for (k = 0; k < NH; k++) if (!hd[k]) all_done = 0;
    end

    for (k = 0; k < NH; k++) begin
        $display("    %-26s vict_sucias=%0d vict_limpias=%0d esperas=%0d fwd=%0d llenados=%0d",
                 cfg_name(k), hvd[k], hvc[k], hrw[k], hfw[k], hmv[k]);
        check({cfg_name(k), ": errores"}, herr[k], 0);
        if (is_wb(k))
            check_true({cfg_name(k), ": hubo víctimas sucias"}, hvd[k] > 0);
        else
            check({cfg_name(k), ": sin víctimas (write-through)"}, hvd[k] + hvc[k], 0);
        if (is_excl(k)) begin
            check_true({cfg_name(k), ": hubo víctimas limpias (caché víctima)"}, hvc[k] > 0);
            check_true({cfg_name(k), ": hubo esperas de línea"}, hrw[k] > 0);
            check({cfg_name(k), ": sin forwarding"}, hfw[k], 0);
        end
        else begin
            check({cfg_name(k), ": NINE no manda víctimas limpias"}, hvc[k], 0);
            if (uses_fwd(k))
                check_true({cfg_name(k), ": hubo forwarding"}, hfw[k] > 0);
            else
                check_true({cfg_name(k), ": hubo esperas RAW"}, hrw[k] > 0);
        end
    end


    tb_finish("tb_l1d_writeback");
end

endmodule
