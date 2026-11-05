/*
================================================================================
 Archivo: cache_defs.sv

 Descripción:
 ------------------------------------------------------------------------------
 Constantes compartidas por la caché de datos L1-D, su política de reemplazo
 y el write buffer L1-D -> L2 (bloque de José, Proyecto Grupal II).

 Es el equivalente de isa_defs.sv pero para la jerarquía de memoria: aquí
 viven TODOS los números "mágicos" (tamaños, anchos de campos, códigos de
 políticas) para que ningún módulo tenga valores repetidos escritos a mano.
 Si mañana el grupo decide, por ejemplo, otro tamaño de línea, se cambia
 aquí y el resto del diseño se ajusta solo.

 Contiene:
   1. Geometría de la L1-D (tamaño, vías, conjuntos, línea).
   2. Cómo se parte una dirección en etiqueta / índice / desplazamiento.
   3. Códigos de las políticas configurables (escritura, asignación,
      reemplazo, riesgo RAW del write buffer) y la política de inclusión
      L1/L2 elegida por el grupo (NINE).
   4. Formato de una entrada del write buffer y de las solicitudes a L2.
   5. Las 4 etapas del acceso segmentado a caché según el libro.

 Nota de compatibilidad con Icarus Verilog 12:
   Igual que isa_defs.sv, este archivo solo declara localparam (nada de
   typedef ni function fuera de un módulo), porque Icarus no siempre los
   acepta en el ámbito de compilación. Lleva guarda de inclusión para que se
   pueda hacer `include "cache_defs.sv" desde varios módulos sin duplicar.
================================================================================
*/
`ifndef CACHE_DEFS_SV
`define CACHE_DEFS_SV


// ============================================================================
// 1. Geometría de la caché L1-D (valores fijados por el enunciado, 3.2.2)
// ============================================================================
//
//   Tamaño total ........ 4 KB
//   Asociatividad ....... 2 vías (2-way set associative)
//   Tamaño de línea ..... 32 bytes = 8 palabras de 32 bits
//
// De ahí salen, con las fórmulas del libro (sección 6.2.1 y 6.2.2):
//
//   Número de bloques   NB = Tcaché / Tbloque = 4096 / 32  = 128 bloques
//   Número de conjuntos NS = NB / n           = 128 / 2    =  64 conjuntos
//
// Es decir: la caché es una tabla de 64 filas (conjuntos) y cada fila tiene
// 2 "casillas" (vías). Cada casilla guarda una línea completa de 8 palabras.

localparam int L1D_SIZE_BYTES = 4096;                          // 4 KB
localparam int L1D_WAYS       = 2;                             // 2 vías
localparam int LINE_BYTES     = 32;                            // bytes por línea
localparam int WORD_BYTES     = 4;                             // bytes por palabra
localparam int LINE_WORDS     = LINE_BYTES / WORD_BYTES;       // 8 palabras por línea
localparam int L1D_LINES      = L1D_SIZE_BYTES / LINE_BYTES;   // 128 bloques
localparam int L1D_SETS       = L1D_LINES / L1D_WAYS;          //  64 conjuntos

// Una línea completa vista como un solo vector de bits (8 x 32 = 256 bits).
// La palabra i de la línea ocupa los bits [32*i+31 : 32*i].
localparam int LINE_W         = LINE_BYTES * 8;                // 256 bits

// Máscara de bytes de una línea: 1 bit por byte (32 bits). Sirve para decir
// qué bytes de la línea son válidos/escritos (ver el write buffer, punto 4).
localparam int LINE_MASK_W    = LINE_BYTES;                    // 32 bits


