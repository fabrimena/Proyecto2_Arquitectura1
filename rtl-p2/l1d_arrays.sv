/*
================================================================================
 Módulo: l1d_arrays

 Descripción:
 ------------------------------------------------------------------------------
 Almacenamiento de la caché L1-D (bloque de José, Proyecto Grupal II):
 los arreglos de etiquetas, de bits de validez y de datos de las 2 vías.
 No toma ninguna decisión; solo guarda y entrega. El control (hit/miss,
 políticas, llenados) está en l1d_cache.sv.

 Organización (cache_defs.sv, punto 1): 64 conjuntos x 2 vías, igual que la
 caché asociativa por conjuntos de 2 vías de las notas de clase (sección
 6.2.2, figura 6.5), pero con 64 conjuntos en vez de 2.

              vía 0                              vía 1
           +---+-----+--------------------+   +---+-----+--------------------+
 conj.  0  | V | tag | línea (8 palabras) |   | V | tag | línea (8 palabras) |
 conj.  1  | V | tag | ...                |   | V | tag | ...                |
   ...     |   |     |                    |   |   |     |                    |
 conj. 63  | V | tag | ...                |   | V | tag | ...                |
           +---+-----+--------------------+   +---+-----+--------------------+

 Cada entrada tiene los tres campos de las notas (sección 6.2.1):
   V   (validez) 1 = la casilla tiene una línea; 0 = está vacía. Al
               arrancar todas están en 0, así que el primer acceso a cada
               línea es un desacierto obligatorio (notas 6.3.2).
   tag (etiqueta, 5 bits) la parte alta de la dirección de la línea
               guardada; se compara para confirmar el acierto.
   línea (datos, 256 bits) las 8 palabras; la palabra i ocupa los bits
               [32i+31:32i].

 ¿Por qué no hay bit "sucio" (dirty)?
   La L1-D es write-through (decisión del grupo, cache_defs.sv): cada store
   se escribe en la L1-D y además va al write buffer hacia la L2. Así, la
   L1-D nunca tiene un dato que la L2 no tenga o que no esté en camino, y
   una línea desalojada simplemente se descarta. El bit sucio solo hace
   falta con write-back (notas 6.2.3).

 Puerto de lectura: ACCESO PARALELO (notas 6.3.1, figura 6.9)
   Se da un conjunto (rd_set) y salen, a la vez y en el mismo ciclo, la
   etiqueta, V y la línea completa de LAS DOS VÍAS. Así l1d_cache.sv compara
   las dos etiquetas en paralelo y un multiplexor elige la vía que acertó
   (notas, figura 6.5). Es la forma con menor latencia, y es la que permite
   que un hit responda en el mismo ciclo que la memoria del proyecto 1. A
   cambio se leen siempre las dos vías de datos, aunque solo una sirva (más
   potencia, notas 6.3.1). La lectura es combinacional, igual que
   rtl/memory.sv.

 Puerto de escritura: una línea completa por ciclo
   Con wr_en = 1 se escriben, en el flanco positivo, la etiqueta y la línea
   de la vía wr_way del conjunto wr_set, y esa casilla queda válida (V = 1).
   Sirve para las dos escrituras que hace la L1-D:
     - llenado: entra la línea nueva que llegó de la L2 (la que había ahí se
       descarta, siempre está limpia);
     - store que acierta: la misma línea con los bytes nuevos ya puestos.
   Un solo puerto alcanza porque, en cada ciclo, la L1-D atiende un solo
   acceso del núcleo.

 Reset: borra los bits V (la caché arranca vacía). Las etiquetas y los datos
 no necesitan borrarse, porque con V = 0 nadie los mira; igual se
 inicializan en 0 al comenzar la simulación para no ver X en las ondas.

================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l1d_arrays (

    input  logic                              clk,
    input  logic                              reset,

    // ------------------------------------------------------------------
    // Lectura (combinacional, las 2 vías a la vez)
    // ------------------------------------------------------------------
    input  logic [L1D_INDEX_W-1:0]            rd_set,
    output logic [L1D_WAYS-1:0]               rd_valid,   // bit w = V de la vía w
    output logic [L1D_WAYS*L1D_TAG_W-1:0]     rd_tag,     // vía w en [w*TAG_W +: TAG_W]
    output logic [L1D_WAYS*LINE_W-1:0]        rd_line,    // vía w en [w*LINE_W +: LINE_W]

    // ------------------------------------------------------------------
    // Escritura de una vía completa (flanco positivo); la deja válida
    // ------------------------------------------------------------------
    input  logic                              wr_en,
    input  logic [L1D_INDEX_W-1:0]            wr_set,
    input  logic                              wr_way,
    input  logic [L1D_TAG_W-1:0]              wr_tag,
    input  logic [LINE_W-1:0]                 wr_line
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

        // ---- Lectura en paralelo ----------------------------------------
        assign rd_valid[w]                       = valid_bits[rd_set];
        assign rd_tag [w*L1D_TAG_W +: L1D_TAG_W] = tag_mem[rd_set];
        assign rd_line[w*LINE_W    +: LINE_W]    = data_mem[rd_set];

        // ---- Escritura ---------------------------------------------------
        always @(posedge clk) begin

            if (reset)
                valid_bits <= '0;

            else if (wr_en && wr_way == WAY_ID) begin

                valid_bits[wr_set] <= 1'b1;
                tag_mem[wr_set]    <= wr_tag;
                data_mem[wr_set]   <= wr_line;
            end
        end
    end
endgenerate


endmodule
