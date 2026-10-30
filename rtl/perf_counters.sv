// Bloques A, B y C del issue #7: trabajo y penalizaciones en una ventana.
// Usar clk sin detener cuando se integre al procesador.
module perf_counters (
    input  logic        clk,
    input  logic        reset,
    input  logic        measure_enable,
    input  logic        bundle_complete,
    input  logic [3:0]  non_nop_mask,
    input  logic        memory_stall,
    input  logic        branch_recovery,
    output logic [63:0] cycle_count,
    output logic [63:0] bundle_count,
    output logic [63:0] instruction_count,
    output logic [63:0] memory_stall_count,
    output logic [63:0] branch_penalty_count
);

// Un bit por slot: ALU, LSU, BRU y CRIPTO, desde el bit 0 al 3.
// Tres bits representan de 0 a 4 operaciones sin truncar la suma.
logic [2:0] completed_ops;
assign completed_ops = {2'b0, non_nop_mask[0]} + {2'b0, non_nop_mask[1]} +
                       {2'b0, non_nop_mask[2]} + {2'b0, non_nop_mask[3]};

// Reset síncrono prioritario. Deshabilitar pausa; no borra la medición.
// La suma de 64 bits vuelve a cero al superar 2^64 - 1.
always @(posedge clk) begin
    if (reset) begin
        cycle_count <= 64'd0;
        bundle_count <= 64'd0;
        instruction_count <= 64'd0;
        memory_stall_count <= 64'd0;
        branch_penalty_count <= 64'd0;
    end
    else if (measure_enable) begin
        cycle_count <= cycle_count + 64'd1;
        // Cada flanco con evento es una finalización distinta, incluso si
        // bundle_complete está activo en varios ciclos consecutivos.
        // El congelamiento global por memoria impide completar otro bundle.
        if (bundle_complete && !memory_stall) begin
            bundle_count <= bundle_count + 64'd1;
            instruction_count <= instruction_count + {61'd0, completed_ops};
        end
        // Convención de medición: memoria tiene prioridad en coincidencias.
        // branch_recovery describe un ciclo perdido, no un evento de salto.
        if (memory_stall)
            memory_stall_count <= memory_stall_count + 64'd1;
        else if (branch_recovery)
            branch_penalty_count <= branch_penalty_count + 64'd1;
    end
end

endmodule