// ============================================================================
// 2. División de la dirección (figura 6.2 del libro)
// ============================================================================
//
// La memoria de datos (rtl/memory.sv) es de 64 KB y SOLO mira los 16 bits
// bajos de la dirección (los bits altos se ignoran). Para que la caché se
// comporte exactamente igual que esa memoria, también trabaja con 16 bits de
// dirección física. Si usáramos los 32 bits, dos direcciones que la memoria
// considera "la misma" (p. ej. 0x0000_0010 y 0x0001_0010) caerían en líneas
// distintas de la caché y el programa daría resultados diferentes.
//
// Dirección de 16 bits, partida en campos:
//
//    15        11 10         5 4      2 1    0
//   +------------+------------+--------+------+
//   |  Etiqueta  |   Índice   | Palabra| Byte |
//   |   5 bits   |   6 bits   | 3 bits |2 bits|
//   +------------+------------+--------+------+
//                              \______________/
//                           desplazamiento de bloque
//                                 (5 bits)
//
//   - Byte    (2 bits): qué byte dentro de la palabra     -> log2(4)  = 2
//   - Palabra (3 bits): qué palabra dentro de la línea    -> log2(8)  = 3
//   - Índice  (6 bits): en qué conjunto buscar            -> log2(64) = 6
//   - Etiqueta(5 bits): lo que sobra; se compara contra la etiqueta guardada
//                       para confirmar que la línea encontrada es la correcta.
//
// Ejemplo: dirección 0x1A3C = 0001 1010 0011 1100
//   etiqueta = 00011 (3), índice = 010001 (17), palabra = 111 (7), byte = 00

localparam int PADDR_W      = 16;                              // bits de dirección física
localparam int BYTE_OFF_W   = $clog2(WORD_BYTES);              // 2
localparam int WORD_OFF_W   = $clog2(LINE_WORDS);              // 3
localparam int BLOCK_OFF_W  = BYTE_OFF_W + WORD_OFF_W;         // 5
localparam int L1D_INDEX_W  = $clog2(L1D_SETS);                // 6
localparam int L1D_TAG_W    = PADDR_W - L1D_INDEX_W - BLOCK_OFF_W; // 5

// Posición de cada campo dentro de la dirección (para hacer addr[MSB:LSB]).
localparam int BYTE_OFF_LSB = 0;
localparam int BYTE_OFF_MSB = BYTE_OFF_LSB + BYTE_OFF_W  - 1;  // 1
localparam int WORD_OFF_LSB = BYTE_OFF_MSB + 1;                // 2
localparam int WORD_OFF_MSB = WORD_OFF_LSB + WORD_OFF_W  - 1;  // 4
localparam int INDEX_LSB    = WORD_OFF_MSB + 1;                // 5
localparam int INDEX_MSB    = INDEX_LSB    + L1D_INDEX_W - 1;  // 10
localparam int TAG_LSB      = INDEX_MSB + 1;                   // 11
localparam int TAG_MSB      = PADDR_W - 1;                     // 15

// Dirección "de línea": la dirección del primer byte de la línea (los 5 bits
// del desplazamiento de bloque en 0). Es lo que se le pide a L2 en un miss.
// Se obtiene como {addr[TAG_MSB:INDEX_LSB], 5'b0}.


// ============================================================================
// 3. Políticas configurables (enunciado 3.2.2 y 7.1.3)
// ============================================================================
//
// El enunciado deja que cada grupo elija estas políticas. Las dejamos como
// PARÁMETROS de la caché para poder comparar configuraciones sin reescribir
// código (lo pide la tarea de José y la comparación de la iteración 5).
//
// --- Política de escritura (qué pasa cuando un store ACIERTA) ---------------
//   WRITE_THROUGH: el store escribe en la L1-D y ADEMÁS se manda al write
//                  buffer hacia L2 de inmediato. L2 siempre está al día.
//   WRITE_BACK   : el store escribe solo en la L1-D y marca la línea como
//                  "sucia" (dirty). L2 se actualiza hasta que esa línea se
//                  desaloja. Menos tráfico, pero hay que vaciar la caché al
//                  final de la simulación (tarea compartida con Alejandro).
localparam logic WP_WRITE_THROUGH = 1'b0;
localparam logic WP_WRITE_BACK    = 1'b1;

// --- Política de asignación (qué pasa cuando un store FALLA) ----------------
//   NO_WRITE_ALLOC: el store no trae la línea; se manda directo al write
//                   buffer. Combinación típica con write-through.
//   WRITE_ALLOC   : primero se trae la línea desde L2 (como si fuera un load)
//                   y luego se escribe en ella. Combinación típica con
//                   write-back.
localparam logic AP_NO_WRITE_ALLOC = 1'b0;
localparam logic AP_WRITE_ALLOC    = 1'b1;

