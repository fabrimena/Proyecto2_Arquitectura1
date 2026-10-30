`timescale 1ns/1ps

module tb_perf_counters;

`include "tb_utils.svh"

logic clk = 0;
logic reset = 1;
logic measure_enable = 0;
logic bundle_complete = 0;
logic [3:0] non_nop_mask = 0;
logic [63:0] cycle_count;
logic [63:0] bundle_count;
logic [63:0] instruction_count;

perf_counters DUT (
    .clk(clk), .reset(reset), .measure_enable(measure_enable),
    .bundle_complete(bundle_complete), .non_nop_mask(non_nop_mask),
    .cycle_count(cycle_count), .bundle_count(bundle_count),
    .instruction_count(instruction_count)
);

always #5 clk = ~clk;

// Comparación completa de 64 bits; check() de tb_utils solo admite 32.
task automatic expect_count(input string name, input logic [63:0] expected);
    check_true(name, cycle_count === expected);
    if (cycle_count !== expected)
        $display("    obtenido=%016h esperado=%016h", cycle_count, expected);
endtask

// Entradas estables antes del flanco; observar después de las asignaciones NBA.
task automatic tick(input logic rst, input logic enabled, input logic [63:0] expected);
    @(negedge clk);
    reset = rst;
    measure_enable = enabled;
    @(posedge clk);
    #1;
    expect_count("valor después del flanco positivo", expected);
endtask

task automatic expect_work(input logic [63:0] bundles, input logic [63:0] instructions);
    check_true("bundles completados (64 bits)", bundle_count === bundles);
    check_true("instrucciones completadas (64 bits)", instruction_count === instructions);
    if (bundle_count !== bundles || instruction_count !== instructions)
        $display("    bundles=%016h esperado=%016h instrucciones=%016h esperado=%016h",
                 bundle_count, bundles, instruction_count, instructions);
endtask

task automatic tick_bundle(input logic rst, input logic enabled, input logic done,
                           input logic [3:0] mask, input logic [63:0] cycles,
                           input logic [63:0] bundles, input logic [63:0] instructions);
    @(negedge clk);
    reset = rst;
    measure_enable = enabled;
    bundle_complete = done;
    non_nop_mask = mask;
    @(posedge clk);
    #1;
    expect_count("ciclos con eventos de finalización", cycles);
    expect_work(bundles, instructions);
endtask

// IPC solo en simulación: no existe divisor ni salida IPC en el hardware.
task automatic expect_ipc(input bit expected_valid, input real expected);
    real ipc;
    bit valid;
    valid = (cycle_count != 0);
    check_true("disponibilidad de IPC", valid == expected_valid);
    if (valid) begin
        ipc = real'(instruction_count) / real'(cycle_count);
        check_true("IPC esperado", ipc - expected < 1.0e-12 && ipc - expected > -1.0e-12);
        $display("    IPC=%0.6f (%0d instrucciones / %0d ciclos)",
                 ipc, instruction_count, cycle_count);
    end
    else
        $display("    IPC=N/D (ventana con cero ciclos)");
endtask

