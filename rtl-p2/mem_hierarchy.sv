/*
================================================================================
 Módulo: mem_hierarchy

 Descripción:
 ------------------------------------------------------------------------------
 Jerarquía de memoria de datos del proyecto 2 (MEM_MODE = 2 en top). Tiene
 los dos puertos de rtl/memory.sv (A para la LSU y B para la cripto) más
 cache_stall y el vaciado, y por dentro:

     puerto A (LSU) ----+
                        +--> l1d_port_arbiter --> l1d_cache --> l2_cache
     puerto B (cripto) -+                                          |
                                                                   v
                        DMEM <-- mem_controller <-- eviction_buffer
                     (clk_mem)    (cruce de relojes)

 Con L2_MODEL = 0 (por defecto) es la jerarquía completa del enunciado:
   - L1-D (José): write-back, write-allocate, exclusiva, LRU, write buffer de
     4 entradas, 2 MSHR y bus versión 2. Va sin parámetros: usa los valores
     por defecto de cache_defs.sv.
   - L2 (Alejandro, l2_cache.sv): 16 KB, 4 vías, hit de 8 ciclos,
     write-back, exclusiva y PLRU por defecto (también desde cache_defs.sv,
     así las dos cachés usan siempre la misma política de inclusión).
   - Eviction buffer de EB_DEPTH líneas y controlador de memoria (Dylan): la
     RAM trabaja con su propio reloj, clk_mem = clk / MEM_DIV (25 MHz con
     MEM_DIV = 4), y una línea tarda Tmem = 25 + 7 × MEM_DIV ciclos (53).
     m_clk lleva clk_mem a DMEM, que top instancia y los testbenches leen.
 Con L2_MODEL = 1 queda la L2 de prueba (l2_model.sv), que siempre acierta
 en 8 ciclos y lee y escribe DMEM con clk. Sirve para comparar y depurar.

 Vaciado (D16, docs/memory-interfaces.md sección 7), con flush_req = 1:
   1. la L1-D manda sus líneas sucias a la L2 (write buffer incluido);
   2. cuando la L1-D termina, la L2 recibe su flush_req y manda sus líneas
      sucias al eviction buffer;
   3. la L2 levanta flush_done cuando además el nivel inferior quedó vacío
      (lower_drained: buffer sin líneas y controlador sin transferencias).
 La L2 recibe su pedido recién al final del paso 1 porque, mientras vacía,
 no atiende peticiones, y la L1-D necesita mandarle sus víctimas.
 flush_done se mantiene mientras flush_req siga en 1. Lo usan los
 testbenches y las herramientas antes de leer DUT.DMEM.mem.

 Todo trabaja con clk, no con core_clk: la caché sigue mientras el núcleo
 está detenido. Solo la RAM usa clk_mem.
================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module mem_hierarchy #(
    // Solo elimina monitores al elaborar; ARB, L1D y L2 son siempre los mismos.
    parameter bit PERF_ENABLE = 1'b1,

    // 0 = L2 real, eviction buffer y controlador; 1 = L2 de prueba (l2_model)
    parameter bit L2_MODEL    = 1'b0,
    parameter int MEM_DIV     = 4,      // clk_mem = clk / MEM_DIV (2 a 5; D12)
    parameter int EB_DEPTH    = 4,      // líneas del eviction buffer (4 a 16; D15)
    // Parámetros de comparación: solo se propagan, sin cambiar algoritmos.
    parameter logic WRITE_POLICY = L1D_DEFAULT_WRITE_POLICY,
    parameter logic ALLOC_POLICY = (WRITE_POLICY == WP_WRITE_BACK) ? AP_WRITE_ALLOC : AP_NO_WRITE_ALLOC,
    parameter logic [1:0] INCL_POLICY = L1D_DEFAULT_INCL_POLICY,
    parameter logic [1:0] L1_REPL_POLICY = L1D_DEFAULT_REPL_POLICY,
    parameter logic [1:0] L2_REPL_POLICY = L2_DEFAULT_REPL_POLICY,
    parameter int N_MSHR = L1D_N_MSHR_DEFAULT,
    parameter int WB_DEPTH = WB_DEPTH_DEFAULT
) (

    input  logic         clk,           // reloj sin detener (no core_clk)
    input  logic         reset,

    // Núcleo, puerto A (LSU)
    input  logic         re,            // carga en EX (cargai, cargabai)
    input  logic         we,            // store en EX (guardap, guardab)
    input  logic [3:0]   be,
    input  logic [31:0]  addr,
    input  logic [31:0]  wdata,
    output logic [31:0]  rdata,

    // Núcleo, puerto B (unidad criptográfica)
    input  logic         re_b,          // vcr o camcon en EX
    input  logic         we_b,          // camcon en EX
    input  logic [31:0]  addr_b,
    input  logic [31:0]  wdata_b,
    output logic [31:0]  rdata_b,

    output logic         stall,         // cache_stall

    // Vaciado de las líneas sucias (testbenches)
    input  logic         flush_req,
    output logic         flush_done,

    // Memoria de datos (puerto A de rtl/memory.sv) y su reloj
    output logic         m_clk,         // clk_mem con la L2 real; clk con l2_model
    output logic         m_we,
    output logic [3:0]   m_be,
    output logic [31:0]  m_addr,
    output logic [31:0]  m_wdata,
    input  logic [31:0]  m_rdata,

    // Default habilitado para consumidores anteriores de la jerarquía.
    // Ventana síncrona común; no regula demandas, grant, respuesta o flush.
    input  logic         perf_measure_enable = 1'b1,

    // Para lcont (D18): lecturas con hit [0] y con miss [1], escrituras con
    // hit [2] y con miss [3] de la L1-D (perf_cache_l1d; cero sin PERF_ENABLE)
    output logic [3:0][63:0] perf_l1d_counts,
    // Acumulados pasivos; cero sin observadores o sin proveedor real.
    // RAM: lecturas, escrituras, ocupado, medido, timeout, error.
    output wire [9:0][63:0] perf_l2_counts,
    output wire [5:0][63:0] perf_ram_counts,
    // Cohortes temporales adicionales. No añaden selectores lcont ni controles;
    // los bancos pueden leerlas sin cambiar top ni el protocolo de memoria.
    output wire [13:0][63:0] perf_l2_latency,
    output wire [21:0][63:0] perf_ram_latency
);


// Puerto único de la L1-D
logic        c_re;
logic        c_we;
logic [3:0]  c_be;
logic [31:0] c_addr;
logic [31:0] c_wdata;
logic [31:0] c_rdata;
logic        c_stall;

// Bus L1-D <-> L2, versión 2
logic                   l2_req;
logic                   l2_we;
logic [31:0]            l2_addr;
logic [LINE_W-1:0]      l2_wline;
logic [LINE_MASK_W-1:0] l2_be;
logic                   l2_wdirty;
logic                   l2_gnt;
logic                   l2_rvalid;
logic [LINE_W-1:0]      l2_rline;
logic                   l2_rdirty;

logic l1_flush_done;
logic l2_idle;


l1d_port_arbiter ARB (
    .clk(clk),
    .reset(reset),
    .re(re),
    .we(we),
    .be(be),
    .addr(addr),
    .wdata(wdata),
    .rdata(rdata),
    .re_b(re_b),
    .we_b(we_b),
    .addr_b(addr_b),
    .wdata_b(wdata_b),
    .rdata_b(rdata_b),
    .stall(stall),
    .c_re(c_re),
    .c_we(c_we),
    .c_be(c_be),
    .c_addr(c_addr),
    .c_wdata(c_wdata),
    .c_rdata(c_rdata),
    .c_stall(c_stall)
);

// Los diecinueve bits provienen exclusivamente de salidas públicas de L1D.
// 0..3 clasifican demandas completadas; 4..6 son esperas, 7..18 auxiliares,
// tráfico, fills, víctimas y MSHR. Un fill o un push de flush no es otra demanda.
// Estas conexiones no reconstruyen hits mediante etiquetas privadas.
wire [18:0] perf_events;
wire [18:0][63:0] perf_event_counts;

assign perf_l1d_counts = {perf_event_counts[3], perf_event_counts[2],
                          perf_event_counts[1], perf_event_counts[0]};
wire [4:0][63:0] perf_access_totals;
wire [3:0][63:0] perf_completed_by_class, perf_service_by_class, perf_wait_by_class;
wire [63:0] perf_completed_accesses, perf_completed_reads, perf_completed_writes;
wire [63:0] perf_completed_hits, perf_completed_misses, perf_service_cycles, perf_wait_cycles;
wire [63:0] perf_no_wait_accesses, perf_excluded_accesses, perf_protocol_errors;
wire perf_pending, perf_pending_eligible;
wire [63:0] perf_pending_wait_cycles;
// La geometría permanece fija; solo cambian políticas explícitamente solicitadas.
l1d_cache #(.WRITE_POLICY(WRITE_POLICY), .ALLOC_POLICY(ALLOC_POLICY),
    .INCL_POLICY(INCL_POLICY), .REPL_POLICY(L1_REPL_POLICY),
    .N_MSHR(N_MSHR), .WB_DEPTH(WB_DEPTH)) L1D (
    .clk(clk),
    .reset(reset),
    .re(c_re),
    .we(c_we),
    .be(c_be),
    .addr(c_addr),
    .wdata(c_wdata),
    .rdata(c_rdata),
    .stall(c_stall),
    .flush_req(flush_req),
    .flush_done(l1_flush_done),
    .l2_req(l2_req),
    .l2_we(l2_we),
    .l2_addr(l2_addr),
    .l2_wline(l2_wline),
    .l2_be(l2_be),
    .l2_wdirty(l2_wdirty),
    .l2_gnt(l2_gnt),
    .l2_rvalid(l2_rvalid),
    .l2_rdirty(l2_rdirty),
    .l2_rline(l2_rline),
    .ev_rd_hit(perf_events[0]),
    .ev_rd_miss(perf_events[1]),
    .ev_wr_hit(perf_events[2]),
    .ev_wr_miss(perf_events[3]),
    .ev_stall(perf_events[4]),
    .ev_wb_full_stall(perf_events[5]),
    .ev_raw_stall(perf_events[6]),
    .ev_raw_forward(perf_events[7]),
    .ev_wb_push(perf_events[8]),
    .ev_l2_read(perf_events[9]),
    .ev_l2_write(perf_events[10]),
    .ev_fill(perf_events[11]),
    .ev_victim_dirty(perf_events[12]),
    .ev_victim_clean(perf_events[13]),
    .ev_mshr_alloc(perf_events[14]),
    .ev_mshr_merge(perf_events[15]),
    .ev_mshr_load(perf_events[16]),
    .ev_hit_under_miss(perf_events[17]),
    .ev_mshr_full_stall(perf_events[18])
);

// Fuentes públicas PRE. Nunca se cuentan niveles ram_req como aceptaciones.
wire [9:0] perf_l2_events;
wire mc_accept, mc_write, mc_busy, mc_timeout, mc_error, mc_ready;
generate if (L2_MODEL) begin : g_l2_model

    // L2 de prueba: siempre acierta y lee y escribe DMEM con clk
    l2_model L2 (
        .clk(clk),
        .reset(reset),
        .l2_req(l2_req),
        .l2_we(l2_we),
        .l2_addr(l2_addr),
        .l2_wline(l2_wline),
        .l2_be(l2_be),
        .l2_wdirty(l2_wdirty),
        .l2_gnt(l2_gnt),
        .l2_rvalid(l2_rvalid),
        .l2_rline(l2_rline),
        .l2_rdirty(l2_rdirty),
        .idle(l2_idle),
        .m_we(m_we),
        .m_be(m_be),
        .m_addr(m_addr),
        .m_wdata(m_wdata),
        .m_rdata(m_rdata)
    );

    assign perf_l2_events = '0;
    assign {mc_accept,mc_write,mc_busy,mc_timeout,mc_error} = '0;
    assign mc_ready = 1'b0;
    assign m_clk      = clk;
    assign flush_done = l1_flush_done && l2_idle;
end
else begin : g_l2_real

    // L2 <-> eviction buffer
    logic              evict_valid;
    logic [31:0]       evict_addr;
    logic [LINE_W-1:0] evict_line;
    logic              evict_ready;
    logic              read_req;
    logic [31:0]       read_addr;
    logic              read_ready;
    logic [LINE_W-1:0] read_line;
    logic              read_forwarded;

    // Eviction buffer <-> controlador de memoria
    logic              ram_req;
    logic              ram_we;
    logic [31:0]       ram_addr;
    logic [LINE_W-1:0] ram_wline;
    logic              ram_ready;
    logic [LINE_W-1:0] ram_rline;
    logic              ram_error;

    // ram_ready ya es un puerto público de MC. Solo se copia al observador;
    // el controlador, el buffer y su temporización conservan sus conexiones.
    assign mc_ready = ram_ready;

    // Controlador <-> RAM (una palabra por flanco de clk_mem)
    logic              clk_mem;
    logic [13:0]       mem_word_addr;
    logic [31:0]       mem_word_wdata;
    logic              mem_word_we;

    logic              eb_busy;
    logic              l2_flush_done;

    l2_cache #(.INCL_POLICY(INCL_POLICY), .REPL_POLICY(L2_REPL_POLICY)) L2 (
        .clk(clk),
        .reset(reset),
        .l2_req(l2_req),
        .l2_we(l2_we),
        .l2_addr(l2_addr),
        .l2_wline(l2_wline),
        .l2_be(l2_be),
        .l2_wdirty(l2_wdirty),
        .l2_gnt(l2_gnt),
        .l2_rvalid(l2_rvalid),
        .l2_rline(l2_rline),
        .l2_rdirty(l2_rdirty),
        .idle(l2_idle),
        .evict_valid(evict_valid),
        .evict_addr(evict_addr),
        .evict_line(evict_line),
        .evict_ready(evict_ready),
        .read_req(read_req),
        .read_addr(read_addr),
        .read_ready(read_ready),
        .read_line(read_line),
        .read_forwarded(read_forwarded),
        .flush_req(flush_req && l1_flush_done),     // paso 2: después de la L1-D
        .flush_done(l2_flush_done),
        .lower_drained(!eb_busy),                   // paso 3: buffer y controlador vacíos
        .ev_l2_rd_hit(perf_l2_events[0]), .ev_l2_rd_miss(perf_l2_events[1]),
        .ev_l2_wr_hit(perf_l2_events[2]), .ev_l2_wr_miss(perf_l2_events[3]),
        .ev_l2_fill(perf_l2_events[4]), .ev_l2_evict(perf_l2_events[5]),
        .ev_l2_writeback(perf_l2_events[6]), .ev_l2_invalid(perf_l2_events[7]),
        .ev_l2_read_req(perf_l2_events[8]), .ev_l2_write_req(perf_l2_events[9])
    );

    eviction_buffer #(.EB_DEPTH(EB_DEPTH)) EB (
        .clk(clk),
        .reset(reset),
        .evict_valid(evict_valid),
        .evict_addr(evict_addr),
        .evict_line(evict_line),
        .evict_ready(evict_ready),
        .read_req(read_req),
        .read_addr(read_addr),
        .read_ready(read_ready),
        .read_line(read_line),
        .read_forwarded(read_forwarded),
        .ram_req(ram_req),
        .ram_we(ram_we),
        .ram_addr(ram_addr),
        .ram_wline(ram_wline),
        .ram_ready(ram_ready),
        .ram_rline(ram_rline),
        .ram_error(ram_error),
        .clear_write_error(1'b0),
        .busy(eb_busy)
    );

    mem_controller #(
        .MEM_DIV(MEM_DIV),
        .MEM_TIMEOUT(256),
        .TMEM(25 + 7 * MEM_DIV)
    ) MC (
        .clk(clk),
        .reset(reset),
        .ram_req(ram_req),
        .ram_we(ram_we),
        .ram_addr(ram_addr),
        .ram_wline(ram_wline),
        .ram_ready(ram_ready),
        .ram_rline(ram_rline),
        .mem_error(ram_error),
        .mem_hold(1'b0),
        .clk_mem(clk_mem),
        .mem_word_addr(mem_word_addr),
        .mem_word_wdata(mem_word_wdata),
        .mem_word_we(mem_word_we),
        .mem_word_rdata(m_rdata),
        .req_accept(mc_accept), .req_we_accepted(mc_write),
        .transfer_busy(mc_busy), .timeout_event(mc_timeout), .error_event(mc_error)
    );

    // DMEM pasa a ser la RAM del controlador: palabras completas con clk_mem
    assign m_clk   = clk_mem;
    assign m_we    = mem_word_we;
    assign m_be    = 4'b1111;
    assign m_addr  = {16'b0, mem_word_addr, 2'b00};
    assign m_wdata = mem_word_wdata;

    assign flush_done = l1_flush_done && l2_flush_done;

`ifndef SYNTHESIS
    // Checker de exclusividad (D3), solo en simulación: le pasa los bits de
    // validez y las etiquetas de las dos cachés. Con NINE no se instancia,
    // porque ahí una línea puede estar en los dos niveles.
    if (INCL_POLICY == INCL_EXCLUSIVE) begin : g_excl

        logic [L1D_WAYS*L1D_SETS-1:0]           x_l1_valid;
        logic [L1D_WAYS*L1D_SETS*L1D_TAG_W-1:0] x_l1_tag;
        logic [L2_WAYS*L2_SETS-1:0]             x_l2_valid;
        logic [L2_WAYS*L2_SETS*L2_TAG_W-1:0]    x_l2_tag;

        genvar xw, xs;

        for (xw = 0; xw < L1D_WAYS; xw++) begin : g_l1_way
            assign x_l1_valid[xw*L1D_SETS +: L1D_SETS] = L1D.ARRAYS.g_way[xw].valid_bits;
            for (xs = 0; xs < L1D_SETS; xs++) begin : g_set
                assign x_l1_tag[(xw*L1D_SETS + xs)*L1D_TAG_W +: L1D_TAG_W] =
                       L1D.ARRAYS.g_way[xw].tag_mem[xs];
            end
        end

        for (xw = 0; xw < L2_WAYS; xw++) begin : g_l2_way
            assign x_l2_valid[xw*L2_SETS +: L2_SETS] = L2.ARRAYS.g_way[xw].valid_bits;
            for (xs = 0; xs < L2_SETS; xs++) begin : g_set
                assign x_l2_tag[(xw*L2_SETS + xs)*L2_TAG_W +: L2_TAG_W] =
                       L2.ARRAYS.g_way[xw].tag_mem[xs];
            end
        end

        excl_checker EXCL (
            .clk(clk),
            .reset(reset),
            .l1_valid(x_l1_valid),
            .l1_tag(x_l1_tag),
            .l2_valid(x_l2_valid),
            .l2_tag(x_l2_tag),
            .violations(),
            .checked_cycles()
        );
    end
`endif

    // D14: después del reintento, un error de memoria se avisa en la simulación
    // (una vez por error: mem_error se mantiene hasta la siguiente petición)
    logic ram_error_q;

    always @(posedge clk) begin
        ram_error_q <= !reset && ram_error;
        if (!reset && ram_error && !ram_error_q)
            $error("mem_hierarchy: error de la memoria principal (timeout después del reintento)");
    end
end endgenerate


// Ambos consumidores usan clk general: la caché continúa con el núcleo
// detenido. Se muestrean eventos PRE y los acumulados cambian mediante NBA.
// La habilitación y reset comunes no se devuelven a ARB/L1D/L2: solo reciben
// los mismos controles de observación que los monitores del núcleo.
generate if (PERF_ENABLE) begin : g_perf
    // K1-A conserva su población por flanco habilitado. Los diecinueve eventos
    // se conectan uno a uno; el productor decide clasificación y finalización.
    // Un store puede terminar al reservar MSHR y su fill posterior solo suma
    // actividad auxiliar. L2-read/write son inicios, no hits/misses de L2.
    // La pausa retiene registros y omite eventos; reset borra con prioridad.
    // Sus salidas no intervienen en stall, solicitudes, flush ni datos.
    perf_cache_l1d PERF_K1A (
        .clk(clk), .reset(reset), .measure_enable(perf_measure_enable),
        .ev_rd_hit(perf_events[0]),
        .ev_rd_miss(perf_events[1]),
        .ev_wr_hit(perf_events[2]),
        .ev_wr_miss(perf_events[3]),
        .ev_stall(perf_events[4]),
        .ev_wb_full_stall(perf_events[5]),
        .ev_raw_stall(perf_events[6]),
        .ev_raw_forward(perf_events[7]),
        .ev_wb_push(perf_events[8]),
        .ev_l2_read(perf_events[9]),
        .ev_l2_write(perf_events[10]),
        .ev_fill(perf_events[11]),
        .ev_victim_dirty(perf_events[12]),
        .ev_victim_clean(perf_events[13]),
        .ev_mshr_alloc(perf_events[14]),
        .ev_mshr_merge(perf_events[15]),
        .ev_mshr_load(perf_events[16]),
        .ev_hit_under_miss(perf_events[17]),
        .ev_mshr_full_stall(perf_events[18]),
        .read_hits(perf_event_counts[0]),
        .read_misses(perf_event_counts[1]),
        .write_hits(perf_event_counts[2]),
        .write_misses(perf_event_counts[3]),
        .stall_cycles(perf_event_counts[4]),
        .wb_full_stall_cycles(perf_event_counts[5]),
        .raw_stall_cycles(perf_event_counts[6]),
        .raw_forward_events(perf_event_counts[7]),
        .wb_push_events(perf_event_counts[8]),
        .l2_read_requests(perf_event_counts[9]),
        .l2_write_requests(perf_event_counts[10]),
        .fill_events(perf_event_counts[11]),
        .victim_dirty_events(perf_event_counts[12]),
        .victim_clean_events(perf_event_counts[13]),
        .mshr_alloc_events(perf_event_counts[14]),
        .mshr_merge_events(perf_event_counts[15]),
        .mshr_load_events(perf_event_counts[16]),
        .hit_under_miss_events(perf_event_counts[17]),
        .mshr_full_stall_cycles(perf_event_counts[18]),
        .read_accesses(perf_access_totals[0]),
        .write_accesses(perf_access_totals[1]),
        .total_accesses(perf_access_totals[2]),
        .total_hits(perf_access_totals[3]),
        .total_misses(perf_access_totals[4])
    );

    // K1-B ve c_re/c_we/c_stall DESPUÉS del árbitro, exactamente la demanda
    // del puerto único que recibe L1D. No suma simultáneamente A y B ni añade
    // el tiempo de arbitraje al servicio interno de una demanda diferente.
    // Cada fase B-read/A/B-write es otra demanda, aunque pertenezcan al mismo
    // bundle. Su clase procede de los mismos cuatro eventos públicos de L1D.
    // El seguimiento continúa en pausa y excluye el acceso que la atraviesa;
    // K1-A puede contar su final habilitado, por lo que sus cohortes difieren.
    // Reset desconoce inicios previos; reposo o fin recuperan frontera conocida.
    // Mantenimiento sin demanda no añade servicio. pending/errores son
    // diagnósticos independientes de la ventana, nunca controles del productor.
    perf_cache_l1d_latency PERF_K1B (
        .clk(clk), .reset(reset), .measure_enable(perf_measure_enable),
        .re(c_re), .we(c_we), .stall(c_stall),
        .ev_rd_hit(perf_events[0]), .ev_rd_miss(perf_events[1]),
        .ev_wr_hit(perf_events[2]), .ev_wr_miss(perf_events[3]),
        .completed_by_class(perf_completed_by_class),
        .service_by_class(perf_service_by_class),
        .wait_by_class(perf_wait_by_class),
        .completed_accesses(perf_completed_accesses),
        .completed_reads(perf_completed_reads),
        .completed_writes(perf_completed_writes),
        .completed_hits(perf_completed_hits),
        .completed_misses(perf_completed_misses),
        .service_cycles(perf_service_cycles),
        .wait_cycles(perf_wait_cycles),
        .no_wait_accesses(perf_no_wait_accesses),
        .excluded_accesses(perf_excluded_accesses),
        .protocol_errors(perf_protocol_errors),
        .pending(perf_pending),
        .pending_eligible(perf_pending_eligible),
        .pending_wait_cycles(perf_pending_wait_cycles)
    );
end else begin : g_no_perf
    // Mismos productores sin consumidores registrados. Ceros explícitos permiten
    // observar la configuración desactivada sin leer instancias inexistentes.
    assign perf_event_counts='0;
    assign perf_access_totals='0;
    assign {perf_completed_by_class,perf_service_by_class,perf_wait_by_class}='0;
    assign {perf_completed_accesses,perf_completed_reads,perf_completed_writes,
            perf_completed_hits,perf_completed_misses,perf_service_cycles,perf_wait_cycles,
            perf_no_wait_accesses,perf_excluded_accesses,perf_protocol_errors,
            perf_pending_wait_cycles}='0;
    assign {perf_pending,perf_pending_eligible}=2'b00;
end endgenerate


// Observadores reales: su única dependencia hacia la jerarquía son entradas.
// El mismo enable de D18/ventana se aplica a L1, L2 y RAM en clk general.
generate if (PERF_ENABLE && !L2_MODEL) begin : g_perf_real
    // Los tiempos asocian aceptación y respuesta, no busy/eventos agregados.
    // Ambos usan clk general y la misma ventana D18 de los contadores existentes.
    perf_cache_l2_latency PERF_L2_LATENCY (
        .clk(clk), .reset(reset), .measure_enable(perf_measure_enable),
        .l2_req(l2_req), .l2_we(l2_we), .l2_gnt(l2_gnt), .l2_rvalid(l2_rvalid),
        .ev_rd_hit(perf_l2_events[0]), .ev_rd_miss(perf_l2_events[1]),
        .ev_wr_hit(perf_l2_events[2]), .ev_wr_miss(perf_l2_events[3]),
        .counts(perf_l2_latency)
    );
    perf_memory_latency PERF_RAM_LATENCY (
        .clk(clk), .reset(reset), .measure_enable(perf_measure_enable),
        .req_accept(mc_accept), .req_we_accepted(mc_write), .transfer_busy(mc_busy),
        .ram_ready(mc_ready), .timeout_event(mc_timeout), .error_event(mc_error),
        .counts(perf_ram_latency)
    );
    perf_cache_l2 PERF_L2 (
        .clk(clk), .reset(reset), .measure_enable(perf_measure_enable),
        .ev_l2_rd_hit(perf_l2_events[0]), .ev_l2_rd_miss(perf_l2_events[1]),
        .ev_l2_wr_hit(perf_l2_events[2]), .ev_l2_wr_miss(perf_l2_events[3]),
        .ev_l2_fill(perf_l2_events[4]), .ev_l2_evict(perf_l2_events[5]),
        .ev_l2_writeback(perf_l2_events[6]), .ev_l2_invalid(perf_l2_events[7]),
        .ev_l2_read_req(perf_l2_events[8]), .ev_l2_write_req(perf_l2_events[9]),
        .event_counts(perf_l2_counts), .read_accesses(), .write_accesses(),
        .total_hits(), .total_misses(), .total_accesses(), .fill_events(),
        .replacement_evictions(), .flush_writebacks(), .exclusive_invalidations(),
        .lower_read_requests(), .lower_write_offer_cycles()
    );
    // req_we_accepted ya está calificada por aceptación en MC. Transfer_busy
    // incluye espera y reintentos reales; no se multiplica por Tmem supuesto.
    perf_memory PERF_RAM (
        .clk(clk), .reset(reset), .clear(1'b0), .measure_enable(perf_measure_enable),
        .req_accept(mc_accept), .req_we(mc_write), .transfer_busy(mc_busy),
        .timeout_event(mc_timeout), .error_event(mc_error),
        .read_accesses(perf_ram_counts[0]), .write_accesses(perf_ram_counts[1]),
        .transfer_cycles(perf_ram_counts[2]), .total_cycles(perf_ram_counts[3]),
        .timeout_count(perf_ram_counts[4]), .error_count(perf_ram_counts[5])
    );
end else begin : g_no_perf_real
    assign perf_l2_latency = '0;
    assign perf_ram_latency = '0;
    assign perf_l2_counts = '0;
    assign perf_ram_counts = '0;
end endgenerate

endmodule
