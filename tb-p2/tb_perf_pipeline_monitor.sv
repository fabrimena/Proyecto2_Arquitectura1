/*
 * Pruebas independientes del transporte de metadatos ID -> EX -> WB.
 * Usa fechas de finalización en avances efectivos como referencia y conecta
 * el clasificador y los contadores para comprobar eventos, máscaras y anulaciones.
 * No instancia el procesador ni mide penalizaciones reales de recuperación.
 */
`timescale 1ns/1ps

module tb_perf_pipeline_monitor;

`include "tb_utils.svh"

logic clk = 0;
logic reset = 1;
logic advance = 0;
logic id_valid = 0;
logic [127:0] id_bundle = 0;
logic [3:0] id_mask;
logic ex_branch_taken = 0;
logic ex_exception = 0;
logic measure_enable = 1;
logic ex_valid, wb_valid, bundle_complete;
logic [3:0] ex_mask, wb_mask;
logic [1:0] ex_cancel_cause, wb_cancel_cause;
logic [63:0] cycles, bundles, instructions, memory_cycles, branch_cycles;

// D1 clasifica las palabras de ID; la validez del bundle se entrega por separado.
perf_slot_mask CLASSIFIER (.bundle_in(id_bundle), .non_nop_mask(id_mask));

perf_pipeline_monitor DUT (
    .clk(clk), .reset(reset), .advance(advance),
    .id_valid(id_valid), .id_non_nop_mask(id_mask),
    .ex_branch_taken(ex_branch_taken), .ex_exception(ex_exception),
    .ex_valid(ex_valid), .ex_non_nop_mask(ex_mask), .ex_cancel_cause(ex_cancel_cause),
    .wb_valid(wb_valid), .wb_non_nop_mask(wb_mask), .wb_cancel_cause(wb_cancel_cause),
    .bundle_complete(bundle_complete)
);

