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
   3. Códigos y valores por defecto de las políticas configurables
      (escritura, asignación, reemplazo, inclusión NINE o exclusiva, riesgo
      RAW, tamaño del write buffer y número de MSHR).
   4. Formato de una entrada del write buffer y bus L1-D <-> L2 (versión 2).
   5. Las etapas del acceso segmentado a caché (notas de clase 6.3.1).

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
// De ahí salen, con las fórmulas de las notas de clase (sección 6.2.1 y 6.2.2):
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
// 2. División de la dirección (notas de clase, figura 6.2)
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
// 3. Políticas configurables (enunciado 3.2.2, 3.2.4, 7.1.3 y 7.1.4;
//    docs/decisiones-importantes.md, decisiones D3 a D8)
// ============================================================================
//
// Todas son PARÁMETROS de l1d_cache.sv, para comparar configuraciones sin
// reescribir código (iteración 5, rúbrica 3b y 3c). Aquí están los códigos y
// los valores por defecto.
//
// --- Política de escritura (qué pasa cuando un store ACIERTA) ---------------
// (Notas de clase, sección 6.2.3)
//   WRITE_THROUGH: el store escribe en la L1-D y ADEMÁS va al write buffer
//                  hacia la L2. La L1-D queda siempre limpia.
//   WRITE_BACK   : el store escribe solo en la L1-D y marca la línea como
//                  "sucia" (dirty). La L2 se entera cuando la línea sale de la
//                  L1-D (por el write buffer) o en el vaciado.
// Por defecto WRITE_BACK (D4): es la única que permite la política exclusiva
// (con write-through cada store iría a la L2, que no tiene esa línea porque
// está en la L1-D). Write-through queda como parámetro para comparar.
localparam logic WP_WRITE_THROUGH = 1'b0;
localparam logic WP_WRITE_BACK    = 1'b1;
localparam logic L1D_DEFAULT_WRITE_POLICY = WP_WRITE_BACK;

// --- Política de asignación (qué pasa cuando un store FALLA) ----------------
// (Notas de clase, sección 6.2.3)
//   NO_WRITE_ALLOC: el store no trae la línea; va directo al write buffer.
//   WRITE_ALLOC   : se trae la línea desde la L2 y luego se escribe en ella.
// D5: cada política de escritura va con su combinación típica (notas 6.2.3):
// write-back con write-allocate y write-through con no-write-allocate.
// l1d_cache.sv elige el valor por defecto según su WRITE_POLICY.
localparam logic AP_NO_WRITE_ALLOC = 1'b0;
localparam logic AP_WRITE_ALLOC    = 1'b1;
localparam logic L1D_ALLOC_WITH_WB = AP_WRITE_ALLOC;
localparam logic L1D_ALLOC_WITH_WT = AP_NO_WRITE_ALLOC;

// --- Política de reemplazo (a qué vía se le quita el lugar en un miss) ------
// (Notas de clase, sección 6.2.3; enunciado 7.1.3)
//   LRU   : se reemplaza la vía usada hace más tiempo. Con 2 vías basta 1 bit
//           por conjunto que dice "cuál fue la última usada".
//   FIFO  : se reemplaza la vía que lleva más tiempo dentro de la caché,
//           aunque se haya usado hace poco. También 1 bit por conjunto.
//   RANDOM: se elige una vía "al azar" con un LFSR (generador pseudoaleatorio
//           muy barato en hardware).
// Por defecto LRU (D6).
localparam logic [1:0] RP_LRU    = 2'd0;
localparam logic [1:0] RP_FIFO   = 2'd1;
localparam logic [1:0] RP_RANDOM = 2'd2;
localparam logic [1:0] L1D_DEFAULT_REPL_POLICY = RP_LRU;