// --- Política de reemplazo (a qué vía se le quita el lugar en un miss) ------
//   LRU   : se reemplaza la vía usada hace más tiempo. Con 2 vías basta 1 bit
//           por conjunto que dice "cuál fue la última usada".
//   FIFO  : se reemplaza la vía que lleva más tiempo dentro de la caché,
//           aunque se haya usado hace poco. También 1 bit por conjunto.
//   RANDOM: se elige una vía "al azar" con un LFSR (generador pseudoaleatorio
//           muy barato en hardware).
localparam logic [1:0] RP_LRU    = 2'd0;
localparam logic [1:0] RP_FIFO   = 2'd1;
localparam logic [1:0] RP_RANDOM = 2'd2;

// --- Riesgo RAW en memoria del write buffer (enunciado 3.4) -----------------
// Si un load lee una dirección cuya escritura todavía está esperando en el
// write buffer (aún no llegó a L2), leer de L2 daría un dato viejo.
//   RAW_STALL  : se detiene el procesador hasta que el buffer drene esa
//                entrada. Correcto pero lento.
//   RAW_FORWARD: store-to-load forwarding, el dato se toma directamente del
//                buffer sin esperar (lo preferido en procesadores modernos).
localparam logic RAW_STALL   = 1'b0;
localparam logic RAW_FORWARD = 1'b1;

// --- Política de inclusión L1-D / L2 (enunciado 3.2.4, libro 6.2.4) --------
// DECISIÓN DEL GRUPO: NINE (Not Inclusive, Not Exclusive).
//
//   NINE significa que NO se impone ninguna relación entre lo que hay en
//   L1-D y lo que hay en L2: una línea puede estar en los dos niveles, solo
//   en uno, o en ninguno, según cómo se vayan dando los accesos.
//
//   ¿Qué implica para la L1-D?
//     - Cuando L2 desaloja una línea, NO le avisa a la L1-D. No hace falta
//       "invalidación hacia atrás" (backward invalidation): la copia en L1-D
//       sigue siendo válida y se puede seguir usando.
//     - Cuando la L1-D desaloja una línea limpia, simplemente la descarta.
//       Si está sucia (write-back), la manda a L2 por el write buffer, igual
//       que en cualquier otra política.
//     - Por lo tanto, la L1-D no necesita ninguna entrada de invalidación
//       desde L2, ni el contador de invalidaciones hacia atrás de la
//       sección 5.2 (ese contador solo es obligatorio con política inclusiva).
//
//   ¿Por qué NINE y no inclusiva?
//     La ventaja clásica de la inclusión (consultar solo L2 para saber si
//     algún núcleo tiene una línea) solo sirve con varios núcleos. Este
//     procesador tiene UN solo núcleo, así que esa ventaja no aplica, y NINE
//     es la opción más simple de implementar y verificar.
//
//   ¿Hay riesgo de datos viejos?
//     No. Con un solo núcleo, toda escritura pasa primero por la L1-D, así
//     que la copia de la L1-D es siempre la más nueva. Lo único que hay que
//     cuidar es que la unidad cripto (puerto B: vcr, camcon) también pase por
//     la caché, para que no escriba la RAM "por detrás" (tarea de Fabricio).
localparam logic [1:0] INCL_INCLUSIVE = 2'd0;
localparam logic [1:0] INCL_NINE      = 2'd1;
localparam logic [1:0] INCL_EXCLUSIVE = 2'd2;   // opcional, no se usa
localparam logic [1:0] L1L2_INCLUSION_POLICY = INCL_NINE;

// Valores por defecto propuestos (se discuten con el grupo, iteración 3):
//   write-back + write-allocate + LRU + forwarding, write buffer de 4 entradas.
localparam logic       L1D_DEFAULT_WRITE_POLICY = WP_WRITE_BACK;
localparam logic       L1D_DEFAULT_ALLOC_POLICY = AP_WRITE_ALLOC;
localparam logic [1:0] L1D_DEFAULT_REPL_POLICY  = RP_LRU;
localparam logic       L1D_DEFAULT_RAW_POLICY   = RAW_FORWARD;

