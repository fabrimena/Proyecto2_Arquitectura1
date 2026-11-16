/*
================================================================================
 Módulo: l2_replacement

 Descripción:
 ------------------------------------------------------------------------------
 Política de reemplazo de la caché L2 unificada (bloque de Alejandro, Proyecto
 Grupal II).

 La L2 es write-back y 4-vías (enunciado 3.2.3 y 7.1.4). Cuando un miss de L2
 deja el conjunto lleno, hay que decidir qué línea se desaloja para hacer sitio
 a la nueva. Este módulo es el equivalente de rtl-p2/l1d_replacement.sv para el
 segundo nivel: recibe los avisos de uso y de llenado, y responde con la VÍA
 VÍCTIMA de un conjunto.

 A diferencia de la L1-D (2 vías, write-through, línea siempre limpia), aquí:

   - Hay 4 vías, así que el LRU exacto necesita 6 bits por conjunto (la matriz
     de recencia completa). Las cachés reales usan aproximaciones por el costo
     en área y en tiempo de consulta; el enunciado 7.1.4 lo pide explícitamente:
     "Pseudo-LRU (tree-based o bit-based), Random, o LFU aproximado con
     contadores de 2-3 bits".

   - La L2 es write-back, así que la víctima puede estar SUCIA. A este módulo no
     le importa: él solo dice qué vía sale. Lo que hacer con la línea sucia (el
     eviction buffer hacia la memoria principal) es de rtl-p2/l2_cache.sv.

   - Con la política EXCLUSIVE la L2 también guarda las víctimas de la L1-D, y
     las mete por el mismo camino de llenado (fill), así que este módulo no
     necesita saber si la línea viene de la memoria o de la L1-D.

 Políticas implementadas (REPL_POLICY, constantes de cache_defs.sv):

   RP2_PLRU  Pseudo-LRU de árbol (tree-based), el de las notas de clase:
             un árbol balanceado cuyas hojas son las vías del conjunto. Cada
             nodo interno tiene un bit que dice en cuál de sus dos hijos está la
             hoja menos reciente. Para 4 vías el árbol es:

                    raíz            (bit: ¿la víctima está a la izquierda o
                   /   \            a la derecha?)
                nodo L nodo R
                /  \     /  \
               v0  v1   v2  v3

             Son 3 bits por conjunto (raíz, nodo L, nodo R), frente a los 6
             del LRU exacto. Es una APROXIMACIÓN: no siempre desaloja la línea
             menos reciente de verdad, pero en la práctica se comporta casi
             igual que LRU y es lo que hacen las cachés reales.

             Ojo: un pseudo-LRU no es un LRU exacto. Por eso el nombre del
             parámetro y de la constante es RP2_PLRU, no RP_LRU, y el
             testbench lo comprueba como tal (no promete el orden exacto).

   RP2_RANDOM Aleatorio con un LFSR (Linear Feedback Shift Register), el
             generador pseudoaleatorio de muy bajo costo en hardware que ya
             usa la L1-D. La víctima sale de los 2 bits bajos del LFSR.

 Observaciones de implementación:
   - victim_way es combinacional: depende del conjunto consultado y de
     registros que solo cambian en el flanco positivo, así que se puede usar en
     el mismo ciclo del acceso sin cambiar la latencia de un hit.
   - Las actualizaciones (touch / fill) se aplican en el flanco positivo.
   - Las vías inválidas (vacías) tienen prioridad sobre la política: si alguna
     vía del conjunto está libre, se usa esa y no se desaloja a nadie. Esa
     decisión la toma rtl-p2/l2_cache.sv, porque es quien conoce los bits de
     validez; este módulo solo responde "si hubiera que sacar a alguien, sería
     esta vía". Igual que en la L1-D.
   - El LFSR solo avanza con llenados (no en cada ciclo ni en cada hit), para
     que la simulación sea repetible: el mismo programa da siempre los mismos
     números.
   - touch y fill son excluyentes en la L2: hay un solo cliente (la L1-D) y
     como mucho una petición por ciclo, así que no pueden caer los dos avisos
     en el mismo ciclo. Si aun así ocurriera sobre el MISMO conjunto, manda el
     llenado (es la última asignación del bloque secuencial y por tanto pisa a
     la del uso).

================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l2_replacement #(

    // Política de reemplazo: RP2_PLRU o RP2_RANDOM (cache_defs.sv)
    parameter logic [1:0] REPL_POLICY = L2_DEFAULT_REPL_POLICY
) (

    input  logic                   clk,
    input  logic                   reset,

    // ------------------------------------------------------------------
    // Consulta: ¿qué vía se reemplazaría en este conjunto?
    // ------------------------------------------------------------------
    input  logic [L2_INDEX_W-1:0] lookup_set,    // conjunto del acceso actual
    output logic [L2_WAY_W-1:0]   victim_way,    // vía propuesta como víctima

    // ------------------------------------------------------------------
    // Aviso de "uso": el acceso encontró su línea en la vía touch_way del
    // conjunto touch_set (hit en la L2, o llenado con bypass).
    // Solo lo usa PLRU.
    // ------------------------------------------------------------------
    input  logic                   touch,
    input  logic [L2_INDEX_W-1:0] touch_set,
    input  logic [L2_WAY_W-1:0]   touch_way,

    // ------------------------------------------------------------------
    // Aviso de "llenado": entró una línea nueva en la vía fill_way del
    // conjunto fill_set. Lo usan PLRU y RANDOM.
    // ------------------------------------------------------------------
    input  logic                   fill,
    input  logic [L2_INDEX_W-1:0] fill_set,
    input  logic [L2_WAY_W-1:0]   fill_way
);


// ============================================================================
// Verificación de los parámetros (solo en simulación)
// ============================================================================

initial begin

    if (L2_WAYS != 4)
        $fatal(1, "l2_replacement: este módulo implementa el árbol de 4 vías (L2_WAYS = %0d)", L2_WAYS);

    if (REPL_POLICY != RP2_PLRU && REPL_POLICY != RP2_RANDOM)
        $fatal(1, "l2_replacement: REPL_POLICY = %0d no es una política válida", REPL_POLICY);
end


// ============================================================================
// Estado de PLRU: 3 bits por conjunto
// ============================================================================
//
// El estado de un conjunto son 3 bits, que se guardan en tres vectores para
// poder indexarlos por conjunto sin usar un array de dos dimensiones:
//
//   plru_root[s]  0 -> la hoja menos reciente del conjunto está en el subárbol
//                        IZQUIERDO (vías 0 y 1)
//                  1 -> está en el subárbol DERECHO (vías 2 y 3)
//   plru_left[s]  dentro del par {vía 0, vía 1}: 0 -> la menos reciente es la
//                  vía 0, 1 -> es la vía 1
//   plru_right[s] dentro del par {vía 2, vía 3}: 0 -> la menos reciente es la
//                  vía 2, 1 -> es la vía 3
//
// Al arrancar todas las vías están vacías, así que el valor inicial (0) da
// igual: la primera línea de cada conjunto va a una vía inválida.

logic [L2_SETS-1:0] plru_root;
logic [L2_SETS-1:0] plru_left;
logic [L2_SETS-1:0] plru_right;


// ============================================================================
// Estado de RANDOM: LFSR de 8 bits
// ============================================================================
//
// Polinomio x^8 + x^6 + x^5 + x^4 + 1 (de longitud máxima: recorre los 255
// valores distintos de 0 antes de repetirse). Forma de Fibonacci: el bit
// nuevo es el XOR de los bits 7, 5, 4 y 3, y entra por la derecha.
//
// La víctima se toma de los 2 bits bajos (lfsr[1:0]), porque la L2 tiene 4 vías.
// Sobre el período de 255 estados cada par aparece 64, 64, 64 y 63 veces, así
// que la distribución es prácticamente uniforme.
//
// Avanza solo cuando hay un llenado (no en cada ciclo). Así la secuencia de
// víctimas depende únicamente de la secuencia de misses del programa y la
// simulación es repetible: el mismo programa da siempre los mismos números.
// La semilla no puede ser 0 (el LFSR se quedaría en 0 para siempre).

localparam logic [7:0] LFSR_SEED = 8'hA5;

logic [7:0] lfsr;
logic       lfsr_feedback;

assign lfsr_feedback = lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3];


// ============================================================================
// Cálculo del nuevo estado del árbol tras un acceso a la vía w
// ============================================================================
//
// Estado empaquetado {raíz, nodo L, nodo R}. Al usar la vía w, el nodo que
// contiene a w pasa a apuntar al HERMANO de w (que es el que queda como menos
// reciente dentro de ese par), y la raíz pasa a apuntar al subárbol que NO
// contiene a w (que es el que queda como menos reciente del conjunto).

function automatic logic [2:0] plru_update(input logic [2:0] st,
                                          input logic [L2_WAY_W-1:0] w);

    logic r, l, rr;

    r  = st[2];
    l  = st[1];
    rr = st[0];

    if (w[1] == 1'b0) begin
        // La vía usada está en el subárbol izquierdo (vías 0 y 1).
        r = 1'b1;      // la menos reciente del conjunto pasa a la derecha
        l = ~w[0];     // dentro del par, la menos reciente es la hermana
    end
    else begin
        // La vía usada está en el subárbol derecho (vías 2 y 3).
        r  = 1'b0;     // la menos reciente del conjunto pasa a la izquierda
        rr = ~w[0];    // dentro del par, la menos reciente es la hermana
    end

    plru_update = {r, l, rr};
endfunction


// ============================================================================
// Estados nuevos del árbol (combinacional, para poder aplicarlos en el flanco)
// ============================================================================

logic [2:0] st_touch;
logic [2:0] st_fill;

always @(*) begin

    st_touch = plru_update({plru_root[touch_set], plru_left[touch_set], plru_right[touch_set]},
                           touch_way);

    st_fill  = plru_update({plru_root[fill_set],  plru_left[fill_set],  plru_right[fill_set]},
                           fill_way);
end


// ============================================================================
// Salida: la víctima propuesta para el conjunto consultado
// ============================================================================

always @(*) begin

    case (REPL_POLICY)

        RP2_RANDOM: victim_way = lfsr[1:0];

        // PLRU: se baja por el árbol siguiendo los bits, hasta la hoja
        default: begin
            if (plru_root[lookup_set] == 1'b0)
                victim_way = {1'b0, plru_left[lookup_set]};   // vías 0 o 1
            else
                victim_way = {1'b1, plru_right[lookup_set]};  // vías 2 o 3
        end
    endcase
end


// ============================================================================
// Actualización del estado (flanco positivo)
// ============================================================================

always @(posedge clk) begin

    if (reset) begin

        plru_root  <= '0;
        plru_left  <= '0;
        plru_right <= '0;
        lfsr       <= LFSR_SEED;
    end
    else begin

        // --- PLRU: cada uso reorganiza el árbol ---------------------------
        // Si en el mismo ciclo hay touch y fill (un llenado que además
        // responde al núcleo), se refieren a la misma vía y conjunto, así
        // que el resultado es el mismo con cualquiera de los dos.
        if (REPL_POLICY == RP2_PLRU) begin

            if (touch) begin
                plru_root[touch_set]  <= st_touch[2];
                plru_left[touch_set]  <= st_touch[1];
                plru_right[touch_set] <= st_touch[0];
            end

            if (fill) begin
                plru_root[fill_set]  <= st_fill[2];
                plru_left[fill_set]  <= st_fill[1];
                plru_right[fill_set] <= st_fill[0];
            end
        end

        // --- RANDOM: el LFSR da un paso por cada llenado -------------------
        if (REPL_POLICY == RP2_RANDOM) begin

            if (fill)
                lfsr <= {lfsr[6:0], lfsr_feedback};
        end
    end
end


endmodule