// --- Política de inclusión L1-D / L2 (enunciado 3.2.4, notas 6.2.4) --------
//   NINE      : no se impone ninguna relación entre L1-D y L2; una línea puede
//               estar en los dos niveles (notas, figura 6.6, tercer caso).
//               La L2 nunca invalida a la L1-D (sin invalidación hacia atrás,
//               figura 6.7). La L1-D descarta las víctimas limpias y manda
//               al write buffer solo las sucias.
//   EXCLUSIVE : crédito extra, L1-D ∩ L2 = ∅ (D3). Un acierto en la L2 ante
//               un miss en la L1-D MUEVE la línea (la L2 la invalida) y TODA
//               víctima de la L1-D, limpia o sucia, va a la L2 en vez de
//               descartarse, como una caché víctima (notas 6.3.3). La línea
//               viaja con su bit sucio (l2_rdirty, l2_wdirty; sección 4).
//               Ventaja: caben 4 + 16 = 20 KB distintos en vez de 16 KB.
//   INCLUSIVE : no se implementa (necesitaría invalidación hacia atrás).
//
// Combinaciones válidas (l1d_cache.sv rechaza las demás con $fatal):
//   write-through + NINE,  write-back + NINE,  write-back + EXCLUSIVE.
// Write-through + EXCLUSIVE no es posible: cada store llegaría a la L2 y la
// línea quedaría en los dos niveles.
//
// Por defecto NINE, mientras el profesor no apruebe la exclusiva y no esté la
// L2 exclusiva de Alejandro (decisiones-importantes.md, 4.1: si no se
// aprueba, NINE queda por defecto). Cuando ambas cosas estén, se cambia
// L1D_DEFAULT_INCL_POLICY a INCL_EXCLUSIVE.
localparam logic [1:0] INCL_INCLUSIVE = 2'd0;
localparam logic [1:0] INCL_NINE      = 2'd1;
localparam logic [1:0] INCL_EXCLUSIVE = 2'd2;
localparam logic [1:0] L1D_DEFAULT_INCL_POLICY = INCL_NINE;

// --- Riesgo RAW en memoria del write buffer (enunciado 3.4, notas 6.3.5) ----
// Si un miss pide a la L2 una línea que todavía tiene escrituras esperando en
// el write buffer, la L2 devolvería datos viejos (notas, figura 6.13).
//   RAW_STALL  : la solicitud espera a que el buffer drene esas entradas.
//   RAW_FORWARD: store-to-load forwarding: la línea que llega de la L2 se
//                corrige con los bytes del buffer, sin esperar.
// Con NINE se usa RAW_POLICY (por defecto forwarding). Con EXCLUSIVE la L1-D
// SIEMPRE espera (D7): si reenviara una víctima que todavía está en el
// buffer, la línea quedaría en la L1-D y, al drenarse la entrada, también en
// la L2, rompiendo la exclusividad.
localparam logic RAW_STALL   = 1'b0;
localparam logic RAW_FORWARD = 1'b1;
localparam logic L1D_DEFAULT_RAW_POLICY = RAW_FORWARD;

// --- Write buffer L1-D -> L2 (enunciado 3.4: entre 2 y 8 entradas) ----------
localparam int WB_DEPTH_DEFAULT = 4;
localparam int WB_DEPTH_MIN     = 2;
localparam int WB_DEPTH_MAX     = 8;

// --- Misses pendientes: MSHR (notas 6.3.4; enunciado 7.1.4, D8) -------------
// Crédito extra "non-blocking": varios misses en curso. Como el hardware no
// puede revisar si el dato de una carga ya llegó (sin scoreboarding,
// enunciado 3.1.1), solo los STORES que fallan siguen sin detener al núcleo;
// cada uno ocupa un MSHR hasta que llega su línea. Una carga que falla sigue
// deteniendo el bundle. N_MSHR = 1 es la caché bloqueante (para comparar).
localparam int L1D_N_MSHR_DEFAULT = 2;
localparam int L1D_N_MSHR_MIN     = 1;
localparam int L1D_N_MSHR_MAX     = 4;

// --- TEMPORAL: nombres de la versión write-through + NINE -------------------
// Los usa el l1d_cache.sv actual mientras pasa a los parámetros de arriba.
// Se BORRAN en el mismo commit en que l1d_cache.sv deje de usarlos.
localparam logic       L1D_WRITE_POLICY         = WP_WRITE_THROUGH;
localparam logic [1:0] L1L2_INCLUSION_POLICY    = INCL_NINE;
localparam logic       L1D_DEFAULT_ALLOC_POLICY = AP_NO_WRITE_ALLOC;


