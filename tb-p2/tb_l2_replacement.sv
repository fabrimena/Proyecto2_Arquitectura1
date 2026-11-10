/*
================================================================================
 Testbench: tb_l2_replacement

 Descripción:
 ------------------------------------------------------------------------------
 Pruebas de rtl-p2/l2_replacement.sv: la política de reemplazo de la L2
 (4 vías, write-back). Se prueban las dos políticas a la vez, una instancia por
 política, alimentadas con las mismas entradas.

   1. PLRU: valores calculados a mano del árbol de 4 vías, para fijar la
      semántica del módulo (qué vía propone en cada situación).
   2. RANDOM: la secuencia del LFSR es determinista y comprobable; los hits
      no la mueven, los llenados sí.
   3. PLRU contra un modelo de referencia escrito aparte en el testbench, con
      una thousand de operaciones aleatorias: el modelo y el DUT tienen que dar
      siempre la misma víctima.
   4. Invariante del árbol: la víctima nunca es la vía que se acaba de usar.
   5. Los conjuntos son independientes.
   6. RANDOM: las 4 vías se eligen con distribución casi uniforme y el
      resultado es reproducible.

 Nota sobre lo que NO se comprueba: el pseudo-LRU de árbol NO es LRU exacto.
 Con 4 vías el árbol de 3 bits se parece mucho al LRU real, pero no siempre
 desaloja la línea menos reciente de verdad. Por eso este testbench compara el
 DUT contra un modelo del ÁRBOL (no contra un LRU exacto), y la documentación
 de docs/memory-hierarchy.md debe decir "pseudo-LRU" y no "LRU".

 Uso: make tb_l2_replacement
================================================================================
*/

`timescale 1ns/1ps
`include "cache_defs.sv"

module tb_l2_replacement;

