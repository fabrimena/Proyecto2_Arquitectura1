`timescale 1ns/1ps

/*
================================================================================
 Testbench: tb_port_b

 Descripción:
 ------------------------------------------------------------------------------
 Prueba el puerto B de la memoria (vcr y camcon de la unidad criptográfica)
 en el procesador completo. Ejecuta el mismo programa en tres copias de top,
 con el mismo reloj y el mismo reset:

     REF   MEM_MODE = 0, el procesador del proyecto 1
     DUT1  MEM_MODE = 1, STALL_CYCLES = 4 (modelo de stalls)
     DUT2  MEM_MODE = 2, jerarquía de caché: los dos puertos pasan por la
           L1-D (l1d_port_arbiter) y la L2 de prueba

 El programa se autentica con setpwd y vcr, y mezcla vcr y camcon con cargas
 y stores de la LSU en el mismo bundle, incluso sobre la misma palabra.
 También usa vcr y camcon sobre palabras que el programa acaba de guardar:
 con la caché write-back esas palabras solo están (sucias) en la L1-D y
 DMEM tiene el valor viejo. Termina con un vcr fallido y una excepción.

 Casos:
   A. El programa da los valores esperados en REF.
   B. DUT1 y DUT2 terminan con los mismos registros, la misma memoria (DUT2
      después del vaciado), la misma bóveda, el mismo ESTADO y la misma
      excepción que REF. Si un camcon rotara dos veces o un vcr leyera un
      valor viejo, la contraseña, ESTADO o la memoria serían distintos.
   C. Las escrituras al banco de registros son las mismas y en el mismo
      orden, y camcon escribe una sola vez en DMEM con el modelo de stalls.
   D. Con la caché el programa tarda más ciclos que REF, y el PC y los
      registros de segmentación no cambian durante los stalls.
================================================================================
*/

`include "isa_defs.sv"


// ============================================================================
// Monitor de una copia de top: escrituras al banco y ciclos de stall
// ============================================================================

module monitor_port_b (

    input  logic             clk,
    input  logic             reset,

    input  logic             core_en,
    input  logic             id_ex_valid,
    input  logic [31:0]      pc,
    input  logic [31:0]      id_pc,
    input  logic [31:0]      ex_pc,

    input  logic [4:0]       wb_we,
    input  logic [4:0][4:0]  wb_waddr,
    input  logic [4:0][31:0] wb_wdata,

    input  logic             dmem_we_b
);

localparam int MAX_EV = 256;

logic [39:0] ev [0:MAX_EV-1];   // {slot, registro, dato}
int          n_ev          = 0;
int          cycle         = 0;
int          stall_cycles  = 0;
int          writes_b      = 0;     // escrituras del puerto B de DMEM
int          trap_cycle    = -1;
int          freeze_errors = 0;

logic        was_stalled   = 1'b0;
logic [95:0] frozen;

