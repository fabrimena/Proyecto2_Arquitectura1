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
   l1d_arrays        etiquetas, bits de validez y datos de las 2 vías
   l1d_replacement   política de reemplazo (LRU, FIFO o RANDOM)
   l1d_write_buffer  write buffer FIFO hacia la L2, con forwarding RAW

 Políticas (decisiones del grupo y parámetros, códigos en cache_defs.sv):
   Escritura     WRITE-THROUGH, fija (notas 6.2.3). Todo store se escribe en
                 la L1-D (si la línea está) y además va al write buffer. La
                 L1-D queda siempre limpia: no hay bit sucio ni desalojos que
                 escribir; la línea que sale se descarta.
   Inclusión     NINE, fija (notas 6.2.4). La L2 nunca invalida a la L1-D.
   ALLOC_POLICY  AP_NO_WRITE_ALLOC (por defecto) o AP_WRITE_ALLOC
   REPL_POLICY   RP_LRU (por defecto), RP_FIFO o RP_RANDOM
   RAW_POLICY    RAW_FORWARD (por defecto) o RAW_STALL (notas 6.3.5)
   WB_DEPTH      entradas del write buffer, 2 a 8 (por defecto 4)


 ==============================================================================
 Interfaz con el núcleo (docs/memory-interfaces.md, sección 2)
 ==============================================================================
   re, we, be, addr, wdata  el acceso de la LSU en EX (puerto A de memory.sv)
   rdata                    la PALABRA completa de addr. Igual que memory.sv,
                            la L1-D no elige el byte: la LSU (rtl/lsu.sv) ya
                            elige el byte y le extiende el signo en cargabai.
   stall                    1 = el acceso no termina en este ciclo (es el
                            cache_stall del documento de interfaces).
 Reglas que se cumplen:
   - Mientras stall = 1 el núcleo está congelado y mantiene el acceso igual.
   - stall solo depende del acceso y de registros que cambian en el flanco
     positivo (incluido l2_ready, que la L2 debe sacar de un registro), así
     que está estable antes del flanco de bajada, cuando top lo toma.
   - Cada store escribe UNA sola vez: solo en el ciclo en que stall = 0.
   - Direcciones de 16 bits (64 KB), como memory.sv: los bits altos se
     ignoran, y los 2 bits bajos no importan para elegir la palabra.

 Puerto B (unidad cripto: vcr y camcon): no está en este módulo. Según la
 división de tareas, hacerlo pasar por la jerarquía es trabajo de Fabricio
 en la integración (docs/memory-interfaces.md, sección 8): su módulo
 atiende los dos puertos uno después del otro sobre este puerto único.


 ==============================================================================
 Interfaz con la L2 (docs/memory-interfaces.md, sección 5)
 ==============================================================================
   l2_req    hay una petición; se mantiene en 1 hasta l2_ready
   l2_we     0 = leer una línea completa, 1 = escribir los bytes de l2_be
   l2_addr   dirección alineada a 32 bytes
   l2_wline  datos de la línea (palabra 0 en los bits bajos)
   l2_be     1 bit por byte de l2_wline (32 bits)
   l2_ready  1 durante un ciclo cuando la L2 terminó (en una lectura,
             l2_rline es válido en ese ciclo). Debe salir de un registro.
   l2_rline  la línea leída
 Una petición a la vez. La L2 tarda 8 ciclos en un hit (Alejandro).


 ==============================================================================
 Vaciado (docs/memory-interfaces.md, sección 7)
 ==============================================================================
   flush_req  (solo testbenches) pedir que todo lo escrito llegue a la L2
   flush_done 1 cuando el write buffer quedó vacío y el bus está libre. Se
              mantiene mientras flush_req siga en 1.
 Con write-through esto es todo lo que hace falta: la L1-D no tiene nada
 que la L2 no tenga, salvo lo que espera en el write buffer. No se recorre
 la L1-D. Mientras dura el vaciado el núcleo queda detenido (stall = 1 si
 accede); las líneas de la L1-D siguen válidas. Bajar la L2 a la RAM es la
 otra mitad del vaciado y le toca a la L2 (Alejandro), DESPUÉS de
 flush_done.


 ==============================================================================
 Organización interna: el "pipeline" de la caché
 ==============================================================================

 A) Camino del HIT: las 4 etapas de las notas (6.3.1, figura 6.8) dentro de
    EX. Son lógica combinacional en cadena, separadas y rotuladas en el
    código. No llevan registros entre ellas porque el hit tiene que
    responder en el mismo ciclo (restricción del proyecto), y la etapa E3 usa
    acceso paralelo (notas, figura 6.9).

      E1 dirección  ->  E2 desambiguación  ->  E3 acceso paralelo  ->  E4 resultado
      (la LSU suma      (etiqueta, índice,     (las 2 vías a la vez,    (elegir la
       base + offset)    palabra)               comparar etiquetas)      palabra)

 B) Camino del MISS: etapas desacopladas con handshake valid/ready
    (mejora OPCIONAL del enunciado 3.3: pipeline interno de la caché):

      M1 Asignación  registra el miss en el MSHR (Miss Status Holding
                     Register, notas 6.3.4): qué vía se va a reemplazar. Así
                     la víctima no cambia mientras se espera. La línea que
                     había ahí se descarta: con write-through está limpia.
      M2 Solicitud   pide la línea a la L2.  valid = sin riesgo RAW que
                     obligue a esperar (RAW_STALL),  ready = bus libre.
      M3 Llenado     llega l2_ready: la línea se corrige con el write buffer
                     (forwarding, notas figura 6.13), se escribe en la vía
                     elegida y, en ese mismo ciclo, se le entrega el dato al
                     núcleo (bypass).

    En paralelo, sin detener al núcleo:
      D1 Drenado     la cabeza del write buffer se escribe en la L2 cuando el
                     bus está libre y M2 no lo necesita (las lecturas tienen
                     prioridad: el núcleo las está esperando).

    La caché es bloqueante (1 MSHR, notas 6.3.4): el núcleo VLIW se congela
    en cada miss, así que nunca llega otro acceso mientras se atiende uno.

 Latencias que resultan (contadas desde el ciclo del acceso):
   hit en L1-D (load o store) ......... 0 ciclos de stall
   miss en L1-D, hit en L2 ............. 8 ciclos de stall (+8)
   miss en L1-D y en L2 ................ 8 + Tmem (lo agrega la L2)
   store que falla con no-write-allocate 0 ciclos (va directo al buffer)
   (más la espera del bus si en ese momento se estaba drenando una entrada,
    o la espera de un lugar si el write buffer está lleno)

 Ejemplo de un load que falla con la L2 respondiendo en 8 ciclos:

   ciclo     0      1      2   ...   7      8
   stall     1      1      1   ...   1      0     <- el núcleo avanza en el 8
   l2_req    1      1      1   ...   1      1
   l2_ready  0      0      0   ...   0      1     <- M3: llenado + bypass
   MSHR      -      v      v   ...   v      v     (se libera en el flanco del 8)

