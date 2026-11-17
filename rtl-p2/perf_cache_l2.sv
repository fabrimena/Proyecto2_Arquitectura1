/* Observa los diez eventos públicos registrados de L2, sin realimentar su control.
 * Acumula en clk general los niveles PRE; reset síncrono tiene prioridad y pausa
 * conserva valores. Cada acumulador desborda naturalmente módulo 2^64.
 * Las cuatro clasificaciones pertenecen a decisiones S2, no a demandas L1.
 * ev_l2_write_req mide ciclos de oferta: una oferta retenida NO es otra escritura
 * física aceptada. Reemplazo, vaciado y movimiento exclusivo son poblaciones distintas. */
module perf_cache_l2 (
    input logic clk, reset, measure_enable,
    input logic ev_l2_rd_hit, ev_l2_rd_miss, ev_l2_wr_hit, ev_l2_wr_miss,
    input logic ev_l2_fill, ev_l2_evict, ev_l2_writeback, ev_l2_invalid,
    input logic ev_l2_read_req, ev_l2_write_req,
    // Orden contractual: RH, RM, WH, WM, fill, víctima sucia por reemplazo,
    // writeback de vaciado, invalidación por movimiento, read_req, write_offer.
    output logic [9:0][63:0] event_counts,
    output wire [63:0] read_accesses, write_accesses,
    output wire [63:0] total_hits, total_misses, total_accesses,
    output wire [63:0] fill_events, replacement_evictions, flush_writebacks,
    output wire [63:0] exclusive_invalidations, lower_read_requests, lower_write_offer_cycles
);
    wire [9:0] events = {ev_l2_write_req,ev_l2_read_req,ev_l2_invalid,
        ev_l2_writeback,ev_l2_evict,ev_l2_fill,ev_l2_wr_miss,ev_l2_wr_hit,
        ev_l2_rd_miss,ev_l2_rd_hit};
    // Sumas combinacionales de una misma población clasificada; no hay divisor,
    // deduplicación por flanco ni una estimación de aceptación del nivel inferior.
    assign read_accesses = event_counts[0]+event_counts[1];
    assign write_accesses = event_counts[2]+event_counts[3];
    assign total_hits = event_counts[0]+event_counts[2];
    assign total_misses = event_counts[1]+event_counts[3];
    assign total_accesses = read_accesses+write_accesses;
    assign fill_events = event_counts[4];
    assign replacement_evictions = event_counts[5];
    assign flush_writebacks = event_counts[6];
    assign exclusive_invalidations = event_counts[7];
    assign lower_read_requests = event_counts[8];
    assign lower_write_offer_cycles = event_counts[9];
    integer i;
    always @(posedge clk) begin
        if (reset) event_counts <= '0;
        else if (measure_enable)
            for (i=0;i<10;i=i+1)
                if (events[i]) event_counts[i] <= event_counts[i]+64'd1;
        // Dos clasificaciones consecutivas pueden ser operaciones distintas.
        // Los eventos fuera de ventana no se guardan para contarlos al reanudar.
    end
endmodule