initial begin
    $dumpfile("tb_perf_counters.vcd");
    $dumpvars(0, tb_perf_counters);

    tb_section("Reset inicial y prioridad sobre habilitación");
    @(posedge clk);
    #1;
    expect_count("reset inicial", 64'd0);
    tick(1, 1, 64'd0);
    tick(0, 0, 64'd0);

    tb_section("Ventana de tres flancos y pausa sin borrar");
    tick(0, 1, 64'd1);
    tick(0, 1, 64'd2);
    tick(0, 1, 64'd3);
    tick(0, 0, 64'd3);
    tick(0, 0, 64'd3);
    tick(0, 1, 64'd4);

    tb_section("Habilitación entre flancos: no cuenta ni reinicia");
    @(negedge clk);
    measure_enable = 0;
    #1;
    expect_count("flanco negativo sin incremento", 64'd4);
    measure_enable = 1;
    #1;
    expect_count("habilitar sin flanco no incrementa", 64'd4);
    measure_enable = 0;
    @(posedge clk);
    #1;
    expect_count("pulso fuera del flanco no cuenta", 64'd4);

    tb_section("Reset síncrono durante ejecución y nueva ventana");
    @(negedge clk);
    reset = 1;
    measure_enable = 1;
    #1;
    expect_count("reset espera el flanco positivo", 64'd4);
    @(posedge clk);
    #1;
    expect_count("reset gana a habilitación", 64'd0);
    tick(0, 1, 64'd1);
    tick(0, 0, 64'd1);
    tick(1, 0, 64'd0);
    tick(0, 0, 64'd0);

    tb_section("Acarreo de 32 bits y desbordamiento de 64 bits");
    // Precarga solo de simulación para evitar ejecutar 2^32 o 2^64 ciclos.
    @(negedge clk);
    DUT.cycle_count = 64'h0000_0000_FFFF_FFFF;
    measure_enable = 1;
    @(posedge clk);
    #1;
    expect_count("acarreo hacia la mitad alta", 64'h0000_0001_0000_0000);
    tick(0, 0, 64'h0000_0001_0000_0000);
    @(negedge clk);
    DUT.cycle_count = 64'hFFFF_FFFF_FFFF_FFFF;
    measure_enable = 1;
    @(posedge clk);
    #1;
    expect_count("desbordamiento módulo 2^64", 64'd0);

    // Las secuencias y las 21 comprobaciones originales del bloque A se
    // ejecutan antes de comenzar las pruebas del bloque B.
    check_true("bloque A: 21 comprobaciones originales sin fallos",
               tb_checks == 21 && tb_errors == 0);
    expect_work(64'd0, 64'd0);

    tb_section("Bloque B: reset y ventana sin ciclos");
    tick_bundle(1, 1, 1, 4'b1111, 0, 0, 0);
    expect_ipc(0, 0.0);
    tick_bundle(0, 0, 1, 4'b1111, 0, 0, 0);
    expect_ipc(0, 0.0);

    tb_section("Ausencia de evento, NOPs y eventos consecutivos de 1 a 4 operaciones");
    tick_bundle(0, 1, 0, 4'b1111, 1, 0, 0);
    expect_ipc(1, 0.0);
    tick_bundle(0, 1, 1, 4'b0000, 2, 1, 0);
    tick_bundle(0, 1, 1, 4'b0001, 3, 2, 1);
    tick_bundle(0, 1, 1, 4'b1010, 4, 3, 3);
    tick_bundle(0, 1, 1, 4'b1101, 5, 4, 6);
    tick_bundle(0, 1, 1, 4'b1111, 6, 5, 10);
    expect_ipc(1, 10.0 / 6.0);
    tick_bundle(0, 1, 0, 4'b1111, 7, 5, 10);
    tick_bundle(0, 1, 0, 4'b0000, 8, 5, 10);

    tb_section("Pausa ignora eventos y reanudación conserva acumulados");
    tick_bundle(0, 0, 1, 4'b1111, 8, 5, 10);
    tick_bundle(0, 0, 1, 4'b0001, 8, 5, 10);
    tick_bundle(0, 1, 1, 4'b1111, 9, 6, 14);
    tick_bundle(1, 0, 1, 4'b1111, 0, 0, 0);
    tick_bundle(0, 1, 1, 4'b1111, 1, 1, 4);
    expect_ipc(1, 4.0);
    tick_bundle(1, 1, 1, 4'b1111, 0, 0, 0);
    expect_ipc(0, 0.0);

    tb_section("Cada slot aporta una sola instrucción");
    tick_bundle(0, 1, 1, 4'b0001, 1, 1, 1);
    tick_bundle(0, 1, 1, 4'b0010, 2, 2, 2);
    tick_bundle(0, 1, 1, 4'b0100, 3, 3, 3);
    tick_bundle(0, 1, 1, 4'b1000, 4, 4, 4);
    expect_ipc(1, 1.0);

    tb_section("Un pulso de finalización entre flancos no cuenta");
    @(negedge clk);
    bundle_complete = 0;
    #1;
    expect_work(4, 4);
    bundle_complete = 1;
    #1;
    expect_work(4, 4);
    bundle_complete = 0;
    @(posedge clk);
    #1;
    expect_count("ciclo sin finalización muestreada", 5);
    expect_work(4, 4);
    expect_ipc(1, 0.8);

    tb_section("Acarreo y desbordamiento de los contadores nuevos");
    @(negedge clk);
    DUT.bundle_count = 64'h0000_0000_FFFF_FFFF;
    DUT.instruction_count = 64'h0000_0000_FFFF_FFFF;
    bundle_complete = 1;
    non_nop_mask = 4'b1111;
    @(posedge clk);
    #1;
    expect_work(64'h0000_0001_0000_0000, 64'h0000_0001_0000_0003);
    tick_bundle(0, 0, 1, 4'b1111, 6,
                64'h0000_0001_0000_0000, 64'h0000_0001_0000_0003);
    @(negedge clk);
    DUT.bundle_count = 64'hFFFF_FFFF_FFFF_FFFF;
    DUT.instruction_count = 64'hFFFF_FFFF_FFFF_FFFF;
    measure_enable = 1;
    @(posedge clk);
    #1;
    expect_work(0, 3);

    tb_finish("tb_perf_counters");
end

endmodule