================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l1d_cache #(

    parameter logic       ALLOC_POLICY = L1D_DEFAULT_ALLOC_POLICY,
    parameter logic [1:0] REPL_POLICY  = L1D_DEFAULT_REPL_POLICY,
    parameter logic       RAW_POLICY   = L1D_DEFAULT_RAW_POLICY,
    parameter int         WB_DEPTH     = WB_DEPTH_DEFAULT
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
    // Vaciado (solo testbenches)
    // ------------------------------------------------------------------
    input  logic          flush_req,
    output logic          flush_done,

    // ------------------------------------------------------------------
    // L2
    // ------------------------------------------------------------------
    output logic          l2_req,
    output logic          l2_we,
    output logic [31:0]   l2_addr,
    output logic [LINE_W-1:0]      l2_wline,
    output logic [LINE_MASK_W-1:0] l2_be,
    input  logic          l2_ready,
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
    output logic          ev_raw_stall,     // ciclo con stall por riesgo RAW (solo RAW_STALL)
    output logic          ev_raw_forward,   // llenado corregido con datos del write buffer
    output logic          ev_wb_push,       // store que entró al write buffer
    output logic          ev_l2_read,       // inicio de una lectura de línea a la L2
    output logic          ev_l2_write       // inicio de una escritura (drenado) a la L2
);


