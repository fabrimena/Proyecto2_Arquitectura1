/*
 * Observa cuánto tiempo contienen bundles las etapas IF, ID, EX y WB y cuánto
 * permanecen congeladas. Recibe validez y avance ya alineados por el productor;
 * no descifra instrucciones ni controla el pipeline, la memoria o las cachés.
 *
 * El reloj general clk mide tiempo incluso cuando core_clk está detenido. Cada
 * entrada describe el estado anterior al flanco; los registros cambian mediante
 * NBA. Un NOP válido ocupa una etapa, mientras una posición inválida es burbuja.
 * El productor debe proporcionar WB para el bundle completo, no solo la ALU.
 *
 * Todas las salidas están en ciclos, con aritmética unsigned módulo 2^64.
 * Los índices empaquetados son 0=IF, 1=ID, 2=EX, 3=WB. No se suman los stalls
 * de las cuatro etapas: observan el mismo congelamiento global.
 */
module perf_stage_counters (
    input  logic clk,
    input  logic reset,             // Reset síncrono: gana sobre ventana y avance.
    input  logic measure_enable,    // Solo pausa los acumulados, no el procesador.
    input  logic core_advance,      // Decisión efectiva y estable antes del flanco.
    input  logic if_valid,
    input  logic id_valid,
    input  logic ex_valid,
    input  logic wb_valid,
    output logic [63:0] measured_cycles,
    output logic [3:0][63:0] occupied_cycles,
    output wire  [3:0][63:0] bubble_cycles,
    output wire  [3:0][63:0] stall_cycles,
    output logic [3:0][63:0] stalled_occupied_cycles
);

// La concatenación deja IF en el bit menos significativo. No se usan máscaras
// no NOP: una máscara cero no permite distinguir un NOP válido de una burbuja.
wire [3:0] stage_valid = {wb_valid, ex_valid, id_valid, if_valid};

// Un único registro representa los ciclos sin avance de todo el núcleo. Evita
// guardar cuatro copias idénticas y no atribuye causas locales que no conocemos.
logic [63:0] frozen_cycles;

// Derivamos las categorías complementarias sin añadir estado redundante.
// La resta de 64 bits equivale al contador de posiciones inválidas, también
// módulo 2^64. Estas conexiones se estabilizan después de actualizar los registros.
for (genvar stage = 0; stage < 4; stage = stage + 1) begin : g_derived
    assign bubble_cycles[stage] = measured_cycles - occupied_cycles[stage];
    assign stall_cycles[stage] = frozen_cycles;
end

always @(posedge clk) begin
    if (reset) begin
        // Una época nueva descarta todos los resultados previos, aunque el
        // productor no avance o la ventana esté cerrada en este mismo flanco.
        measured_cycles <= 64'd0;
        frozen_cycles <= 64'd0;
        occupied_cycles <= '0;
        stalled_occupied_cycles <= '0;
    end
    else if (measure_enable) begin
        // Contamos una observación de tiempo. No condicionamos este incremento
        // al avance: precisamente queremos medir los flancos perdidos en espera.
        measured_cycles <= measured_cycles + 64'd1;
        if (!core_advance)
            frozen_cycles <= frozen_cycles + 64'd1;

        // Cada índice representa una etapa, no una operación dentro del bundle.
        // Un mismo bundle retenido puede ocupar varios ciclos; eso mide tiempo
        // de residencia, sin emitir ni duplicar eventos de instrucciones retiradas.
        for (integer stage = 0; stage < 4; stage = stage + 1) begin
            if (stage_valid[stage]) begin
                occupied_cycles[stage] <= occupied_cycles[stage] + 64'd1;
                // Ocupación y congelamiento son dimensiones simultáneas. Una
                // burbuja congelada suma frozen_cycles, pero no este subconjunto.
                if (!core_advance)
                    stalled_occupied_cycles[stage] <=
                        stalled_occupied_cycles[stage] + 64'd1;
            end
        end
    end
    // Sin reset ni habilitación se retienen los diez registros. Reanudar no
    // recupera observaciones de la pausa ni introduce un ciclo de compensación.
end

endmodule