// En estos estímulos, no avanzar representa un stall global de memoria.
// branch_recovery se fija en cero: las marcas de flush no prueban ciclos perdidos.
perf_counters COUNTERS (
    .clk(clk), .reset(reset), .measure_enable(measure_enable),
    .bundle_complete(bundle_complete), .non_nop_mask(wb_mask),
    .memory_stall(!advance), .branch_recovery(1'b0),
    .cycle_count(cycles), .bundle_count(bundles), .instruction_count(instructions),
    .memory_stall_count(memory_cycles), .branch_penalty_count(branch_cycles)
);

// Cada índice representa una fecha de finalización en número de avances efectivos.
// Un bundle presentado en ID en el avance n finaliza en n+2. El modelo registra
// validez, máscara y anulaciones por fecha, sin copiar los registros EX/WB del DUT.
localparam int MAX_DUE = 2048;
bit valid_due [0:MAX_DUE-1];
logic [3:0] mask_due [0:MAX_DUE-1];
int cause_due [0:MAX_DUE-1];
int forced_cancel [0:MAX_DUE-1]; // Cancelaciones de posiciones jóvenes por fecha futura.
int advances = 0;
logic [63:0] ref_cycles = 0, ref_bundles = 0, ref_instructions = 0, ref_memory = 0;

// Un reset descarta todo lo pendiente y reinicia los totales esperados.
task automatic clear_reference();
    advances = 0;
    ref_cycles = 0;
    ref_bundles = 0;
    ref_instructions = 0;
    ref_memory = 0;
    for (int i = 0; i < MAX_DUE; i++) begin
        valid_due[i] = 0;
        mask_due[i] = 0;
        cause_due[i] = 0;
        forced_cancel[i] = 0;
    end
endtask

// Tras n avances, la fecha n+2 corresponde a EX y n+1 al WB aún por consumir.
// Se comprueban también los acumulados, para detectar un evento contado un ciclo tarde.
task automatic check_state(input string phase);
    check_true({phase, ": validez EX"}, ex_valid === valid_due[advances+2]);
    check({phase, ": máscara EX"}, ex_mask, mask_due[advances+2]);
    check({phase, ": causa EX"}, ex_cancel_cause, cause_due[advances+2]);
    check_true({phase, ": validez WB"}, wb_valid === valid_due[advances+1]);
    check({phase, ": máscara WB"}, wb_mask, mask_due[advances+1]);
    check({phase, ": causa WB"}, wb_cancel_cause, cause_due[advances+1]);
    check_true({phase, ": evento del WB que YA está presente"},
               bundle_complete === (!reset && advance && valid_due[advances+1]));
    check_true({phase, ": ciclos"}, cycles === ref_cycles);
    check_true({phase, ": bundles"}, bundles === ref_bundles);
    check_true({phase, ": instrucciones"}, instructions === ref_instructions);
    check_true({phase, ": memoria"}, memory_cycles === ref_memory);
    check_true({phase, ": D2 no atribuye penalizaciones de salto"}, branch_cycles === 64'd0);
endtask

// Calcula el estado esperado para el flanco usando solo entradas y la tabla de fechas.
// La ventana limita los acumulados, pero no impide que avancen los metadatos.
task automatic update_reference(input logic [3:0] incoming_mask);
    int next_advance, redirect;
    if (reset)
        clear_reference();
    else begin
        if (measure_enable) begin
            ref_cycles++;
            if (!advance)
                ref_memory++;
            else if (valid_due[advances+1]) begin
                // Consume primero el WB anterior: una excepción del EX siguiente
                // no debe quitar esta finalización que ya estaba pendiente.
                ref_bundles++;
                for (int slot = 0; slot < 4; slot++)
                    if (mask_due[advances+1][slot]) ref_instructions++;
            end
        end
        if (advance) begin
            next_advance = advances + 1;
            if (next_advance + 3 >= MAX_DUE) $fatal(1, "referencia sin espacio");
            redirect = 0;
            // La fecha siguiente es la del EX actual. Solo un EX válido acepta
            // controles, y una excepción tiene prioridad sobre un salto simultáneo.
            if (valid_due[next_advance+1]) begin
                if (ex_exception) redirect = 2;
                else if (ex_branch_taken) redirect = 1;
            end
            // La excepción cancela la fecha del EX actual; no toca el WB viejo.
            if (redirect == 2) begin
                valid_due[next_advance+1] = 0;
                mask_due[next_advance+1] = 0;
                cause_due[next_advance+1] = 2;
            end
            valid_due[next_advance+2] = id_valid;
            mask_due[next_advance+2] = id_valid ? incoming_mask : 4'b0;
            cause_due[next_advance+2] = 0;
            if (redirect != 0) begin
                // Reserva dos cancelaciones futuras para las posiciones de ID e IF.
                // Son marcas de procedencia del flush, no una suma de penalizaciones.
                forced_cancel[next_advance+2] = redirect;
                forced_cancel[next_advance+3] = redirect;
            end
            if (forced_cancel[next_advance+2] != 0) begin
                // Una posición anulada no puede conservar máscara ni finalizar.
                valid_due[next_advance+2] = 0;
                mask_due[next_advance+2] = 0;
                cause_due[next_advance+2] = forced_cancel[next_advance+2];
            end
            advances = next_advance;
        end
    end
endtask

// Mantiene clk bajo mientras aplica entradas y comprueba el estado anterior.
// Luego genera el flanco, actualiza la referencia y espera NBA para comparar de nuevo.
task automatic step(input bit rst, input bit move, input bit valid_id,
                    input logic [3:0] mask, input bit taken, input bit fault,
                    input bit measuring);
    clk = 0;
    reset = rst;
    advance = move;
    id_valid = valid_id;
    ex_branch_taken = taken;
    ex_exception = fault;
    measure_enable = measuring;
    id_bundle = 0;
    // Cada bit solicitado coloca una operación real en su slot; el resultado
    // esperado usa la máscara del estímulo, no la salida calculada por el DUT.
    if (mask[0]) id_bundle[31:0] = 32'h80000001; // sumai
    if (mask[1]) id_bundle[63:32] = 32'h92000000; // guardap
    if (mask[2]) id_bundle[95:64] = 32'h96000000; // sye
    if (mask[3]) id_bundle[127:96] = 32'h04600000; // vcr
    #2;
    check("máscara D1 de entrada", id_mask, mask);
    check_state("antes del flanco");
    clk = 1;
    update_reference(mask);
    #1;
    check_state("después de NBA");
endtask

// Totales dirigidos complementan el modelo por fechas en los escenarios clave.
task automatic expect_totals(input logic [63:0] expected_bundles,
                             input logic [63:0] expected_instructions);
    check_true("total dirigido de bundles", bundles === expected_bundles);
    check_true("total dirigido de instrucciones", instructions === expected_instructions);
endtask

integer seed = 32'hCE430102;
logic [31:0] random_bits;

initial begin
    $dumpfile("tb_perf_pipeline_monitor.vcd");
    $dumpvars(0, tb_perf_pipeline_monitor);
    clear_reference();
    // El primer flanco resetea el DUT antes de observar sus registros.
    clk = 1;
    #1;
    check_state("reset inicial");

    // El primer bundle es válido y completamente NOP: debe sumar uno a bundles
    // y cero a instrucciones. Los siguientes aportan 1+2+3+4 operaciones.
    tb_section("Reset prioritario, llenado, NOP válido, 1 a 4 slots y drenado");
    step(1, 0, 1, 15, 1, 1, 1);
    step(0, 1, 1, 0, 0, 0, 1);
    check_true("primer bundle solo está en EX", ex_valid && !wb_valid);
    step(0, 1, 1, 1, 0, 0, 1);
    expect_totals(0, 0);
    step(0, 1, 1, 3, 0, 0, 1);
    expect_totals(1, 0);
    step(0, 1, 1, 7, 0, 0, 1);
    step(0, 1, 1, 15, 0, 0, 1);
    step(0, 1, 0, 15, 0, 0, 1); // Inválido con máscara no cero, no es un NOP válido.
    // Dos avances sin nuevas entradas permiten consumir los últimos bundles en WB.
    step(0, 1, 0, 0, 0, 0, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    expect_totals(5, 10);
    check_true("pipeline drenado", !ex_valid && !wb_valid);

    // Congela entre uno y cuatro ciclos. El WB pendiente no debe completar
    // durante la pausa ni repetirse al reanudar; los avances consumen bundles en orden.
    tb_section("Retenciones variables, reanudación y finalizaciones consecutivas");
    step(1, 1, 0, 0, 0, 0, 1);
    step(0, 1, 1, 15, 0, 0, 1);
    step(0, 1, 1, 3, 0, 0, 1);
    for (int hold_cycles = 1; hold_cycles <= 4; hold_cycles++) begin
        repeat (hold_cycles) step(0, 0, 1, 8, 0, 0, 1);
        step(0, 1, 1, 1, 0, 0, 1);
    end
    step(0, 1, 0, 0, 0, 0, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    expect_totals(6, 10);
    check_true("diez ciclos congelados", memory_cycles == 10);

    // El anterior y el salto pueden finalizar. Las dos posiciones jóvenes se
    // descartan; tras el drenado solo se suma además el bundle destino.
    tb_section("Salto tomado: conservar salto y anterior, anular ID e IF");
    step(1, 1, 0, 0, 0, 0, 1);
    step(0, 1, 1, 1, 0, 0, 1); // Anterior.
    step(0, 1, 1, 4, 0, 0, 1); // Salto.
    step(0, 1, 1, 3, 1, 0, 1); // Se resuelve EX, ID se descarta.
    expect_totals(1, 1);
    check("marca joven en EX", ex_cancel_cause, 1);
    step(0, 1, 0, 0, 0, 0, 1); // IF/ID vaciado, segunda posición.
    check("primera marca llega a WB", wb_cancel_cause, 1);
    step(0, 1, 1, 8, 0, 0, 1); // Destino del salto en ID.
    check("segunda marca llega a WB", wb_cancel_cause, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    expect_totals(3, 3);

    // Sin indicador de salto tomado, las entradas siguientes siguen el flujo normal.
    tb_section("Salto no tomado: ningún bundle joven se anula");
    step(1, 1, 0, 0, 0, 0, 1);
    step(0, 1, 1, 4, 0, 0, 1);
    step(0, 1, 1, 3, 0, 0, 1);
    step(0, 1, 1, 8, 0, 0, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    expect_totals(3, 4);

    // La excepción elimina el bundle con cuatro slots y las dos posiciones jóvenes.
    // El WB anterior y el manejador representado por el bundle destino sí completan.
    // Repetir con salto simultáneo debe conservar la causa de excepción.
    tb_section("Excepción cripto y prioridad sobre salto del mismo bundle");
    for (int simultaneous_branch = 0; simultaneous_branch <= 1; simultaneous_branch++) begin
        step(1, 1, 0, 0, 0, 0, 1);
        step(0, 1, 1, 1, 0, 0, 1);
        step(0, 1, 1, 15, 0, 0, 1); // Bundle que falla, con cuatro slots.
        repeat (2) step(0, 0, 1, 3, simultaneous_branch, 1, 1);
        step(0, 1, 1, 3, simultaneous_branch, 1, 1);
        expect_totals(1, 1); // El anterior finalizó; el que falla no finaliza.
        check("bundle con excepción anulado en WB", wb_cancel_cause, 2);
        repeat (2) step(0, 0, 0, 0, 0, 0, 1); // Congela también las marcas.
        step(0, 1, 0, 0, 0, 0, 1);
        check("ID joven anulado por excepción", wb_cancel_cause, 2);
        step(0, 1, 1, 8, 0, 0, 1);
        check("IF joven anulado por excepción", wb_cancel_cause, 2);
        step(0, 1, 0, 0, 0, 0, 1);
        step(0, 1, 0, 0, 0, 0, 1);
        expect_totals(2, 2);
    end

    // Un redirect sostenido solo se acepta al avanzar. Congelar después tampoco
    // crea marcas nuevas; reset debe limpiar incluso con advance desactivado.
    tb_section("Redirect retenido, marcas congeladas y reset sin avance");
    step(1, 1, 0, 0, 0, 0, 1);
    step(0, 1, 1, 1, 0, 0, 1);
    step(0, 1, 1, 4, 0, 0, 1);
    repeat (4) step(0, 0, 1, 15, 1, 0, 1);
    expect_totals(0, 0);
    step(0, 1, 1, 15, 1, 0, 1); // Solo ahora se acepta el salto.
    repeat (3) step(0, 0, 0, 0, 1, 1, 1); // Sin crear marcas nuevas.
    step(0, 1, 0, 0, 0, 0, 1);
    step(0, 1, 1, 8, 0, 0, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    expect_totals(3, 3);
    step(1, 0, 1, 15, 1, 1, 0);
    expect_totals(0, 0);

    // Un control que desaparece durante el stall no se encola. Si EX no contiene
    // un bundle válido, sus indicadores tampoco pueden cancelar el WB anterior.
    tb_section("Control transitorio sin avance y controles de EX inválido");
    step(0, 1, 1, 1, 1, 1, 1); // No hay EX válido: no hay redirect.
    step(0, 0, 1, 15, 1, 1, 1); // Pulso sin aceptar: se retira antes de avanzar.
    step(0, 1, 1, 3, 0, 0, 1);
    step(0, 1, 0, 0, 0, 0, 1);
    step(0, 1, 0, 0, 1, 1, 1); // EX inválido no mata el WB anterior.
    expect_totals(2, 3);

    // El primer bundle termina fuera de la ventana y no se recupera después.
    // Reabrir la medición solo cuenta el segundo bundle, que aún estaba en WB.
    tb_section("Ventana deshabilitada no congela metadatos");
    step(1, 1, 0, 0, 0, 0, 1);
    step(0, 1, 1, 15, 0, 0, 0);
    step(0, 1, 1, 1, 0, 0, 0);
    step(0, 1, 0, 0, 0, 0, 0); // Primera finalización fuera de ventana.
    step(0, 1, 0, 0, 0, 0, 1); // Solo se cuenta el segundo bundle.
    expect_totals(1, 1);

    // Combina reset, avance, máscaras y controles con semilla reproducible.
    // Son entradas abstractas del monitor: no ejecutan instrucciones en el núcleo.
    tb_section("300 ciclos deterministas contra fechas de salida independientes");
    step(1, 1, 0, 0, 0, 0, 1);
    repeat (300) begin
        random_bits = $random(seed);
        step(random_bits[11:7] == 0, random_bits[0] || random_bits[1],
             random_bits[2], random_bits[6:3], random_bits[12],
             random_bits[13], random_bits[14]);
    end
    // Vacía lo pendiente para comprobar que no quede una finalización desplazada.
    repeat (4) step(0, 1, 0, 0, 0, 0, 1);
    tb_finish("tb_perf_pipeline_monitor");
end

endmodule