// ============================================================================
// Verificación de parámetros (solo en simulación)
// ============================================================================

initial begin

    if (L1L2_INCLUSION_POLICY != INCL_NINE)
        $fatal(1, "l1d_cache: esta L1-D está hecha para la política NINE (cache_defs.sv)");

    if (L1D_WRITE_POLICY != WP_WRITE_THROUGH)
        $fatal(1, "l1d_cache: esta L1-D está hecha para write-through (cache_defs.sv)");
end


// Atajos para leer las políticas
localparam logic IS_WALLOC  = (ALLOC_POLICY == AP_WRITE_ALLOC);
localparam logic IS_RAW_FWD = (RAW_POLICY   == RAW_FORWARD);


// ############################################################################
//  CAMINO DEL HIT (combinacional, dentro de EX)
// ############################################################################

// ============================================================================
// E1. Cálculo de dirección
// ============================================================================
// La suma base + offset la hace la LSU (rtl/lsu.sv) y llega en addr. Aquí
// solo se recortan los 16 bits que usa la memoria de 64 KB.

logic [PADDR_W-1:0] paddr;
logic               acc;            // hay un acceso del núcleo en EX

assign paddr = addr[PADDR_W-1:0];
assign acc   = !reset && (re || we);


// ============================================================================
// E2. Desambiguación: partir la dirección en campos (notas 6.2.1, figura 6.2;
//     cache_defs.sv, punto 2)
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

logic [L1D_WAYS-1:0]           rd_valid;
logic [L1D_WAYS*L1D_TAG_W-1:0] rd_tag;
logic [L1D_WAYS*LINE_W-1:0]    rd_line;

// Puerto de escritura de los arreglos (se arma en "Escritura de los arreglos")
logic                   arr_we;
logic                   arr_wway;
logic [LINE_W-1:0]      arr_wline;

l1d_arrays ARRAYS (
    .clk(clk),
    .reset(reset),
    .rd_set(a_index),
    .rd_valid(rd_valid),
    .rd_tag(rd_tag),
    .rd_line(rd_line),
    .wr_en(arr_we),
    .wr_set(a_index),               // siempre se escribe el conjunto del acceso
    .wr_way(arr_wway),
    .wr_tag(a_tag),
    .wr_line(arr_wline)
);

// Separar los datos de cada vía
logic [L1D_TAG_W-1:0] tag0, tag1;
logic [LINE_W-1:0]    line0, line1;

assign tag0  = rd_tag[0*L1D_TAG_W +: L1D_TAG_W];
assign tag1  = rd_tag[1*L1D_TAG_W +: L1D_TAG_W];
assign line0 = rd_line[0*LINE_W +: LINE_W];
assign line1 = rd_line[1*LINE_W +: LINE_W];

// Comparadores de etiqueta, uno por vía, trabajando a la vez ("=" y "&" de
// la figura 6.5); el OR de los dos da la señal de acierto
logic [L1D_WAYS-1:0] way_hit;
logic                hit;           // la línea está en la L1-D
logic                hit_way;       // en cuál vía
logic [LINE_W-1:0]   hit_line;      // la línea que acertó

assign way_hit[0] = rd_valid[0] && (tag0 == a_tag);
assign way_hit[1] = rd_valid[1] && (tag1 == a_tag);

assign hit      = |way_hit;
assign hit_way  = way_hit[1];                       // si no es la 1, es la 0
assign hit_line = hit_way ? line1 : line0;          // multiplexor de vía


// ============================================================================
// E4. Entrega del resultado
// ============================================================================
// La línea que se usa es la de la vía que acertó o, en el ciclo de llenado,
// la que acaba de llegar de la L2 (bypass, ver M3). De ella el multiplexor
// de palabra elige la pedida (notas, figura 6.4). El byte y su extensión de
// signo los elige la LSU.

