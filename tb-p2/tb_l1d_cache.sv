/*
================================================================================
 Testbench: tb_l1d_cache

 Descripción:
 ------------------------------------------------------------------------------
 Pruebas de la caché L1-D completa (rtl-p2/l1d_cache.sv con l1d_arrays,
 l1d_replacement y l1d_write_buffer) con la configuración write-through +
 NINE, puesta de forma EXPLÍCITA en cada instancia (no depende de los valores
 por defecto). Write-back y la política exclusiva se prueban en
 tb_l1d_writeback.sv.

 La L2 real es trabajo de Alejandro. Para probar la L1-D sin esperarla, este
 archivo trae tb_l2_model: una L2 "ideal" que siempre acierta, guarda los
 64 KB completos y usa el bus L1-D <-> L2 versión 2 (cache_defs.sv,
 sección 4): acepta con l2_gnt (registrado) y responde las lecturas con
 l2_rvalid; una escritura termina al ser aceptada. Es bloqueante: después
 de aceptar algo no acepta otra petición hasta terminarlo.
   - Latencia fija de 8 ciclos (hit de L2), o
   - latencia aleatoria: aceptación demorada, a veces 8 + 53 (como un miss
     de L2 con Tmem = 53 ciclos a 25 MHz) y a veces unos ciclos más.
 También revisa que la L1-D no cambie la petición mientras espera l2_gnt.

 Parte 1. Pruebas dirigidas (write-through + NINE + no-write-allocate, LRU,
          forwarding, write buffer de 4 entradas):
   1. Miss en frío: exactamente 8 ciclos de stall y dato correcto.
   2. Hit: 0 ciclos de stall, en el mismo ciclo (notas 6.3.1, acceso paralelo).
   3. guardap y guardab que aciertan: 0 ciclos, la L1-D se actualiza.
   4. Write-through (notas 6.2.3): cada store llega a la L2 por el write
      buffer, sin necesidad de vaciado.
   5. Store que falla con no-write-allocate: 0 ciclos, no trae la línea.
   6. Riesgo RAW (notas 6.3.5, figura 6.13): se lee esa línea mientras el
      store sigue en el write buffer -> forwarding, dato correcto, 8 ciclos.
   7. LRU con 2 vías (notas 6.2.3): A, B, A, C saca a B; la línea que sale
      se descarta sin escribir en la L2 (está limpia).
   8. Write buffer lleno: el 6.º store seguido espera (riesgo estructural).
   9. Vaciado: solo drena el write buffer; las líneas siguen en la L1-D.

 Parte 2. Pruebas aleatorias de 6 configuraciones a la vez (tb_l1d_harness),
          cada una contra una memoria de referencia:
   - cada load devuelve exactamente lo último que se escribió;
   - cada acceso genera exactamente un evento hit/miss;
   - después del vaciado, la memoria de la L2 es idéntica a la referencia;
   - se ejercitaron forwarding (RAW_FORWARD) y esperas RAW (RAW_STALL).

 Uso: make tb_l1d_cache
================================================================================
*/

`timescale 1ns/1ps
`include "cache_defs.sv"

// Contenido inicial de la memoria (L2 y referencia): un valor distinto por
// palabra para que cualquier error de dirección se note.
`define INIT_WORD(i) ((32'(i) * 32'h9E37_79B9) ^ 32'h5A5A_0000)

// Las pruebas aleatorias son largas: se amplía el watchdog de tb_utils.svh
`define TB_TIMEOUT 100000000


// ############################################################################
//  Modelo de L2 ideal (solo para este testbench)
// ############################################################################

module tb_l2_model #(
    parameter int LAT      = 8,     // ciclos desde la aceptación hasta l2_rvalid
    parameter bit RAND_LAT = 0,     // 1: aceptación y latencia variables
    parameter int SEED     = 1
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         l2_req,
    input  logic         l2_we,
    input  logic [31:0]  l2_addr,
    input  logic [255:0] l2_wline,
    input  logic [31:0]  l2_be,
    output logic         l2_gnt,
    output logic         l2_rvalid,
    output logic [255:0] l2_rline,
    output int           n_reads,
    output int           n_writes,
    output int           proto_errors
);

