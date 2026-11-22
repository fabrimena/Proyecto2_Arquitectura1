/*
================================================================================
 Módulo: l2_arrays

 Descripción:
 ------------------------------------------------------------------------------
 Almacenamiento de la caché L2 (bloque de Alejandro, Proyecto Grupal II):
 los arreglos de etiquetas, de bits de validez, de bits sucios y de datos de las
 4 vías. No toma ninguna decisión; solo guarda y entrega. El control (acierto,
 fallo, políticas, llenados, vaciado) está en l2_cache.sv.

 Es el módulo hermano de l1d_arrays.sv (de José) para la L2: mismo estilo, mismo
 reparto de responsabilidades.

 Organización (enunciado 3.2.3, geometría FIJADA; no es una decisión de diseño):
     16 KB, 4 vías, líneas de 32 B  ->  512 líneas, 128 conjuntos
     índice addr[11:5] (7 bits), etiqueta addr[15:12] (4 bits)

              vía 0                                  vía 1
           +---+---+-----+--------------------+   +---+---+-----+--------------------+
 conj.  0  | V | D | tag | línea (8 palabras) |   | V | D | tag | línea (8 palabras) |
 conj.  1  | V | D | tag | ...                |   | V | D | tag | ...                |
   ...     |   |   |     |                    |   |   |   |     |                    |
 conj.127  | V | D | tag | ...                |   | V | D | tag | ...                |
           +---+---+-----+--------------------+   +---+---+-----+--------------------+

 Los otros dos conjuntos de vías (2 y 3) tienen la misma forma.

 Campos de cada entrada (notas de clase 6.2.1, 6.2.3 y 6.3.2):
   V   (validez) 1 = la casilla tiene una línea; 0 = está vacía. Al arrancar
               todas están en 0, así que el primer acceso a cada línea es un
               desacierto obligatorio (notas 6.3.2).
   D   (sucio)   1 = la línea tiene datos que el nivel de abajo no tiene. Con
               write-back (cache_defs.sv) un store que acierta lo pone en 1; la
               línea baja sucia a la RAM cuando sale de la L2 o en el vaciado.
   tag (etiqueta, 4 bits) la parte alta de la dirección de la línea guardada;
               se compara para confirmar el acierto.
   línea (datos, 256 bits) las 8 palabras; la palabra i ocupa los bits
               [32i+31:32i].

 Puerto de lectura (rd_*): un solo conjunto por ciclo
   Se da un conjunto (rd_set) y salen, a la vez y en el mismo ciclo, la
   etiqueta, V, D y la línea completa de LAS CUATRO VÍAS. Así l2_cache.sv
   compara las cuatro etiquetas en paralelo y un multiplexor elige la vía que
   acertó (notas, figura 6.5).

   La L2 tiene UN SOLO puerto de lectura, multiplexado: durante el vaciado el
   conjunto que se lee es el que está revisando el barrido, no el de la
   petición. Es el mismo truco que usa la L1-D con su puerto B (l1d_arrays.sv).

   La lectura es combinacional, igual que rtl/memory.sv.

 Puerto de escritura (wr_*): una línea completa por ciclo
   Con wr_en = 1 se escriben, en el flanco positivo, la etiqueta, la línea, el
   bit D y el bit V (wr_valid) de la vía wr_way del conjunto wr_set. Sirve para
   todas las escrituras de la L2:
     - llenado: entra la línea que llegó del nivel inferior (con NINE) o la
       víctima de la L1-D (con exclusiva);
     - store que acierta: la misma línea con los bytes nuevos;
     - un acierto con exclusiva: la línea se MUEVE a la L1-D, así que aquí se
       escribe con V = 0 (la L2 ya no tiene esa línea).

 Puerto de limpieza del bit sucio (clr_dirty_*)
   Es una operación aparte del puerto de escritura, porque el vaciado solo
   necesita dejar la línea LIMPIA: la etiqueta y los datos no se tocan. Con
   clr_dirty_en = 1 se pone D = 0 en la vía clr_dirty_way del conjunto
   clr_dirty_set, sin escribir la etiqueta ni la línea.

   La copia de la L2 sigue siendo válida y sigue teniendo los mismos datos:
   a partir de ahí la L2 y la RAM tienen lo mismo (notas 6.3.5).

 Reset: borra los bits V y D (la caché arranca vacía y limpia). Las etiquetas y
 los datos no necesitan borrarse, porque con V = 0 nadie los mira; igual se
 inicializan en 0 al comenzar la simulación para no ver X en las ondas.

================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l2_arrays (

    input  logic                              clk,
    input  logic                              reset,

    // ------------------------------------------------------------------
    // Lectura: un conjunto por ciclo (combinacional, las 4 vías a la vez)
    // ------------------------------------------------------------------
    input  logic [L2_INDEX_W-1:0]             rd_set,
    output logic [L2_WAYS-1:0]                rd_valid,   // bit w = V de la vía w
    output logic [L2_WAYS*L2_TAG_W-1:0]       rd_tag,     // vía w en [w*TAG_W +: TAG_W]
    output logic [L2_WAYS*LINE_W-1:0]         rd_line,    // vía w en [w*LINE_W +: LINE_W]
    output logic [L2_WAYS-1:0]                rd_dirty,   // bit w = D de la vía w

    // ------------------------------------------------------------------
    // Escritura: una línea completa por ciclo (flanco positivo)
    // ------------------------------------------------------------------
    input  logic                              wr_en,
    input  logic [L2_INDEX_W-1:0]             wr_set,
    input  logic [L2_WAY_W-1:0]               wr_way,
    input  logic [L2_TAG_W-1:0]               wr_tag,
    input  logic [LINE_W-1:0]                 wr_line,
    input  logic                              wr_dirty,
    input  logic                              wr_valid,   // 0 = invalidar la casilla

    // ------------------------------------------------------------------
    // Limpieza del solo bit sucio (la usa el vaciado)
    // ------------------------------------------------------------------
    input  logic                              clr_dirty_en,
    input  logic [L2_INDEX_W-1:0]             clr_dirty_set,
    input  logic [L2_WAY_W-1:0]               clr_dirty_way
);


// ============================================================================
// Un bloque por vía. Cada vía tiene sus propios arreglos de 128 posiciones.
// (Las salidas se entregan "aplanadas": la vía w ocupa su tramo del vector.
//  Es más compatible con Icarus Verilog que los arreglos empaquetados de
//  varias dimensiones en los puertos.)
// ============================================================================

genvar w;
generate
    for (w = 0; w < L2_WAYS; w = w + 1) begin : g_way

        // Ojo: hay que darle ancho explícito. "logic" a secas es de UN bit,
        // y con 4 vías las vías 2 y 3 se quedarían con WAY_ID = 0 y 1.
        localparam logic [L2_WAY_W-1:0] WAY_ID = w;

        logic [L2_SETS-1:0]  valid_bits;                   // V de cada conjunto
        logic [L2_SETS-1:0]  dirty_bits;                   // D de cada conjunto
        logic [L2_TAG_W-1:0] tag_mem  [0:L2_SETS-1];        // etiquetas
        logic [LINE_W-1:0]    data_mem [0:L2_SETS-1];        // líneas de datos

        // Valores iniciales de simulación (solo para no ver X en las ondas)
        integer s;
        initial begin
            for (s = 0; s < L2_SETS; s = s + 1) begin
                tag_mem[s]  = '0;
                data_mem[s] = '0;
            end
        end

        // ---- Lectura -------------------------------------------------------
        assign rd_valid[WAY_ID]                       = valid_bits[rd_set];
        assign rd_tag  [WAY_ID*L2_TAG_W +: L2_TAG_W]  = tag_mem[rd_set];
        assign rd_line [WAY_ID*LINE_W    +: LINE_W]   = data_mem[rd_set];
        assign rd_dirty[WAY_ID]                       = dirty_bits[rd_set];

        // ---- Escritura -----------------------------------------------------
        always @(posedge clk) begin

            if (reset) begin

                valid_bits <= '0;
                dirty_bits <= '0;
            end
            else if (wr_en && (wr_way == WAY_ID)) begin

                valid_bits[wr_set] <= wr_valid;
                dirty_bits[wr_set] <= wr_dirty;
                tag_mem[wr_set]    <= wr_tag;
                data_mem[wr_set]   <= wr_line;
            end
            else if (clr_dirty_en && (clr_dirty_way == WAY_ID)) begin

                // Solo el bit sucio: la etiqueta y los datos no se tocan.
                dirty_bits[clr_dirty_set] <= 1'b0;
            end
        end
    end
endgenerate


endmodule