logic              fill_now;        // M3: llega la línea de la L2 en este ciclo
logic [LINE_W-1:0] fill_line;       // esa línea, ya corregida con el write buffer
logic              acc_present;     // la línea del acceso está disponible
logic [LINE_W-1:0] acc_line;        // ... y es esta

assign acc_present = hit || fill_now;
assign acc_line    = hit ? hit_line : fill_line;
assign rdata       = acc_line[a_word*32 +: 32];


// ============================================================================
// Store: bytes nuevos puestos sobre la línea, y su entrada del write buffer
// ============================================================================
// be dice qué bytes de la palabra se escriben; se corre a la posición de la
// palabra dentro de la línea (4 bits de máscara por palabra).
//
// Ejemplo: guardab en la dirección ...0x0D -> palabra 3, byte 1:
//          be = 0010, st_mask = 0010 << (3*4) = bit 13 en 1.
//
// st_mask y st_data son, también, la entrada que el store deja en el write
// buffer (formato de cache_defs.sv, punto 4).

logic [LINE_MASK_W-1:0] st_mask;    // bytes de la línea que toca el store
logic [LINE_W-1:0]      st_data;    // wdata repetido en las 8 palabras
logic [LINE_W-1:0]      st_line;    // acc_line con los bytes del store encima

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
//  CAMINO DEL MISS (etapas M1 a M3) Y DRENADO (D1)
// ############################################################################

// ---- Write buffer (notas 6.3.5) ----------------------------------------------
logic                   wb_push;
logic                   wb_pop;
logic [LINE_ADDR_W-1:0] wb_head_line;
logic [LINE_MASK_W-1:0] wb_head_mask;
logic [LINE_W-1:0]      wb_head_data;
logic                   wb_full;
logic                   wb_empty;
logic                   wb_fwd_hit;
logic [LINE_W-1:0]      wb_fwd_line;

l1d_write_buffer #(.DEPTH(WB_DEPTH)) WBUF (
    .clk(clk),
    .reset(reset),
    .push(wb_push),
    .push_line_addr(a_line),            // el único que escribe es el store
    .push_mask(st_mask),
    .push_data(st_data),
    .pop(wb_pop),
    .head_line_addr(wb_head_line),
    .head_mask(wb_head_mask),
    .head_data(wb_head_data),
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
// (Con no-write-allocate, el store que falla va directo al write buffer.)

logic flush_active;     // el vaciado está en curso (ver al final)
logic acc_eval;         // el acceso se atiende en este ciclo (no hay vaciado)
logic need_fill;

assign acc_eval  = acc && !flush_active;
assign need_fill = acc_eval && !hit && (re || IS_WALLOC);


// ============================================================================
// M1. Asignación: MSHR y elección de la víctima
// ============================================================================
// Primero se usa una vía vacía si la hay; si las dos están ocupadas, decide
// la política de reemplazo (notas 6.2.3). La decisión se guarda en el MSHR
// en el primer ciclo del miss y se usa hasta el llenado. La línea que había
// en esa vía se descarta en el llenado: con write-through siempre está
// limpia, así que no hay nada que mandar a la L2.

logic repl_victim;      // víctima que propone la política de reemplazo
logic repl_touch;       // aviso de uso para LRU (se arma más abajo)
logic repl_touch_way;

logic mshr_valid;       // hay un miss en curso
logic mshr_way;         // vía elegida para la línea nueva

logic victim_new;       // víctima calculada en este ciclo
logic v_way;            // víctima vigente (la del MSHR si ya hay uno)

assign victim_new = !rd_valid[0] ? 1'b0 :
                    !rd_valid[1] ? 1'b1 :
                                   repl_victim;

assign v_way = mshr_valid ? mshr_way : victim_new;

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


