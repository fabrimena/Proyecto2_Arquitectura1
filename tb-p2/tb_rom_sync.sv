`timescale 1ns/1ps

/*
================================================================================
 Testbench: tb_rom_sync

 Descripción:
 ------------------------------------------------------------------------------
 Prueba la memoria de instrucciones síncrona (rtl-p2/rom_sync.sv, D1).
 Ejecuta el mismo programa en cuatro copias de top, con el mismo reloj y el
 mismo reset:

     C0  ROM_SYNC = 0, MEM_MODE = 0   memoria combinacional (proyecto 1)
     S0  ROM_SYNC = 1, MEM_MODE = 0   ROM síncrona
     C4  ROM_SYNC = 0, MEM_MODE = 1   combinacional con 4 ciclos de stall por acceso
     S4  ROM_SYNC = 1, MEM_MODE = 1   síncrona con 4 ciclos de stall por acceso

 La ROM síncrona lee con el siguiente PC, así que tiene que entregar en cada
 ciclo el mismo bundle que la combinacional: los saltos, las excepciones y
 los stalls no pueden notar la diferencia.

 El programa usa las 4 unidades: carga la contraseña y la llave, se
 autentica, cifra 2 bloques en un bucle con el salto hacia atrás junto a un
 guardado, llama a una subrutina con sye y vuelve con syer, y termina con un
 vcr fallido y una excepción (salto a TRAP_VECTOR, el último bundle de la
 ROM).

 Casos:
   A. El programa da los valores esperados con la memoria combinacional.
   B. En cada ciclo, la ROM síncrona y la combinacional tienen el mismo PC,
      el mismo bundle en IF, los mismos registros de segmentación y las
      mismas escrituras en WB, sin stalls y con stalls.
   C. En cada ciclo, el bundle de la ROM síncrona es memory[pc], también
      durante los stalls (se congela con el PC).
   D. El mismo estado final y la misma cantidad de ciclos.
   E. La lectura es de verdad síncrona: un cambio en memory se ve con la
      memoria combinacional en el acto y con la ROM recién en el flanco.
================================================================================
*/

`include "isa_defs.sv"


// ============================================================================
// Comparación ciclo a ciclo de dos copias de top
// ============================================================================

module rom_pair_check (

    input  logic                 clk,
    input  logic                 reset,

    input  logic [31:0]          c_pc,          // copia con la memoria combinacional
    input  logic [BUNDLE_W-1:0]  c_bundle,
    input  logic [31:0]          c_id_pc,
    input  logic [BUNDLE_W-1:0]  c_id_bundle,
    input  logic [31:0]          c_ex_pc,
    input  logic                 c_id_ex_valid,
    input  logic [4:0]           c_wb_we,
    input  logic [4:0][31:0]     c_wb_wdata,
    input  logic                 c_core_en,

    input  logic [31:0]          s_pc,          // copia con la ROM síncrona
    input  logic [BUNDLE_W-1:0]  s_bundle,
    input  logic [31:0]          s_id_pc,
    input  logic [BUNDLE_W-1:0]  s_id_bundle,
    input  logic [31:0]          s_ex_pc,
    input  logic                 s_id_ex_valid,
    input  logic [4:0]           s_wb_we,
    input  logic [4:0][31:0]     s_wb_wdata,
    input  logic                 s_core_en
);

int cycles       = 0;
int diff_pc      = 0;   // ciclos con PC distinto
int diff_bundle  = 0;   // ciclos con distinto bundle en IF
int diff_pipe    = 0;   // ciclos con IF/ID o ID/EX distintos
int diff_wb      = 0;   // ciclos con escrituras distintas en WB
int redirects    = 0;   // saltos tomados y excepciones vistos (cobertura)
int stalls       = 0;   // ciclos de stall vistos (cobertura)

logic [31:0] prev_pc;

always @(negedge clk) begin

    if (!reset) begin

        cycles++;

        if (s_pc !== c_pc)
            diff_pc++;
        if (s_bundle !== c_bundle)
            diff_bundle++;
        if ({s_id_pc, s_id_bundle, s_ex_pc, s_id_ex_valid} !== {c_id_pc, c_id_bundle, c_ex_pc, c_id_ex_valid})
            diff_pipe++;
        if ({s_wb_we, s_wb_wdata} !== {c_wb_we, c_wb_wdata})
            diff_wb++;

        if (!c_core_en)
            stalls++;
        else if (cycles > 1 && c_pc != prev_pc + BUNDLE_BYTES && c_pc != prev_pc)
            redirects++;

        prev_pc = c_pc;
    end