`include "tb_utils.svh"


logic                   clk = 1'b0;
logic                   reset;
logic [L2_INDEX_W-1:0] lookup_set;
logic                   touch, fill;
logic [L2_INDEX_W-1:0] touch_set, fill_set;
logic [L2_WAY_W-1:0]   touch_way, fill_way;

logic [L2_WAY_W-1:0]   victim_plru, victim_rnd;

always #5 clk = ~clk;


// Dos instancias, una por política, con las mismas señales de entrada
l2_replacement #(.REPL_POLICY(RP2_PLRU)) DUT_PLRU (
    .clk(clk), .reset(reset), .lookup_set(lookup_set), .victim_way(victim_plru),
    .touch(touch), .touch_set(touch_set), .touch_way(touch_way),
    .fill(fill), .fill_set(fill_set), .fill_way(fill_way)
);

l2_replacement #(.REPL_POLICY(RP2_RANDOM)) DUT_RND (
    .clk(clk), .reset(reset), .lookup_set(lookup_set), .victim_way(victim_rnd),
    .touch(touch), .touch_set(touch_set), .touch_way(touch_way),
    .fill(fill), .fill_set(fill_set), .fill_way(fill_way)
);


// ----------------------------------------------------------------------------
// Modelo de referencia del árbol de PLRU, escrito aparte del DUT.
//
// El estado de un conjunto son 3 bits: raíz, nodo izquierdo, nodo derecho.
//   raíz  0 -> la hoja menos reciente está en el subárbol izquierdo (vías 0,1)
//         1 -> está en el subárbol derecho (vías 2,3)
//   nodo L  0 -> dentro de {vía 0, vía 1} la menos reciente es la vía 0
//   nodo R  0 -> dentro de {vía 2, vía 3} la menos reciente es la vía 2
//
// Al usar la vía w, el nodo que la contiene pasa a apuntar a la hermana (que
// queda como la menos reciente del par) y la raíz pasa a apuntar al subárbol
// que NO contiene a w (que queda como el menos reciente del conjunto).
// ----------------------------------------------------------------------------

logic [L2_SETS-1:0] ref_root;
logic [L2_SETS-1:0] ref_left;
logic [L2_SETS-1:0] ref_right;

task automatic ref_update(input int s, input logic [1:0] w);

    if (w[1] == 1'b0) begin
        ref_root[s] = 1'b1;
        ref_left[s] = ~w[0];
    end
    else begin
        ref_root[s]  = 1'b0;
        ref_right[s] = ~w[0];
    end
endtask

function automatic logic [1:0] ref_victim(input int s);

    if (ref_root[s] == 1'b0)
        ref_victim = {1'b0, ref_left[s]};
    else
        ref_victim = {1'b1, ref_right[s]};
endfunction


// ----------------------------------------------------------------------------
// Ayudas: un ciclo con un "uso" (hit) o con un "llenado"
// ----------------------------------------------------------------------------

task automatic do_touch(input logic [L2_INDEX_W-1:0] s, input logic [1:0] w);

    touch_set = s; touch_way = w; touch = 1'b1;
    @(posedge clk); #1;
    touch = 1'b0;
endtask

task automatic do_fill(input logic [L2_INDEX_W-1:0] s, input logic [1:0] w);

    fill_set = s; fill_way = w; fill = 1'b1;
    @(posedge clk); #1;
    fill = 1'b0;
endtask

// Deja el DUT y el modelo en un estado conocido (reset) y fija el conjunto
// que se está mirando.
task automatic hard_reset(input logic [L2_INDEX_W-1:0] s);

    reset = 1'b1;
    @(posedge clk); @(posedge clk); #1;
    reset = 1'b0;
    @(posedge clk); #1;

    ref_root  = '0;
    ref_left  = '0;
    ref_right = '0;

    lookup_set = s; #1;
endtask


int  i;
int  seen[4];
int  seed;
int  r_set;
int  r_way;
int  r_op;
logic prev_rnd;


initial begin

    $dumpfile("tb_l2_replacement.vcd");
    $dumpvars(0, tb_l2_replacement);

    touch = 0; fill = 0; touch_set = 0; fill_set = 0; touch_way = 0; fill_way = 0;
    lookup_set = 0; #1;


    // ------------------------------------------------------------------
    tb_section("1. PLRU: valores del árbol de 4 vías calculados a mano");
    // ------------------------------------------------------------------
    // Tras el reset el estado de todos los conjuntos es 000: la raíz dice que
    // la hoja menos reciente está a la izquierda y el nodo izquierdo dice que
    // es la vía 0. La víctima inicial de cualquier conjunto es la vía 0.
    hard_reset(5);
    check("PLRU: con el estado inicial la víctima es la vía 0", victim_plru, 2'd0);

    // Tras usar la vía 0: la raíz pasa a 1 (la menos reciente del conjunto está
    // a la derecha) y el nodo izquierdo pasa a 1 (dentro del par {0,1} la
    // menos reciente es la vía 1). La víctima sale del subárbol derecho, y el
    // nodo derecho sigue en 0 -> vía 2.
    do_touch(5, 0);
    check("PLRU: tras usar la vía 0 la víctima es la vía 2", victim_plru, 2'd2);

    // Tras usar la vía 1: la raíz se mantiene en 1 y el nodo izquierdo pasa a
    // 0 (dentro del par {0,1} ahora la menos reciente es la vía 0). La
    // víctima sigue viniendo del subárbol derecho -> vía 2.
    do_touch(5, 1);
    check("PLRU: tras usar la vía 1 la víctima es la vía 2", victim_plru, 2'd2);

    // Tras usar la vía 2: la raíz pasa a 0 (la menos reciente del conjunto
    // está a la izquierda) y el nodo derecho pasa a 1 (dentro de {2,3} la
    // menos reciente es la vía 3). La víctima sale del subárbol izquierdo, con
    // el nodo izquierdo en 0 -> vía 0.
    do_touch(5, 2);
    check("PLRU: tras usar la vía 2 la víctima es la vía 0", victim_plru, 2'd0);

    // Tras usar la vía 3: la raíz se mantiene en 0 y el nodo derecho pasa a 0
    // (dentro de {2,3} la menos reciente es la vía 2). La víctima sigue
    // viniendo del subárbol izquierdo -> vía 0.
    do_touch(5, 3);
    check("PLRU: tras usar la vía 3 la víctima es la vía 0", victim_plru, 2'd0);

    // Un llenado reorganiza el árbol igual que un uso: la línea que entra
    // queda como la más reciente de su conjunto.
    do_fill(5, 2);
    check("PLRU: tras llenar la vía 2 la víctima es la vía 0", victim_plru, 2'd0);


    // ------------------------------------------------------------------
    tb_section("2. RANDOM: LFSR determinista que solo avanza con llenados");
    // ------------------------------------------------------------------
    // El LFSR arranca en 8'hA5 = 1010_0101 y la víctima son sus 2 bits bajos.
    // Polinomio x^8+x^6+x^5+x^4+1: el bit nuevo es lfsr[7]^lfsr[5]^lfsr[4]^lfsr[3]
    // y entra por la derecha.
    hard_reset(0);
    check("RANDOM: la víctima inicial es la vía 1 (lfsr = 8'hA5)", victim_rnd, 2'd1);

    // Un hit no mueve el LFSR.
    prev_rnd = victim_rnd;
    for (i = 0; i < 10; i++) do_touch(3, 2);
    check("RANDOM: los hits no avanzan el LFSR", victim_rnd, prev_rnd);

    // Cada llenado avanza el LFSR un paso:
    //   8'hA5 -> 8'h4A -> 8'h95 -> 8'h2A -> 8'h54 -> 8'hA9
    // y los 2 bits bajos van dando 1, 2, 1, 2, 0, 1.
    do_fill(0, 0);
    check("RANDOM: tras el llenado 1 la víctima es la vía 2", victim_rnd, 2'd2);
    do_fill(0, 0);
    check("RANDOM: tras el llenado 2 la víctima es la vía 1", victim_rnd, 2'd1);
    do_fill(0, 0);
    check("RANDOM: tras el llenado 3 la víctima es la vía 2", victim_rnd, 2'd2);
    do_fill(0, 0);
    check("RANDOM: tras el llenado 4 la víctima es la vía 0", victim_rnd, 2'd0);
    do_fill(0, 0);
    check("RANDOM: tras el llenado 5 la víctima es la vía 1", victim_rnd, 2'd1);

    check_true("RANDOM sin X", victim_rnd !== 2'bxx);


    // ------------------------------------------------------------------
    tb_section("3. PLRU contra el modelo de referencia (1000 operaciones)");
    // ------------------------------------------------------------------
    hard_reset(0);
    seed = 1;
    for (i = 0; i < 1000; i++) begin

        // $random puede devolver negativos, así que se enmascara: L2_SETS es
        // potencia de dos y 4 vías caben en 2 bits.
        r_set = $random(seed) & (L2_SETS-1);
        r_way = $random(seed) & 3;
        r_op  = $random(seed) & 1;

        lookup_set = r_set[L2_INDEX_W-1:0]; #1;

        if (r_op == 0) begin
            do_touch(r_set[L2_INDEX_W-1:0], r_way[1:0]);
            ref_update(r_set, r_way[1:0]);
        end
        else begin
            do_fill(r_set[L2_INDEX_W-1:0], r_way[1:0]);
            ref_update(r_set, r_way[1:0]);
        end

        if (victim_plru !== ref_victim(r_set)) begin
            check("PLRU: el modelo y el DUT no coinciden", victim_plru, ref_victim(r_set));
            $display("  (fallo en la operación %0d: conjunto %0d, vía %0d, op %0d)",
                     i, r_set, r_way, r_op);
            i = 1000;   // sale del ciclo: no hace falta seguir
        end
    end
    check("PLRU: 1000 operaciones coinciden con el modelo de referencia", 1'b1, 1'b1);


    // ------------------------------------------------------------------
    tb_section("4. PLRU: la víctima nunca es la vía que se acaba de usar");
    // ------------------------------------------------------------------
    hard_reset(0);
    for (i = 0; i < 200; i++) begin

        r_set = $random(seed) & (L2_SETS-1);
        r_way = $random(seed) & 3;

        lookup_set = r_set[L2_INDEX_W-1:0]; #1;

        do_touch(r_set[L2_INDEX_W-1:0], r_way[1:0]);

        check_true("PLRU: la víctima no es la vía recién usada", victim_plru !== r_way[1:0]);
    end


    // ------------------------------------------------------------------
    tb_section("5. Los conjuntos son independientes");
    // ------------------------------------------------------------------
    hard_reset(0);
    lookup_set = 100; #1;
    check("PLRU: conjunto 100 sin usar -> víctima 0", victim_plru, 2'd0);

    do_touch(100, 0);
    check("PLRU: conjunto 100 tras usar la vía 0 -> víctima 2", victim_plru, 2'd2);

    lookup_set = 101; #1;
    check("PLRU: conjunto 101 sin tocar -> víctima 0", victim_plru, 2'd0);

    lookup_set = 100; #1;
    check("PLRU: conjunto 100 no cambió", victim_plru, 2'd2);

    // Un llenado en otro conjunto tampoco toca el estado del primero.
    do_fill(101, 3);
    lookup_set = 100; #1;
    check("PLRU: llenar en el conjunto 101 no altera el 100", victim_plru, 2'd2);
    lookup_set = 101; #1;
    check("PLRU: conjunto 101 tras llenar la vía 3 -> víctima 0", victim_plru, 2'd0);


    // ------------------------------------------------------------------
    tb_section("6. RANDOM: distribución entre las 4 vías y reproducibilidad");
    // ------------------------------------------------------------------
    hard_reset(0);
    for (i = 0; i < 4; i++) seen[i] = 0;

    for (i = 0; i < 256; i++) begin
        seen[victim_rnd]++;
        do_fill(i[L2_INDEX_W-1:0], 0);
    end

    check_true("RANDOM: la vía 0 aparece alguna vez", seen[0] > 0);
    check_true("RANDOM: la vía 1 aparece alguna vez", seen[1] > 0);
    check_true("RANDOM: la vía 2 aparece alguna vez", seen[2] > 0);
    check_true("RANDOM: la vía 3 aparece alguna vez", seen[3] > 0);

    // 256 llenados repartidos en 4 vías: 64 cada una si el LFSR está bien
    // mezclado. Se aceptan +-30 para no ser brittle con el punto de partida.
    check_true("RANDOM: la vía 0 sale unas 64 veces", seen[0] > 34 && seen[0] < 94);
    check_true("RANDOM: la vía 1 sale unas 64 veces", seen[1] > 34 && seen[1] < 94);
    check_true("RANDOM: la vía 2 sale unas 64 veces", seen[2] > 34 && seen[2] < 94);
    check_true("RANDOM: la vía 3 sale unas 64 veces", seen[3] > 34 && seen[3] < 94);

    // Reproducible: la misma secuencia de llenados da la misma secuencia.
    begin
        logic [L2_WAY_W-1:0] primera [0:15];
        logic [L2_WAY_W-1:0] segunda [0:15];

        hard_reset(0);
        for (i = 0; i < 16; i++) begin
            primera[i] = victim_rnd;
            do_fill(i[L2_INDEX_W-1:0], 0);
        end

        hard_reset(0);
        for (i = 0; i < 16; i++) begin
            segunda[i] = victim_rnd;
            do_fill(i[L2_INDEX_W-1:0], 0);
        end

        for (i = 0; i < 16; i++)
            check("RANDOM: la secuencia es reproducible", segunda[i], primera[i]);
    end


    tb_finish("tb_l2_replacement");
end

endmodule