logic [31:0] mem [0:16383];

integer i;
initial for (i = 0; i < 16384; i++) mem[i] = `INIT_WORD(i);

integer      seed = SEED;
int          busy;              // ciclos que faltan para quedar libre tras una escritura
logic        rd_on;             // hay una lectura en curso
int          rd_cnt;
logic [31:0] rd_addr;
logic        prev_wait;         // en el ciclo anterior había una petición sin aceptar
logic        prev_we;
logic [31:0] prev_addr;

always @(posedge clk) begin

    if (reset) begin
        busy <= 0; rd_on <= 0; l2_gnt <= 1; l2_rvalid <= 0; prev_wait <= 0;
        n_reads <= 0; n_writes <= 0; proto_errors <= 0;
    end
    else begin

        // La petición tiene que mantenerse igual hasta que se acepta
        if (prev_wait && (!l2_req || l2_we !== prev_we || l2_addr !== prev_addr)) begin
            $display("  [L2] la petición cambió antes de l2_gnt (t=%0t)", $time);
            proto_errors <= proto_errors + 1;
        end
        prev_wait <= l2_req && !l2_gnt;
        prev_we   <= l2_we;
        prev_addr <= l2_addr;

        l2_rvalid <= 1'b0;

        // ---- Petición aceptada ------------------------------------------
        if (l2_req && l2_gnt) begin
            if (l2_addr[4:0] != 0) begin
                $display("  [L2] dirección no alineada %h", l2_addr);
                proto_errors <= proto_errors + 1;
            end
            if (l2_we) begin
                // La escritura termina al ser aceptada
                for (int b = 0; b < 32; b++)
                    if (l2_be[b]) mem[l2_addr[15:2] + b/4][8*(b%4) +: 8] = l2_wline[8*b +: 8];
                n_writes <= n_writes + 1;
                busy     <= LAT + (RAND_LAT ? $unsigned($random(seed)) % 3 : 0);
            end
            else begin
                rd_on   <= 1'b1;
                rd_addr <= l2_addr;
                rd_cnt  <= LAT - 2 + (RAND_LAT ? (($unsigned($random(seed)) % 8 == 0) ? 53
                                                  : $unsigned($random(seed)) % 3) : 0);
            end
        end

        // ---- Respuesta de la lectura (l2_rvalid, un ciclo) --------------
        if (rd_on) begin
            if (rd_cnt == 0) begin
                for (int w = 0; w < 8; w++) l2_rline[32*w +: 32] <= mem[rd_addr[15:2] + w];
                n_reads   <= n_reads + 1;
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
//  Arnés de prueba aleatoria: una L1-D con una configuración + su L2 ideal
//  + una memoria de referencia
// ############################################################################

module tb_l1d_harness #(
    parameter logic       ALLOC_POLICY = AP_NO_WRITE_ALLOC,
    parameter logic [1:0] REPL_POLICY  = RP_LRU,
    parameter logic       RAW_POLICY   = RAW_FORWARD,
    parameter int         WB_DEPTH     = 4,
    parameter bit         RAND_LAT     = 0,
    parameter int         SEED         = 1,
    parameter int         N_OPS        = 3000
) (
    input  logic clk,
    input  logic reset,
    input  logic start,
    output logic done,
    output int   errors,
    output int   n_accesses,
    output int   n_events,          // eventos hit/miss (debe ser = n_accesses)
    output int   n_raw_fwd,
    output int   n_raw_stall,
    output int   n_wb_full,
    output int   n_rd_miss,
    output int   n_rd_hit
);

logic        re, we, flush_req, flush_done, stall;
logic [3:0]  be;
logic [31:0] addr, wdata, rdata;
logic        l2_req, l2_we, l2_gnt, l2_rvalid, l2_wdirty;
logic [31:0] l2_addr, l2_be;
logic [255:0] l2_wline, l2_rline;
logic ev_rd_hit, ev_rd_miss, ev_wr_hit, ev_wr_miss, ev_stall, ev_wb_full_stall;
logic ev_raw_stall, ev_raw_forward, ev_wb_push, ev_l2_read, ev_l2_write;
int   l2_reads, l2_writes, l2_proto;

l1d_cache #(
    .WRITE_POLICY(WP_WRITE_THROUGH), .INCL_POLICY(INCL_NINE), .L2_BUS_V2(1),
    .ALLOC_POLICY(ALLOC_POLICY), .REPL_POLICY(REPL_POLICY),
    .RAW_POLICY(RAW_POLICY),     .WB_DEPTH(WB_DEPTH)
) DUT (
    .clk(clk), .reset(reset),
    .re(re), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata), .stall(stall),
    .flush_req(flush_req), .flush_done(flush_done),
    .l2_req(l2_req), .l2_we(l2_we), .l2_addr(l2_addr), .l2_wline(l2_wline), .l2_be(l2_be),
    .l2_wdirty(l2_wdirty), .l2_gnt(l2_gnt), .l2_rvalid(l2_rvalid), .l2_rline(l2_rline),
    .ev_rd_hit(ev_rd_hit), .ev_rd_miss(ev_rd_miss), .ev_wr_hit(ev_wr_hit), .ev_wr_miss(ev_wr_miss),
    .ev_stall(ev_stall), .ev_wb_full_stall(ev_wb_full_stall), .ev_raw_stall(ev_raw_stall),
    .ev_raw_forward(ev_raw_forward), .ev_wb_push(ev_wb_push),
    .ev_l2_read(ev_l2_read), .ev_l2_write(ev_l2_write)
);

tb_l2_model #(.LAT(8), .RAND_LAT(RAND_LAT), .SEED(SEED + 1000)) L2 (
    .clk(clk), .reset(reset),
    .l2_req(l2_req), .l2_we(l2_we), .l2_addr(l2_addr), .l2_wline(l2_wline), .l2_be(l2_be),
    .l2_gnt(l2_gnt), .l2_rvalid(l2_rvalid), .l2_rline(l2_rline),
    .n_reads(l2_reads), .n_writes(l2_writes), .proto_errors(l2_proto)
);

// Memoria de referencia: lo que el programa debería ver
logic [31:0] gold [0:16383];
integer gi;
initial for (gi = 0; gi < 16384; gi++) gold[gi] = `INIT_WORD(gi);