// ============================================================================
// M2. Solicitud de la línea a la L2 / D1. Drenado del write buffer
// ============================================================================
// Hay UN bus hacia la L2 y una petición a la vez. port_busy recuerda que hay
// una petición en curso (l2_req ya se subió y todavía no llega l2_ready) y
// port_is_read si es una lectura (M2) o una escritura (D1).
//
// Riesgo RAW en memoria (notas 6.3.5, figura 6.13): si la línea que se va a
// pedir tiene stores pendientes en el write buffer, la L2 todavía no los
// tiene.
//   RAW_STALL  : la lectura no se pide hasta que el buffer drene esos stores.
//   RAW_FORWARD: se pide igual y se corrige en M3 con los bytes del buffer.

logic port_busy;
logic port_is_read;

logic raw_block;        // RAW_STALL: hay que esperar al write buffer
logic start_read;       // M2 empieza una lectura en este ciclo
logic start_drain;      // D1 empieza una escritura en este ciclo
logic cur_read;         // la petición presente en el bus es una lectura

assign raw_block   = !IS_RAW_FWD && wb_fwd_hit;

assign start_read  = need_fill && !raw_block && !port_busy;

// El drenado solo usa el bus si está libre y nadie quiere leer
assign start_drain = !port_busy && !start_read && !wb_empty;

assign cur_read    = port_busy ? port_is_read : start_read;

// Bus hacia la L2. Durante una lectura el núcleo está congelado, así que
// a_line no cambia; durante un drenado, la cabeza del buffer tampoco
// cambia hasta el pop. Por eso l2_addr se mantiene estable hasta l2_ready.
assign l2_req   = port_busy || start_read || start_drain;
assign l2_we    = !cur_read;
assign l2_addr  = cur_read ? {{(32-PADDR_W){1'b0}}, a_line,       {BLOCK_OFF_W{1'b0}}}
                           : {{(32-PADDR_W){1'b0}}, wb_head_line, {BLOCK_OFF_W{1'b0}}};
assign l2_wline = wb_head_data;
assign l2_be    = cur_read ? '0 : wb_head_mask;

logic l2_done;          // la petición presente termina en este ciclo

assign l2_done  = l2_req && l2_ready;
assign wb_pop   = l2_done && !cur_read;          // D1 terminó: sale la cabeza

always @(posedge clk) begin

    if (reset) begin

        port_busy    <= 1'b0;
        port_is_read <= 1'b0;
    end
    else begin

        port_busy    <= l2_req && !l2_ready;     // sigue esperando a la L2
        port_is_read <= cur_read;
    end
end


// ============================================================================
// M3. Llenado (y respuesta en el mismo ciclo)
// ============================================================================
// Llegó la línea de la L2. Con RAW_FORWARD se le ponen encima los bytes que
// todavía esperan en el write buffer (store-to-load forwarding); con
// RAW_STALL no hay nada que corregir porque M2 esperó al buffer.

assign fill_now  = l2_done && cur_read;
assign fill_line = IS_RAW_FWD ? wb_fwd_line : l2_rline;


// ############################################################################
//  TERMINACIÓN DEL ACCESO Y STALL
// ############################################################################
//
// Load : termina cuando su línea está presente (hit, o llenado en este ciclo).
// Store: con write-through SIEMPRE va al write buffer, así que termina cuando
//          - el buffer tiene espacio (si no, riesgo estructural: espera), y
//          - su línea está presente, o es un miss con no-write-allocate
//            (no hace falta traerla).

logic complete;         // el acceso termina en este ciclo

always @(*) begin

    if (!acc_eval)
        complete = 1'b0;
    else if (re)
        complete = acc_present;
    else                                         // store
        complete = (acc_present || !IS_WALLOC) && !wb_full;
end

assign stall = acc && !complete;

// El store entra al write buffer en el ciclo en que termina (una sola vez)
assign wb_push = complete && we;


// ============================================================================
// Escritura de los arreglos (un solo puerto)
// ============================================================================
//   - M3 llenado: entra la línea nueva en la vía del MSHR. Si es un store que
//     termina en este mismo ciclo (write-allocate), se escribe ya con sus
//     bytes.
//   - Store que acierta: la línea de la L1-D se actualiza con los bytes
//     nuevos (y el store también va al write buffer: write-through).
//   - Store que falla con no-write-allocate: la L1-D no se toca.

