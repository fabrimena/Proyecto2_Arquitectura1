/* Acumula eventos públicos de L1-D sin intervenir en accesos, políticas o handshake. */
module perf_cache_l1d (
    input logic clk, // Reloj general: la caché trabaja también con el núcleo detenido.
    input logic reset,
    input logic measure_enable, // Solo habilita acumulación; los eventos omitidos no se encolan.
    input logic ev_rd_hit,
    input logic ev_rd_miss,
    input logic ev_wr_hit,
    input logic ev_wr_miss,
    input logic ev_stall,
    input logic ev_wb_full_stall,
    input logic ev_raw_stall,
    input logic ev_raw_forward,
    input logic ev_wb_push,
    input logic ev_l2_read,
    input logic ev_l2_write,
    input logic ev_fill,
    input logic ev_victim_dirty,
    input logic ev_victim_clean,
    input logic ev_mshr_alloc,
    input logic ev_mshr_merge,
    input logic ev_mshr_load,
    input logic ev_hit_under_miss,
    input logic ev_mshr_full_stall,
    output logic [63:0] fill_events,
    output logic [63:0] victim_dirty_events,
    output logic [63:0] victim_clean_events,
    output logic [63:0] mshr_alloc_events,
    output logic [63:0] mshr_merge_events,
    output logic [63:0] mshr_load_events,
    output logic [63:0] hit_under_miss_events,
    output logic [63:0] mshr_full_stall_cycles,
    output logic [63:0] read_hits,
    output logic [63:0] read_misses,
    output logic [63:0] write_hits,
    output logic [63:0] write_misses,
    output logic [63:0] stall_cycles,
    output logic [63:0] wb_full_stall_cycles,
    output logic [63:0] raw_stall_cycles,
    output logic [63:0] raw_forward_events,
    output logic [63:0] wb_push_events,
    output logic [63:0] l2_read_requests,
    output logic [63:0] l2_write_requests,
    output logic [63:0] read_accesses,
    output logic [63:0] write_accesses,
    output logic [63:0] total_accesses,
    output logic [63:0] total_hits,
    output logic [63:0] total_misses
);

// Los totales se derivan sin registros adicionales. Tanto estas sumas como
// los diecinueve acumuladores son unsigned de 64 bits y desbordan módulo 2^64.
assign read_accesses = read_hits + read_misses;
assign write_accesses = write_hits + write_misses;
assign total_accesses = read_accesses + write_accesses;
assign total_hits = read_hits + write_hits;
assign total_misses = read_misses + write_misses;

always @(posedge clk) begin
    if (reset) begin
        // Reset síncrono prioritario, incluso con medición y eventos activos.
        fill_events <= 64'd0;
        victim_dirty_events <= 64'd0;
        victim_clean_events <= 64'd0;
        mshr_alloc_events <= 64'd0;
        mshr_merge_events <= 64'd0;
        mshr_load_events <= 64'd0;
        hit_under_miss_events <= 64'd0;
        mshr_full_stall_cycles <= 64'd0;
        read_hits <= 64'd0;
        read_misses <= 64'd0;
        write_hits <= 64'd0;
        write_misses <= 64'd0;
        stall_cycles <= 64'd0;
        wb_full_stall_cycles <= 64'd0;
        raw_stall_cycles <= 64'd0;
        raw_forward_events <= 64'd0;
        wb_push_events <= 64'd0;
        l2_read_requests <= 64'd0;
        l2_write_requests <= 64'd0;
    end
    else if (measure_enable) begin
        // Clasificaciones al completar el acceso. No se detectan flancos del
        // evento: dos niveles activos consecutivos pueden ser dos accesos distintos.
        if (ev_rd_hit) read_hits <= read_hits + 64'd1;
        if (ev_rd_miss) read_misses <= read_misses + 64'd1;
        if (ev_wr_hit) write_hits <= write_hits + 64'd1;
        if (ev_wr_miss) write_misses <= write_misses + 64'd1;
        // Esperas por flanco. Las causas no se suman para reconstruir el total
        // ni se aplican prioridades: cada indicador conserva su propia magnitud.
        if (ev_stall) stall_cycles <= stall_cycles + 64'd1;
        if (ev_wb_full_stall) wb_full_stall_cycles <= wb_full_stall_cycles + 64'd1;
        if (ev_raw_stall) raw_stall_cycles <= raw_stall_cycles + 64'd1;
        // Forwarding y push son eventos auxiliares, no nuevos accesos demandados.
        if (ev_raw_forward) raw_forward_events <= raw_forward_events + 64'd1;
        if (ev_wb_push) wb_push_events <= wb_push_events + 64'd1;
        // Inicios L1-D -> L2; no indican hits o misses de una L2 real.
        if (ev_l2_read) l2_read_requests <= l2_read_requests + 64'd1;
        if (ev_l2_write) l2_write_requests <= l2_write_requests + 64'd1;
        // Los llenados, víctimas y MSHR no son nuevas demandas. Un store
        // puede reservar o mezclar sin stall; el fill sucede por detrás.
        // La víctima se cuenta al entrar al buffer, nunca por su permanencia.
        if (ev_fill) fill_events <= fill_events + 64'd1;
        if (ev_victim_dirty) victim_dirty_events <= victim_dirty_events + 64'd1;
        if (ev_victim_clean) victim_clean_events <= victim_clean_events + 64'd1;
        if (ev_mshr_alloc) mshr_alloc_events <= mshr_alloc_events + 64'd1;
        if (ev_mshr_merge) mshr_merge_events <= mshr_merge_events + 64'd1;
        if (ev_mshr_load) mshr_load_events <= mshr_load_events + 64'd1;
        if (ev_hit_under_miss) hit_under_miss_events <= hit_under_miss_events + 64'd1;
        if (ev_mshr_full_stall) mshr_full_stall_cycles <= mshr_full_stall_cycles + 64'd1;
    end
    // En pausa todos los acumuladores se conservan y los totales siguen sus sumas.
    // El productor garantiza clasificación única y un pulso por inicio L2;
    // este consumidor no deduplica peticiones ni altera el funcionamiento de L1-D.
end
endmodule