// Contadores de eventos
always @(posedge clk) begin
    if (reset) begin
        n_events = 0; n_raw_fwd = 0; n_raw_stall = 0; n_wb_full = 0;
        n_rd_miss = 0; n_rd_hit = 0;
    end
    else begin
        n_events    += ev_rd_hit + ev_rd_miss + ev_wr_hit + ev_wr_miss;
        n_raw_fwd   += ev_raw_forward;
        n_raw_stall += ev_raw_stall;
        n_wb_full   += ev_wb_full_stall;
        n_rd_miss   += ev_rd_miss;
        n_rd_hit    += ev_rd_hit;
    end
end

integer seed = SEED;

function automatic int rnd(input int n);     // entero en 0 .. n-1
    return $unsigned($random(seed)) % n;
endfunction

// Dirección aleatoria con muchos conflictos: pocos conjuntos y pocas etiquetas
function automatic logic [31:0] rand_addr();
    logic [4:0] tag;
    logic [5:0] idx;
    int r;
    r   = rnd(10);
    idx = (r < 4) ? 6'd0 : (r < 7) ? 6'd1 : (r < 8) ? 6'd63 : 6'(rnd(64));
    tag = (rnd(8) == 0) ? 5'(rnd(32)) : 5'(rnd(4));
    return {rnd(65536) == 0 ? 16'hFFFF : 16'h0000, tag, idx, 3'(rnd(8)), 2'(rnd(4))};
endfunction