// Tamaño del write buffer L1-D -> L2: el enunciado pide entre 2 y 8 entradas.
localparam int WB_DEPTH_DEFAULT = 4;
localparam int WB_DEPTH_MIN     = 2;
localparam int WB_DEPTH_MAX     = 8;


// ============================================================================
// 4. Formato de una entrada del write buffer y de las solicitudes a L2
// ============================================================================
//
// Para que el MISMO write buffer sirva con write-through y con write-back,
// cada entrada guarda una línea completa más una máscara de bytes:
//
//   +--------------------+----------------------+-------------------------+
//   | dirección de línea | máscara (32 bits)    | datos de la línea (256) |
//   |   (16 bits)        | 1 = ese byte se      |                         |
//   |                    |     escribe en L2    |                         |
//   +--------------------+----------------------+-------------------------+
//
//   - Write-through: cada store ocupa una entrada con solo 1 a 4 bits de la
//     máscara en 1 (los bytes que tocó el store, guardab o guardap).
//   - Write-back: una línea sucia desalojada ocupa una entrada con TODA la
//     máscara en 1 (se escriben los 32 bytes).
//
// Así L2 recibe siempre el mismo tipo de solicitud ("escribe estos bytes de
// esta línea") y el forwarding RAW es igual en ambos casos.

// Tipos de solicitud que la L1-D (o su write buffer) le hace a L2.
// Protocolo valid/ready: la solicitud se considera aceptada en el ciclo en
// que req_valid y req_ready están en 1 a la vez (acuerdo de la "primera
// semana": documento de interfaces del grupo).
localparam logic L2_REQ_READ_LINE  = 1'b0;   // traer una línea completa (fill)
localparam logic L2_REQ_WRITE_MASK = 1'b1;   // escribir los bytes marcados


// ============================================================================
// 5. Acceso segmentado a caché (libro, sección 6.3.1, figura 6.8)
// ============================================================================
//
// El libro divide un acceso a caché en 4 etapas:
//
//   Etapa 1  Cálculo de dirección   -> dirección efectiva = base + offset
//   Etapa 2  Desambiguación         -> separar etiqueta / índice / palabra
//   Etapa 3  Acceso a caché         -> leer arreglos de etiquetas y de datos
//                                      y decidir hit o miss
//   Etapa 4  Entrega de resultado   -> elegir la palabra, alinear el byte
//                                      (cargabai con extensión de signo)
//
// Restricción del proyecto: un HIT tiene que responder en el MISMO ciclo que
// la memoria actual (la regla N+3 y la latencia de los loads no pueden
// cambiar). Por eso, en el camino del hit, las 4 etapas están dentro de la
// etapa EX del procesador como lógica combinacional, separadas y
// etiquetadas en el código, y la etapa 3 usa ACCESO PARALELO (etiquetas y
// datos de las 2 vías se leen a la vez y un multiplexor elige la vía que
// acertó), que es la variante del libro con menor latencia (figura 6.9).
//
// La segmentación con registros entre etapas se usa en el camino del MISS
// (solicitud a L2, espera, llenado de la línea, reintento), que es donde el
// enunciado permite ciclos extra. Estos son los estados de ese camino:
localparam logic [2:0] L1D_ST_IDLE      = 3'd0;  // atendiendo hits normalmente
localparam logic [2:0] L1D_ST_EVICT     = 3'd1;  // mandar la línea sucia al write buffer
localparam logic [2:0] L1D_ST_REQ       = 3'd2;  // pedir la línea a L2 (valid/ready)
localparam logic [2:0] L1D_ST_WAIT      = 3'd3;  // esperar la respuesta de L2
localparam logic [2:0] L1D_ST_FILL      = 3'd4;  // escribir la línea nueva en la vía elegida
localparam logic [2:0] L1D_ST_RAW_WAIT  = 3'd5;  // (solo RAW_STALL) esperar que drene el buffer


`endif
