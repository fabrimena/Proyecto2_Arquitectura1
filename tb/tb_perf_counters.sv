`timescale 1ns/1ps

module tb_perf_counters;

`include "tb_utils.svh"

logic clk = 0;
logic reset = 1;
logic measure_enable = 0;
logic [63:0] cycle_count;

perf_counters DUT (
    .clk(clk), .reset(reset), .measure_enable(measure_enable),
    .cycle_count(cycle_count)
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

    tb_finish("tb_perf_counters");
end

endmodule