end

endmodule


module tb_rom_sync;

`include "tb_utils.svh"


logic clk;
logic reset;

top #(.ROM_SYNC(0)) C0 (.clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write());
top #(.ROM_SYNC(1)) S0 (.clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write());

top #(.ROM_SYNC(0), .MEM_MODE(1), .STALL_CYCLES(4)) C4 (
    .clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write()
);
top #(.ROM_SYNC(1), .MEM_MODE(1), .STALL_CYCLES(4)) S4 (
    .clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write()
);

always #5 clk = ~clk;


`define PAIR(NAME, C, S) \
rom_pair_check NAME ( \
    .clk(clk), .reset(reset), \
    .c_pc(C.pc), .c_bundle(C.instruction_bundle), .c_id_pc(C.id_pc), .c_id_bundle(C.id_bundle), \
    .c_ex_pc(C.ex_pc), .c_id_ex_valid(C.id_ex_valid), .c_wb_we(C.wb_we), .c_wb_wdata(C.wb_wdata), \
    .c_core_en(C.core_en), \
    .s_pc(S.pc), .s_bundle(S.instruction_bundle), .s_id_pc(S.id_pc), .s_id_bundle(S.id_bundle), \
    .s_ex_pc(S.ex_pc), .s_id_ex_valid(S.id_ex_valid), .s_wb_we(S.wb_we), .s_wb_wdata(S.wb_wdata), \
    .s_core_en(S.core_en) \
);

`PAIR(P0, C0, S0)
`PAIR(P4, C4, S4)


// El bundle de la ROM síncrona tiene que ser memory[pc] en cada ciclo
int not_pc_s0 = 0;
int not_pc_s4 = 0;

always @(negedge clk) begin

    if (!reset) begin
        if (S0.instruction_bundle !== S0.IMEM.memory[S0.pc[13:4]])
            not_pc_s0++;
        if (S4.instruction_bundle !== S4.IMEM.memory[S4.pc[13:4]])
            not_pc_s4++;
    end
end


// Ciclo en que cada copia llega al manejador
int cycle = 0;
int trap_c0 = -1, trap_s0 = -1, trap_c4 = -1, trap_s4 = -1;

always @(posedge clk) begin

    if (!reset)
        cycle++;
end

always @(negedge clk) begin

    if (!reset) begin
        if (C0.id_ex_valid && C0.ex_pc == TRAP_VECTOR && trap_c0 < 0) trap_c0 = cycle;
        if (S0.id_ex_valid && S0.ex_pc == TRAP_VECTOR && trap_s0 < 0) trap_s0 = cycle;
        if (C4.id_ex_valid && C4.ex_pc == TRAP_VECTOR && trap_c4 < 0) trap_c4 = cycle;
        if (S4.id_ex_valid && S4.ex_pc == TRAP_VECTOR && trap_s4 < 0) trap_s4 = cycle;
    end
end


// ============================================================================
// Codificación de instrucciones (formatos del ISA)
// ============================================================================

localparam logic [31:0] NOP = 32'h0000_0000;

function automatic logic [31:0] sumai(input logic [4:0] rg, input logic [4:0] rf1,
                                      input logic [10:0] imm);

    return {TYPE_IMM, OP_SUMI, rf1, rg, imm};
endfunction