always @(*) begin

    arr_we    = 1'b0;
    arr_wway  = v_way;
    arr_wline = fill_line;

    if (fill_now) begin
        arr_we    = 1'b1;
        arr_wway  = v_way;
        arr_wline = (we && complete) ? st_line : fill_line;
    end
    else if (we && complete && hit) begin
        arr_we    = 1'b1;
        arr_wway  = hit_way;
        arr_wline = st_line;
    end
end


// ============================================================================
// Registros del MSHR y del acceso en curso
// ============================================================================

logic acc_busy;         // el acceso empezó en un ciclo anterior y no ha terminado
logic acc_was_miss;     // ese acceso falló en su primer ciclo

logic first_cycle;
logic is_miss;          // clasificación del acceso actual (para los eventos)

assign first_cycle = !acc_busy;
assign is_miss     = first_cycle ? !hit : acc_was_miss;

always @(posedge clk) begin

    if (reset) begin

        mshr_valid   <= 1'b0;
        mshr_way     <= 1'b0;
        acc_busy     <= 1'b0;
        acc_was_miss <= 1'b0;
    end
    else begin

        // MSHR: se ocupa en el primer ciclo del miss y se libera al llenar.
        // (Si un store no pudo terminar en el ciclo del llenado porque el
        //  write buffer estaba lleno, en el ciclo siguiente ya es un hit y
        //  no hace falta MSHR.)
        if (fill_now)
            mshr_valid <= 1'b0;
        else if (need_fill && !mshr_valid) begin
            mshr_valid <= 1'b1;
            mshr_way   <= victim_new;
        end

        // Acceso en curso
        if (acc_eval && !complete) begin
            acc_busy <= 1'b1;
            if (first_cycle)
                acc_was_miss <= !hit;
        end
        else if (complete)
            acc_busy <= 1'b0;
    end
end


// ============================================================================
// Actualización de la política de reemplazo
// ============================================================================
// "touch" = el acceso terminó usando la línea de la vía acc_way (LRU).
// El llenado (fill_now) se conecta directo en la instancia REPL.

assign repl_touch     = complete && acc_present;
assign repl_touch_way = hit ? hit_way : v_way;


// ############################################################################
//  VACIADO (flush)
// ############################################################################
//
// Con write-through solo hay que esperar a que el write buffer se vacíe:
//
//   FL_IDLE  -> esperando flush_req. Empieza cuando no hay ningún acceso a
//               medias (ni MSHR ni acceso que se quede esperando).
//   FL_DRAIN -> el núcleo espera; el write buffer drena hasta quedar vacío
//               y el bus libre.
//   FL_DONE  -> flush_done = 1 hasta que bajen flush_req.

localparam logic [1:0] FL_IDLE  = 2'd0;
localparam logic [1:0] FL_DRAIN = 2'd1;
localparam logic [1:0] FL_DONE  = 2'd2;

logic [1:0] fl_state;

assign flush_active = (fl_state != FL_IDLE);
assign flush_done   = (fl_state == FL_DONE);

always @(posedge clk) begin

    if (reset)
        fl_state <= FL_IDLE;
    else begin

        case (fl_state)

            FL_IDLE:
                // No se interrumpe un acceso a medias del núcleo
                if (flush_req && !mshr_valid && !acc_busy && !(acc && !complete))
                    fl_state <= FL_DRAIN;

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
assign ev_wb_full_stall = stall && acc_eval && we && wb_full && (acc_present || !IS_WALLOC);
assign ev_raw_stall     = stall && need_fill && raw_block && !port_busy;
assign ev_raw_forward   = fill_now && IS_RAW_FWD && wb_fwd_hit;
assign ev_wb_push       = wb_push;
assign ev_l2_read       = start_read;
assign ev_l2_write      = start_drain;


// ############################################################################
//  Verificaciones de simulación
// ############################################################################

always @(posedge clk) begin

    if (!reset && re && we)
        $error("l1d_cache: load y store a la vez en el mismo puerto");
end


endmodule