// Un acceso completo: lo presenta, espera a que stall = 0 y lo verifica
task automatic access(input logic is_load, input logic [31:0] a,
                      input logic [3:0] bes, input logic [31:0] d);
    int waited;
    re = is_load; we = !is_load; addr = a; be = bes; wdata = d;
    waited = 0;
    @(negedge clk);
    while (stall && waited <= 2000) begin    // esperar a que el acceso termine
        waited++;
        @(negedge clk);
    end
    if (stall) begin
        $display("  [%m] acceso colgado en %h", a);
        errors++;
    end
    if (is_load && rdata !== gold[a[15:2]]) begin
        if (errors < 10)
            $display("  [%m] load %h: obtenido %h esperado %h", a, rdata, gold[a[15:2]]);
        errors++;
    end
    @(posedge clk);
    if (!is_load)
        for (int k = 0; k < 4; k++)
            if (bes[k]) gold[a[15:2]][8*k +: 8] = d[8*k +: 8];
    n_accesses++;
    #1;
    re = 0; we = 0;
endtask

// Vaciado y comparación completa de la L2 con la referencia
task automatic flush_and_compare(input string when);
    int bad, waited;
    flush_req = 1;
    waited = 0;
    while (!flush_done && waited < 20000) begin
        @(posedge clk); #1;
        waited++;
    end
    if (!flush_done) begin
        $display("  [%m] el vaciado no terminó (%s)", when);
        errors++;
    end
    bad = 0;
    for (int k = 0; k < 16384; k++)
        if (L2.mem[k] !== gold[k]) begin
            if (bad < 5)
                $display("  [%m] %s: L2[%h] = %h, esperado %h", when, k*4, L2.mem[k], gold[k]);
            bad++;
        end
    errors += bad;
    flush_req = 0;
    @(posedge clk); #1;
endtask

