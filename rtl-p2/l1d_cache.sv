/*
================================================================================
 Módulo: l1d_cache

 Descripción:
 ------------------------------------------------------------------------------
 Caché de datos L1-D del procesador VLIW (bloque de José, Proyecto Grupal II).

   Tamaño 4 KB, 2 vías, líneas de 32 bytes (8 palabras), 64 conjuntos
   (enunciado 3.2.2; notas de clase 6.2.2, asociativa por conjuntos).
   Hit en 1 ciclo: el dato sale EN EL MISMO CICLO del acceso, igual que la
   memoria del proyecto 1 (rtl/memory.sv). Así no cambian la regla N+3, la
   latencia de las cargas ni nada de lo que ve el software.

 Módulos que usa:
   l1d_arrays        etiquetas, bits de validez, bits sucios y datos
   l1d_replacement   política de reemplazo (LRU, FIFO o RANDOM)
   l1d_write_buffer  write buffer FIFO hacia la L2 (stores o víctimas)

 Parámetros (códigos en cache_defs.sv; decisiones D3 a D9 de
 docs/decisiones-importantes.md):
   WRITE_POLICY  WP_WRITE_BACK o WP_WRITE_THROUGH (notas 6.2.3)
   INCL_POLICY   INCL_EXCLUSIVE o INCL_NINE (notas 6.2.4)
   ALLOC_POLICY  por defecto la combinación típica (notas 6.2.3):
                 write-allocate con write-back, no-write-allocate con
                 write-through
   REPL_POLICY   RP_LRU, RP_FIFO o RP_RANDOM
   RAW_POLICY    RAW_FORWARD o RAW_STALL (con exclusiva siempre se espera)
   WB_DEPTH      entradas del write buffer, 2 a 8
   L2_BUS_V2     1 = bus versión 2 (l2_gnt / l2_rvalid); 0 = bus anterior
                 (l2_ready)
 Combinaciones válidas: write-through + NINE, write-back + NINE y
 write-back + exclusiva. Las demás se rechazan con $fatal al inicio.

 TEMPORAL: mientras tb-p2/tb_perf_cache_l1d_k1a.sv (Javier) siga con el bus
 anterior y sin pasar WRITE_POLICY ni INCL_POLICY, los valores por defecto
 son los de la versión anterior: write-through + NINE + bus anterior (alias
 L1D_WRITE_POLICY y L1L2_INCLUSION_POLICY de cache_defs.sv). Cuando Javier lo
 actualice, otro commit pone por defecto write-back + exclusiva + bus
 versión 2 (L1D_DEFAULT_WRITE_POLICY, L1D_DEFAULT_INCL_POLICY) y borra los
 alias.


 ==============================================================================
 Qué hace cada política
 ==============================================================================

                          write-through + NINE   write-back + NINE    write-back + exclusiva
   store que acierta      L1-D y write buffer    L1-D, línea sucia    L1-D, línea sucia
   store que falla        según ALLOC_POLICY     según ALLOC_POLICY   según ALLOC_POLICY
   miss, hit en L2        la línea se copia      la línea se copia    la línea se MUEVE (la L2
                                                                      la invalida; l2_rdirty)
   la L1-D desaloja       se descarta            sucia: al buffer;    SIEMPRE al buffer, limpia
                                                 limpia: se descarta  o sucia (l2_wdirty)
   vaciado                drenar el buffer       limpiar las sucias   MOVER las sucias a la L2
                                                 y drenar             (se invalidan) y drenar

 Con exclusiva, una línea nunca está en la L1-D y en la L2 a la vez (notas
 6.2.4, L1 ∩ L2 = ∅): la L2 hace de caché víctima de la L1-D (notas 6.3.3).


 ==============================================================================
 Interfaz con el núcleo (docs/memory-interfaces.md, sección 2)
 ==============================================================================
   re, we, be, addr, wdata  el acceso de la LSU en EX (puerto A de memory.sv)
   rdata                    la PALABRA completa de addr. La LSU (rtl/lsu.sv)
                            elige el byte y le extiende el signo en cargabai.
   stall                    1 = el acceso no termina en este ciclo
                            (cache_stall).
 Reglas que se cumplen:
   - Mientras stall = 1 el núcleo está congelado y mantiene el acceso igual.
   - stall solo depende del acceso y de registros que cambian en el flanco
     positivo (las respuestas de la L2 salen de registros), así que está
     estable antes del flanco de bajada, cuando top lo toma.
   - Cada store escribe UNA sola vez: solo en el ciclo en que stall = 0.
   - Direcciones de 16 bits (64 KB), como memory.sv.
 Puerto B (vcr, camcon): lo junta Fabricio sobre este puerto único
 (rtl-p2/l1d_port_arbiter.sv, D17).


 ==============================================================================
 Interfaz con la L2 (cache_defs.sv, sección 4; D9)
 ==============================================================================
   Bus versión 2 (L2_BUS_V2 = 1):
     l2_req, l2_we, l2_addr, l2_wline, l2_be, l2_wdirty   petición
     l2_gnt                     la L2 aceptó la petición en este ciclo
     l2_rvalid, l2_rline, l2_rdirty   respuesta de una lectura, en orden
     Las escrituras terminan al ser aceptadas.
   Bus anterior (L2_BUS_V2 = 0): l2_ready hace de aceptación y, en una
   lectura, también de respuesta (la L2 acepta cuando ya terminó).
   En los dos, la petición se mantiene igual hasta que se acepta, y las
   salidas de la L2 salen de registros.


 ==============================================================================
 Vaciado (D16)
 ==============================================================================
   flush_req  (testbenches o la instrucción vaciarc) pedir que todo lo que
              la L1-D tiene de más llegue a la L2
   flush_done 1 cuando terminó; se mantiene mientras flush_req siga en 1.
   Write-through: solo hay que drenar el write buffer.
   Write-back: se recorren las 128 casillas (puerto B de los arreglos) y
   cada línea sucia se manda al write buffer; con NINE queda válida y
   limpia, con exclusiva se invalida (se MUEVE a la L2; si quedara válida
   estaría en los dos niveles). Después se drena el write buffer.
   Mientras dura, el núcleo espera (stall = 1 si accede). Bajar la L2 a la
   RAM le toca a la L2 (Alejandro), DESPUÉS de flush_done.


 ==============================================================================
 Organización interna: el "pipeline" de la caché
 ==============================================================================

 A) Camino del HIT: las 4 etapas de las notas (6.3.1, figura 6.8) dentro de
    EX, combinacionales, con acceso paralelo (figura 6.9).

      E1 dirección  ->  E2 desambiguación  ->  E3 acceso paralelo  ->  E4 resultado

 B) Camino del MISS: etapas desacopladas con handshake (enunciado 3.3):

      M1 Asignación  el miss queda registrado (MSHR, notas 6.3.4) hasta que
                     llega su línea. Esta versión es bloqueante (1 MSHR): el
                     núcleo espera. Los MSHR non-blocking para stores (D8)
                     van en el commit siguiente.
      M2 Solicitud   pide la línea.  valid = sin riesgo RAW que obligue a
                     esperar y, con write-back, con un lugar libre en el
                     write buffer para la víctima;  ready = l2_gnt.
      M3 Llenado     llega l2_rvalid: se elige la víctima EN ESE MOMENTO
                     (D8), sale al write buffer si hace falta, la línea
                     nueva (corregida con el write buffer si hay forwarding)
                     se escribe en su vía y el dato sale al núcleo en ese
                     mismo ciclo (bypass).

    En paralelo:
      D1 Drenado     la cabeza del write buffer se escribe en la L2 cuando el
                     bus está libre y no hay una lectura pendiente.

    Mientras hay una lectura pendiente no se drena el write buffer. Así:
      - el lugar que M2 reservó para la víctima sigue libre en M3;
      - la L2 responde la lectura antes de recibir cualquier escritura
        posterior, y el forwarding ve todas las entradas que la L2 todavía
        no tiene.

 Latencias (bus versión 2 con una L2 que acepta de inmediato y responde a
 los 8 ciclos):
   hit en L1-D ............................ 0 ciclos de stall
   miss en L1-D, hit en L2 ................ 8 (aunque la víctima esté sucia)
   miss en L1-D y en L2 ................... 8 + Tmem (lo agrega la L2)
   store que falla con no-write-allocate .. 0
   (más la espera del bus o de un lugar en el write buffer)

================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l1d_cache #(

    // TEMPORAL: valores por defecto de la versión anterior (ver arriba)
    parameter logic       WRITE_POLICY = L1D_WRITE_POLICY,
    parameter logic [1:0] INCL_POLICY  = L1L2_INCLUSION_POLICY,
    parameter logic       ALLOC_POLICY = (WRITE_POLICY == WP_WRITE_BACK) ? L1D_ALLOC_WITH_WB
                                                                         : L1D_ALLOC_WITH_WT,
    parameter logic [1:0] REPL_POLICY  = L1D_DEFAULT_REPL_POLICY,
    parameter logic       RAW_POLICY   = L1D_DEFAULT_RAW_POLICY,
    parameter int         WB_DEPTH     = WB_DEPTH_DEFAULT,
    parameter bit         L2_BUS_V2    = 1'b0      // TEMPORAL: bus anterior por defecto
) (

    input  logic          clk,          // reloj sin detener (no core_clk)
    input  logic          reset,

    // ------------------------------------------------------------------
    // Núcleo (puerto A, LSU)
    // ------------------------------------------------------------------
    input  logic          re,           // carga en EX (cargai, cargabai)
    input  logic          we,           // store en EX (guardap, guardab)
    input  logic [3:0]    be,           // bytes del store dentro de la palabra
    input  logic [31:0]   addr,         // dirección de byte
    input  logic [31:0]   wdata,        // dato ya colocado en la posición del byte
    output logic [31:0]   rdata,        // palabra completa de addr
    output logic          stall,        // cache_stall

    // ------------------------------------------------------------------
    // Vaciado
    // ------------------------------------------------------------------
    input  logic          flush_req,
    output logic          flush_done,

    // ------------------------------------------------------------------
    // L2 (los dos buses comparten las señales de la petición)
    // ------------------------------------------------------------------
    output logic                   l2_req,
    output logic                   l2_we,
    output logic [31:0]            l2_addr,
    output logic [LINE_W-1:0]      l2_wline,
    output logic [LINE_MASK_W-1:0] l2_be,
    output logic                   l2_wdirty,
    input  logic                   l2_gnt    = 1'b0,   // bus versión 2
    input  logic                   l2_rvalid = 1'b0,   // bus versión 2
    input  logic                   l2_rdirty = 1'b0,   // bus versión 2 (exclusiva)
    input  logic                   l2_ready  = 1'b0,   // bus anterior
    input  logic [LINE_W-1:0]      l2_rline,

    // ------------------------------------------------------------------
    // Eventos para los contadores (pulsos de 1 ciclo, reloj clk).
    // Los cuatro primeros se dan UNA vez por acceso, en el ciclo en que el
    // acceso termina; la clasificación hit/miss es la del primer ciclo.
    // ------------------------------------------------------------------
    output logic          ev_rd_hit,        // load que acertó
    output logic          ev_rd_miss,       // load que falló
    output logic          ev_wr_hit,        // store que acertó
    output logic          ev_wr_miss,       // store que falló
    output logic          ev_stall,         // ciclo con stall (cualquier causa)
    output logic          ev_wb_full_stall, // ciclo con stall porque el write buffer está lleno
    output logic          ev_raw_stall,     // ciclo con stall por riesgo RAW (o espera de línea)
    output logic          ev_raw_forward,   // llenado corregido con datos del write buffer
    output logic          ev_wb_push,       // entrada nueva en el write buffer
    output logic          ev_l2_read,       // inicio de una lectura de línea a la L2
    output logic          ev_l2_write,      // inicio de una escritura (drenado) a la L2
    output logic          ev_fill,          // llegó una línea de la L2 (con exclusiva: un movimiento)
    output logic          ev_victim_dirty,  // víctima sucia al write buffer
    output logic          ev_victim_clean   // víctima limpia al write buffer (solo exclusiva)
);


// ============================================================================
// Atajos y verificación de parámetros (solo en simulación)
// ============================================================================

localparam logic IS_WB      = (WRITE_POLICY == WP_WRITE_BACK);
localparam logic IS_EXCL    = (INCL_POLICY  == INCL_EXCLUSIVE);
localparam logic IS_WALLOC  = (ALLOC_POLICY == AP_WRITE_ALLOC);
// Forwarding solo con NINE: con exclusiva siempre se espera (D7)
localparam logic USE_FWD    = (RAW_POLICY == RAW_FORWARD) && !IS_EXCL;

initial begin

    if (INCL_POLICY != INCL_NINE && INCL_POLICY != INCL_EXCLUSIVE)
        $fatal(1, "l1d_cache: solo se implementan NINE y exclusiva (cache_defs.sv)");

    if (IS_EXCL && !IS_WB)
        $fatal(1, "l1d_cache: write-through + exclusiva no es posible (cada store llegaría a la L2)");
end


// ############################################################################
//  CAMINO DEL HIT (combinacional, dentro de EX)
// ############################################################################

// ============================================================================
// E1. Cálculo de dirección (la suma la hace la LSU; aquí se toman 16 bits)
// ============================================================================

logic [PADDR_W-1:0] paddr;
logic               acc;            // hay un acceso del núcleo en EX

assign paddr = addr[PADDR_W-1:0];
assign acc   = !reset && (re || we);


// ============================================================================
// E2. Desambiguación (notas 6.2.1, figura 6.2; cache_defs.sv, punto 2)
// ============================================================================

logic [L1D_TAG_W-1:0]   a_tag;      // etiqueta
logic [L1D_INDEX_W-1:0] a_index;    // conjunto
logic [WORD_OFF_W-1:0]  a_word;     // desplazamiento de palabra
logic [LINE_ADDR_W-1:0] a_line;     // dirección de línea = {etiqueta, índice}

assign a_tag   = paddr[TAG_MSB:TAG_LSB];
assign a_index = paddr[INDEX_MSB:INDEX_LSB];
assign a_word  = paddr[WORD_OFF_MSB:WORD_OFF_LSB];
assign a_line  = paddr[TAG_MSB:INDEX_LSB];


// ============================================================================
// E3. Acceso paralelo a los arreglos y comparación de etiquetas
//     (notas 6.3.1, figura 6.9; hardware como la figura 6.5)
// ============================================================================

// Señales del vaciado que usan el puerto B (ver al final)
logic                   flush_active;
logic                   flush_scanning;
logic [L1D_INDEX_W-1:0] scan_set;
logic                   scan_way;

// Puerto A: el acceso del núcleo
logic [L1D_WAYS-1:0]           rd_valid;
logic [L1D_WAYS*L1D_TAG_W-1:0] rd_tag;
logic [L1D_WAYS*LINE_W-1:0]    rd_line;

// Puerto B: la víctima del llenado (mismo conjunto que el acceso, porque la
// caché es bloqueante) o la casilla que revisa el vaciado
logic [L1D_INDEX_W-1:0]        rdb_set;
logic [L1D_WAYS-1:0]           rdb_valid;
logic [L1D_WAYS-1:0]           rdb_dirty;
logic [L1D_WAYS*L1D_TAG_W-1:0] rdb_tag;
logic [L1D_WAYS*LINE_W-1:0]    rdb_line;

assign rdb_set = flush_scanning ? scan_set : a_index;

// Puerto de escritura (se arma en "Escritura de los arreglos")
logic                   arr_we;
logic [L1D_INDEX_W-1:0] arr_wset;
logic                   arr_wway;
logic [L1D_TAG_W-1:0]   arr_wtag;
logic [LINE_W-1:0]      arr_wline;
logic                   arr_wdirty;
logic                   arr_wvalid;

l1d_arrays ARRAYS (
    .clk(clk),
    .reset(reset),
    .rd_set(a_index),
    .rd_valid(rd_valid),
    .rd_tag(rd_tag),
    .rd_line(rd_line),
    .rdb_set(rdb_set),
    .rdb_valid(rdb_valid),
    .rdb_dirty(rdb_dirty),
    .rdb_tag(rdb_tag),
    .rdb_line(rdb_line),
    .wr_en(arr_we),
    .wr_set(arr_wset),
    .wr_way(arr_wway),
    .wr_tag(arr_wtag),
    .wr_line(arr_wline),
    .wr_dirty(arr_wdirty),
    .wr_valid(arr_wvalid)
);

// Separar los datos de cada vía (puerto A)
logic [L1D_TAG_W-1:0] tag0, tag1;
logic [LINE_W-1:0]    line0, line1;

assign tag0  = rd_tag[0*L1D_TAG_W +: L1D_TAG_W];
assign tag1  = rd_tag[1*L1D_TAG_W +: L1D_TAG_W];
assign line0 = rd_line[0*LINE_W +: LINE_W];
assign line1 = rd_line[1*LINE_W +: LINE_W];

// Comparadores de etiqueta, uno por vía, trabajando a la vez
logic [L1D_WAYS-1:0] way_hit;
logic                hit;           // la línea está en la L1-D
logic                hit_way;       // en cuál vía
logic [LINE_W-1:0]   hit_line;      // la línea que acertó

assign way_hit[0] = rd_valid[0] && (tag0 == a_tag);
assign way_hit[1] = rd_valid[1] && (tag1 == a_tag);

assign hit      = |way_hit;
assign hit_way  = way_hit[1];
assign hit_line = hit_way ? line1 : line0;          // multiplexor de vía


// ============================================================================
// E4. Entrega del resultado (multiplexor de palabra, notas figura 6.4)
// ============================================================================

logic              fill_now;        // M3: llega la línea de la L2 en este ciclo
logic [LINE_W-1:0] fill_line;       // esa línea, ya corregida (forwarding)
logic              acc_present;     // la línea del acceso está disponible
logic [LINE_W-1:0] acc_line;

assign acc_present = hit || fill_now;
assign acc_line    = hit ? hit_line : fill_line;
assign rdata       = acc_line[a_word*32 +: 32];


// ============================================================================
// Store: bytes nuevos puestos sobre la línea
// ============================================================================
// be se corre a la posición de la palabra dentro de la línea (4 bits por
// palabra). st_mask y st_data también son la entrada del write buffer cuando
// el store va a la L2 (write-through, o miss sin asignación).

logic [LINE_MASK_W-1:0] st_mask;
logic [LINE_W-1:0]      st_data;
logic [LINE_W-1:0]      st_line;

assign st_mask = {{(LINE_MASK_W-4){1'b0}}, be} << (a_word * 4);
assign st_data = {LINE_WORDS{wdata}};

integer sb;
always @(*) begin

    st_line = acc_line;
    for (sb = 0; sb < LINE_BYTES; sb++)
        if (st_mask[sb])
            st_line[8*sb +: 8] = st_data[8*sb +: 8];
end


// ############################################################################
//  CAMINO DEL MISS (M1 a M3) Y DRENADO (D1)
// ############################################################################

// ---- Write buffer (notas 6.3.5) ----------------------------------------------
logic                   wb_push;
logic [LINE_ADDR_W-1:0] wb_push_line;
logic [LINE_MASK_W-1:0] wb_push_mask;
logic [LINE_W-1:0]      wb_push_data;
logic                   wb_push_dirty;
logic                   wb_pop;
logic [LINE_ADDR_W-1:0] wb_head_line;
logic [LINE_MASK_W-1:0] wb_head_mask;
logic [LINE_W-1:0]      wb_head_data;
logic                   wb_head_dirty;
logic                   wb_full;
logic                   wb_empty;
logic                   wb_fwd_hit;
logic [LINE_W-1:0]      wb_fwd_line;

l1d_write_buffer #(.DEPTH(WB_DEPTH)) WBUF (
    .clk(clk),
    .reset(reset),
    .push(wb_push),
    .push_line_addr(wb_push_line),
    .push_mask(wb_push_mask),
    .push_data(wb_push_data),
    .push_dirty(wb_push_dirty),
    .pop(wb_pop),
    .head_line_addr(wb_head_line),
    .head_mask(wb_head_mask),
    .head_data(wb_head_data),
    .head_dirty(wb_head_dirty),
    .full(wb_full),
    .empty(wb_empty),
    .count(),
    .fwd_line_addr(a_line),             // la línea que pide el acceso actual
    .fwd_base_line(l2_rline),           // tal como llega de la L2
    .fwd_hit(wb_fwd_hit),
    .fwd_mask(),
    .fwd_line(wb_fwd_line)
);


// ============================================================================
// ¿Este acceso necesita traer su línea de la L2?
// ============================================================================
//   - un load que falla, siempre;
//   - un store que falla, solo con write-allocate.

logic acc_eval;         // el acceso se atiende en este ciclo (no hay vaciado)
logic need_fill;

assign acc_eval  = acc && !flush_active;
assign need_fill = acc_eval && !hit && (re || IS_WALLOC);


// ============================================================================
// M2. Solicitud a la L2 / D1. Drenado del write buffer
// ============================================================================
//
// req_busy: hay una petición presentada que la L2 todavía no aceptó; se
//           mantiene igual hasta la aceptación (req_is_read dice cuál es).
// rd_pending: la L2 aceptó la lectura y falta su respuesta (bus versión 2).
//
// Riesgo RAW (notas 6.3.5, figura 6.13): si la línea que se va a pedir
// tiene entradas en el write buffer, la L2 todavía no las tiene.
//   NINE + RAW_FORWARD : se pide igual y se corrige en M3.
//   NINE + RAW_STALL y EXCLUSIVA : se espera a que esas entradas se drenen.
//     (Con exclusiva puede ser una víctima en camino: reenviarla dejaría la
//      línea en la L1-D y, al drenarse, también en la L2.)
//
// Con write-back, M2 además espera un lugar libre en el write buffer: en M3
// puede salir una víctima, y como no se drena mientras la lectura está
// pendiente, ese lugar sigue libre cuando llega la línea.

logic req_busy;
logic req_is_read;
logic rd_pending;

logic raw_block;        // hay que esperar al write buffer
logic read_ok;          // M2 puede empezar (valid)
logic start_read;       // M2 presenta una lectura en este ciclo
logic start_drain;      // D1 presenta una escritura en este ciclo
logic cur_read;         // la petición presente es una lectura
logic port_busy;        // el bus está ocupado: petición sin aceptar o lectura pendiente
logic gnt;              // la L2 acepta la petición presente
logic rsp;              // la L2 entrega la respuesta de la lectura
logic accept;

assign raw_block   = !USE_FWD && wb_fwd_hit;
assign read_ok     = !raw_block && !(IS_WB && wb_full);

assign start_read  = !req_busy && !rd_pending && need_fill && read_ok;
assign start_drain = !req_busy && !rd_pending && !start_read && !wb_empty;

assign cur_read    = req_busy ? req_is_read : start_read;
assign port_busy   = req_busy || rd_pending;

// Bus anterior: l2_ready acepta y, en una lectura, también responde
assign gnt         = L2_BUS_V2 ? l2_gnt    : l2_ready;
assign rsp         = L2_BUS_V2 ? l2_rvalid : (l2_ready && cur_read);

assign l2_req      = req_busy || start_read || start_drain;
assign accept      = l2_req && gnt;
assign l2_we       = !cur_read;
assign l2_addr     = cur_read ? {{(32-PADDR_W){1'b0}}, a_line,       {BLOCK_OFF_W{1'b0}}}
                              : {{(32-PADDR_W){1'b0}}, wb_head_line, {BLOCK_OFF_W{1'b0}}};
assign l2_wline    = wb_head_data;
assign l2_be       = cur_read ? '0 : wb_head_mask;
assign l2_wdirty   = !cur_read && wb_head_dirty;

assign wb_pop      = accept && !cur_read;   // la L2 aceptó la escritura de la cabeza

always @(posedge clk) begin

    if (reset) begin

        req_busy    <= 1'b0;
        req_is_read <= 1'b0;
        rd_pending  <= 1'b0;
    end
    else begin

        req_busy    <= l2_req && !gnt;                       // sigue esperando aceptación
        req_is_read <= cur_read;
        rd_pending  <= (rd_pending || (accept && cur_read)) && !rsp;
    end
end


// ============================================================================
// M3. Llenado (y respuesta en el mismo ciclo)
// ============================================================================
// Llegó la línea. Con forwarding se le ponen encima los bytes que siguen en
// el write buffer. Con exclusiva llega además l2_rdirty: la línea se movió
// desde la L2 y conserva su bit sucio.

logic fill_dirty_in;

assign fill_now      = rsp && (rd_pending || (accept && cur_read));
assign fill_line     = USE_FWD ? wb_fwd_line : l2_rline;
assign fill_dirty_in = IS_EXCL && l2_rdirty;


// ---- Elección de la víctima, en el momento del llenado (D8) ---------------
// Primero una vía vacía; si las dos están ocupadas, la política de
// reemplazo (notas 6.2.3). Se lee del puerto B, que en este momento mira el
// conjunto del acceso.

logic repl_victim;
logic repl_touch;
logic repl_touch_way;

logic                 v_way;
logic                 v_valid;
logic                 v_dirty;
logic [L1D_TAG_W-1:0] v_tag;
logic [LINE_W-1:0]    v_line;
logic                 victim_push;  // la víctima sale al write buffer

assign v_way   = !rdb_valid[0] ? 1'b0 :
                 !rdb_valid[1] ? 1'b1 :
                                 repl_victim;
assign v_valid = rdb_valid[v_way];
assign v_dirty = rdb_dirty[v_way];
assign v_tag   = rdb_tag [v_way*L1D_TAG_W +: L1D_TAG_W];
assign v_line  = rdb_line[v_way*LINE_W    +: LINE_W];

// Con exclusiva sale toda víctima válida; con NINE + write-back solo las
// sucias; con write-through nunca hay víctimas sucias.
assign victim_push = fill_now && v_valid && (IS_EXCL || v_dirty);

l1d_replacement #(.REPL_POLICY(REPL_POLICY)) REPL (
    .clk(clk),
    .reset(reset),
    .lookup_set(a_index),
    .victim_way(repl_victim),
    .touch(repl_touch),
    .touch_set(a_index),
    .touch_way(repl_touch_way),
    .fill(fill_now),
    .fill_set(a_index),
    .fill_way(v_way)
);


// ############################################################################
//  TERMINACIÓN DEL ACCESO Y STALL
// ############################################################################
//
// Load : termina cuando su línea está presente (hit, o llenado en este ciclo).
// Store: termina cuando su línea está presente (o es un miss sin asignación)
//        y, si además va al write buffer, hay espacio.
// El store va al write buffer con write-through (siempre) o cuando falla
// sin asignación (con write-back también: no tiene línea donde quedarse).

logic st_to_wb;
logic complete;

assign st_to_wb = we && (!IS_WB || !acc_present);

always @(*) begin

    if (!acc_eval)
        complete = 1'b0;
    else if (re)
        complete = acc_present;
    else
        complete = (acc_present || !IS_WALLOC) && !(st_to_wb && wb_full);
end

assign stall = acc && !complete;


// ============================================================================
// Entrada del write buffer (una sola fuente por ciclo)
// ============================================================================
//   - víctima (M3): línea completa con su bit sucio;
//   - store: sus bytes (bit sucio = write-back: dato más nuevo que la RAM);
//   - vaciado: línea sucia completa.
// Nunca coinciden: las víctimas solo salen en M3, y en ese ciclo un store
// que termina no va al buffer (con write-back está presente; con
// write-through no hay víctimas); el vaciado ocurre con el núcleo detenido.

logic store_push;
logic flush_push;

assign store_push = complete && st_to_wb;

always @(*) begin

    wb_push       = victim_push || store_push || flush_push;
    wb_push_line  = a_line;
    wb_push_mask  = st_mask;
    wb_push_data  = st_data;
    wb_push_dirty = IS_WB;

    if (victim_push) begin
        wb_push_line  = {v_tag, a_index};
        wb_push_mask  = '1;
        wb_push_data  = v_line;
        wb_push_dirty = v_dirty;
    end
    else if (flush_push) begin
        wb_push_line  = {rdb_tag[scan_way*L1D_TAG_W +: L1D_TAG_W], scan_set};
        wb_push_mask  = '1;
        wb_push_data  = rdb_line[scan_way*LINE_W +: LINE_W];
        wb_push_dirty = 1'b1;
    end
end


// ============================================================================
// Escritura de los arreglos (un solo puerto, por prioridad)
// ============================================================================
//   - M3 llenado: la línea nueva en la vía de la víctima. Si un store
//     termina en este mismo ciclo, ya va con sus bytes; queda sucia si la
//     línea llegó sucia (exclusiva) o si es un store con write-back.
//   - Store que acierta: los bytes nuevos; con write-back la línea queda
//     sucia.
//   - Vaciado: la línea que se mandó a la L2 queda limpia (NINE) o se
//     invalida (exclusiva: se movió).

always @(*) begin

    arr_we     = 1'b0;
    arr_wset   = a_index;
    arr_wway   = v_way;
    arr_wtag   = a_tag;
    arr_wline  = fill_line;
    arr_wdirty = 1'b0;
    arr_wvalid = 1'b1;

    if (fill_now) begin
        arr_we     = 1'b1;
        arr_wway   = v_way;
        arr_wline  = (we && complete) ? st_line : fill_line;
        arr_wdirty = fill_dirty_in || (we && complete && IS_WB);
    end
    else if (we && complete && hit) begin
        arr_we     = 1'b1;
        arr_wway   = hit_way;
        arr_wline  = st_line;
        arr_wdirty = IS_WB;
    end
    else if (flush_push) begin
        arr_we     = 1'b1;
        arr_wset   = scan_set;
        arr_wway   = scan_way;
        arr_wtag   = rdb_tag [scan_way*L1D_TAG_W +: L1D_TAG_W];
        arr_wline  = rdb_line[scan_way*LINE_W    +: LINE_W];
        arr_wdirty = 1'b0;
        arr_wvalid = !IS_EXCL;
    end
end


// ============================================================================
// Acceso en curso (para clasificar hit/miss una sola vez por acceso)
// ============================================================================

logic acc_busy;
logic acc_was_miss;
logic first_cycle;
logic is_miss;

assign first_cycle = !acc_busy;
assign is_miss     = first_cycle ? !hit : acc_was_miss;

always @(posedge clk) begin

    if (reset) begin

        acc_busy     <= 1'b0;
        acc_was_miss <= 1'b0;
    end
    else if (acc_eval && !complete) begin

        acc_busy <= 1'b1;
        if (first_cycle)
            acc_was_miss <= !hit;
    end
    else if (complete)
        acc_busy <= 1'b0;
end


// Actualización de LRU: el acceso terminó usando la línea de esa vía
assign repl_touch     = complete && acc_present;
assign repl_touch_way = hit ? hit_way : v_way;


// ############################################################################
//  VACIADO (D16)
// ############################################################################
//
//   FL_IDLE  -> esperando flush_req; empieza cuando no hay ningún miss ni
//               acceso a medias.
//   FL_SCAN  -> (solo write-back) recorre las 128 casillas por el puerto B;
//               cada línea válida y sucia va al write buffer.
//   FL_DRAIN -> espera a que el write buffer quede vacío y el bus libre.
//   FL_DONE  -> flush_done = 1 hasta que bajen flush_req.

localparam logic [1:0] FL_IDLE  = 2'd0;
localparam logic [1:0] FL_SCAN  = 2'd1;
localparam logic [1:0] FL_DRAIN = 2'd2;
localparam logic [1:0] FL_DONE  = 2'd3;

logic [1:0]           fl_state;
logic [L1D_INDEX_W:0] scan_ptr;     // {conjunto, vía}: 0 .. 127
logic                 scan_dirty;
logic                 scan_last;

assign flush_active   = (fl_state != FL_IDLE);
assign flush_scanning = (fl_state == FL_SCAN);
assign flush_done     = (fl_state == FL_DONE);

assign scan_set   = scan_ptr[L1D_INDEX_W:1];
assign scan_way   = scan_ptr[0];
assign scan_dirty = rdb_valid[scan_way] && rdb_dirty[scan_way];
assign scan_last  = (scan_ptr == {(L1D_INDEX_W+1){1'b1}});

assign flush_push = flush_scanning && scan_dirty && !wb_full;

always @(posedge clk) begin

    if (reset) begin

        fl_state <= FL_IDLE;
        scan_ptr <= '0;
    end
    else begin

        case (fl_state)

            FL_IDLE:
                if (flush_req && !rd_pending && !acc_busy && !(acc && !complete)) begin
                    fl_state <= IS_WB ? FL_SCAN : FL_DRAIN;
                    scan_ptr <= '0;
                end

            FL_SCAN:
                if (!scan_dirty || flush_push) begin
                    if (scan_last)
                        fl_state <= FL_DRAIN;
                    scan_ptr <= scan_ptr + 1'b1;
                end

            FL_DRAIN:
                if (wb_empty && !port_busy)
                    fl_state <= FL_DONE;

            FL_DONE:
                if (!flush_req)
                    fl_state <= FL_IDLE;

            default:
                fl_state <= FL_IDLE;
        endcase
    end
end


// ############################################################################
//  EVENTOS
// ############################################################################

assign ev_rd_hit        = complete && re && !is_miss;
assign ev_rd_miss       = complete && re &&  is_miss;
assign ev_wr_hit        = complete && we && !re && !is_miss;
assign ev_wr_miss       = complete && we && !re &&  is_miss;
assign ev_stall         = stall;
assign ev_wb_full_stall = stall && acc_eval &&
                          ((we && st_to_wb && wb_full && (acc_present || !IS_WALLOC)) ||
                           (need_fill && !raw_block && IS_WB && wb_full && !req_busy && !rd_pending));
assign ev_raw_stall     = stall && need_fill && raw_block && !req_busy && !rd_pending;
assign ev_raw_forward   = fill_now && USE_FWD && wb_fwd_hit;
assign ev_wb_push       = wb_push;
assign ev_l2_read       = start_read;
assign ev_l2_write      = start_drain;
assign ev_fill          = fill_now;
assign ev_victim_dirty  = victim_push &&  v_dirty;
assign ev_victim_clean  = victim_push && !v_dirty;


// ############################################################################
//  Verificaciones de simulación
// ############################################################################

always @(posedge clk) begin

    if (!reset) begin

        if (re && we)
            $error("l1d_cache: load y store a la vez en el mismo puerto");

        if (victim_push && store_push)
            $error("l1d_cache: víctima y store al write buffer en el mismo ciclo");

        if (L2_BUS_V2 && l2_rvalid && !(rd_pending || (accept && cur_read)))
            $error("l1d_cache: l2_rvalid sin una lectura pendiente");
    end
end


endmodule
