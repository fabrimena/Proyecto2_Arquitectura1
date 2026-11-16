`timescale 1ns/1ps

/*
================================================================================
 Testbench: tb_cache_isa

 Descripción:
 ------------------------------------------------------------------------------
 Prueba las instrucciones de caché y medición (D18: vaciarc, medir y lcont)
 conectadas en top. Ejecuta el mismo programa en tres copias de top, con el
 mismo reloj y el mismo reset:

     REF   MEM_MODE = 0, conexión directa con DMEM
     DUT1  MEM_MODE = 1, STALL_CYCLES = 4 (modelo de stalls)
     DUT2  MEM_MODE = 2, jerarquía completa

 Casos:
   A. lcont: dos lecturas seguidas de ciclos o de bundles difieren en 1, la
      mitad alta de los ciclos es 0 y el resultado se ve desde el bundle N+3
      (en N+1 y N+2 el registro todavía tiene el valor de antes).
   B. medir: con medir 0 dos lecturas separadas por varios bundles dan el
      mismo valor; con medir 1 vuelven a avanzar.
   C. vaciarc: en DUT2, al terminar el vaciado DMEM ya tiene los stores que
      estaban sucios en la caché; el store y el camcon del bundle siguiente
      se hacen después del vaciado y una sola vez. En REF y DUT1 cuesta 2
      ciclos.
   D. Anulación: un medir 0 y un lcont detrás de un salto tomado, y un
      medir 0 en el bundle de una excepción, no tienen efecto.
   E. Contadores de la L1-D: en DUT2 lcont devuelve los mismos valores que
      perf_cache_l1d; en REF son 0.
   F. Los tres terminan con los mismos registros (salvo los que guardan
      contadores), la misma memoria (DUT2 después del vaciado del testbench),
      la misma contraseña en la bóveda y la misma excepción.
================================================================================
*/

`include "isa_defs.sv"


// ============================================================================
// Monitor de una copia de top: ciclos de vaciarc y escrituras en DMEM
// ============================================================================

module monitor_cache_isa (

    input  logic        clk,
    input  logic        reset,

    input  logic        hold,           // top.cisa_hold
    input  logic        dmem_we,
    input  logic [31:0] dmem_addr,
    input  logic        dmem_we_b,

    input  logic [31:0] m200,
    input  logic [31:0] m204,
    input  logic [31:0] m208
);

int          hold_cycles = 0;       // ciclos con el vaciado de vaciarc en curso
int          writes_b    = 0;       // escrituras del puerto B de DMEM (camcon)
int          writes_208  = 0;       // escrituras del puerto A en 0x208

logic        prev_hold   = 1'b0;
bit          seen_rise   = 0;
bit          seen_fall   = 0;
logic [31:0] before_200, after_200, after_204, after_208;