// ============================================================================
// 4. Entradas del write buffer y bus L1-D <-> L2 (versión 2, D9)
// ============================================================================
//
// Cada entrada del write buffer tiene el mismo formato que una escritura en
// el bus hacia la L2: "escribe estos bytes de esta línea".
//
//   +--------------------+----------------------+-----------------+-------+
//   | dirección de línea | máscara (32 bits)    | datos (256)     | sucia |
//   | (11 bits, [15:5])  | 1 = ese byte se      | solo cuentan los| (1)   |
//   |                    |     escribe en L2    | bytes marcados  |       |
//   +--------------------+----------------------+-----------------+-------+
//
//   - Store con write-through: 1 a 4 bytes marcados (guardab o guardap).
//   - Víctima de la L1-D (write-back): los 32 bytes marcados. Con NINE solo
//     salen las víctimas sucias; con EXCLUSIVE salen todas y "sucia" dice a
//     la L2 si la línea tiene datos que la RAM no tiene (l2_wdirty).

// Ancho de la dirección de línea: 16 - 5 = 11 bits (addr[15:5]).
localparam int LINE_ADDR_W = PADDR_W - BLOCK_OFF_W;

// Bus versión 2 (reemplaza la sección 5 de docs/memory-interfaces.md):
//
//   Señal       Hacia  Bits  Significado
//   l2_req      L2      1    hay una petición
//   l2_gnt      L1-D    1    la L2 la aceptó en este ciclo (l2_req y l2_gnt en 1)
//   l2_we       L2      1    L2_REQ_READ_LINE o L2_REQ_WRITE_MASK
//   l2_addr     L2     32    dirección alineada a 32 bytes
//   l2_wline    L2    256    datos de la línea (palabra 0 en los bits bajos)
//   l2_be       L2     32    bytes válidos de l2_wline
//   l2_wdirty   L2      1    la víctima que se escribe está sucia (exclusiva)
//   l2_rvalid   L1-D    1    un ciclo en 1 con la respuesta de una lectura, en orden
//   l2_rline    L1-D  256    línea leída
//   l2_rdirty   L1-D    1    la línea que se mueve estaba sucia en la L2 (exclusiva)
//
// La aceptación (l2_gnt) va separada de la respuesta (l2_rvalid), así una L2
// segmentada puede aceptar una petición por ciclo. Las escrituras terminan
// al ser aceptadas y no tienen respuesta. Las salidas de la L2 salen de
// registros (stall de la L1-D solo depende de registros).
localparam logic L2_REQ_READ_LINE  = 1'b0;   // traer una línea completa (fill)
localparam logic L2_REQ_WRITE_MASK = 1'b1;   // escribir los bytes marcados


// ============================================================================
// 5. Acceso segmentado a caché (notas de clase, sección 6.3.1, figura 6.8)
// ============================================================================
//
// Las notas dividen un acceso a caché en 4 etapas:
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
// acertó), que es la variante de las notas con menor latencia (figura 6.9:
// paralelo frente a serie).
//
// El camino del MISS sí se segmenta (pipeline interno de la caché, mejora
// opcional del enunciado 3.3). Sus etapas se pasan el trabajo con handshake
// valid/ready:
//
//   M1 Asignación  ocupa un MSHR (notas 6.3.4) con la línea que falta. Un
//                  store que falla deja ahí sus bytes y el núcleo sigue
//                  (non-blocking); otro store a la misma línea se mezcla en
//                  ese MSHR. Una carga que falla detiene el bundle.
//   M2 Solicitud   pide la línea a la L2 hasta que l2_gnt la acepta.
//                  valid = sin riesgo RAW que obligue a esperar,
//                  ready = l2_gnt.
//   M3 Llenado     llega l2_rvalid (en orden): se elige la víctima en ese
//                  momento (dos MSHR del mismo conjunto no eligen la misma
//                  vía), la víctima sale al write buffer si hace falta
//                  (sucia con NINE; siempre con EXCLUSIVE), se mezclan los
//                  bytes de los stores del MSHR y se escribe la línea. Si una
//                  carga la estaba esperando, el dato sale al núcleo en ese
//                  mismo ciclo (bypass).
//
// En paralelo, sin detener al núcleo:
//   D1 Drenado     la entrada más vieja del write buffer se escribe en la L2
//                  cuando el bus está libre y M2 no lo necesita (las lecturas
//                  tienen prioridad).
//
// Vaciado (D16), cadena completa:
//   MSHR vacíos -> la L1-D manda sus líneas sucias al write buffer -> write
//   buffer vacío -> la L2 manda las suyas al eviction buffer -> eviction
//   buffer vacío -> flush_done. Las dos primeras partes son de la L1-D.


`endif