task automatic random_ops(input int n);
    int kind, sh;
    logic [31:0] a;
    for (int op = 0; op < n; op++) begin
        if (rnd(10) == 0) begin             // a veces un ciclo sin acceso
            @(posedge clk); #1;
        end
        kind = rnd(10);
        a    = rand_addr();
        sh   = a[1:0];
        if (kind < 5)                       // cargai / cargabai (la L1-D da la palabra)
            access(1, a, 4'b0000, 0);
        else if (kind < 8)                  // guardap
            access(0, a, 4'b1111, $random(seed));
        else                                // guardab: byte en su posición
            access(0, a, 4'b0001 << sh, ($random(seed) & 32'hFF) << (8*sh));
    end
endtask

initial begin
    re = 0; we = 0; be = 0; addr = 0; wdata = 0; flush_req = 0;
    done = 0; errors = 0; n_accesses = 0;
    wait (start === 1'b1);
    @(posedge clk); #1;
    random_ops(N_OPS);
    flush_and_compare("tras las pruebas aleatorias");
    random_ops(N_OPS / 4);                  // la caché sigue sirviendo tras vaciar
    flush_and_compare("tras el segundo bloque");
    errors += l2_proto;
    if (n_events != n_accesses) begin
        $display("  [%m] eventos hit/miss = %0d, accesos = %0d", n_events, n_accesses);
        errors++;
    end
    done = 1;
end

endmodule


// ############################################################################
//  Testbench principal
// ############################################################################

module tb_l1d_cache;

`include "tb_utils.svh"

logic clk = 1'b0;
logic reset;
always #5 clk = ~clk;


// ============================================================================
// Parte 1: DUT de las pruebas dirigidas (configuración por defecto)
// ============================================================================

logic        re, we, flush_req, flush_done, stall;
logic [3:0]  be;
logic [31:0] addr, wdata, rdata;
logic        l2_req, l2_we, l2_gnt, l2_rvalid, l2_wdirty;
logic [31:0] l2_addr, l2_be;
logic [255:0] l2_wline, l2_rline;
logic ev_rd_hit, ev_rd_miss, ev_wr_hit, ev_wr_miss, ev_stall, ev_wb_full_stall;
logic ev_raw_stall, ev_raw_forward, ev_wb_push, ev_l2_read, ev_l2_write;
int   l2_reads, l2_writes, l2_proto;

l1d_cache #(
    .WRITE_POLICY(WP_WRITE_THROUGH), .INCL_POLICY(INCL_NINE), .L2_BUS_V2(1),
    .ALLOC_POLICY(AP_NO_WRITE_ALLOC), .REPL_POLICY(RP_LRU),
    .RAW_POLICY(RAW_FORWARD), .WB_DEPTH(4)
) DUT (
    .clk(clk), .reset(reset),
    .re(re), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata), .stall(stall),
    .flush_req(flush_req), .flush_done(flush_done),
    .l2_req(l2_req), .l2_we(l2_we), .l2_addr(l2_addr), .l2_wline(l2_wline), .l2_be(l2_be),
    .l2_wdirty(l2_wdirty), .l2_gnt(l2_gnt), .l2_rvalid(l2_rvalid), .l2_rline(l2_rline),
    .ev_rd_hit(ev_rd_hit), .ev_rd_miss(ev_rd_miss), .ev_wr_hit(ev_wr_hit), .ev_wr_miss(ev_wr_miss),
    .ev_stall(ev_stall), .ev_wb_full_stall(ev_wb_full_stall), .ev_raw_stall(ev_raw_stall),
    .ev_raw_forward(ev_raw_forward), .ev_wb_push(ev_wb_push),
    .ev_l2_read(ev_l2_read), .ev_l2_write(ev_l2_write)
);

tb_l2_model #(.LAT(8)) L2 (
    .clk(clk), .reset(reset),
    .l2_req(l2_req), .l2_we(l2_we), .l2_addr(l2_addr), .l2_wline(l2_wline), .l2_be(l2_be),
    .l2_gnt(l2_gnt), .l2_rvalid(l2_rvalid), .l2_rline(l2_rline),
    .n_reads(l2_reads), .n_writes(l2_writes), .proto_errors(l2_proto)
);

// Contadores de eventos de la parte 1
int c_rd_hit, c_rd_miss, c_wr_hit, c_wr_miss, c_raw_fwd, c_wb_full;
always @(posedge clk) begin
    if (reset) begin
        c_rd_hit = 0; c_rd_miss = 0; c_wr_hit = 0; c_wr_miss = 0; c_raw_fwd = 0; c_wb_full = 0;
    end
    else begin
        c_rd_hit  += ev_rd_hit;
        c_rd_miss += ev_rd_miss;
        c_wr_hit  += ev_wr_hit;
        c_wr_miss += ev_wr_miss;
        c_raw_fwd += ev_raw_forward;
        c_wb_full += ev_wb_full_stall;
    end
end


// Dirección a partir de sus campos: {etiqueta, conjunto, palabra, byte}
function automatic logic [31:0] mk(input int tag, input int set, input int word);
    return {16'h0, 5'(tag), 6'(set), 3'(word), 2'b00};
endfunction

// Valor inicial de la palabra de la dirección a
function automatic logic [31:0] init_of(input logic [31:0] a);
    return `INIT_WORD(a[15:2]);
endfunction

// Un acceso; devuelve el dato (load) y cuántos ciclos de stall tuvo
task automatic do_access(input logic is_load, input logic [31:0] a, input logic [3:0] bes,
                         input logic [31:0] d, output logic [31:0] q, output int stalls);
    re = is_load; we = !is_load; addr = a; be = bes; wdata = d;
    stalls = 0;
    @(negedge clk);
    while (stall && stalls <= 500) begin     // contar ciclos de stall
        stalls++;
        @(negedge clk);
    end
    q = rdata;
    @(posedge clk); #1;
    re = 0; we = 0;
endtask

// Espera, sin accesos, a que el write buffer quede vacío, el bus libre y la
// L2 desocupada. Se usa para que cada prueba dirigida empiece así y las
// latencias medidas sean exactas.
task automatic wait_drained();
    while (!(DUT.wb_empty && !DUT.port_busy && L2.busy == 0 && !L2.rd_on)) begin
        @(posedge clk); #1;
    end
endtask

logic [31:0] q;
int          st, k, w_before, r_before;


// ============================================================================
// Parte 2: 6 configuraciones aleatorias en paralelo
// ============================================================================

localparam int NH = 6;
logic start_rand;
logic done   [NH];
int   errs   [NH];
int   nacc   [NH];
int   nev    [NH];
int   nfwd   [NH];
int   nraws  [NH];
int   nfull  [NH];
int   nrmiss [NH];
int   nrhit  [NH];

`define HARNESS(K, AP, RP, RAW, D, RL) \
    tb_l1d_harness #(.ALLOC_POLICY(AP), .REPL_POLICY(RP), \
                     .RAW_POLICY(RAW), .WB_DEPTH(D), .RAND_LAT(RL), .SEED(K*7919+11)) H``K ( \
        .clk(clk), .reset(reset), .start(start_rand), .done(done[K]), .errors(errs[K]), \
        .n_accesses(nacc[K]), .n_events(nev[K]), .n_raw_fwd(nfwd[K]), \
        .n_raw_stall(nraws[K]), .n_wb_full(nfull[K]), .n_rd_miss(nrmiss[K]), .n_rd_hit(nrhit[K]));

`HARNESS(0, AP_NO_WRITE_ALLOC, RP_LRU,    RAW_FORWARD, 4, 0)
`HARNESS(1, AP_WRITE_ALLOC,    RP_FIFO,   RAW_STALL,   2, 1)
`HARNESS(2, AP_NO_WRITE_ALLOC, RP_RANDOM, RAW_FORWARD, 2, 1)
`HARNESS(3, AP_WRITE_ALLOC,    RP_LRU,    RAW_STALL,   8, 0)
`HARNESS(4, AP_WRITE_ALLOC,    RP_RANDOM, RAW_FORWARD, 3, 1)
`HARNESS(5, AP_NO_WRITE_ALLOC, RP_FIFO,   RAW_STALL,   4, 1)

// Nombre de cada configuración para los mensajes
function automatic string cfg_name(input int k);
    case (k)
        0: return "NWA+LRU+FWD D4";
        1: return "WA+FIFO+STALL D2 lat-var";
        2: return "NWA+RANDOM+FWD D2 lat-var";
        3: return "WA+LRU+STALL D8";
        4: return "WA+RANDOM+FWD D3 lat-var";
        5: return "NWA+FIFO+STALL D4 lat-var";
        default: return "?";
    endcase
endfunction

function automatic bit is_fwd(input int k);
    return (k == 0 || k == 2 || k == 4);
endfunction


// ============================================================================
// Secuencia de pruebas
// ============================================================================

int all_done;

initial begin

    $dumpfile("tb_l1d_cache.vcd");
    $dumpvars(0, tb_l1d_cache.DUT);
    $dumpvars(0, tb_l1d_cache.L2);

    re = 0; we = 0; be = 0; addr = 0; wdata = 0; flush_req = 0;
    start_rand = 0;
    reset = 1;
    @(posedge clk); @(posedge clk); #1;
    reset = 0;


    // ------------------------------------------------------------------
    tb_section("1. Miss en frío: L1 miss + L2 hit = 8 ciclos de stall");
    // ------------------------------------------------------------------
    do_access(1, mk(1, 5, 3), 0, 0, q, st);
    check("stall del miss", st, 8);
    check("dato del miss", q, init_of(mk(1, 5, 3)));
    check("evento rd_miss", c_rd_miss, 1);


    // ------------------------------------------------------------------
    tb_section("2. Hit: 0 ciclos de stall (mismo ciclo que memory.sv)");
    // ------------------------------------------------------------------
    do_access(1, mk(1, 5, 6), 0, 0, q, st);
    check("stall del hit", st, 0);
    check("dato del hit", q, init_of(mk(1, 5, 6)));
    check("evento rd_hit", c_rd_hit, 1);


    // ------------------------------------------------------------------
    tb_section("3. guardap y guardab que aciertan");
    // ------------------------------------------------------------------
    w_before = l2_writes;
    do_access(0, mk(1, 5, 6), 4'b1111, 32'hDEAD_BEEF, q, st);
    check("stall de guardap (hit)", st, 0);
    check("evento wr_hit", c_wr_hit, 1);
    do_access(1, mk(1, 5, 6), 0, 0, q, st);
    check("leer guardap: la L1-D ya tiene el dato", q, 32'hDEAD_BEEF);
    check("leer guardap: hit", st, 0);
    // guardab en el byte 1: la LSU manda be = 0010 y el byte ya corrido
    do_access(0, mk(1, 5, 6) + 1, 4'b0010, 32'h0000_7700, q, st);
    check("stall de guardab (hit)", st, 0);
    do_access(1, mk(1, 5, 6), 0, 0, q, st);
    check("leer tras guardab (solo cambia el byte 1)", q, 32'hDEAD_77EF);


    // ------------------------------------------------------------------
    tb_section("4. Write-through: los stores llegan a la L2 sin vaciado");
    // ------------------------------------------------------------------
    // Sin ningún flush, al drenar el write buffer la L2 ya tiene el dato.
    wait_drained();
    check("la L2 recibió los 2 stores del punto 3", l2_writes - w_before, 2);
    check("la L2 tiene el valor nuevo", L2.mem[mk(1, 5, 6) >> 2], 32'hDEAD_77EF);


    // ------------------------------------------------------------------
    tb_section("5. Store que falla con no-write-allocate");
    // ------------------------------------------------------------------
    // Va directo al write buffer: 0 ciclos y no se pide la línea a la L2.
    r_before = l2_reads;
    do_access(0, mk(7, 20, 2), 4'b1111, 32'h1234_5678, q, st);
    check("store miss: 0 ciclos de stall", st, 0);
    check("evento wr_miss", c_wr_miss, 1);
    check("no se pidió la línea a la L2", l2_reads, r_before);


    // ------------------------------------------------------------------
    tb_section("6. Riesgo RAW: forwarding desde el write buffer");
    // ------------------------------------------------------------------
    // En el ciclo siguiente se lee esa misma palabra. La línea no está en
    // la L1-D (no-write-allocate) y el store todavía está en el write buffer
    // (la lectura tiene prioridad sobre el drenado), así que la L2 tiene el
    // valor viejo: el dato correcto sale por forwarding.
    w_before = l2_writes;
    do_access(1, mk(7, 20, 2), 0, 0, q, st);
    check("la L2 aún no recibió el store", l2_writes, w_before);
    check("forwarding: dato nuevo", q, 32'h1234_5678);
    check("forwarding: 8 ciclos (sin esperar al drenado)", st, 8);
    check("evento raw_forward", c_raw_fwd, 1);
    do_access(1, mk(7, 20, 3), 0, 0, q, st);
    check("la línea quedó en la L1-D: hit", st, 0);
    check("palabra no escrita sale de la L2", q, init_of(mk(7, 20, 3)));


    // ------------------------------------------------------------------
    tb_section("7. LRU con 2 vías: la línea que sale se descarta");
    // ------------------------------------------------------------------
    // Conjunto 5: vía 0 = etiqueta 1 (escrita en el punto 3).
    wait_drained();
    do_access(1, mk(2, 5, 0), 0, 0, q, st);           // etiqueta 2 -> vía 1
    check("etiqueta 2: miss", st, 8);
    do_access(1, mk(1, 5, 0), 0, 0, q, st);           // usar la 1 -> la 2 es la LRU
    check("etiqueta 1: hit", st, 0);
    w_before = l2_writes;
    do_access(1, mk(3, 5, 0), 0, 0, q, st);           // C saca a la 2
    check("etiqueta 3: miss de 8 ciclos", st, 8);
    check("la línea que sale no se escribe en la L2 (está limpia)", l2_writes, w_before);
    do_access(1, mk(1, 5, 6), 0, 0, q, st);
    check("etiqueta 1 sigue en la caché", st, 0);
    check("etiqueta 1 conserva el dato", q, 32'hDEAD_77EF);
    do_access(1, mk(2, 5, 0), 0, 0, q, st);
    check("etiqueta 2 se había ido: miss", st, 8);
    check("dato de la etiqueta 2", q, init_of(mk(2, 5, 0)));


    // ------------------------------------------------------------------
    tb_section("8. Write buffer lleno (4 entradas): el 6.º store espera");
    // ------------------------------------------------------------------
    // Seis guardap seguidos que aciertan, uno por ciclo (ciclos c0 a c5).
    // Con el bus versión 2 una escritura termina al ser aceptada:
    //   - el store de c0 entra al buffer y en c1 la L2 lo acepta (sale);
    //   - la L2 queda ocupada 8 ciclos y vuelve a aceptar en c10;
    //   - los stores de c1 a c4 llenan las 4 entradas;
    //   - el de c5 encuentra el buffer lleno; en c10 sale otra entrada y el
    //     store entra en c11: espera de c5 a c10, 6 ciclos.
    wait_drained();
    for (k = 0; k < 5; k++) begin
        do_access(0, mk(1, 5, k), 4'b1111, 32'hA000_0000 + k, q, st);
        check($sformatf("store %0d: sin espera", k + 1), st, 0);
    end
    do_access(0, mk(1, 5, 5), 4'b1111, 32'hA000_0005, q, st);
    check("store 6: espera a que se libere un lugar", st, 6);
    check("eventos de buffer lleno", c_wb_full, 6);
    do_access(1, mk(1, 5, 5), 0, 0, q, st);
    check("el 6.º store quedó escrito", q, 32'hA000_0005);


    // ------------------------------------------------------------------
    tb_section("9. Vaciado: solo drena el write buffer");
    // ------------------------------------------------------------------
    flush_req = 1;
    k = 0;
    while (!flush_done && k < 2000) begin @(posedge clk); #1; k++; end
    check_true("flush_done", flush_done);
    check_true("write buffer vacío", DUT.wb_empty);
    for (k = 0; k < 6; k++)
        check($sformatf("L2 tras el vaciado (store %0d)", k + 1),
              L2.mem[mk(1, 5, k) >> 2], 32'hA000_0000 + k);
    // Durante el vaciado el núcleo espera
    re = 1; addr = mk(1, 5, 0); #1;
    check("stall durante el vaciado", stall, 1'b1);
    re = 0;
    flush_req = 0;
    @(posedge clk); #1;
    do_access(1, mk(1, 5, 2), 0, 0, q, st);
    check("la línea sigue en la caché tras vaciar", st, 0);
    check("y conserva el dato", q, 32'hA000_0002);
    check("sin errores de protocolo con la L2", l2_proto, 0);


    // ------------------------------------------------------------------
    tb_section("10. Aleatorias: 6 configuraciones contra la referencia");
    // ------------------------------------------------------------------
    start_rand = 1;
    all_done = 0;
    while (!all_done) begin
        @(posedge clk);
        all_done = 1;
        for (k = 0; k < NH; k++) if (!done[k]) all_done = 0;
    end

    for (k = 0; k < NH; k++) begin
        $display("    %-26s accesos=%0d rd_hit=%0d rd_miss=%0d fwd=%0d raw_stall=%0d wb_lleno=%0d",
                 cfg_name(k), nacc[k], nrhit[k], nrmiss[k], nfwd[k], nraws[k], nfull[k]);
        check({cfg_name(k), ": errores"}, errs[k], 0);
        check({cfg_name(k), ": un evento hit/miss por acceso"}, nev[k], nacc[k]);
        check_true({cfg_name(k), ": hubo hits y misses"}, nrhit[k] > 0 && nrmiss[k] > 0);
        check_true({cfg_name(k), ": hubo esperas por buffer lleno"}, nfull[k] > 0);
        if (is_fwd(k))
            check_true({cfg_name(k), ": hubo forwarding RAW"}, nfwd[k] > 0);
        else
            check_true({cfg_name(k), ": hubo esperas RAW"}, nraws[k] > 0);
    end


    tb_finish("tb_l1d_cache");
end

endmodule
