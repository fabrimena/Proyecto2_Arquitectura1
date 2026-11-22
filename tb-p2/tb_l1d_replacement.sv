/*
================================================================================
 Testbench: tb_l1d_replacement

 Descripción:
 ------------------------------------------------------------------------------
 Pruebas de rtl-p2/l1d_replacement.sv con las tres políticas de reemplazo
 de las notas de clase (sección 6.2.3) a la vez: una instancia por política,
 todas con las mismas entradas.

   1. LRU : un hit en una vía convierte a la otra en la víctima.
   2. FIFO: los hits NO cambian la víctima; solo los llenados.
   3. Los conjuntos son independientes: tocar el conjunto 5 no cambia el 6.
   4. Secuencia A, B, A, C: LRU saca a B (la usada hace más tiempo) y FIFO
      saca a A (la que entró primero), la diferencia clásica entre ambas.
   5. RANDOM: la víctima sale del LFSR, el LFSR solo avanza con llenados y
      genera las dos vías (no se queda pegado en una).

 Uso: make tb_l1d_replacement
================================================================================
*/

`timescale 1ns/1ps
`include "cache_defs.sv"

module tb_l1d_replacement;

`include "tb_utils.svh"


logic                   clk = 1'b0;
logic                   reset;
logic [L1D_INDEX_W-1:0] lookup_set;
logic                   touch, fill;
logic [L1D_INDEX_W-1:0] touch_set, fill_set;
logic                   touch_way, fill_way;

logic victim_lru, victim_fifo, victim_rnd;

always #5 clk = ~clk;


// Tres instancias, una por política, alimentadas con las mismas señales
l1d_replacement #(.REPL_POLICY(RP_LRU)) DUT_LRU (
    .clk(clk), .reset(reset), .lookup_set(lookup_set), .victim_way(victim_lru),
    .touch(touch), .touch_set(touch_set), .touch_way(touch_way),
    .fill(fill), .fill_set(fill_set), .fill_way(fill_way)
);

l1d_replacement #(.REPL_POLICY(RP_FIFO)) DUT_FIFO (
    .clk(clk), .reset(reset), .lookup_set(lookup_set), .victim_way(victim_fifo),
    .touch(touch), .touch_set(touch_set), .touch_way(touch_way),
    .fill(fill), .fill_set(fill_set), .fill_way(fill_way)
);

l1d_replacement #(.REPL_POLICY(RP_RANDOM)) DUT_RND (
    .clk(clk), .reset(reset), .lookup_set(lookup_set), .victim_way(victim_rnd),
    .touch(touch), .touch_set(touch_set), .touch_way(touch_way),
    .fill(fill), .fill_set(fill_set), .fill_way(fill_way)
);


// ----------------------------------------------------------------------------
// Ayudas: un ciclo con un "uso" (hit) o con un "llenado"
// ----------------------------------------------------------------------------

task automatic do_touch(input logic [L1D_INDEX_W-1:0] s, input logic w);
    touch_set = s; touch_way = w; touch = 1'b1;
    @(posedge clk); #1;
    touch = 1'b0;
endtask

task automatic do_fill(input logic [L1D_INDEX_W-1:0] s, input logic w);
    fill_set = s; fill_way = w; fill = 1'b1;
    @(posedge clk); #1;
    fill = 1'b0;
endtask


int  i;
int  seen0, seen1;
logic prev_rnd;

initial begin

    $dumpfile("tb_l1d_replacement.vcd");
    $dumpvars(0, tb_l1d_replacement);

    touch = 0; fill = 0; touch_set = 0; fill_set = 0; touch_way = 0; fill_way = 0;
    lookup_set = 0; #1;
    reset = 1;
    @(posedge clk); @(posedge clk); #1;
    reset = 0;


    // ------------------------------------------------------------------
    tb_section("1. LRU: la víctima es la vía usada hace más tiempo");
    // ------------------------------------------------------------------
    lookup_set = 5; #1;
    do_fill(5, 0);                                   // entra la línea A en vía 0
    check("LRU tras llenar vía 0 -> víctima 1", victim_lru, 1'b1);
    do_fill(5, 1);                                   // entra la línea B en vía 1
    check("LRU tras llenar vía 1 -> víctima 0", victim_lru, 1'b0);
    do_touch(5, 0);                                  // se vuelve a usar A
    check("LRU tras hit en vía 0 -> víctima 1", victim_lru, 1'b1);
    do_touch(5, 1);
    check("LRU tras hit en vía 1 -> víctima 0", victim_lru, 1'b0);


    // ------------------------------------------------------------------
    tb_section("2. FIFO: los hits no cambian la víctima");
    // ------------------------------------------------------------------
    // Misma secuencia que arriba: llenado 0, llenado 1, hit 0, hit 1.
    // Después de los llenados la víctima es la vía 0 (entró primero) y los
    // hits no la mueven.
    lookup_set = 5; #1;
    check("FIFO tras llenar 0 y 1 y dos hits -> víctima 0", victim_fifo, 1'b0);
    do_touch(5, 0);
    check("FIFO hit en vía 0 no cambia la víctima", victim_fifo, 1'b0);
    do_fill(5, 0);                                   // se reemplaza la vía 0
    check("FIFO tras reemplazar vía 0 -> víctima 1", victim_fifo, 1'b1);


    // ------------------------------------------------------------------
    tb_section("3. Conjuntos independientes");
    // ------------------------------------------------------------------
    lookup_set = 6; #1;
    check("LRU conjunto 6 sin tocar -> víctima 0", victim_lru, 1'b0);
    check("FIFO conjunto 6 sin tocar -> víctima 0", victim_fifo, 1'b0);
    do_fill(6, 0);
    check("LRU conjunto 6 tras llenar 0 -> víctima 1", victim_lru, 1'b1);
    lookup_set = 5; #1;
    check("LRU conjunto 5 no cambió", victim_lru, 1'b1);


    // ------------------------------------------------------------------
    tb_section("4. Secuencia A, B, A, C: LRU y FIFO eligen distinto");
    // ------------------------------------------------------------------
    // Ejemplo clásico de la diferencia entre ambas políticas (notas 6.2.3).
    // En el conjunto 20 (todavía sin usar) entran A (vía 0) y B (vía 1), se
    // vuelve a usar A, y luego llega C, que no está:
    //   LRU  saca a B: es la que lleva más tiempo SIN USARSE.
    //   FIFO saca a A: es la que lleva más tiempo DENTRO, aunque se acaba
    //        de usar.
    lookup_set = 20; #1;
    do_fill(20, 0);                                  // entra A en la vía 0
    do_fill(20, 1);                                  // entra B en la vía 1
    do_touch(20, 0);                                 // hit en A
    check("LRU: llega C y saca a B (vía 1)",  victim_lru,  1'b1);
    check("FIFO: llega C y saca a A (vía 0)", victim_fifo, 1'b0);
    // (Las tres instancias reciben las mismas entradas, así que aquí se
    //  verifica la decisión en la que difieren; guardar C en una vía
    //  distinta para cada una ya es trabajo de l1d_cache.)


    // ------------------------------------------------------------------
    tb_section("5. RANDOM: LFSR que solo avanza con llenados");
    // ------------------------------------------------------------------
    prev_rnd = victim_rnd;
    for (i = 0; i < 10; i++) do_touch(3, 1);         // los hits no lo mueven
    check("RANDOM: los hits no avanzan el LFSR", victim_rnd, prev_rnd);

    seen0 = 0; seen1 = 0;
    for (i = 0; i < 64; i++) begin
        if (victim_rnd) seen1++; else seen0++;
        do_fill(i[L1D_INDEX_W-1:0], victim_rnd);
    end
    check_true("RANDOM eligió alguna vez la vía 0", seen0 > 0);
    check_true("RANDOM eligió alguna vez la vía 1", seen1 > 0);
    check_true("RANDOM sin X", victim_rnd !== 1'bx);


    tb_finish("tb_l1d_replacement");
end

endmodule
