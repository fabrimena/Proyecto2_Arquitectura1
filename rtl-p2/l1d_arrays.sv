/*
================================================================================
 Módulo: l1d_arrays

 Descripción:
 ------------------------------------------------------------------------------
 Almacenamiento de la caché L1-D (bloque de José, Proyecto Grupal II):
 los arreglos de etiquetas, de bits de validez, de bits sucios y de datos de
 las 2 vías. No toma ninguna decisión; solo guarda y entrega. El control
 (hit/miss, políticas, llenados, vaciado) está en l1d_cache.sv.

 Organización (cache_defs.sv, punto 1): 64 conjuntos x 2 vías, igual que la
 caché asociativa por conjuntos de 2 vías de las notas de clase (sección
 6.2.2, figura 6.5), pero con 64 conjuntos en vez de 2.

              vía 0                                  vía 1
           +---+---+-----+--------------------+   +---+---+-----+--------------------+
 conj.  0  | V | D | tag | línea (8 palabras) |   | V | D | tag | línea (8 palabras) |
 conj.  1  | V | D | tag | ...                |   | V | D | tag | ...                |
   ...     |   |   |     |                    |   |   |   |     |                    |
 conj. 63  | V | D | tag | ...                |   | V | D | tag | ...                |
           +---+---+-----+--------------------+   +---+---+-----+--------------------+

 Campos de cada entrada (notas 6.2.1 y 6.2.3):
   V   (validez) 1 = la casilla tiene una línea; 0 = está vacía. Al arrancar
               todas están en 0, así que el primer acceso a cada línea es un
               desacierto obligatorio (notas 6.3.2).
   D   (sucio)   1 = la línea tiene datos que el nivel de abajo no tiene.
               Solo se usa con write-back (cache_defs.sv): un store que
               acierta lo pone en 1, y cuando la línea sale de la L1-D (o en
               el vaciado) se manda a la L2. Con write-through queda siempre
               en 0. Con la política exclusiva, una línea que llega de la L2
               ya sucia (l2_rdirty) también entra con D = 1.
   tag (etiqueta, 5 bits) la parte alta de la dirección de la línea
               guardada; se compara para confirmar el acierto.
   línea (datos, 256 bits) las 8 palabras; la palabra i ocupa los bits
               [32i+31:32i].

 Puerto de lectura A: el acceso del núcleo, con ACCESO PARALELO (notas
 6.3.1, figura 6.9)
   Se da un conjunto (rd_set) y salen, a la vez y en el mismo ciclo, la
   etiqueta, V y la línea completa de LAS DOS VÍAS. Así l1d_cache.sv compara
   las dos etiquetas en paralelo y un multiplexor elige la vía que acertó
   (notas, figura 6.5). Es la forma con menor latencia, y es la que permite
   que un hit responda en el mismo ciclo que la memoria del proyecto 1. A
   cambio se leen siempre las dos vías de datos, aunque solo una sirva (más
   potencia, notas 6.3.1). La lectura es combinacional, igual que
   rtl/memory.sv.

 Puerto de lectura B: llenado y vaciado (rdb_*)
   Con la caché non-blocking (MSHR para stores, cache_defs.sv), la línea de
   un miss puede llegar de la L2 mientras el núcleo ya está haciendo OTRO
   acceso, a otro conjunto. En ese mismo ciclo el llenado tiene que leer su
   conjunto para elegir la víctima y, si está sucia (o con exclusiva),
   mandarla al write buffer. El puerto A está ocupado con el acceso del
   núcleo, así que el llenado usa este segundo puerto. El vaciado también lo
   usa para recorrer las 128 casillas buscando líneas sucias. Entrega lo
   mismo que el puerto A más los bits D.

 Puerto de escritura: una línea completa por ciclo
   Con wr_en = 1 se escriben, en el flanco positivo, la etiqueta, la línea y
   el bit D de la vía wr_way del conjunto wr_set, y esa casilla queda válida
   (V = 1). Sirve para todas las escrituras de la L1-D:
     - llenado: entra la línea nueva (D = 0, o D = l2_rdirty con exclusiva,
       o D = 1 si trae stores mezclados con write-back);
     - store que acierta: la misma línea con los bytes nuevos (D = 1 con
       write-back, D = 0 con write-through);
     - vaciado: la misma línea con D = 0, después de mandarla a la L2.
   l1d_cache.sv se encarga de que en un ciclo haya una sola escritura (si un
   llenado y un store coinciden, el store espera un ciclo).

 Compatibilidad: los puertos nuevos (rdb_*, wr_dirty) tienen valor por
 defecto en 0, como el puerto B de rtl/memory.sv, así que un módulo que no
 los conecte funciona igual que antes (sin bits sucios).

 Reset: borra los bits V y D (la caché arranca vacía y limpia). Las
 etiquetas y los datos no necesitan borrarse, porque con V = 0 nadie los
 mira; igual se inicializan en 0 al comenzar la simulación para no ver X en
 las ondas.

================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l1d_arrays (

    input  logic                              clk,
    input  logic                              reset,

    // ------------------------------------------------------------------
    // Lectura A: acceso del núcleo (combinacional, las 2 vías a la vez)
    // ------------------------------------------------------------------
    input  logic [L1D_INDEX_W-1:0]            rd_set,
    output logic [L1D_WAYS-1:0]               rd_valid,   // bit w = V de la vía w
    output logic [L1D_WAYS*L1D_TAG_W-1:0]     rd_tag,     // vía w en [w*TAG_W +: TAG_W]
    output logic [L1D_WAYS*LINE_W-1:0]        rd_line,    // vía w en [w*LINE_W +: LINE_W]

    // ------------------------------------------------------------------
    // Lectura B: llenado y vaciado (combinacional, las 2 vías a la vez)
    // ------------------------------------------------------------------
    input  logic [L1D_INDEX_W-1:0]            rdb_set = '0,
    output logic [L1D_WAYS-1:0]               rdb_valid,
    output logic [L1D_WAYS-1:0]               rdb_dirty,  // bit w = D de la vía w
    output logic [L1D_WAYS*L1D_TAG_W-1:0]     rdb_tag,
    output logic [L1D_WAYS*LINE_W-1:0]        rdb_line,

    // ------------------------------------------------------------------
    // Escritura de una vía completa (flanco positivo); la deja válida
    // ------------------------------------------------------------------
    input  logic                              wr_en,
    input  logic [L1D_INDEX_W-1:0]            wr_set,
    input  logic                              wr_way,
    input  logic [L1D_TAG_W-1:0]              wr_tag,
    input  logic [LINE_W-1:0]                 wr_line,
    input  logic                              wr_dirty = 1'b0
);


// ============================================================================
// Un bloque por vía. Cada vía tiene sus propios arreglos de 64 posiciones.
// (Las salidas se entregan "aplanadas": la vía w ocupa su tramo del vector.
//  Es más compatible con Icarus Verilog que los arreglos empaquetados de
//  varias dimensiones en los puertos.)
// ============================================================================

genvar w;
generate
    for (w = 0; w < L1D_WAYS; w++) begin : g_way

        localparam logic WAY_ID = w;                       // número de esta vía (0 o 1)

        logic [L1D_SETS-1:0]  valid_bits;                  // V de cada conjunto
        logic [L1D_SETS-1:0]  dirty_bits;                  // D de cada conjunto
        logic [L1D_TAG_W-1:0] tag_mem  [0:L1D_SETS-1];     // etiquetas
        logic [LINE_W-1:0]    data_mem [0:L1D_SETS-1];     // líneas de datos

        // Valores iniciales de simulación (solo para no ver X en las ondas)
        integer s;
        initial begin
            for (s = 0; s < L1D_SETS; s++) begin
                tag_mem[s]  = '0;
                data_mem[s] = '0;
            end
        end

        // ---- Lectura A (núcleo) -----------------------------------------
        assign rd_valid[w]                        = valid_bits[rd_set];
        assign rd_tag [w*L1D_TAG_W +: L1D_TAG_W]  = tag_mem[rd_set];
        assign rd_line[w*LINE_W    +: LINE_W]     = data_mem[rd_set];

        // ---- Lectura B (llenado y vaciado) ------------------------------
        assign rdb_valid[w]                       = valid_bits[rdb_set];
        assign rdb_dirty[w]                       = dirty_bits[rdb_set];
        assign rdb_tag [w*L1D_TAG_W +: L1D_TAG_W] = tag_mem[rdb_set];
        assign rdb_line[w*LINE_W    +: LINE_W]    = data_mem[rdb_set];

        // ---- Escritura ---------------------------------------------------
        always @(posedge clk) begin

            if (reset) begin

                valid_bits <= '0;
                dirty_bits <= '0;
            end
            else if (wr_en && wr_way == WAY_ID) begin

                valid_bits[wr_set] <= 1'b1;
                dirty_bits[wr_set] <= wr_dirty;
                tag_mem[wr_set]    <= wr_tag;
                data_mem[wr_set]   <= wr_line;
            end
        end
    end
endgenerate


endmodule