function automatic logic [31:0] suma(input logic [4:0] rg, input logic [4:0] rf1,
                                     input logic [4:0] rf2);

    return {TYPE_REG, OP_SUM, rg, rf1, rf2, 6'b0};
endfunction

function automatic logic [31:0] lsu(input logic [3:0] id, input logic [4:0] base,
                                    input logic [4:0] reg_dato, input logic [10:0] off);

    return {TYPE_LSU, id, base, reg_dato, off};
endfunction

function automatic logic [31:0] branch(input logic [3:0] id, input logic [4:0] rf1,
                                       input logic [4:0] rf2, input logic [10:0] off);

    return {TYPE_BRU_COND, id, rf1, rf2, off};
endfunction

function automatic logic [31:0] sye(input logic [4:0] rg, input logic [15:0] off);

    return {TYPE_BRU_JUMP, OP_SYE, rg, off};
endfunction

function automatic logic [31:0] syer(input logic [4:0] rg, input logic [4:0] rf1,
                                     input logic [10:0] off);

    return {TYPE_BRU_JUMP, OP_SYER, rg, rf1, off};
endfunction

function automatic logic [31:0] fsl(input logic [4:0] rd, input logic [4:0] r1,
                                    input logic [1:0] lk, input logic [1:0] rk);

    return {TYPE_CRYPTO, OP_FSL, lk, rk, rd, r1, 7'b0};
endfunction

function automatic logic [31:0] ell(input logic [1:0] lk, input logic [1:0] off,
                                    input logic [4:0] rs1, input logic [4:0] rs2);

    return {TYPE_CRYPTO, OP_ELL, lk, off, rs1, rs2, 7'b0};
endfunction

function automatic logic [31:0] vcr(input logic [15:0] dir);

    return {TYPE_CRYPTO, OP_VCR, dir, 5'b0};
endfunction

function automatic logic [31:0] setpwd(input logic [4:0] rs);

    return {TYPE_CRYPTO, OP_SETPWD, 16'b0, rs};
endfunction

// Bundle: slot 0 ALU en los bits bajos, slot 3 CRIPTO en los altos
function automatic logic [127:0] bundle(input logic [31:0] alu, input logic [31:0] mem,
                                        input logic [31:0] bru, input logic [31:0] cripto);

    return {cripto, bru, mem, alu};
endfunction

function automatic logic [127:0] solo_alu(input logic [31:0] i);

    return bundle(i, NOP, NOP, NOP);
endfunction

function automatic logic [127:0] solo_lsu(input logic [31:0] i);

    return bundle(NOP, i, NOP, NOP);
endfunction

function automatic logic [127:0] solo_cri(input logic [31:0] i);

    return bundle(NOP, NOP, NOP, i);
endfunction


// ============================================================================
// Programa y datos (reglas N+3 del banco, N+1 de la bóveda y N+3 de ESTADO)
// ============================================================================

localparam logic [31:0] PWD   = 32'h5EC2_E7A1;
localparam logic [31:0] WRONG = 32'h0BAD_0BAD;

// Manejador en TRAP_VECTOR: x30 = 99 y se queda en un bucle
localparam logic [127:0] HANDLER = {NOP, sye(5'd0, 16'd0), NOP, sumai(5'd30, 5'd0, 11'd99)};

logic [127:0]     prog [0:63];
logic [3:0][31:0] key;
logic [31:0]      plain [0:3];

task automatic build_program();

    for (int i = 0; i < 64; i++)
        prog[i] = 128'b0;

    // Contraseña y llave; setpwd y vcr van en bundles con una carga
    prog[0]  = bundle(sumai(5'd16, 5'd0, 11'h200), lsu(OP_CARGAI, 5'd0, 5'd6,  11'h100), NOP, NOP);
    prog[1]  = bundle(sumai(5'd17, 5'd0, 11'h210), lsu(OP_CARGAI, 5'd0, 5'd8,  11'h110), NOP, NOP);
    prog[2]  = solo_lsu(lsu(OP_CARGAI, 5'd0, 5'd9,  11'h114));
    prog[3]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd10, 11'h118), NOP, setpwd(5'd6));
    prog[4]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd11, 11'h11C), NOP, vcr(16'h104));
    prog[7]  = solo_cri(ell(2'd0, 2'd0, 5'd8,  5'd9));
    prog[8]  = solo_cri(ell(2'd0, 2'd2, 5'd10, 5'd11));

    // Bucle: cifra el bloque en M[x16] (salto hacia atrás en el mismo bundle que un guardado)
    prog[9]  = solo_lsu(lsu(OP_CARGAI, 5'd16, 5'd4, 11'd0));
    prog[10] = solo_lsu(lsu(OP_CARGAI, 5'd16, 5'd5, 11'd4));
    prog[11] = solo_alu(sumai(5'd16, 5'd16, 11'd8));
    prog[13] = solo_cri(fsl(5'd4, 5'd4, 2'd0, 2'd0));
    prog[16] = solo_cri(fsl(5'd4, 5'd4, 2'd0, 2'd1));
    prog[19] = solo_cri(fsl(5'd4, 5'd4, 2'd0, 2'd2));
    prog[22] = solo_cri(fsl(5'd4, 5'd4, 2'd0, 2'd3));
    prog[25] = solo_lsu(lsu(OP_GUARDAP, 5'd16, 5'd4, -11'sd8));
    prog[26] = bundle(NOP, lsu(OP_GUARDAP, 5'd16, 5'd5, -11'sd4),
                      branch(OP_MENORA, 5'd16, 5'd17, 11'((9 - 26) * 16)), NOP);

    // sye a la subrutina del bundle 48 (x1 = 0x1C0); los bundles 28 y 29 se
    // anulan en la ida y se ejecutan a la vuelta
    prog[27] = bundle(NOP, NOP, sye(5'd1, 16'((48 - 27) * 16)), NOP);
    prog[28] = solo_alu(suma(5'd20, 5'd4, 5'd5));                          // x20 = L + R
    prog[29] = solo_cri(vcr(16'h108));                                     // AUTH = 0

    // Excepción: fsl 3 bundles después del vcr fallido
    prog[32] = bundle(sumai(5'd27, 5'd0, 11'd7), lsu(OP_CARGAI, 5'd0, 5'd28, 11'h200), NOP,
                      fsl(5'd4, 5'd4, 2'd0, 2'd0));
    prog[33] = solo_alu(sumai(5'd29, 5'd0, 11'd2));                        // anulado
    prog[34] = solo_alu(sumai(5'd29, 5'd0, 11'd3));                        // anulado

    // Subrutina: x18 = 33 y vuelve con syer
    prog[48] = solo_alu(sumai(5'd18, 5'd0, 11'd33));
    prog[49] = bundle(NOP, NOP, syer(5'd0, 5'd1, 11'd0), NOP);
    prog[50] = solo_alu(sumai(5'd19, 5'd0, 11'd1));                        // anulado
    prog[51] = solo_alu(sumai(5'd19, 5'd0, 11'd2));                        // anulado
endtask

`define LOAD(D) \
    for (int i = 0; i < 64; i++) D.IMEM.memory[i] = prog[i]; \
    D.IMEM.memory[TRAP_VECTOR / BUNDLE_BYTES] = HANDLER; \
    D.DMEM.mem[32'h100 >> 2] = PWD; \
    D.DMEM.mem[32'h104 >> 2] = PWD; \
    D.DMEM.mem[32'h108 >> 2] = WRONG; \
    for (int i = 0; i < 4; i++) D.DMEM.mem[(32'h110 >> 2) + i] = key[i]; \
    for (int i = 0; i < 4; i++) D.DMEM.mem[(32'h200 >> 2) + i] = plain[i];


`define SAME_STATE(C, S, NAME) \
begin \
    int diff_regs, diff_mem; \
    diff_regs = 0; diff_mem = 0; \
    for (int r = 0; r < 32; r++) \
        if (S.REGFILE.regs[r] !== C.REGFILE.regs[r]) diff_regs++; \
    for (int a = 0; a < 16384; a++) \
        if (S.DMEM.mem[a] !== C.DMEM.mem[a]) diff_mem++; \
    check({NAME, ": registros distintos"}, diff_regs, 0); \
    check({NAME, ": palabras de memoria distintas"}, diff_mem, 0); \
    check({NAME, ": mismo ESTADO"}, S.crypto_estado, C.crypto_estado); \
    check({NAME, ": misma excepción (trap_pc)"}, S.trap_pc, C.trap_pc); \
end

`define SAME_CYCLES(P, NAME) \
begin \
    check({NAME, ": ciclos con PC distinto"}, P.diff_pc, 0); \
    check({NAME, ": ciclos con otro bundle en IF"}, P.diff_bundle, 0); \
    check({NAME, ": ciclos con IF/ID o ID/EX distintos"}, P.diff_pipe, 0); \
    check({NAME, ": ciclos con escrituras distintas en WB"}, P.diff_wb, 0); \
end


initial begin

    logic [127:0] antes;
    int           idx;

    $dumpfile("tb_rom_sync.vcd");
    $dumpvars(0, tb_rom_sync);

    clk   = 0;
    reset = 1;

    key = {32'hC3D2_E1F0, 32'h8796_A5B4, 32'h4B5A_6978, 32'h0F1E_2D3C};

    plain[0] = 32'h414C_4F48;  plain[1] = 32'h3632_3032;     // "HOLA" "2026"
    plain[2] = 32'h636F_7250;  plain[3] = 32'h6461_7365;     // "Proc" "esad"

    // Esperar la inicialización de las memorias; el programa se carga
    // durante el reset, antes del flanco en que la ROM lee el bundle 0
    #1;

    build_program();
    `LOAD(C0)
    `LOAD(S0)
    `LOAD(C4)
    `LOAD(S4)

    repeat (2) @(negedge clk);
    reset = 0;

    repeat (300) @(negedge clk);


    // ========================================================================
    tb_section("A. Programa con la memoria combinacional");
    // ========================================================================

    check("bloque 0: L = 03D44466 (HOLA2026)", C0.DMEM.mem[32'h200 >> 2], 32'h03D4_4466);
    check("bloque 0: R = D685AFAF",            C0.DMEM.mem[32'h204 >> 2], 32'hD685_AFAF);
    check("x18 = 33 (subrutina)",              C0.REGFILE.regs[18], 32'd33);
    check("x1 = 0x1C0 (enlace del sye)",       C0.REGFILE.regs[1], 32'h1C0);
    check("x19 = 0 (anulados por el syer)",    C0.REGFILE.regs[19], 32'd0);
    check("x20 = L + R (bundle de la vuelta)", C0.REGFILE.regs[20],
          C0.DMEM.mem[32'h208 >> 2] + C0.DMEM.mem[32'h20C >> 2]);
    check("x29 = 0 (anulados por la excepción)", C0.REGFILE.regs[29], 32'd0);
    check("x30 = 99 (manejador)",              C0.REGFILE.regs[30], 32'd99);
    check("trap_pc = 0x200 (bundle 32)",       C0.trap_pc, 32'h200);
    check_true("hay saltos y excepciones",     P0.redirects >= 5);
    check_true("C4 tiene ciclos de stall",     P4.stalls > 0);


    // ========================================================================
    tb_section("B. Mismo PC, bundle y pipeline en cada ciclo");
    // ========================================================================

    `SAME_CYCLES(P0, "sin stalls")
    `SAME_CYCLES(P4, "con stalls")


    // ========================================================================
    tb_section("C. El bundle de la ROM síncrona es memory[pc]");
    // ========================================================================

    check("S0: ciclos con un bundle que no es memory[pc]", not_pc_s0, 0);
    check("S4: ciclos con un bundle que no es memory[pc]", not_pc_s4, 0);


    // ========================================================================
    tb_section("D. Mismo estado final y mismos ciclos");
    // ========================================================================

    `SAME_STATE(C0, S0, "sin stalls")
    `SAME_STATE(C4, S4, "con stalls")
    check_true("C0 llegó al manejador", trap_c0 > 0);
    check("S0 llega al manejador en el mismo ciclo", trap_s0, trap_c0);
    check("S4 llega al manejador en el mismo ciclo que C4", trap_s4, trap_c4);
    $display("    llegan al manejador en el ciclo %0d sin stalls y %0d con stalls (%0d ciclos de stall)",
             trap_c0, trap_c4, P4.stalls);


    // ========================================================================
    tb_section("E. La lectura es síncrona");
    // ========================================================================

    // Cambiar el bundle actual: la combinacional lo muestra en el acto y la
    // ROM síncrona sigue con el que leyó en el flanco
    @(negedge clk);
    idx    = S0.pc[13:4];
    antes = S0.instruction_bundle;
    S0.IMEM.memory[idx] = ~antes;
    C0.IMEM.memory[idx] = ~antes;
    #1;
    check_true("combinacional: el cambio se ve en el acto", C0.instruction_bundle === ~antes);
    check_true("síncrona: sigue el bundle del flanco",      S0.instruction_bundle === antes);


    tb_finish("tb_rom_sync");
end

endmodule
