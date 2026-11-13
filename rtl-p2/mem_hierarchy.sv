/*
================================================================================
 Módulo: mem_hierarchy

 Descripción:
 ------------------------------------------------------------------------------
 Jerarquía de memoria de datos del proyecto 2 (MEM_MODE = 2 en top). Tiene
 los dos puertos de rtl/memory.sv (A para la LSU y B para la cripto) más
 cache_stall y el vaciado, y por dentro:

     puerto A (LSU) ----+
                        +--> l1d_port_arbiter --> l1d_cache --> l2_model --> DMEM
     puerto B (cripto) -+

 La L1-D va sin parámetros, con su configuración por defecto (cache_defs.sv):
 write-back, write-allocate, exclusiva, LRU, write buffer de 4 entradas,
 2 MSHR y bus versión 2. Mientras no esté la L2 real, l2_model hace de L2:
 siempre acierta en 8 ciclos y lee y escribe DMEM. Después se conectan aquí
 la L2, el eviction buffer y el controlador de memoria, sin cambiar top.

 Vaciado: con flush_req = 1 la L1-D manda sus líneas sucias a la L2.
 flush_done = 1 cuando la L1-D terminó y la L2 de prueba ya escribió todo en
 DMEM, y se mantiene mientras flush_req siga en 1. Lo usan los testbenches
 antes de leer DUT.DMEM.mem.

 Todo trabaja con clk, no con core_clk: la caché sigue mientras el núcleo
 está detenido.
================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module mem_hierarchy #(
    // Solo elimina monitores al elaborar; ARB, L1D y L2 son siempre los mismos.
    parameter bit PERF_ENABLE = 1'b1
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

    // Memoria de datos (puerto A de rtl/memory.sv)
    output logic         m_we,
    output logic [3:0]   m_be,
    output logic [31:0]  m_addr,
    output logic [31:0]  m_wdata,
    input  logic [31:0]  m_rdata,

    // Default habilitado para consumidores anteriores de la jerarquía.
    // Ventana síncrona común; no regula demandas, grant, respuesta o flush.
    input  logic         perf_measure_enable = 1'b1
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
wire [4:0][63:0] perf_access_totals;
wire [3:0][63:0] perf_completed_by_class, perf_service_by_class, perf_wait_by_class;
wire [63:0] perf_completed_accesses, perf_completed_reads, perf_completed_writes;
wire [63:0] perf_completed_hits, perf_completed_misses, perf_service_cycles, perf_wait_cycles;
wire [63:0] perf_no_wait_accesses, perf_excluded_accesses, perf_protocol_errors;
wire perf_pending, perf_pending_eligible;
wire [63:0] perf_pending_wait_cycles;
l1d_cache L1D (
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

assign flush_done = l1_flush_done && l2_idle;


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

endmodule
