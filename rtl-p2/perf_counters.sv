/*
 * Contadores de rendimiento del procesador VLIW.
 * Acumula ciclos, bundles, operaciones no NOP y ciclos perdidos dentro de una
 * ventana de medición. Recibe los eventos de otro módulo; no los deduce del PC
 * ni de escrituras al banco de registros. El IPC se calcula fuera del RTL.
 */
module perf_counters (
    input  logic        clk, // Reloj general: debe seguir activo durante un stall.
    input  logic        reset,
    input  logic        measure_enable, // Pausa o reanuda la medición sin borrar acumulados.
    input  logic        bundle_complete, // Cada flanco activo representa un bundle distinto.
    input  logic [3:0]  non_nop_mask, // Operaciones del bundle que finaliza, una por slot.
    input  logic        memory_stall,
    input  logic        branch_recovery, // Indica un ciclo perdido, no el evento de salto.
    output logic [63:0] cycle_count,
    output logic [63:0] bundle_count,
    output logic [63:0] instruction_count,
    output logic [63:0] memory_stall_count,
    output logic [63:0] branch_penalty_count
);

// Suma los bits ALU, LSU, BRU y CRIPTO de la máscara. Tres bits permiten
// representar cuatro operaciones; sumar bits de un solo bit podría truncarlas.
logic [2:0] completed_ops;
assign completed_ops = {2'b0, non_nop_mask[0]} + {2'b0, non_nop_mask[1]} +
                       {2'b0, non_nop_mask[2]} + {2'b0, non_nop_mask[3]};

// Actualiza en el flanco positivo. Los acumulados de 64 bits desbordan módulo 2^64.
always @(posedge clk) begin
    if (reset) begin
        // El reset borra todos los acumulados aunque la medición esté deshabilitada.
        cycle_count <= 64'd0;
        bundle_count <= 64'd0;
        instruction_count <= 64'd0;
        memory_stall_count <= 64'd0;
        branch_penalty_count <= 64'd0;
    end
    else if (measure_enable) begin
        // El tiempo total incluye los flancos en que el núcleo no puede avanzar.
        cycle_count <= cycle_count + 64'd1;
        // Un stall global retiene el bundle: no puede contarse otra finalización.
        // Sin stall, eventos consecutivos pueden corresponder a bundles distintos.
        if (bundle_complete && !memory_stall) begin
            bundle_count <= bundle_count + 64'd1;
            // Un bundle NOP suma un bundle y cero instrucciones. La extensión
            // conserva el ancho de 64 bits del acumulado al sumar de cero a cuatro.
            instruction_count <= instruction_count + {61'd0, completed_ops};
        end
        // Si coinciden memoria y recuperación de salto, el ciclo se atribuye solo
        // a memoria. No se multiplica por dos ni se aplaza el indicador de salto.
        if (memory_stall)
            memory_stall_count <= memory_stall_count + 64'd1;
        else if (branch_recovery)
            branch_penalty_count <= branch_penalty_count + 64'd1;
    end
    // Sin reset ni habilitación, todos los registros conservan su valor.
end

endmodule