always @(posedge clk) begin

    if (!reset) begin

        cycle++;

        if (core_en) begin
            for (int p = 0; p < 5; p++)
                if (wb_we[p] && trap_cycle < 0) begin
                    if (n_ev < MAX_EV)
                        ev[n_ev] = {3'(p), wb_waddr[p], wb_wdata[p]};
                    n_ev++;
                end
        end
        else
            stall_cycles++;

        if (dmem_we_b)
            writes_b++;

        was_stalled = !core_en;
        frozen      = {pc, id_pc, ex_pc};
    end
end

always @(negedge clk) begin

    if (!reset) begin

        if (was_stalled && {pc, id_pc, ex_pc} !== frozen)
            freeze_errors++;

        if (id_ex_valid && ex_pc == TRAP_VECTOR && trap_cycle < 0)
            trap_cycle = cycle;
    end
end

endmodule


module tb_port_b;

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
monitor_port_b NAME ( \
    .clk(clk), .reset(reset), \
    .core_en(D.core_en), .id_ex_valid(D.id_ex_valid), \
    .pc(D.pc), .id_pc(D.id_pc), .ex_pc(D.ex_pc), \
    .wb_we(D.wb_we), .wb_waddr(D.wb_waddr), .wb_wdata(D.wb_wdata), \
    .dmem_we_b(D.dmem_we_b) \
);

`MONITOR(M_REF,  REF)
`MONITOR(M_DUT1, DUT1)
`MONITOR(M_DUT2, DUT2)


// ============================================================================
// Codificación de instrucciones (formatos del ISA)
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

function automatic logic [31:0] fsl(input logic [4:0] rd, input logic [4:0] r1,
                                    input logic [1:0] lk, input logic [1:0] rk);

    return {TYPE_CRYPTO, OP_FSL, lk, rk, rd, r1, 7'b0};
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

// Bundle: slot 0 ALU en los bits bajos, slot 3 CRIPTO en los altos
function automatic logic [127:0] bundle(input logic [31:0] alu, input logic [31:0] mem,
                                        input logic [31:0] bru, input logic [31:0] cripto);

    return {cripto, bru, mem, alu};
endfunction


// ============================================================================
// Programa y datos
//
// Respeta la regla N+3 del banco, la de la bóveda (N+1) y la de ESTADO (N+3).
// ============================================================================

localparam logic [31:0] PWD   = 32'h5EC2_E7A1;
localparam logic [31:0] WRONG = 32'h0BAD_0BAD;
localparam logic [31:0] W300  = 32'h1234_5678;
localparam logic [31:0] W304  = 32'h0F0F_0F0F;
localparam logic [31:0] W310  = 32'h0000_0000;
localparam logic [31:0] W500  = 32'hDEAD_BEEF;
localparam logic [31:0] W380  = 32'h0380_0380;

// Manejador en TRAP_VECTOR: x30 = 99 y se queda en un bucle
localparam logic [127:0] HANDLER = {NOP, sye(5'd0, 16'd0), NOP, sumai(5'd30, 5'd0, 11'd99)};

logic [127:0] prog [0:31];

task automatic build_program();

    for (int i = 0; i < 32; i++)
        prog[i] = 128'b0;

    // x6 = contraseña; setpwd y vcr (correcto) junto con cargas. Cada camcon
    // rota también la contraseña de la bóveda: después del bundle 7 es
    // ROL(PWD, 4) (x14), después del 13 ROL(PWD, 12) y después del 16 ROL(PWD, 15).
    prog[0]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd6, 11'h100), NOP, NOP);
    prog[1]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd14, 11'h118), NOP, NOP);
    prog[3]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd7, 11'h300), NOP, setpwd(5'd6));
    prog[4]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd8, 11'h304), NOP, vcr(16'h104));

    // camcon y una carga de la misma palabra: la carga lee el valor de antes
    prog[7]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd9, 11'h300), NOP, camcon(16'h300, 5'd4));
    prog[8]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd10, 11'h300), NOP, NOP);

    // vcr de una palabra recién guardada (con la caché, solo está en la L1-D)
    prog[9]  = bundle(NOP, lsu(OP_GUARDAP, 5'd0, 5'd14, 11'h310), NOP, NOP);
    prog[10] = bundle(NOP, NOP, NOP, vcr(16'h310));

    // store y camcon en la misma palabra: camcon lee el valor de antes y gana
    prog[13] = bundle(NOP, lsu(OP_GUARDAP, 5'd0, 5'd8, 11'h310), NOP, camcon(16'h310, 5'd8));
    prog[14] = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd11, 11'h310), NOP, NOP);

    // store y vcr en la misma palabra: vcr lee el valor de antes, que es la
    // contraseña ya rotada, ROL(PWD, 12); el store guarda PWD
    prog[15] = bundle(NOP, lsu(OP_GUARDAP, 5'd0, 5'd6, 11'h314), NOP, vcr(16'h314));

    // camcon y una carga que fallan en la caché (líneas nuevas)
    prog[16] = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd13, 11'h380), NOP, camcon(16'h500, 5'd3));

    // fsl con AUTH = 1 (del vcr del bundle 15); después vcr fallido y excepción
    prog[18] = bundle(NOP, NOP, NOP, fsl(5'd4, 5'd4, 2'd0, 2'd0));
    prog[19] = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd12, 11'h108), NOP, vcr(16'h108));
    prog[22] = bundle(sumai(5'd27, 5'd0, 11'd7), lsu(OP_CARGAI, 5'd0, 5'd28, 11'h300), NOP,
                      fsl(5'd4, 5'd4, 2'd0, 2'd0));
    prog[23] = bundle(sumai(5'd29, 5'd0, 11'd2), NOP, NOP, NOP);           // anulado
endtask

`define LOAD(D) \
    for (int i = 0; i < 32; i++) D.IMEM.memory[i] = prog[i]; \
    D.IMEM.memory[TRAP_VECTOR / BUNDLE_BYTES] = HANDLER; \
    D.DMEM.mem[32'h100 >> 2] = PWD; \
    D.DMEM.mem[32'h104 >> 2] = PWD; \
    D.DMEM.mem[32'h108 >> 2] = WRONG; \
    D.DMEM.mem[32'h118 >> 2] = rol(PWD, 4); \
    D.DMEM.mem[32'h300 >> 2] = W300; \
    D.DMEM.mem[32'h304 >> 2] = W304; \
    D.DMEM.mem[32'h310 >> 2] = W310; \
    D.DMEM.mem[32'h314 >> 2] = rol(PWD, 12); \
    D.DMEM.mem[32'h500 >> 2] = W500; \
    D.DMEM.mem[32'h380 >> 2] = W380;


// ============================================================================
// Comparaciones con REF
// ============================================================================

`define SAME_STATE(D, NAME) \
begin \
    int diff_regs, diff_mem, diff_vault; \
    diff_regs = 0; diff_mem = 0; diff_vault = 0; \
    for (int r = 0; r < 32; r++) \
        if (D.REGFILE.regs[r] !== REF.REGFILE.regs[r]) diff_regs++; \
    for (int a = 0; a < 16384; a++) \
        if (D.DMEM.mem[a] !== REF.DMEM.mem[a]) diff_mem++; \
    for (int k = 0; k < 4; k++) \
        for (int w = 0; w < 4; w++) \
            if (D.CRYPTO.VAULT.keys[k][w] !== REF.CRYPTO.VAULT.keys[k][w]) diff_vault++; \
    check({NAME, ": registros distintos de REF"}, diff_regs, 0); \
    check({NAME, ": palabras de memoria distintas de REF"}, diff_mem, 0); \
    check({NAME, ": palabras de la bóveda distintas de REF"}, diff_vault, 0); \
    check({NAME, ": misma contraseña en la bóveda"}, D.CRYPTO.VAULT.password, REF.CRYPTO.VAULT.password); \
    check({NAME, ": mismo ESTADO"}, D.crypto_estado, REF.crypto_estado); \
    check({NAME, ": misma excepción (trap_pc)"}, D.trap_pc, REF.trap_pc); \
    check({NAME, ": una sola excepción"}, D.trap_count, 32'd1); \
end

`define SAME_EVENTS(M, NAME) \
begin \
    int diff_ev; \
    diff_ev = 0; \
    for (int i = 0; i < M_REF.n_ev && i < M_REF.MAX_EV; i++) \
        if (M.ev[i] !== M_REF.ev[i]) diff_ev++; \
    check({NAME, ": mismo número de escrituras al banco que REF"}, M.n_ev, M_REF.n_ev); \
    check({NAME, ": escrituras distintas o en otro orden"}, diff_ev, 0); \
end


int fl_cycles = 0;

initial begin

    $dumpfile("tb_port_b.vcd");
    $dumpvars(0, tb_port_b);

    clk   = 0;
    reset = 1;

    // Esperar a que instruction_memory y memory terminen su inicialización
    #1;

    build_program();
    `LOAD(REF)
    `LOAD(DUT1)
    `LOAD(DUT2)

    repeat (2) @(negedge clk);
    reset = 0;

    repeat (400) @(negedge clk);

    // DUT2: vaciar la caché antes de leer DMEM
    flush_req = 1'b1;
    while (!flush_done) begin
        @(negedge clk);
        fl_cycles++;
    end


    // ========================================================================
    tb_section("A. Programa del proyecto 1 en REF");
    // ========================================================================

    check("x9 = M[0x300] antes de camcon",          REF.REGFILE.regs[9],  W300);
    check("x10 = M[0x300] rotado 4 (camcon)",       REF.REGFILE.regs[10], rol(W300, 4));
    check("M[0x300] = ROL(W300, 4)",                REF.DMEM.mem[32'h300 >> 2], rol(W300, 4));
    check("x11 = M[0x310]: gana camcon sobre el store", REF.REGFILE.regs[11], rol(PWD, 12));
    check("M[0x314] = contraseña (store junto al vcr)", REF.DMEM.mem[32'h314 >> 2], PWD);
    check("M[0x500] = ROL(W500, 3)",                REF.DMEM.mem[32'h500 >> 2], rol(W500, 3));
    check("x13 = M[0x380]",                         REF.REGFILE.regs[13], W380);
    check("contraseña rotada 4 + 8 + 3 por los camcon", REF.CRYPTO.VAULT.password, rol(PWD, 15));
    check("x12 = la candidata incorrecta",          REF.REGFILE.regs[12], WRONG);
    check("AUTH = 0 después del vcr fallido",       REF.crypto_estado[0], 1'b0);
    check("excepción en el bundle 22 (trap_pc = 0x160)", REF.trap_pc, 32'h160);
    check("una sola excepción (el fsl del bundle 18 tenía AUTH)", REF.trap_count, 32'd1);
    check("x27 = 0 (ALU del bundle con excepción)", REF.REGFILE.regs[27], 32'd0);
    check("x28 = 0 (carga del bundle con excepción)", REF.REGFILE.regs[28], 32'd0);
    check("x29 = 0 (bundle anulado)",               REF.REGFILE.regs[29], 32'd0);
    check("x30 = 99 (manejador)",                   REF.REGFILE.regs[30], 32'd99);
    check_true("REF llegó al manejador",            M_REF.trap_cycle > 0);


    // ========================================================================
    tb_section("B. Mismo estado final que REF");
    // ========================================================================

    `SAME_STATE(DUT1, "DUT1")
    `SAME_STATE(DUT2, "DUT2")


    // ========================================================================
    tb_section("C. Mismas escrituras al banco; camcon escribe una vez");
    // ========================================================================

    check_true("REF tiene escrituras para comparar", M_REF.n_ev > 10);
    `SAME_EVENTS(M_DUT1, "DUT1")
    `SAME_EVENTS(M_DUT2, "DUT2")
    check("REF: 3 escrituras de camcon en DMEM",   M_REF.writes_b, 3);
    check("DUT1: 3 escrituras de camcon en DMEM",  M_DUT1.writes_b, 3);
    check("DUT2: el puerto B de DMEM no se usa",   M_DUT2.writes_b, 0);


    // ========================================================================
    tb_section("D. Ciclos y congelamiento");
    // ========================================================================

    check("REF sin ciclos de stall", M_REF.stall_cycles, 0);
    check_true("DUT2 tiene ciclos de stall", M_DUT2.stall_cycles > 0);
    check("DUT2 llega al manejador con los ciclos de stall de más",
          M_DUT2.trap_cycle - M_REF.trap_cycle, M_DUT2.stall_cycles);
    check("DUT1: PC, IF/ID e ID/EX quietos en cada stall", M_DUT1.freeze_errors, 0);
    check("DUT2: PC, IF/ID e ID/EX quietos en cada stall", M_DUT2.freeze_errors, 0);

    $display("    REF llega al manejador en el ciclo %0d, DUT1 en el %0d y DUT2 en el %0d; vaciado en %0d ciclos",
             M_REF.trap_cycle, M_DUT1.trap_cycle, M_DUT2.trap_cycle, fl_cycles);


    tb_finish("tb_port_b");
end

endmodule
