/*
================================================================================
 Módulo: l2_cache

 Descripción:
 ------------------------------------------------------------------------------
 Caché L2 unificada del Proyecto Grupal II (bloque de Alejandro; la
 segmentación en 4 etapas es la decisión 11, de Fabricio).

 Sustituye a rtl-p2/l2_model.sv, que era un stub que siempre acertaba. Esta es
 la L2 de verdad: guarda líneas, aplica la política de reemplazo, cumple la
 política de inclusión L1-D/L2 y habla con el eviction buffer.

 Geometría (enunciado 3.2.3, fijada; NO es una decisión de diseño):
     16 KB, 4 vías, líneas de 32 B, hit de 8 ciclos, write-back.
     512 líneas, 128 conjuntos, índice addr[11:5], etiqueta addr[15:12].

 Bus hacia arriba (L1-D <-> L2, versión 2 de cache_defs.sv):
     Mismos nombres y polaridad que l2_model.sv, para que la L2 se pueda
     poner en su lugar en rtl-p2/mem_hierarchy.sv sin tocar el resto.
       l2_req, l2_we, l2_addr[31:0], l2_wline[255:0], l2_be[32], l2_wdirty
       l2_gnt, l2_rvalid, l2_rline[255:0], l2_rdirty
     La aceptación es l2_req && l2_gnt. Las escrituras terminan al ser
     aceptadas (no tienen respuesta) y las lecturas responden en orden. Las
     salidas salen de registros, porque el stall de la L1-D tiene que depender
     solo de registros.

 Bus hacia abajo (eviction buffer, sección 6.7 de docs/memory-interfaces.md):
     La L2 no habla con la RAM: le pide las líneas al eviction buffer, que a su
     vez habla con el controlador de memoria principal. Los nombres de las
     señales son los del buffer, sin adaptadores:
       evict_valid, evict_addr, evict_line  ->  evict_ready
       read_req, read_addr                   ->  read_ready, read_line,
                                                 read_forwarded

 Política de inclusión (INCL_POLICY):
     INCL_EXCLUSIVE (por defecto): L1-D ∩ L2 = vacío.
         - Un acierto en la L2 ante un fallo en la L1-D MUEVE la línea: la L2
           invalida su copia y se la entrega a la L1-D con su bit sucio
           (l2_rdirty). La L2 deja de tener esa línea.
         - Un fallo en la L2 entrega la línea SOLO a la L1-D: la L2 no se
           guarda nada, porque si lo guardara la línea estaría en los dos
           niveles (notas de clase, figura 6.6).
         - Toda víctima de la L1-D (limpia o sucia) entra a la L2, que funciona
           como caché víctima de la L1-D (lección 14b).
     INCL_NINE: la L2 se queda con una copia de todo. Un acierto copia la línea
           y la L2 la conserva; un fallo la guarda en la L2.

 Política de escritura: write-back. Una línea solo baja a la RAM cuando sale
 sucia de la L2 (por el eviction buffer) o en el vaciado.

 Etapas (decisiones-importantes.md 4.3, D11)
 ------------------------------------------------------------------------------
     S1 Recepción   cola de 2 entradas. l2_gnt (registrado) dice que la cola
                    tiene lugar en este ciclo, así que se acepta una petición
                    por ciclo mientras las etapas siguientes avancen.
     S2 Etiquetas   compara las 4 vías, decide acierto o fallo y la víctima.
                    Aquí esperan los fallos (la línea que se pide al nivel
                    inferior) y los desalojos de víctimas sucias: todo va en
                    orden, así que un fallo detiene S2 y las peticiones de
                    atrás esperan en la cola.
     S3 Datos       escribe los arreglos (llenado, store o la invalidación de
                    la exclusiva) y actualiza el reemplazo, en el flanco en
                    que la petición sale de S3.
     S4 Respuesta   la línea de un acierto espera hasta completar los 8
                    ciclos desde su aceptación y sale por l2_rvalid.

     Riesgos entre etapas:
       - Si S3 todavía no escribió el conjunto que S2 tiene que mirar, S2
         espera un ciclo. Con RANDOM también espera si S3 hace un llenado,
         porque el LFSR es uno solo para todos los conjuntos.
       - La respuesta de un fallo sale directo desde S2 cuando llega la línea,
         si no hay una lectura más vieja en S3 o S4; si la hay, espera su
         turno (las respuestas nunca se desordenan).

 Tiempos:
     Acierto: la petición se acepta en el ciclo t y l2_rvalid sale en t+8.
     Fallo:   la petición se acepta en t, la L2 pide la línea en t+5, el nivel
              inferior tarda Tmem y l2_rvalid sale en t+8+Tmem. Con Tmem = 53
              son 61 ciclos, que es el 8 + Tmem del enunciado.
     Una escritura ocupa la L2 un ciclo (la versión bloqueante necesitaba 3) y
     una lectura se puede aceptar en el ciclo siguiente a una escritura.

 Vaciado (D16)
 ------------------------------------------------------------------------------
 La L2 sabe vaciarse. La interfaz es la misma que usa la L1-D (l1d_cache.sv):
     flush_req      pedido de vaciado (el testbench o la instrucción vaciarc).
     flush_done     1 cuando TODAS las líneas sucias de la L2 ya llegaron a la
                    RAM; se mantiene mientras flush_req siga en 1.
     lower_drained  1 cuando el nivel inferior no tiene líneas sucias
                    pendientes: el eviction buffer está vacío, o sea, la RAM ya
                    confirmó las escrituras.

 Cómo funciona:
     1. Con flush_req = 1 la L2 deja de aceptar peticiones (l2_gnt = 0) y
        termina las que tiene en las etapas. Una petición que ya estaba
        aceptada se atiende antes del barrido.
     2. La L2 recorre sus 512 líneas (128 conjuntos x 4 vías) buscando las
        sucias. Cada línea sucia se le entrega al eviction buffer con el mismo
        handshake de siempre (evict_valid y evict_ready) y su copia en la L2
        queda limpia: a partir de ahí la L2 y la RAM tienen lo mismo.
     3. Cuando ya no quedan líneas sucias, la L2 espera a que el nivel
        inferior se vacíe (lower_drained = 1) y entonces pone flush_done = 1.

 Contrato con el nivel de arriba:
     - El pedido de vaciado de la L2 se sube DESPUÉS de que la L1-D haya
       terminado su propio vaciado (su flush_done). Así las líneas sucias de
       la L1-D ya están dentro de la L2 y el vaciado de la L2 las alcanza.
     - flush_done es un NIVEL: se levanta cuando el vaciado termina y se
       mantiene mientras flush_req siga en alto. La L2 vuelve a aceptar
       peticiones cuando flush_req baja.

 Política de reemplazo (REPL_POLICY): la decide rtl-p2/l2_replacement.sv.
     RP2_PLRU (por defecto) es un pseudo-LRU de árbol: una APROXIMACIÓN del LRU
     exacto, no el LRU exacto. RP2_RANDOM usa un LFSR.

 Almacenamiento: está en rtl-p2/l2_arrays.sv, como el de la L1-D
 (l1d_arrays.sv). La L2 tiene un solo puerto de lectura, multiplexado: S2 lo
 usa con el conjunto de su petición y, durante el vaciado, apunta al conjunto
 que se está revisando.

 Eventos (Javier, issue #26): pulsos de un ciclo con lo que hizo la L2:
     ev_l2_rd_hit, ev_l2_rd_miss, ev_l2_wr_hit, ev_l2_wr_miss, ev_l2_fill,
     ev_l2_evict, ev_l2_writeback, ev_l2_invalid, ev_l2_read_req,
     ev_l2_write_req. La convención es la misma que usa la L1-D.

 ==============================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l2_cache #(

    // Política de reemplazo: RP2_PLRU o RP2_RANDOM (cache_defs.sv)
    parameter logic [1:0] REPL_POLICY = L2_DEFAULT_REPL_POLICY,

    // Política de inclusión L1-D/L2: INCL_EXCLUSIVE (por defecto) o INCL_NINE
    parameter logic [1:0] INCL_POLICY = L2_DEFAULT_INCL_POLICY

) (

    input  logic                   clk,
    input  logic                   reset,

    // ------------------------------------------------------------------
    // Bus L1-D <-> L2, versión 2 (idéntico al de l2_model.sv)
    // ------------------------------------------------------------------
    input  logic                   l2_req,
    input  logic                   l2_we,
    input  logic [31:0]            l2_addr,
    input  logic [LINE_W-1:0]      l2_wline,
    input  logic [LINE_MASK_W-1:0] l2_be,
    input  logic                   l2_wdirty,
    output logic                   l2_gnt,
    output logic                   l2_rvalid,
    output logic [LINE_W-1:0]      l2_rline,
    output logic                   l2_rdirty,
    output logic                   idle,

    // ------------------------------------------------------------------
    // Hacia el eviction buffer (docs/memory-interfaces.md, sección 6.7)
    // ------------------------------------------------------------------
    output logic                   evict_valid,
    output logic [31:0]            evict_addr,
    output logic [LINE_W-1:0]      evict_line,
    input  logic                   evict_ready,

    // ------------------------------------------------------------------
    // Petición de una línea al nivel inferior (el eviction buffer)
    // ------------------------------------------------------------------
    output logic                   read_req,
    output logic [31:0]            read_addr,
    input  logic                   read_ready,
    input  logic [LINE_W-1:0]      read_line,
    input  logic                   read_forwarded,

    // ------------------------------------------------------------------
    // Vaciado (D16). Misma convención que la L1-D (l1d_cache.sv).
    // ------------------------------------------------------------------
    //   flush_req      pedido de vaciado.
    //   flush_done     1 cuando las líneas sucias de la L2 ya están en la RAM.
    //   lower_drained  1 cuando el nivel inferior no tiene líneas sucias
    //                  pendientes (el eviction buffer está vacío).
    input  logic                   flush_req,
    output logic                   flush_done,
    input  logic                   lower_drained,

    // ------------------------------------------------------------------
    // Eventos para los contadores (Javier, issue #26)
    // ------------------------------------------------------------------
    // Pulsos de UN ciclo, con la misma convención que usa la L1-D (l1d_cache.sv).
    //
    //   ev_l2_rd_hit      una lectura aceptada acertó
    //   ev_l2_rd_miss     una lectura aceptada falló
    //   ev_l2_wr_hit      una escritura aceptada acertó
    //   ev_l2_wr_miss     una escritura aceptada falló
    //   ev_l2_fill        una línea entró en la L2 (relleno o víctima de la L1-D)
    //   ev_l2_evict       una línea sucia salió por reemplazo al eviction buffer
    //   ev_l2_writeback   una línea sucia salió al eviction buffer en el vaciado
    //   ev_l2_invalid     invalidación hacia atrás: la L2 tira su copia porque
    //                     la línea se MUEVE a la L1-D (política exclusiva)
    //   ev_l2_read_req    la L2 pidió una línea al nivel inferior
    //   ev_l2_write_req   la L2 entregó una línea al nivel inferior
    output logic                   ev_l2_rd_hit,
    output logic                   ev_l2_rd_miss,
    output logic                   ev_l2_wr_hit,
    output logic                   ev_l2_wr_miss,
    output logic                   ev_l2_fill,
    output logic                   ev_l2_evict,
    output logic                   ev_l2_writeback,
    output logic                   ev_l2_invalid,
    output logic                   ev_l2_read_req,
    output logic                   ev_l2_write_req
);


localparam logic IS_EXCL = (INCL_POLICY == INCL_EXCLUSIVE);
localparam logic IS_RND  = (REPL_POLICY == RP2_RANDOM);

initial begin
    if (INCL_POLICY != INCL_EXCLUSIVE && INCL_POLICY != INCL_NINE)
        $fatal(1, "l2_cache: INCL_POLICY = %0d no es una política valida", INCL_POLICY);
    if (REPL_POLICY != RP2_PLRU && REPL_POLICY != RP2_RANDOM)
        $fatal(1, "l2_cache: REPL_POLICY = %0d no es una politica valida", REPL_POLICY);
end

localparam logic [LINE_MASK_W-1:0] FULL_MASK = {LINE_MASK_W{1'b1}};

function automatic [LINE_W-1:0] merge_bytes(
    input [LINE_W-1:0]      old_line,
    input [LINE_W-1:0]      new_line,
    input [LINE_MASK_W-1:0] be_mask);

    integer b;
    begin
        for (b = 0; b < LINE_BYTES; b = b + 1)
            merge_bytes[8*b +: 8] = be_mask[b] ? new_line[8*b +: 8] : old_line[8*b +: 8];
    end
endfunction

function automatic [7:0] age_inc(input [7:0] a);
    age_inc = (a == 8'hFF) ? a : a + 8'd1;
endfunction


// ============================================================================
// Arreglos y reemplazo (los mismos módulos de la versión bloqueante)
// ============================================================================

logic [L2_INDEX_W-1:0]       bus_set;
logic [L2_WAYS-1:0]          bus_valid;
logic [L2_WAYS*L2_TAG_W-1:0] bus_tag;
logic [L2_WAYS*LINE_W-1:0]   bus_line;
logic [L2_WAYS-1:0]          bus_dirty;

logic                  wr_en;
logic [L2_INDEX_W-1:0] wr_set;
logic [L2_WAY_W-1:0]   wr_way;
logic [L2_TAG_W-1:0]   wr_tag;
logic [LINE_W-1:0]     wr_line;
logic                  wr_dirty;
logic                  wr_valid;

logic                  clr_dirty_en;
logic [L2_INDEX_W-1:0] clr_dirty_set;
logic [L2_WAY_W-1:0]   clr_dirty_way;

l2_arrays ARRAYS (
    .clk(clk), .reset(reset),
    .rd_set(bus_set), .rd_valid(bus_valid), .rd_tag(bus_tag), .rd_line(bus_line), .rd_dirty(bus_dirty),
    .wr_en(wr_en), .wr_set(wr_set), .wr_way(wr_way), .wr_tag(wr_tag), .wr_line(wr_line),
    .wr_dirty(wr_dirty), .wr_valid(wr_valid),
    .clr_dirty_en(clr_dirty_en), .clr_dirty_set(clr_dirty_set), .clr_dirty_way(clr_dirty_way)
);

logic [L2_WAY_W-1:0]   repl_victim;
logic                  touch_pulse;
logic                  fill_pulse;

l2_replacement #(.REPL_POLICY(REPL_POLICY)) REPL (
    .clk(clk), .reset(reset),
    .lookup_set(bus_set), .victim_way(repl_victim),
    .touch(touch_pulse), .touch_set(wr_set), .touch_way(wr_way),
    .fill(fill_pulse), .fill_set(wr_set), .fill_way(wr_way)
);


// ============================================================================
// S1: cola de recepción de 2 entradas (q0 = la más vieja)
// ============================================================================

logic                   q0_v, q1_v;
logic                   q0_we, q1_we;
logic [31:0]            q0_addr, q1_addr;
logic [LINE_W-1:0]      q0_wline, q1_wline;
logic [LINE_MASK_W-1:0] q0_be, q1_be;
logic                   q0_wdirty, q1_wdirty;
logic [7:0]             q0_age, q1_age;

logic accept;
logic pop;                  // S2 toma q0 en este ciclo

assign accept = l2_req && l2_gnt;


// ============================================================================
// S2: etiquetas y decisión
// ============================================================================

localparam logic [2:0] D_DECIDE = 3'd0;   // comparar y decidir
localparam logic [2:0] D_SEND   = 3'd1;   // decidido, espera lugar en S3
localparam logic [2:0] D_EVICT  = 3'd2;   // saca la víctima sucia al eviction buffer
localparam logic [2:0] D_WAIT   = 3'd3;   // fallo de lectura: espera t+5 para pedir
localparam logic [2:0] D_FETCH  = 3'd4;   // espera la línea del nivel inferior
localparam logic [2:0] D_RESP   = 3'd5;   // respuesta de un fallo esperando su turno

logic                   r2_v;
logic [2:0]             r2_st;
logic                   r2_we;
logic [31:0]            r2_addr;
logic [LINE_W-1:0]      r2_wline;
logic [LINE_MASK_W-1:0] r2_be;
logic                   r2_wdirty;
logic [7:0]             r2_age;

// Decisión ya tomada (para los estados que siguen a D_DECIDE)
logic [L2_WAY_W-1:0]    r2_way;
logic [LINE_W-1:0]      r2_line;      // línea para S3 (store o llenado) o la respuesta
logic                   r2_dirty;
logic                   r2_s3_wr;     // S3 escribe los arreglos
logic                   r2_s3_valid;  // valor del bit V que escribe (0 = invalidar)
logic                   r2_s3_touch;
logic                   r2_s3_fill;
logic                   r2_s3_read;   // lleva una respuesta a S4
logic                   r2_after_evict_fetch;   // después del desalojo, pedir la línea
logic                   r2_after_evict_wait;    // después del desalojo, esperar t+5
logic [LINE_W-1:0]      r2_vic_line;
logic [L2_TAG_W-1:0]    r2_vic_tag;

logic [L2_INDEX_W-1:0]  r2_set;
logic [L2_TAG_W-1:0]    r2_tag;

assign r2_set = r2_addr[L2_INDEX_MSB:L2_INDEX_LSB];
assign r2_tag = r2_addr[L2_TAG_MSB:L2_TAG_LSB];


// ============================================================================
// S3 y S4
// ============================================================================

logic                   r3_v;
logic                   r3_wr, r3_valid_bit, r3_touch, r3_fill, r3_read;
logic [L2_INDEX_W-1:0]  r3_set;
logic [L2_WAY_W-1:0]    r3_way;
logic [L2_TAG_W-1:0]    r3_tag;
logic [LINE_W-1:0]      r3_line;      // lo que se escribe en los arreglos
logic                   r3_dirty;
logic [LINE_W-1:0]      r3_rline;     // respuesta (lecturas)
logic                   r3_rdirty;
logic [7:0]             r3_age;

logic                   r4_v;
logic [LINE_W-1:0]      r4_line;
logic                   r4_dirty;
logic [7:0]             r4_age;

logic s4_emit, s4_free, s3_adv, s3_free;

assign s4_emit = r4_v && (r4_age >= L2_HIT_CYCLES - 1);
assign s4_free = !r4_v || s4_emit;
assign s3_adv  = r3_v && (!r3_read || s4_free);
assign s3_free = !r3_v || s3_adv;

// Escritura de los arreglos y del reemplazo: en el flanco en que S3 avanza
assign wr_en       = s3_adv && r3_wr;
assign wr_set      = r3_set;
assign wr_way      = r3_way;
assign wr_tag      = r3_tag;
assign wr_line     = r3_line;
assign wr_dirty    = r3_dirty;
assign wr_valid    = r3_valid_bit;
assign touch_pulse = s3_adv && r3_touch;
assign fill_pulse  = s3_adv && r3_fill;

// Riesgo: S3 todavía no escribió el conjunto que S2 tiene que mirar
logic hazard;

assign hazard = r3_v && (((r3_wr || r3_touch || r3_fill) && (r3_set == r2_set)) ||
                         (IS_RND && r3_fill));

// Hay una lectura más vieja que todavía no respondió
logic older_read;

assign older_read = (r3_v && r3_read) || r4_v;


// ============================================================================
// Vaciado (el mismo barrido de la versión bloqueante)
// ============================================================================

localparam logic [2:0] F_NONE  = 3'd0;
localparam logic [2:0] F_SCAN  = 3'd1;
localparam logic [2:0] F_EVICT = 3'd2;
localparam logic [2:0] F_WAIT  = 3'd3;
localparam logic [2:0] F_DONE  = 3'd4;

logic [2:0]            fl_st;
logic [8:0]            scan_ptr;
logic [L2_INDEX_W-1:0] scan_set;
logic [L2_WAY_W-1:0]   scan_way;
logic [LINE_W-1:0]     flush_line_q;
logic [L2_TAG_W-1:0]   flush_tag_q;
logic [L2_INDEX_W-1:0] flush_set_q;
logic [L2_WAY_W-1:0]   flush_way_q;

localparam logic [8:0] SCAN_LAST = 9'h1FF;

assign scan_set = scan_ptr[L2_INDEX_W+1:2];
assign scan_way = scan_ptr[L2_WAY_W-1:0];

assign bus_set    = (fl_st == F_SCAN || fl_st == F_EVICT) ? scan_set : r2_set;
assign flush_done = (fl_st == F_DONE);

logic pipe_empty;

assign pipe_empty = !q0_v && !q1_v && !r2_v && !r3_v && !r4_v;

// Libre: nada en las etapas y ya salió el pulso del último llenado
assign idle = (fl_st == F_NONE) && pipe_empty && !l2_rvalid && !ev_l2_fill;


// ============================================================================
// Decisión combinacional de S2 (D_DECIDE)
// ============================================================================

logic                hit;
logic [L2_WAY_W-1:0] hit_way;
logic [LINE_W-1:0]   hit_line;
logic                hit_dirty;
logic                free_found;
logic [L2_WAY_W-1:0] free_way;
logic [L2_WAY_W-1:0] fill_way_sel;
logic                vic_dirty;

integer wi;

always @(*) begin

    hit        = 1'b0;
    hit_way    = '0;
    hit_line   = '0;
    hit_dirty  = 1'b0;
    free_found = 1'b0;
    free_way   = '0;

    for (wi = 0; wi < L2_WAYS; wi = wi + 1) begin
        if (!hit && bus_valid[wi] && (bus_tag[wi*L2_TAG_W +: L2_TAG_W] == r2_tag)) begin
            hit       = 1'b1;
            hit_way   = wi[L2_WAY_W-1:0];
            hit_line  = bus_line[wi*LINE_W +: LINE_W];
            hit_dirty = bus_dirty[wi];
        end
        if (!free_found && !bus_valid[wi]) begin
            free_found = 1'b1;
            free_way   = wi[L2_WAY_W-1:0];
        end
    end
end

assign fill_way_sel = free_found ? free_way : repl_victim;
assign vic_dirty    = !free_found && bus_dirty[repl_victim];

// Una decisión "simple" pasa directo a S3 sin esperar nada abajo
logic decide_now;       // S2 decide en este ciclo
logic dec_simple;       // acierto, o escritura de línea completa sin víctima sucia
logic dec_rd_hit, dec_rd_miss, dec_wr_hit, dec_wr_miss;

assign decide_now  = r2_v && (r2_st == D_DECIDE) && !hazard;
assign dec_rd_hit  = decide_now && !r2_we &&  hit;
assign dec_rd_miss = decide_now && !r2_we && !hit;
assign dec_wr_hit  = decide_now &&  r2_we &&  hit;
assign dec_wr_miss = decide_now &&  r2_we && !hit;
assign dec_simple  = dec_rd_hit || dec_wr_hit ||
                     (dec_wr_miss && (r2_be == FULL_MASK) && !vic_dirty);

// S2 manda su petición a S3 en este ciclo
logic s2_to_s3;
logic s2_resp_now;      // la respuesta de un fallo sale en este ciclo
logic s2_retire;        // S2 queda libre en este ciclo

logic fetch_done;       // llegó la línea pedida
logic miss_rd_fetch;    // la línea que llegó es de un fallo de lectura

assign fetch_done    = r2_v && (r2_st == D_FETCH) && read_ready;
assign miss_rd_fetch = fetch_done && !r2_we;

assign s2_resp_now = (miss_rd_fetch && !older_read) ||
                     (r2_v && r2_st == D_RESP && !older_read);

always @(*) begin

    s2_to_s3  = 1'b0;
    s2_retire = 1'b0;

    if (r2_v) begin
        case (r2_st)
            D_DECIDE: if (dec_simple && s3_free) begin s2_to_s3 = 1'b1; s2_retire = 1'b1; end
            D_SEND:   if (s3_free)               begin s2_to_s3 = 1'b1; s2_retire = 1'b1; end
            D_FETCH:  if (read_ready) begin
                          if (!r2_we) begin
                              // Fallo de lectura: con NINE además se llena la L2
                              if (!older_read && (IS_EXCL || s3_free)) begin
                                  s2_to_s3  = !IS_EXCL;
                                  s2_retire = 1'b1;
                              end
                          end
                          else if (s3_free) begin
                              s2_to_s3  = 1'b1;     // write-allocate: guardar la mezcla
                              s2_retire = 1'b1;
                          end
                      end
            D_RESP:   if (!older_read && (IS_EXCL || s3_free)) begin
                          s2_to_s3  = !IS_EXCL;
                          s2_retire = 1'b1;
                      end
            default: ;
        endcase
    end
end

// Lo que S2 manda a S3 (desde la decisión de este ciclo o desde lo guardado)
logic                  n3_wr, n3_valid_bit, n3_touch, n3_fill, n3_read;
logic [L2_WAY_W-1:0]   n3_way;
logic [LINE_W-1:0]     n3_line;
logic                  n3_dirty;
logic [LINE_W-1:0]     n3_rline;
logic                  n3_rdirty;

always @(*) begin

    n3_wr = 1'b0; n3_valid_bit = 1'b1; n3_touch = 1'b0; n3_fill = 1'b0; n3_read = 1'b0;
    n3_way = r2_way; n3_line = r2_line; n3_dirty = r2_dirty;
    n3_rline = r2_line; n3_rdirty = r2_dirty;

    if (r2_st == D_DECIDE) begin
        if (dec_rd_hit) begin
            n3_read   = 1'b1;
            n3_touch  = 1'b1;
            n3_way    = hit_way;
            n3_rline  = hit_line;
            n3_rdirty = IS_EXCL ? hit_dirty : 1'b0;
            if (IS_EXCL) begin
                n3_wr        = 1'b1;        // la línea se MUEVE: se invalida
                n3_valid_bit = 1'b0;
                n3_line      = hit_line;
                n3_dirty     = 1'b0;
            end
        end
        else if (dec_wr_hit) begin
            n3_wr    = 1'b1;
            n3_touch = 1'b1;
            n3_way   = hit_way;
            n3_line  = merge_bytes(hit_line, r2_wline, r2_be);
            n3_dirty = (r2_be == FULL_MASK) ? (hit_dirty | r2_wdirty) : 1'b1;
        end
        else begin                          // escritura de línea completa que falla
            n3_wr    = 1'b1;
            n3_fill  = 1'b1;
            n3_way   = fill_way_sel;
            n3_line  = r2_wline;
            n3_dirty = r2_wdirty;
        end
    end
    else if (r2_st == D_FETCH && r2_we) begin
        n3_wr    = 1'b1;                    // write-allocate: línea vieja + bytes nuevos
        n3_fill  = 1'b1;
        n3_line  = merge_bytes(read_line, r2_wline, r2_be);
        n3_dirty = 1'b1;
    end
    else if (r2_st == D_FETCH || r2_st == D_RESP) begin
        n3_wr    = 1'b1;                    // NINE: la L2 guarda su copia
        n3_fill  = 1'b1;
        n3_line  = (r2_st == D_FETCH) ? read_line : r2_line;
        n3_dirty = (r2_st == D_FETCH) ? read_forwarded : r2_dirty;
    end
    else begin                              // D_SEND: todo quedó guardado en r2
        n3_wr    = r2_s3_wr;
        n3_valid_bit = r2_s3_valid;
        n3_touch = r2_s3_touch;
        n3_fill  = r2_s3_fill;
        n3_read  = r2_s3_read;
    end
end

// La cola entrega su cabeza a S2 cuando S2 está libre o queda libre
assign pop = q0_v && (!r2_v || s2_retire) && (fl_st == F_NONE);


// ============================================================================
// Registros
// ============================================================================

logic [1:0] q_cnt_next;

always @(*) begin
    q_cnt_next = {1'b0, q0_v} + {1'b0, q1_v} + {1'b0, accept} - {1'b0, pop};
end

always @(posedge clk) begin

    // pulsos de un ciclo
    l2_rvalid       <= 1'b0;
    read_req        <= 1'b0;
    clr_dirty_en    <= 1'b0;
    ev_l2_rd_hit    <= 1'b0;
    ev_l2_rd_miss   <= 1'b0;
    ev_l2_wr_hit    <= 1'b0;
    ev_l2_wr_miss   <= 1'b0;
    ev_l2_fill      <= 1'b0;
    ev_l2_evict     <= 1'b0;
    ev_l2_writeback <= 1'b0;
    ev_l2_invalid   <= 1'b0;
    ev_l2_read_req  <= 1'b0;
    ev_l2_write_req <= 1'b0;

    if (reset) begin

        q0_v <= 1'b0; q1_v <= 1'b0;
        r2_v <= 1'b0; r2_st <= D_DECIDE;
        r3_v <= 1'b0; r4_v <= 1'b0;
        evict_valid <= 1'b0;
        fl_st    <= F_NONE;
        scan_ptr <= 9'd0;
        l2_gnt   <= 1'b1;
    end
    else begin

        // ---------------- S1: cola ----------------
        // Las edades cuentan los ciclos desde la aceptación (1 en t+1)
        if (pop) begin
            q0_v      <= q1_v || (accept && q1_v);
            q0_we     <= q1_we;     q0_addr  <= q1_addr;  q0_wline <= q1_wline;
            q0_be     <= q1_be;     q0_wdirty<= q1_wdirty; q0_age  <= age_inc(q1_age);
            q1_v      <= 1'b0;
            if (accept) begin
                if (q1_v) begin
                    q1_v <= 1'b1; q1_we <= l2_we; q1_addr <= l2_addr; q1_wline <= l2_wline;
                    q1_be <= l2_be; q1_wdirty <= l2_wdirty; q1_age <= 8'd1;
                end
                else begin
                    q0_v <= 1'b1; q0_we <= l2_we; q0_addr <= l2_addr; q0_wline <= l2_wline;
                    q0_be <= l2_be; q0_wdirty <= l2_wdirty; q0_age <= 8'd1;
                end
            end
        end
        else begin
            q0_age <= age_inc(q0_age);
            q1_age <= age_inc(q1_age);
            if (accept) begin
                if (!q0_v) begin
                    q0_v <= 1'b1; q0_we <= l2_we; q0_addr <= l2_addr; q0_wline <= l2_wline;
                    q0_be <= l2_be; q0_wdirty <= l2_wdirty; q0_age <= 8'd1;
                end
                else begin
                    q1_v <= 1'b1; q1_we <= l2_we; q1_addr <= l2_addr; q1_wline <= l2_wline;
                    q1_be <= l2_be; q1_wdirty <= l2_wdirty; q1_age <= 8'd1;
                end
            end
        end

        // Permiso del próximo ciclo: lugar en la cola y sin vaciado
        l2_gnt <= (q_cnt_next < 2'd2) && !flush_req && (fl_st == F_NONE);

        // ---------------- S4: respuesta de un acierto ----------------
        r4_age <= age_inc(r4_age);
        if (s4_emit) begin
            l2_rvalid <= 1'b1;
            l2_rline  <= r4_line;
            l2_rdirty <= r4_dirty;
            r4_v      <= 1'b0;
        end

        // ---------------- S3: datos ----------------
        r3_age <= age_inc(r3_age);
        if (s3_adv) begin
            r3_v <= 1'b0;
            if (r3_fill)
                ev_l2_fill <= 1'b1;
            if (r3_read) begin
                r4_v     <= 1'b1;
                r4_line  <= r3_rline;
                r4_dirty <= r3_rdirty;
                r4_age   <= age_inc(r3_age);
            end
        end

        if (s2_to_s3) begin
            r3_v         <= 1'b1;
            r3_wr        <= n3_wr;
            r3_valid_bit <= n3_valid_bit;
            r3_touch     <= n3_touch;
            r3_fill      <= n3_fill;
            r3_read      <= n3_read;
            r3_set       <= r2_set;
            r3_way       <= n3_way;
            r3_tag       <= r2_tag;
            r3_line      <= n3_line;
            r3_dirty     <= n3_dirty;
            r3_rline     <= n3_rline;
            r3_rdirty    <= n3_rdirty;
            r3_age       <= age_inc(r2_age);
        end

        // ---------------- respuesta de un fallo (sale desde S2) ----------------
        if (s2_resp_now) begin
            l2_rvalid <= 1'b1;
            l2_rline  <= (r2_st == D_FETCH) ? read_line : r2_line;
            l2_rdirty <= IS_EXCL ? ((r2_st == D_FETCH) ? read_forwarded : r2_dirty) : 1'b0;
        end

        // ---------------- S2: etiquetas y decisión ----------------
        r2_age <= age_inc(r2_age);

        if (r2_v) begin
            case (r2_st)

            D_DECIDE: if (!hazard) begin

                ev_l2_rd_hit  <= dec_rd_hit;
                ev_l2_rd_miss <= dec_rd_miss;
                ev_l2_wr_hit  <= dec_wr_hit;
                ev_l2_wr_miss <= dec_wr_miss;
                ev_l2_invalid <= dec_rd_hit && IS_EXCL;

                // Se guarda la decisión por si S2 tiene que esperar
                r2_way      <= n3_way;
                r2_line     <= dec_rd_hit ? n3_rline : n3_line;
                r2_dirty    <= dec_rd_hit ? n3_rdirty : n3_dirty;
                r2_s3_wr    <= n3_wr;
                r2_s3_valid <= n3_valid_bit;
                r2_s3_touch <= n3_touch;
                r2_s3_fill  <= n3_fill;
                r2_s3_read  <= n3_read;
                r2_vic_line <= bus_line[repl_victim*LINE_W +: LINE_W];
                r2_vic_tag  <= bus_tag[repl_victim*L2_TAG_W +: L2_TAG_W];

                if (dec_simple) begin
                    if (!s3_free)
                        r2_st <= D_SEND;
                end
                else if (dec_rd_miss) begin
                    r2_way <= fill_way_sel;
                    if (!IS_EXCL && vic_dirty) begin
                        r2_st <= D_EVICT;
                        r2_after_evict_wait  <= 1'b1;
                        r2_after_evict_fetch <= 1'b0;
                    end
                    else
                        r2_st <= D_WAIT;
                end
                else if (dec_wr_miss && r2_be == FULL_MASK) begin
                    // víctima sucia: desalojar y después guardar. El bit sucio
                    // se calcula igual que en la versión bloqueante.
                    r2_way   <= fill_way_sel;
                    r2_line  <= r2_wline;
                    r2_dirty <= r2_wdirty | vic_dirty;
                    r2_st    <= D_EVICT;
                    r2_after_evict_wait  <= 1'b0;
                    r2_after_evict_fetch <= 1'b0;
                end
                else begin
                    // escritura parcial que falla: write-allocate
                    r2_way <= fill_way_sel;
                    if (vic_dirty) begin
                        r2_st <= D_EVICT;
                        r2_after_evict_wait  <= 1'b0;
                        r2_after_evict_fetch <= 1'b1;
                    end
                    else begin
                        r2_st          <= D_FETCH;
                        read_req       <= 1'b1;
                        read_addr      <= {r2_addr[31:L2_INDEX_LSB], {L2_INDEX_LSB{1'b0}}};
                        ev_l2_read_req <= 1'b1;
                    end
                end
            end

            D_EVICT: begin
                evict_valid     <= 1'b1;
                ev_l2_write_req <= 1'b1;
                if (evict_valid && evict_ready) begin
                    evict_valid <= 1'b0;
                    ev_l2_evict <= 1'b1;
                    if (r2_after_evict_wait)
                        r2_st <= D_WAIT;
                    else if (r2_after_evict_fetch) begin
                        r2_st          <= D_FETCH;
                        read_req       <= 1'b1;
                        read_addr      <= {r2_addr[31:L2_INDEX_LSB], {L2_INDEX_LSB{1'b0}}};
                        ev_l2_read_req <= 1'b1;
                    end
                    else begin
                        // línea completa: guardar (store + llenado)
                        r2_s3_wr <= 1'b1; r2_s3_valid <= 1'b1; r2_s3_touch <= 1'b0;
                        r2_s3_fill <= 1'b1; r2_s3_read <= 1'b0;
                        r2_st <= D_SEND;
                    end
                end
            end

            D_WAIT: if (r2_age >= L2_HIT_CYCLES - 3) begin
                read_req       <= 1'b1;
                read_addr      <= {r2_addr[31:L2_INDEX_LSB], {L2_INDEX_LSB{1'b0}}};
                ev_l2_read_req <= 1'b1;
                r2_st          <= D_FETCH;
            end

            D_FETCH: if (read_ready && !s2_retire) begin
                // La línea llegó pero no puede seguir todavía: se guarda
                if (!r2_we) begin
                    r2_line  <= read_line;
                    r2_dirty <= IS_EXCL ? read_forwarded : read_forwarded;
                    r2_st    <= s2_resp_now ? D_SEND : D_RESP;
                    // con NINE, si la respuesta ya salió, falta el llenado
                    r2_s3_wr <= 1'b1; r2_s3_valid <= 1'b1; r2_s3_touch <= 1'b0;
                    r2_s3_fill <= 1'b1; r2_s3_read <= 1'b0;
                end
                else begin
                    r2_line  <= merge_bytes(read_line, r2_wline, r2_be);
                    r2_dirty <= 1'b1;
                    r2_s3_wr <= 1'b1; r2_s3_valid <= 1'b1; r2_s3_touch <= 1'b0;
                    r2_s3_fill <= 1'b1; r2_s3_read <= 1'b0;
                    r2_st    <= D_SEND;
                end
            end

            D_RESP: if (s2_resp_now && !s2_retire) begin
                // salió la respuesta; con NINE falta el llenado en S3
                r2_s3_wr <= 1'b1; r2_s3_valid <= 1'b1; r2_s3_touch <= 1'b0;
                r2_s3_fill <= 1'b1; r2_s3_read <= 1'b0;
                r2_st <= D_SEND;
            end

            default: ;
            endcase
        end

        if (s2_retire)
            r2_v <= 1'b0;

        if (pop) begin
            r2_v      <= 1'b1;
            r2_st     <= D_DECIDE;
            r2_we     <= q0_we;
            r2_addr   <= q0_addr;
            r2_wline  <= q0_wline;
            r2_be     <= q0_be;
            r2_wdirty <= q0_wdirty;
            r2_age    <= age_inc(q0_age);
        end

        // ---------------- vaciado ----------------
        case (fl_st)

        F_NONE: if (flush_req && pipe_empty && !accept && !l2_rvalid) begin
            scan_ptr <= 9'd0;
            fl_st    <= F_SCAN;
        end

        F_SCAN: begin
            if (bus_valid[scan_way] && bus_dirty[scan_way]) begin
                flush_line_q <= bus_line[scan_way*LINE_W +: LINE_W];
                flush_tag_q  <= bus_tag[scan_way*L2_TAG_W +: L2_TAG_W];
                flush_set_q  <= scan_set;
                flush_way_q  <= scan_way;
                fl_st        <= F_EVICT;
            end
            else if (scan_ptr == SCAN_LAST)
                fl_st <= F_WAIT;
            else
                scan_ptr <= scan_ptr + 9'd1;
        end

        F_EVICT: begin
            evict_valid     <= 1'b1;
            ev_l2_write_req <= 1'b1;
            if (evict_valid && evict_ready) begin
                evict_valid     <= 1'b0;
                clr_dirty_en    <= 1'b1;
                clr_dirty_set   <= flush_set_q;
                clr_dirty_way   <= flush_way_q;
                ev_l2_writeback <= 1'b1;
                scan_ptr        <= scan_ptr + 9'd1;
                fl_st           <= (scan_ptr == SCAN_LAST) ? F_WAIT : F_SCAN;
            end
        end

        F_WAIT: if (lower_drained) fl_st <= F_DONE;

        F_DONE: if (!flush_req) begin
            fl_st  <= F_NONE;
            l2_gnt <= 1'b1;
        end

        default: fl_st <= F_NONE;
        endcase
    end
end


// ============================================================================
// Línea que va al eviction buffer
// ============================================================================

always @(*) begin
    if (fl_st == F_EVICT) begin
        evict_addr = {{(32-PADDR_W){1'b0}}, flush_tag_q, flush_set_q, {L2_INDEX_LSB{1'b0}}};
        evict_line = flush_line_q;
    end
    else if (r2_v && r2_st == D_EVICT) begin
        evict_addr = {{(32-PADDR_W){1'b0}}, r2_vic_tag, r2_set, {L2_INDEX_LSB{1'b0}}};
        evict_line = r2_vic_line;
    end
    else begin
        evict_addr = 32'b0;
        evict_line = '0;
    end
end


// ============================================================================
// Comprobaciones (solo simulación)
// ============================================================================

`ifndef SYNTHESIS
always @(posedge clk) begin
    if (!reset && s4_emit && s2_resp_now)
        $error("l2_cache: dos respuestas en el mismo ciclo");
end
`endif

endmodule
