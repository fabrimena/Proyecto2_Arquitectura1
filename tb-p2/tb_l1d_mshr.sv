/*
================================================================================
 Testbench: tb_l1d_mshr

 Descripción:
 ------------------------------------------------------------------------------
 Pruebas de los MSHR non-blocking para stores de rtl-p2/l1d_cache.sv
 (decisión D8 de docs/decisiones-importantes.md; notas de clase 6.3.4,
 cachés non-blocking y MSHR). Los MSHR se usan con write-back +
 write-allocate y N_MSHR >= 2; N_MSHR = 1 es la caché bloqueante.

 La L2 real es de Alejandro. Este archivo trae tb_l2m_model, una L2 con el
 bus versión 2 igual a la de tb_l1d_writeback.sv (cada testbench se compila
 por separado, por eso va una copia): bloqueante, guarda todo lo que hay
 debajo de la L1-D (mem) y lo que tiene la RAM (ram), mueve las líneas con
 la política exclusiva (l2_rdirty) y revisa el protocolo y las víctimas
 limpias. La diferencia: la latencia variable se enciende con la entrada
 rand_on, para poder medir primero con latencia fija.

 Parte 1. Pruebas dirigidas (write-back + exclusiva + write-allocate + LRU,
          write buffer de 4, N_MSHR = 2, L2 de 8 ciclos):
   1. Store que falla con un MSHR libre: 0 ciclos de stall.
   2. Otro store a la misma línea pendiente: se mezcla en el mismo MSHR.
   3. Load a la línea pendiente con sus 4 bytes escritos: sale del MSHR.
   4. Load a la línea pendiente sin sus 4 bytes: espera a que llegue la
      línea, y la línea llega con los bytes de los stores encima (sucia).
   5. Hit under miss: con un MSHR ocupado, un load y un store que aciertan
      siguen sin stall.
   6. MSHR llenos: el tercer store que falla espera a que se libere uno.
   7. Load que falla con MSHR ocupados: espera a que se vacíen y luego
      hace su propio miss.
   8. Dos MSHR del mismo conjunto: como la víctima se elige al llenar, las
      dos líneas quedan en vías distintas. Un tercer store saca a la LRU
      (sucia) y va a la L2.
   9. Vaciado con un MSHR ocupado: espera a que llegue la línea y después
      la mueve a la L2 (exclusiva).
   Durante toda la parte 1 y la 2 se revisa la exclusividad: cada vez que la
   L2 acepta una línea completa, esa línea no puede estar válida en la L1-D.

 Parte 2. 6 configuraciones a la vez (tb_l1d_mshr_harness), cada una:
   a) Ráfaga: 6 stores seguidos que fallan en líneas distintas, con la
      latencia fija. Con N_MSHR = 1 el primero espera los 8 ciclos del
      miss; con N_MSHR = N los N primeros pasan sin stall y el siguiente
      espera.
   b) Aleatorias contra una memoria de referencia, con latencia variable:
      cada load, la memoria después de cada vaciado, que el vaciado no deje
      líneas sucias, un evento hit/miss por acceso, y que se hayan
      ejercitado reservas, mezclas, loads desde un MSHR, hits durante un
      miss y MSHR llenos.
   c) Comparación: las configuraciones 0, 1 y 2 hacen EXACTAMENTE la misma
      secuencia de accesos con N_MSHR = 1, 2 y 4. Con más MSHR tiene que
      tardar menos ciclos.

 Uso: make tb_l1d_mshr
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

module tb_l2m_model #(
    parameter bit EXCL = 0,         // 1 = la lectura mueve la línea (exclusiva)
    parameter int LAT  = 8,         // ciclos desde la aceptación hasta l2_rvalid
    parameter int SEED = 1
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         rand_on,       // 1 = aceptación y latencia variables
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
        errors <= 0; n_wr_dirty <= 0; n_wr_clean <= 0; prev_wait <= 0;
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
                busy <= LAT + (rand_on ? $unsigned($random(seed)) % 3 : 0);
            end
            else begin
                rd_on   <= 1'b1;
                rd_addr <= l2_addr;
                rd_cnt  <= LAT - 2 + (rand_on ? (($unsigned($random(seed)) % 8 == 0) ? 53
                                                 : $unsigned($random(seed)) % 3) : 0);
            end
        end

        // ---- Respuesta de la lectura ------------------------------------
        if (rd_on) begin
            if (rd_cnt == 0) begin
                for (int w = 0; w < 8; w++) l2_rline[32*w +: 32] <= mem[rd_addr[15:2] + w];
                l2_rdirty <= EXCL && l2dirty[rd_addr[15:5]];
                if (EXCL) l2dirty[rd_addr[15:5]] = 1'b0;     // se movió a la L1-D
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
                  (!rand_on || $unsigned($random(seed)) % 4 != 0);
    end
end

endmodule


// ############################################################################
//  Arnés: una L1-D con MSHR + su L2 + memoria de referencia
// ############################################################################

module tb_l1d_mshr_harness #(
    parameter logic [1:0] INCL   = INCL_EXCLUSIVE,
    parameter logic [1:0] RP     = RP_LRU,
    parameter logic       RAW    = RAW_FORWARD,
    parameter int         DEPTH  = 4,
    parameter int         NM     = 2,       // N_MSHR
    parameter int         SEED   = 1,
    parameter int         N_OPS  = 3000
) (
    input  logic clk,
    input  logic reset,
    input  logic start,
    output logic done,
    output int   errors,
    output logic [47:0] burst,  // stall de cada store de la ráfaga (8 bits c/u; el b en [8b+7:8b])
    output int   cycles,        // ciclos de las pruebas aleatorias (sin vaciados)
    output int   n_alloc,
    output int   n_merge,
    output int   n_ld,
    output int   n_hum,
    output int   n_full
);

logic        re, we, fr, fd, stall;
logic [3:0]  be;
logic [31:0] addr, wdata, rdata;
logic        rq, lwe, wd, gnt, rv, rdd;
logic [31:0] la, lbe;
logic [255:0] wl, rl;
int          l2_err, l2_wd, l2_wc;
logic        rand_on;

// Los eventos se leen desde adentro (DUT.ev_*), no hace falta conectarlos
l1d_cache #(.WRITE_POLICY(WP_WRITE_BACK), .INCL_POLICY(INCL), .ALLOC_POLICY(AP_WRITE_ALLOC),
            .REPL_POLICY(RP), .RAW_POLICY(RAW), .WB_DEPTH(DEPTH), .N_MSHR(NM),
            .L2_BUS_V2(1)) DUT (
    .clk(clk), .reset(reset),
    .re(re), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata), .stall(stall),
    .flush_req(fr), .flush_done(fd),
    .l2_req(rq), .l2_we(lwe), .l2_addr(la), .l2_wline(wl), .l2_be(lbe), .l2_wdirty(wd),
    .l2_gnt(gnt), .l2_rvalid(rv), .l2_rdirty(rdd), .l2_rline(rl)
);

tb_l2m_model #(.EXCL(INCL == INCL_EXCLUSIVE), .SEED(SEED + 99)) L2 (
    .clk(clk), .reset(reset), .rand_on(rand_on),
    .l2_req(rq), .l2_we(lwe), .l2_wdirty(wd), .l2_addr(la),
    .l2_be(lbe), .l2_wline(wl), .l2_gnt(gnt), .l2_rvalid(rv), .l2_rdirty(rdd), .l2_rline(rl),
    .errors(l2_err), .n_wr_dirty(l2_wd), .n_wr_clean(l2_wc)
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
        n_events = 0; n_alloc = 0; n_merge = 0; n_ld = 0; n_hum = 0; n_full = 0;
    end
    else begin
        n_events += DUT.ev_rd_hit + DUT.ev_rd_miss + DUT.ev_wr_hit + DUT.ev_wr_miss;
        n_alloc  += DUT.ev_mshr_alloc;
        n_merge  += DUT.ev_mshr_merge;
        n_ld     += DUT.ev_mshr_load;
        n_hum    += DUT.ev_hit_under_miss;
        n_full   += DUT.ev_mshr_full_stall;
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

// Dirección aleatoria con muchos conflictos (y muchas veces la misma línea,
// para que haya mezclas en los MSHR y loads a líneas pendientes)
function automatic logic [31:0] rand_addr();
    logic [4:0] t;
    logic [5:0] x;
    int r;
    r = rnd(10);
    x = (r < 4) ? 6'd0 : (r < 7) ? 6'd1 : (r < 8) ? 6'd63 : 6'(rnd(64));
    t = (rnd(8) == 0) ? 5'(rnd(32)) : 5'(rnd(4));
    return {16'h0, t, x, 3'(rnd(8)), 2'(rnd(4))};
endfunction

// Un acceso completo: lo presenta, espera stall = 0 y lo verifica.
// En last_stall deja los ciclos que esperó.
int last_stall;

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
    last_stall = w;
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
    if (DUT.m_count != 0) begin
        $display("  [%m] %s: quedaron MSHR ocupados", when);
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

realtime t0;

initial begin
    re = 0; we = 0; be = 0; addr = 0; wdata = 0; fr = 0; rand_on = 0;
    done = 0; errors = 0; n_acc = 0;
    wait (start === 1'b1);
    @(posedge clk); #1;

    // a) Ráfaga de 6 stores que fallan, en conjuntos distintos (sin víctimas)
    for (int b = 0; b < 6; b++) begin
        access(0, {16'h0, 5'd9, 6'(10 + b), 3'd0, 2'd0}, 4'b1111, 32'hB000_0000 + b);
        burst[8*b +: 8] = last_stall[7:0];
    end
    flush_and_compare("tras la ráfaga");

    // b) y c) Aleatorias con latencia variable
    rand_on = 1;
    t0 = $realtime;
    random_ops(N_OPS);
    cycles = int'(($realtime - t0) / 10.0);
    flush_and_compare("tras las pruebas aleatorias");
    random_ops(N_OPS / 4);                  // la caché sigue sirviendo tras vaciar
    flush_and_compare("tras el segundo bloque");

    errors += l2_err;
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

module tb_l1d_mshr;

`include "tb_utils.svh"

logic clk = 1'b0;
logic reset;
always #5 clk = ~clk;


// ============================================================================
// Parte 1: DUT de las pruebas dirigidas (write-back + exclusiva, 2 MSHR)
// ============================================================================

logic        re, we, fr, fd, stall;
logic [3:0]  be;
logic [31:0] addr, wdata, rdata;
logic        rq, lwe, wd, gnt, rv, rdd;
logic [31:0] la, lbe;
logic [255:0] wl, rl;
int          l2_err, l2_wd, l2_wc;

l1d_cache #(.WRITE_POLICY(WP_WRITE_BACK), .INCL_POLICY(INCL_EXCLUSIVE),
            .ALLOC_POLICY(AP_WRITE_ALLOC), .REPL_POLICY(RP_LRU), .WB_DEPTH(4),
            .N_MSHR(2), .L2_BUS_V2(1)) DUT (
    .clk(clk), .reset(reset),
    .re(re), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata), .stall(stall),
    .flush_req(fr), .flush_done(fd),
    .l2_req(rq), .l2_we(lwe), .l2_addr(la), .l2_wline(wl), .l2_be(lbe), .l2_wdirty(wd),
    .l2_gnt(gnt), .l2_rvalid(rv), .l2_rdirty(rdd), .l2_rline(rl)
);

tb_l2m_model #(.EXCL(1), .LAT(8)) L2 (
    .clk(clk), .reset(reset), .rand_on(1'b0),
    .l2_req(rq), .l2_we(lwe), .l2_wdirty(wd), .l2_addr(la),
    .l2_be(lbe), .l2_wline(wl), .l2_gnt(gnt), .l2_rvalid(rv), .l2_rdirty(rdd), .l2_rline(rl),
    .errors(l2_err), .n_wr_dirty(l2_wd), .n_wr_clean(l2_wc)
);

// Contadores de eventos y revisión de exclusividad de la parte 1
int c_alloc, c_merge, c_ld, c_hum, c_full, c_wrmiss, c_vdirty, x_err;
logic [5:0] xs;
logic [4:0] xt;

always @(posedge clk) begin
    if (reset) begin
        c_alloc = 0; c_merge = 0; c_ld = 0; c_hum = 0; c_full = 0;
        c_wrmiss = 0; c_vdirty = 0; x_err = 0;
    end
    else begin
        c_alloc  += DUT.ev_mshr_alloc;
        c_merge  += DUT.ev_mshr_merge;
        c_ld     += DUT.ev_mshr_load;
        c_hum    += DUT.ev_hit_under_miss;
        c_full   += DUT.ev_mshr_full_stall;
        c_wrmiss += DUT.ev_wr_miss;
        c_vdirty += DUT.ev_victim_dirty;
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

// ¿La línea de la dirección a está en la L1-D? ¿está sucia? ¿en qué vía?
function automatic bit in_way(input logic [31:0] a, input int w);
    if (w == 0)
        return DUT.ARRAYS.g_way[0].valid_bits[a[10:5]] && DUT.ARRAYS.g_way[0].tag_mem[a[10:5]] == a[15:11];
    else
        return DUT.ARRAYS.g_way[1].valid_bits[a[10:5]] && DUT.ARRAYS.g_way[1].tag_mem[a[10:5]] == a[15:11];
endfunction

function automatic bit in_l1(input logic [31:0] a);
    return in_way(a, 0) || in_way(a, 1);
endfunction

function automatic bit dirty_l1(input logic [31:0] a);
    return (in_way(a, 0) && DUT.ARRAYS.g_way[0].dirty_bits[a[10:5]]) ||
           (in_way(a, 1) && DUT.ARRAYS.g_way[1].dirty_bits[a[10:5]]);
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

// Espera sin accesos a que no queden MSHR, el write buffer esté vacío y el
// bus libre (así cada prueba empieza desde cero)
task automatic wait_idle();
    while (!(DUT.m_count == 0 && DUT.wb_empty && !DUT.port_busy && L2.busy == 0 && !L2.rd_on))
        begin @(posedge clk); #1; end
endtask

logic [31:0] q;
int          st, k, n_before;


// ============================================================================
// Parte 2: 6 configuraciones en paralelo
// ============================================================================
//   0, 1, 2: misma configuración y misma semilla, N_MSHR = 1, 2 y 4
//            (la misma secuencia de accesos: sirve para comparar)
//   3, 4, 5: otras combinaciones de inclusión, reemplazo, RAW y write buffer

localparam int NH = 6;
logic start_rand;
logic hd    [NH];
int   herr  [NH];
logic [47:0] hbur [NH];
int   hcyc  [NH];
int   hal   [NH];
int   hmg   [NH];
int   hld   [NH];
int   hhum  [NH];
int   hfull [NH];

`define MSH(K, X1, X2, X3, X4, X5, X6) \
    tb_l1d_mshr_harness #(.INCL(X1), .RP(X2), .RAW(X3), .DEPTH(X4), .NM(X5), .SEED(X6)) H``K ( \
        .clk(clk), .reset(reset), .start(start_rand), .done(hd[K]), .errors(herr[K]), \
        .burst(hbur[K]), .cycles(hcyc[K]), .n_alloc(hal[K]), .n_merge(hmg[K]), \
        .n_ld(hld[K]), .n_hum(hhum[K]), .n_full(hfull[K]));

`MSH(0, INCL_EXCLUSIVE, RP_LRU,    RAW_STALL,   4, 1, 11)
`MSH(1, INCL_EXCLUSIVE, RP_LRU,    RAW_STALL,   4, 2, 11)
`MSH(2, INCL_EXCLUSIVE, RP_LRU,    RAW_STALL,   4, 4, 11)
`MSH(3, INCL_NINE,      RP_LRU,    RAW_FORWARD, 4, 2, 23)
`MSH(4, INCL_NINE,      RP_FIFO,   RAW_STALL,   2, 3, 37)
`MSH(5, INCL_EXCLUSIVE, RP_RANDOM, RAW_STALL,   2, 2, 41)

function automatic string cfg_name(input int k);
    case (k)
        0: return "EXCL+LRU D4 N_MSHR=1";
        1: return "EXCL+LRU D4 N_MSHR=2";
        2: return "EXCL+LRU D4 N_MSHR=4";
        3: return "NINE+LRU+FWD D4 N_MSHR=2";
        4: return "NINE+FIFO+STALL D2 N_MSHR=3";
        5: return "EXCL+RANDOM D2 N_MSHR=2";
        default: return "?";
    endcase
endfunction

function automatic int n_of(input int k);
    case (k)
        0: return 1;
        2: return 4;
        4: return 3;
        default: return 2;
    endcase
endfunction


// ============================================================================
// Secuencia de pruebas
// ============================================================================

int all_done;
int nm;

initial begin

    $dumpfile("tb_l1d_mshr.vcd");
    $dumpvars(0, tb_l1d_mshr.DUT);
    $dumpvars(0, tb_l1d_mshr.L2);

    re = 0; we = 0; be = 0; addr = 0; wdata = 0; fr = 0;
    start_rand = 0;
    reset = 1;
    @(posedge clk); @(posedge clk); #1;
    reset = 0;


    // ------------------------------------------------------------------
    tb_section("1. Store que falla con un MSHR libre: 0 ciclos");
    // ------------------------------------------------------------------
    // Línea A = (etiqueta 1, conjunto 10). Su lectura a la L2 empieza en el
    // ciclo siguiente y llega unos 8 ciclos después: las pruebas 2 a 4 se
    // hacen mientras tanto.
    do_access(0, mk(1, 10, 2), 4'b1111, 32'hA1A1_0002, q, st);
    check("stall del store que falla", st, 0);
    check("un MSHR ocupado", DUT.m_count, 1);
    check("evento de reserva de MSHR", c_alloc, 1);
    check("cuenta como store que falló", c_wrmiss, 1);
    check_true("la línea todavía no está en la L1-D", !in_l1(mk(1, 10, 0)));


    // ------------------------------------------------------------------
    tb_section("2. Otro store a la misma línea pendiente: se mezcla");
    // ------------------------------------------------------------------
    do_access(0, mk(1, 10, 5), 4'b0011, 32'h0000_5555, q, st);   // 2 bytes de la palabra 5
    check("stall del segundo store", st, 0);
    check("sigue un solo MSHR", DUT.m_count, 1);
    check("evento de mezcla", c_merge, 1);


    // ------------------------------------------------------------------
    tb_section("3. Load a la línea pendiente con sus 4 bytes: sale del MSHR");
    // ------------------------------------------------------------------
    do_access(1, mk(1, 10, 2), 0, 0, q, st);
    check("stall del load", st, 0);
    check("dato desde el MSHR", q, 32'hA1A1_0002);
    check("evento de load desde MSHR", c_ld, 1);


    // ------------------------------------------------------------------
    tb_section("4. Load a la línea pendiente sin sus 4 bytes: espera la línea");
    // ------------------------------------------------------------------
    // La palabra 5 solo tiene 2 bytes en el MSHR: hay que esperar la línea.
    // Al llegar, se le ponen encima los bytes de los stores.
    // Tiempos: el store de A fue en el ciclo 0, su lectura empezó en el 1 y
    // la línea llega en el 9 (8 ciclos, como un miss). Este load llega en el
    // ciclo 3, espera del 3 al 9 y en el 10 ya acierta: 7 ciclos.
    do_access(1, mk(1, 10, 5), 0, 0, q, st);
    check("esperó la línea: 7 ciclos", st, 7);
    check("dato: 2 bytes del store + 2 de la L2", q,
          {init_of(mk(1, 10, 5)) >> 16, 16'h5555});
    check("no salió del MSHR", c_ld, 1);
    check("el MSHR se liberó", DUT.m_count, 0);
    check_true("la línea está en la L1-D y sucia", dirty_l1(mk(1, 10, 0)));
    do_access(1, mk(1, 10, 2), 0, 0, q, st);
    check("la palabra 2 del primer store está en la línea (hit)", q, 32'hA1A1_0002);
    check("y es un hit", st, 0);
    do_access(1, mk(1, 10, 7), 0, 0, q, st);
    check("una palabra que no tocó nadie viene de la L2", q, init_of(mk(1, 10, 7)));


    // ------------------------------------------------------------------
    tb_section("5. Hit under miss: con un MSHR ocupado, los hits siguen");
    // ------------------------------------------------------------------
    wait_idle();
    do_access(1, mk(2, 20, 0), 0, 0, q, st);                     // H entra (miss)
    check("miss bloqueante de H: 8 ciclos", st, 8);
    n_before = c_hum;
    do_access(0, mk(3, 30, 1), 4'b1111, 32'hC3C3_0001, q, st);   // X falla -> MSHR
    check("store X que falla: 0 ciclos", st, 0);
    do_access(1, mk(2, 20, 0), 0, 0, q, st);
    check("load H (hit) durante el miss: 0 ciclos", st, 0);
    check("dato de H", q, init_of(mk(2, 20, 0)));
    do_access(0, mk(2, 20, 1), 4'b1111, 32'hD2D2_0001, q, st);
    check("store H (hit) durante el miss: 0 ciclos", st, 0);
    check("dos hits durante el miss", c_hum - n_before, 2);
    wait_idle();
    do_access(1, mk(3, 30, 1), 0, 0, q, st);
    check("X llegó con su store", q, 32'hC3C3_0001);
    check("X es un hit", st, 0);
    do_access(1, mk(2, 20, 1), 0, 0, q, st);
    check("H tiene su store", q, 32'hD2D2_0001);


    // ------------------------------------------------------------------
    tb_section("6. MSHR llenos: el tercer store que falla espera");
    // ------------------------------------------------------------------
    // Con 2 MSHR, el tercer store espera a que se llene el primero. Tiempos:
    // stores en los ciclos 0, 1 y 2; la lectura del primero empieza en el 1
    // y llega en el 9. En el ciclo 9 (el del llenado) los stores también
    // esperan, porque el puerto de escritura está ocupado; en el 10 ya hay
    // un MSHR libre. Espera del 2 al 9: 8 ciclos, 7 de ellos con los MSHR
    // llenos.
    wait_idle();
    n_before = c_full;
    do_access(0, mk(4, 40, 0), 4'b1111, 32'h4444_0000, q, st);
    check("primer store: 0 ciclos", st, 0);
    do_access(0, mk(5, 41, 0), 4'b1111, 32'h5555_0000, q, st);
    check("segundo store: 0 ciclos", st, 0);
    check("dos MSHR ocupados", DUT.m_count, 2);
    do_access(0, mk(6, 42, 0), 4'b1111, 32'h6666_0000, q, st);
    check("tercer store: espera 8 ciclos", st, 8);
    check("ciclos con MSHR llenos = stall - 1 (el ciclo del llenado)", c_full - n_before, st - 1);
    wait_idle();
    do_access(1, mk(4, 40, 0), 0, 0, q, st); check("dato 1", q, 32'h4444_0000);
    do_access(1, mk(5, 41, 0), 0, 0, q, st); check("dato 2", q, 32'h5555_0000);
    do_access(1, mk(6, 42, 0), 0, 0, q, st); check("dato 3", q, 32'h6666_0000);


    // ------------------------------------------------------------------
    tb_section("7. Load que falla con MSHR ocupados: espera a que se vacíen");
    // ------------------------------------------------------------------
    // El load no puede adelantarse: primero se llena el MSHR (así los
    // llenados salen en orden) y después hace su propio miss de 8 ciclos.
    // Tiempos: store en el ciclo 0, load en el 1; el MSHR se llena en el 9,
    // el load pide su línea en el 10 y la recibe en el 18: 17 ciclos.
    wait_idle();
    do_access(0, mk(7, 50, 0), 4'b1111, 32'h7777_0000, q, st);
    check("store: 0 ciclos", st, 0);
    do_access(1, mk(8, 51, 3), 0, 0, q, st);
    check("el load espera el MSHR y su miss: 17 ciclos", st, 17);
    check("dato del load", q, init_of(mk(8, 51, 3)));
    check_true("el store ya está en la L1-D, sucio", dirty_l1(mk(7, 50, 0)));


    // ------------------------------------------------------------------
    tb_section("8. Dos MSHR del mismo conjunto: la víctima se elige al llenar");
    // ------------------------------------------------------------------
    // Las dos líneas faltan en el conjunto 60, que está vacío. Si la vía se
    // eligiera al pedir, las dos verían la vía 0 libre y una pisaría a la
    // otra. Eligiéndola al llenar, cada una queda en su vía.
    wait_idle();
    do_access(0, mk(9,  60, 0), 4'b1111, 32'h9999_0000, q, st);
    do_access(0, mk(10, 60, 0), 4'b1111, 32'hAAAA_0000, q, st);
    check("dos MSHR del conjunto 60", DUT.m_count, 2);
    wait_idle();
    check_true("la primera línea quedó en la vía 0", in_way(mk(9,  60, 0), 0));
    check_true("la segunda en la vía 1",            in_way(mk(10, 60, 0), 1));
    check_true("las dos sucias", dirty_l1(mk(9, 60, 0)) && dirty_l1(mk(10, 60, 0)));
    // Un tercer store al conjunto 60 saca a la LRU (la primera), que está
    // sucia y va a la L2
    n_before = c_vdirty;
    do_access(0, mk(11, 60, 0), 4'b1111, 32'hBBBB_0000, q, st);
    check("tercer store: 0 ciclos", st, 0);
    wait_idle();
    check("salió una víctima sucia", c_vdirty - n_before, 1);
    check_true("la primera ya no está en la L1-D", !in_l1(mk(9, 60, 0)));
    check("la L2 tiene el store de la primera", L2.mem[mk(9, 60, 0) >> 2], 32'h9999_0000);
    check_true("la tercera ocupó la vía 0", in_way(mk(11, 60, 0), 0));


    // ------------------------------------------------------------------
    tb_section("9. Vaciado con un MSHR ocupado: espera y mueve la línea");
    // ------------------------------------------------------------------
    wait_idle();
    do_access(0, mk(12, 61, 4), 4'b1111, 32'hCCCC_0004, q, st);
    check("un MSHR ocupado al pedir el vaciado", DUT.m_count, 1);
    fr = 1;
    k  = 0;
    while (!fd && k < 4000) begin @(posedge clk); #1; k++; end
    check_true("flush_done", fd);
    check("no quedan MSHR", DUT.m_count, 0);
    check("la L2 tiene el store", L2.mem[mk(12, 61, 4) >> 2], 32'hCCCC_0004);
    check_true("la línea se movió: ya no está en la L1-D", !in_l1(mk(12, 61, 0)));
    fr = 0;
    @(posedge clk); #1;
    check("exclusividad en toda la parte 1", x_err, 0);
    check("sin errores del modelo de L2 (protocolo y víctimas limpias)", l2_err, 0);


    // ------------------------------------------------------------------
    tb_section("10. Ráfagas, aleatorias y comparación de N_MSHR");
    // ------------------------------------------------------------------
    start_rand = 1;
    all_done   = 0;
    while (!all_done) begin
        @(posedge clk);
        all_done = 1;
        for (k = 0; k < NH; k++) if (!hd[k]) all_done = 0;
    end

    for (k = 0; k < NH; k++) begin
        nm = n_of(k);
        $display("    %-28s ráfaga=%0d,%0d,%0d,%0d,%0d,%0d ciclos=%0d reservas=%0d mezclas=%0d loads_mshr=%0d hits_miss=%0d llenos=%0d",
                 cfg_name(k), hbur[k][7:0], hbur[k][15:8], hbur[k][23:16], hbur[k][31:24], hbur[k][39:32], hbur[k][47:40],
                 hcyc[k], hal[k], hmg[k], hld[k], hhum[k], hfull[k]);
        check({cfg_name(k), ": errores"}, herr[k], 0);
        if (nm == 1) begin
            check({cfg_name(k), ": ráfaga, el primer store espera el miss"}, hbur[k][7:0], 8);
            check({cfg_name(k), ": sin uso de MSHR"}, hal[k] + hmg[k] + hld[k] + hhum[k] + hfull[k], 0);
        end
        else begin
            for (int b = 0; b < nm; b++)
                check($sformatf("%s: ráfaga, store %0d sin stall", cfg_name(k), b), hbur[k][8*b +: 8], 0);
            check_true($sformatf("%s: ráfaga, el store %0d espera un MSHR", cfg_name(k), nm),
                       hbur[k][8*nm +: 8] > 0);
            check_true({cfg_name(k), ": hubo reservas"},        hal[k]  > 0);
            check_true({cfg_name(k), ": hubo mezclas"},         hmg[k]  > 0);
            check_true({cfg_name(k), ": hubo loads desde MSHR"}, hld[k] > 0);
            check_true({cfg_name(k), ": hubo hits durante un miss"}, hhum[k] > 0);
            check_true({cfg_name(k), ": hubo MSHR llenos"},     hfull[k] > 0);
        end
    end
    check_true("misma secuencia: 2 MSHR tarda menos que 1", hcyc[1] < hcyc[0]);
    check_true("misma secuencia: 4 MSHR no tarda más que 2", hcyc[2] <= hcyc[1]);
    $display("    ciclos con N_MSHR = 1 / 2 / 4: %0d / %0d / %0d", hcyc[0], hcyc[1], hcyc[2]);


    tb_finish("tb_l1d_mshr");
end

endmodule