always @(posedge clk) begin

    if (!reset) begin
        if (dmem_we_b)
            writes_b++;
        if (dmem_we && dmem_addr == 32'h208)
            writes_208++;
    end
end

always @(negedge clk) begin

    if (!reset) begin

        if (hold)
            hold_cycles++;

        // DMEM justo antes y justo después del vaciado de vaciarc
        if (hold && !prev_hold && !seen_rise) begin
            seen_rise  = 1;
            before_200 = m200;
        end

        if (!hold && prev_hold && !seen_fall) begin
            seen_fall = 1;
            after_200 = m200;
            after_204 = m204;
            after_208 = m208;
        end

        prev_hold = hold;
    end
end

endmodule


module tb_cache_isa;

`include "tb_utils.svh"

logic clk;
logic reset;
logic flush_req = 1'b0;
logic flush_done;

top REF (.clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write());

top #(.MEM_MODE(1), .STALL_CYCLES(4)) DUT1 (
    .clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write()
);

top #(.MEM_MODE(2)) DUT2 (
    .clk(clk), .reset(reset), .flush_req(flush_req), .flush_done(flush_done),
    .debug_result(), .debug_rd(), .debug_write()
);

always #5 clk = ~clk;


`define MONITOR(NAME, D) \
monitor_cache_isa NAME ( \
    .clk(clk), .reset(reset), .hold(D.cisa_hold), \
    .dmem_we(D.dmem_we), .dmem_addr(D.dmem_addr), .dmem_we_b(D.dmem_we_b), \
    .m200(D.DMEM.mem[32'h200 >> 2]), .m204(D.DMEM.mem[32'h204 >> 2]), \
    .m208(D.DMEM.mem[32'h208 >> 2]) \
);

`MONITOR(M_REF,  REF)
`MONITOR(M_DUT1, DUT1)
`MONITOR(M_DUT2, DUT2)


// ============================================================================
// Codificación de instrucciones
// ============================================================================

localparam logic [31:0] NOP = 32'h0000_0000;

function automatic logic [31:0] rol(input logic [31:0] x, input int r);

    r = r % 32;
    return (r == 0) ? x : ((x << r) | (x >> (32 - r)));
endfunction

function automatic logic [31:0] sumai(input logic [4:0] rg, input logic [4:0] rf1,
                                      input logic [10:0] imm);

    return {TYPE_IMM, OP_SUMI, rf1, rg, imm};
endfunction

function automatic logic [31:0] lsu(input logic [3:0] id, input logic [4:0] base,
                                    input logic [4:0] reg_dato, input logic [10:0] off);

    return {TYPE_LSU, id, base, reg_dato, off};
endfunction

function automatic logic [31:0] sye(input logic [4:0] rg, input logic [15:0] off);

    return {TYPE_BRU_JUMP, OP_SYE, rg, off};
endfunction

function automatic logic [31:0] vcr(input logic [15:0] dir);

    return {TYPE_CRYPTO, OP_VCR, dir, 5'b0};
endfunction

function automatic logic [31:0] camcon(input logic [15:0] dir, input logic [4:0] imm);

    return {TYPE_CRYPTO, OP_CAMCON, dir, imm};
endfunction

function automatic logic [31:0] setpwd(input logic [4:0] rs);

    return {TYPE_CRYPTO, OP_SETPWD, 16'b0, rs};
endfunction

// Tipo 1001101 (isa.md, extensión D18): vaciarc = 9a000000, medir = 9a20000i,
// lcont = 9a40 | rg << 11 | sel
localparam logic [31:0] VACIARC = 32'h9A00_0000;

function automatic logic [31:0] medir(input logic imm);

    return 32'h9A20_0000 | {31'b0, imm};
endfunction

function automatic logic [31:0] lcont(input logic [4:0] rg, input logic [5:0] sel);

    return 32'h9A40_0000 | {16'b0, rg, 5'b0, sel};
endfunction

function automatic logic [127:0] bundle(input logic [31:0] alu, input logic [31:0] mem,
                                        input logic [31:0] bru, input logic [31:0] cripto);

    return {cripto, bru, mem, alu};
endfunction


// ============================================================================
// Programa y datos (respeta N+3, salvo los bundles 24 y 25, que leen x21
// antes de tiempo a propósito)
// ============================================================================

localparam logic [31:0] PWD  = 32'h5EC2_E7A1;
localparam logic [31:0] W300 = 32'h1234_5678;

localparam logic [127:0] HANDLER = {NOP, sye(5'd0, 16'd0), NOP, sumai(5'd30, 5'd0, 11'd99)};

localparam int N_PROG = 40;
logic [127:0] prog [0:N_PROG-1];

task automatic build_program();

    for (int i = 0; i < N_PROG; i++)
        prog[i] = 128'b0;

    // Datos y autenticación (AUTH = 1 para el camcon del bundle 20)
    prog[0]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd6, 11'h100), NOP, NOP);
    prog[1]  = bundle(sumai(5'd4, 5'd0, 11'h055), NOP, NOP, NOP);
    prog[2]  = bundle(sumai(5'd5, 5'd0, 11'h066), NOP, NOP, NOP);
    prog[3]  = bundle(NOP, NOP, NOP, setpwd(5'd6));
    prog[4]  = bundle(NOP, lsu(OP_GUARDAP, 5'd0, 5'd4, 11'h200), NOP, vcr(16'h104));
    prog[5]  = bundle(NOP, lsu(OP_GUARDAP, 5'd0, 5'd5, 11'h204), NOP, NOP);

    // A. lcont seguidos: ciclos, bundles y la mitad alta de los ciclos
    prog[6]  = bundle(NOP, lcont(5'd10, 6'd0), NOP, NOP);
    prog[7]  = bundle(NOP, lcont(5'd11, 6'd0), NOP, NOP);
    prog[8]  = bundle(NOP, lcont(5'd12, 6'd1), NOP, NOP);
    prog[9]  = bundle(NOP, lcont(5'd13, 6'd1), NOP, NOP);
    prog[10] = bundle(NOP, lcont(5'd14, 6'd32), NOP, NOP);

    // B. medir 0: los ciclos no avanzan entre el bundle 12 y el 15; medir 1
    prog[11] = bundle(NOP, medir(1'b0), NOP, NOP);
    prog[12] = bundle(NOP, lcont(5'd15, 6'd0), NOP, NOP);
    prog[15] = bundle(NOP, lcont(5'd16, 6'd0), NOP, NOP);
    prog[16] = bundle(NOP, medir(1'b1), NOP, NOP);
    prog[17] = bundle(NOP, lcont(5'd17, 6'd0), NOP, NOP);
    prog[18] = bundle(NOP, lcont(5'd18, 6'd0), NOP, NOP);

    // C. vaciarc; el bundle siguiente guarda y hace camcon
    prog[19] = bundle(NOP, VACIARC, NOP, NOP);
    prog[20] = bundle(NOP, lsu(OP_GUARDAP, 5'd0, 5'd4, 11'h208), NOP, camcon(16'h300, 5'd4));
    prog[21] = bundle(NOP, lcont(5'd19, 6'd3), NOP, NOP);
    prog[22] = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd20, 11'h200), NOP, NOP);

    // A. Regla N+3 de lcont: x22 y x23 leen x21 antes de tiempo, x25 a tiempo
    prog[23] = bundle(NOP, lcont(5'd21, 6'd1), NOP, NOP);
    prog[24] = bundle(sumai(5'd22, 5'd21, 11'd0), NOP, NOP, NOP);
    prog[25] = bundle(sumai(5'd23, 5'd21, 11'd0), NOP, NOP, NOP);
    prog[26] = bundle(sumai(5'd25, 5'd21, 11'd0), NOP, NOP, NOP);

    // D. Salto al bundle 30: el 28 y el 29 se anulan
    prog[27] = bundle(NOP, NOP, sye(5'd0, 16'd48), NOP);
    prog[28] = bundle(NOP, medir(1'b0), NOP, NOP);
    prog[29] = bundle(NOP, lcont(5'd24, 6'd0), NOP, NOP);

    // E. Contadores de la L1-D
    prog[30] = bundle(NOP, lcont(5'd26, 6'd5), NOP, NOP);
    prog[31] = bundle(NOP, lcont(5'd27, 6'd7), NOP, NOP);
    prog[32] = bundle(NOP, lcont(5'd28, 6'd6), NOP, NOP);
    prog[33] = bundle(NOP, lcont(5'd29, 6'd8), NOP, NOP);

    // D. setpwd con INIT = 0: excepción; el medir 0 del mismo bundle se anula
    prog[34] = bundle(NOP, medir(1'b0), NOP, setpwd(5'd6));
    prog[35] = bundle(sumai(5'd31, 5'd0, 11'd1), NOP, NOP, NOP);     // anulado
endtask

`define LOAD(D) \
    for (int i = 0; i < N_PROG; i++) D.IMEM.memory[i] = prog[i]; \
    D.IMEM.memory[TRAP_VECTOR / BUNDLE_BYTES] = HANDLER; \
    D.DMEM.mem[32'h100 >> 2] = PWD; \
    D.DMEM.mem[32'h104 >> 2] = PWD; \
    D.DMEM.mem[32'h300 >> 2] = W300;


// ============================================================================
// Revisiones comunes a las tres copias
// ============================================================================

`define CHECK_COUNTERS(D, NAME) \
begin \
    check({NAME, ": dos lcont de ciclos seguidos difieren en 1"}, \
          D.REGFILE.regs[11] - D.REGFILE.regs[10], 32'd1); \
    check({NAME, ": dos lcont de bundles seguidos difieren en 1"}, \
          D.REGFILE.regs[13] - D.REGFILE.regs[12], 32'd1); \
    check({NAME, ": mitad alta de los ciclos = 0"}, D.REGFILE.regs[14], 32'd0); \
    check_true({NAME, ": los ciclos avanzan antes de medir 0"}, D.REGFILE.regs[15] > D.REGFILE.regs[11]); \
    check({NAME, ": con medir 0 los ciclos no avanzan"}, D.REGFILE.regs[16], D.REGFILE.regs[15]); \
    check({NAME, ": con medir 1 vuelven a avanzar de a 1"}, \
          D.REGFILE.regs[18] - D.REGFILE.regs[17], 32'd1); \
    check_true({NAME, ": lcont de bundles distinto de 0"}, D.REGFILE.regs[21] != 0); \
    check({NAME, ": N+1 lee x21 de antes del lcont"}, D.REGFILE.regs[22], 32'd0); \
    check({NAME, ": N+2 lee x21 de antes del lcont"}, D.REGFILE.regs[23], 32'd0); \
    check({NAME, ": N+3 lee el valor de lcont"}, D.REGFILE.regs[25], D.REGFILE.regs[21]); \
    check({NAME, ": lcont detrás de un salto tomado no escribe"}, D.REGFILE.regs[24], 32'd0); \
    check({NAME, ": medir 0 anulado (salto y excepción): sigue midiendo"}, D.cisa_measure_enable, 1'b1); \
    check({NAME, ": carga después de vaciarc"}, D.REGFILE.regs[20], 32'h55); \
    check({NAME, ": excepción en el bundle 34 (trap_pc = 0x220)"}, D.trap_pc, 32'h220); \
    check({NAME, ": una sola excepción"}, D.trap_count, 32'd1); \
    check({NAME, ": x30 = 99 (manejador)"}, D.REGFILE.regs[30], 32'd99); \
    check({NAME, ": x31 = 0 (bundle anulado)"}, D.REGFILE.regs[31], 32'd0); \
end

`define SAME_AS_REF(D, NAME) \
begin \
    int diff_regs, diff_mem; \
    diff_regs = 0; diff_mem = 0; \
    foreach (same_regs[k]) \
        if (D.REGFILE.regs[same_regs[k]] !== REF.REGFILE.regs[same_regs[k]]) diff_regs++; \
    for (int a = 0; a < 16384; a++) \
        if (D.DMEM.mem[a] !== REF.DMEM.mem[a]) diff_mem++; \
    check({NAME, ": registros sin contadores distintos de REF"}, diff_regs, 0); \
    check({NAME, ": palabras de memoria distintas de REF"}, diff_mem, 0); \
    check({NAME, ": misma contraseña en la bóveda"}, D.CRYPTO.VAULT.password, REF.CRYPTO.VAULT.password); \
end

// Registros que no guardan contadores (iguales en los tres modos)
int same_regs [] = '{4, 5, 6, 20, 22, 23, 24, 30, 31};


// ============================================================================
// Estímulos y verificación
// ============================================================================

int fl_cycles = 0;

initial begin

    $dumpfile("tb_cache_isa.vcd");
    $dumpvars(0, tb_cache_isa);

    clk   = 0;
    reset = 1;

    // Esperar a que la ROM y la memoria terminen su inicialización
    #1;

    build_program();
    `LOAD(REF)
    `LOAD(DUT1)
    `LOAD(DUT2)

    repeat (2) @(negedge clk);
    reset = 0;

    repeat (1500) @(negedge clk);

    // DUT2: vaciar la caché antes de comparar DMEM
    flush_req = 1'b1;
    while (!flush_done) begin
        @(negedge clk);
        fl_cycles++;
    end


    // ========================================================================
    tb_section("A, B y D. lcont, medir y anulación en las tres copias");
    // ========================================================================

    `CHECK_COUNTERS(REF,  "REF")
    `CHECK_COUNTERS(DUT1, "DUT1")
    `CHECK_COUNTERS(DUT2, "DUT2")


    // ========================================================================
    tb_section("C. vaciarc");
    // ========================================================================

    check("REF: vaciarc cuesta 2 ciclos sin caché",  M_REF.hold_cycles, 2);
    check("DUT1: vaciarc cuesta 2 ciclos sin caché", M_DUT1.hold_cycles, 2);
    check_true("DUT2: vaciarc espera el vaciado de la jerarquía", M_DUT2.hold_cycles > 2);
    check("REF: ciclos de stall por memoria = los 2 de vaciarc", REF.REGFILE.regs[19], 32'd2);
    check_true("DUT2: lcont de stalls por memoria > 2", DUT2.REGFILE.regs[19] > 2);
    check("DUT2: antes del vaciado, M[0x200] solo estaba en la caché", M_DUT2.before_200, 32'h0);
    check("DUT2: al terminar vaciarc, DMEM tiene M[0x200]", M_DUT2.after_200, 32'h55);
    check("DUT2: al terminar vaciarc, DMEM tiene M[0x204]", M_DUT2.after_204, 32'h66);
    check("DUT2: el store del bundle siguiente todavía no llegó a DMEM", M_DUT2.after_208, 32'h0);
    check("REF: el store después de vaciarc escribe una vez",  M_REF.writes_208, 1);
    check("DUT1: el store después de vaciarc escribe una vez", M_DUT1.writes_208, 1);
    check("REF: camcon después de vaciarc escribe una vez",  M_REF.writes_b, 1);
    check("DUT1: camcon después de vaciarc escribe una vez", M_DUT1.writes_b, 1);
    check("REF: M[0x300] rotado una sola vez", REF.DMEM.mem[32'h300 >> 2], rol(W300, 4));
    check("REF: M[0x208] = x4", REF.DMEM.mem[32'h208 >> 2], 32'h55);


    // ========================================================================
    tb_section("E. Contadores de la L1-D");
    // ========================================================================

    check("REF: lecturas con hit = 0 (sin L1-D)", REF.REGFILE.regs[26], 32'd0);
    check("REF: lecturas con miss = 0 (sin L1-D)", REF.REGFILE.regs[28], 32'd0);
    check("DUT2: lecturas con hit = perf_cache_l1d",
          DUT2.REGFILE.regs[26], DUT2.g_mem_cache.HIER.g_perf.PERF_K1A.read_hits[31:0]);
    check("DUT2: escrituras con hit = perf_cache_l1d",
          DUT2.REGFILE.regs[27], DUT2.g_mem_cache.HIER.g_perf.PERF_K1A.write_hits[31:0]);
    check("DUT2: lecturas con miss = perf_cache_l1d",
          DUT2.REGFILE.regs[28], DUT2.g_mem_cache.HIER.g_perf.PERF_K1A.read_misses[31:0]);
    check("DUT2: escrituras con miss = perf_cache_l1d",
          DUT2.REGFILE.regs[29], DUT2.g_mem_cache.HIER.g_perf.PERF_K1A.write_misses[31:0]);
    check_true("DUT2: hubo lecturas en la L1-D", DUT2.REGFILE.regs[26] + DUT2.REGFILE.regs[28] > 0);
    check_true("DUT2: hubo escrituras en la L1-D", DUT2.REGFILE.regs[27] + DUT2.REGFILE.regs[29] > 0);


    // ========================================================================
    tb_section("F. Mismo estado final que REF");
    // ========================================================================

    `SAME_AS_REF(DUT1, "DUT1")
    `SAME_AS_REF(DUT2, "DUT2")
    check("DUT2: ninguna línea en la L1-D y en la L2 a la vez (excl_checker)",
          DUT2.g_mem_cache.HIER.g_l2_real.g_excl.EXCL.violations, 0);

    $display("    vaciarc: REF %0d ciclos, DUT1 %0d y DUT2 %0d; vaciado final de DUT2 en %0d ciclos",
             M_REF.hold_cycles, M_DUT1.hold_cycles, M_DUT2.hold_cycles, fl_cycles);


    tb_finish("tb_cache_isa");
end

endmodule
