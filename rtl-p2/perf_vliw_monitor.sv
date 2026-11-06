/* Integra las métricas VLIW y la recuperación causal BRU sin intervenir en el núcleo. */
module perf_vliw_monitor (
    input logic clk, // Reloj general: continúa activo durante las esperas.
    input logic reset,
    input logic measure_enable, // Solo habilita acumulación; no detiene el seguimiento.
    input logic core_advance, // Decisión efectiva y estable antes del flanco actual.
    input logic id_valid,
    input logic [127:0] id_bundle,
    input logic ex_valid, // Validez real del bundle que ocupa EX antes del flanco.
    input logic ex_branch_taken,
    input logic ex_exception,
    output logic [63:0] cycle_count,
    output logic [63:0] bundle_count,
    output logic [63:0] instruction_count,
    output logic [63:0] memory_stall_count,
    output logic [63:0] branch_penalty_count,
    output logic bundle_complete,
    output logic branch_recovery,
    output logic memory_stall,
    output logic [3:0] wb_non_nop_mask // Máscara del WB que puede consumirse en este flanco.
);

logic [3:0] id_non_nop_mask;
logic effective_branch, effective_exception, accepted_branch;
logic discarded_id, discarded_ex;

// Una excepción de EX válido suprime BRU. El monitor conserva su propia validez
// transportada; el productor debe alinear las entradas reales con ese mismo flujo.
assign effective_exception = ex_valid && ex_exception;
assign effective_branch = ex_valid && ex_branch_taken && !ex_exception;
assign accepted_branch = !reset && core_advance && effective_branch;

perf_slot_mask CLASSIFIER (
    .bundle_in(id_bundle), .non_nop_mask(id_non_nop_mask)
);
perf_pipeline_monitor PIPELINE (
    .clk(clk), .reset(reset), .advance(core_advance),
    .id_valid(id_valid), .id_non_nop_mask(id_non_nop_mask),
    .ex_branch_taken(effective_branch), .ex_exception(effective_exception),
    .ex_valid(), .ex_non_nop_mask(), .ex_cancel_cause(),
    .wb_valid(), .wb_non_nop_mask(wb_non_nop_mask), .wb_cancel_cause(),
    .bundle_complete(bundle_complete)
);

// El flanco R acepta el salto y vacía las posiciones jóvenes de ID e IF.
// Sus huecos ocuparán EX en los dos avances siguientes. Se conserva su origen,
// sin sumar automáticamente dos ciclos ni identificar NOP por sus bits cero.
always @(posedge clk) begin
    if (reset) begin
        discarded_id <= 1'b0;
        discarded_ex <= 1'b0;
    end
    else if (core_advance) begin
        discarded_id <= accepted_branch;
        discarded_ex <= accepted_branch || discarded_id;
    end
    // Sin avance se retienen ambas posiciones, aunque BRU siga indicando salto.
end

// Se consume una oportunidad EX perdida solo si el núcleo avanza y EX está
// realmente vacío. Un WB anterior todavía puede completar durante ese mismo flanco.
assign branch_recovery = !reset && core_advance && discarded_ex && !ex_valid;
// Supuesto de esta interfaz: toda falta de avance es congelamiento global por
// memoria. Una arquitectura con avance parcial u otras causas requiere revisarlo.
assign memory_stall = !reset && !core_advance;

perf_counters COUNTERS (
    .clk(clk), .reset(reset), .measure_enable(measure_enable),
    .bundle_complete(bundle_complete), .non_nop_mask(wb_non_nop_mask),
    .memory_stall(memory_stall), .branch_recovery(branch_recovery),
    .cycle_count(cycle_count), .bundle_count(bundle_count),
    .instruction_count(instruction_count), .memory_stall_count(memory_stall_count),
    .branch_penalty_count(branch_penalty_count)
);
endmodule
