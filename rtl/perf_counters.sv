// Bloque A del issue #7: ciclos dentro de una ventana de medición.
// Usar clk sin detener cuando se integre al procesador.
module perf_counters (
    input  logic        clk,
    input  logic        reset,
    input  logic        measure_enable,
    output logic [63:0] cycle_count
);

// Reset síncrono prioritario. Deshabilitar pausa; no borra la medición.
// La suma de 64 bits vuelve a cero al superar 2^64 - 1.
always @(posedge clk) begin
    if (reset)
        cycle_count <= 64'd0;
    else if (measure_enable)
        cycle_count <= cycle_count + 64'd1;
end

endmodule
