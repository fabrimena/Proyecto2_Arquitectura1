`timescale 1ns/1ps

/*
================================================================================
 Testbench: tb_pipeline_stall

 Descripción:
 ------------------------------------------------------------------------------
 Prueba el congelamiento del procesador (proyecto 2, iteración 1). Ejecuta el
 mismo programa en tres copias de top, con el mismo reloj y el mismo reset:

     REF   MEM_MODE = 0, el procesador del proyecto 1
     DUT1  MEM_MODE = 1, STALL_CYCLES = 1 (cada acceso de la LSU tarda 1 ciclo más)
     DUT4  MEM_MODE = 1, STALL_CYCLES = 4

 Con stalls, el programa tiene que terminar igual que en REF, sólo que más
 tarde: el bundle completo se congela y nada se repite ni se pierde.

 El programa usa las 4 unidades: carga la contraseña y la llave, se autentica
 (setpwd y vcr en bundles con una carga), cifra 2 bloques en un bucle (cargas,
 4 fsl y guardados, con el salto hacia atrás en el mismo bundle que un
 guardado), guarda y lee palabras y bytes, ejecuta camcon en el mismo bundle
 que una carga, un sye en el mismo bundle que otra y termina con una
 excepción de privilegio (un fsl después de un vcr fallido, en un bundle con
 una carga que no debe ejecutarse).

 Casos:
   A. El programa del proyecto 1 da los valores esperados en REF (incluido el
      vector conocido HOLA2026 -> 03D44466 D685AFAF).
   B. DUT1 y DUT4 terminan con los mismos registros, la misma memoria de
      datos, la misma bóveda, el mismo ESTADO y la misma excepción que REF.
   C. Las escrituras al banco y a la memoria son las mismas y en el mismo
      orden: ninguna se repite durante un stall (camcon rota M[dir] una sola
      vez) y ninguna se pierde.
   D. Ciclos: cada acceso de la LSU agrega STALL_CYCLES ciclos, el programa
      termina exactamente STALL_CYCLES x accesos ciclos después que en REF y,
      en cada ciclo de stall, el PC y los registros de segmentación no
      cambian.

================================================================================
*/

`include "isa_defs.sv"


// ============================================================================
// Monitor de una copia de top
//
// En cada flanco de clk anota lo que se escribe en el banco (si el núcleo
// avanza) y en DMEM, y cuenta los ciclos de stall y los accesos de la LSU.
// Deja de anotar escrituras cuando el manejador llega a EX: su bucle escribe
// x30 en cada vuelta y REF da más vueltas porque llega antes.
// ============================================================================

module monitor_stall (

    input  logic             clk,
    input  logic             reset,

    input  logic             core_en,       // 1: el núcleo avanza en este flanco
    input  logic             id_ex_valid,
    input  logic [31:0]      pc,
    input  logic [31:0]      id_pc,
    input  logic [31:0]      ex_pc,

    input  logic             mem_re,        // acceso de la LSU en EX
    input  logic             mem_we,

    input  logic [4:0]       wb_we,
    input  logic [4:0][4:0]  wb_waddr,
    input  logic [4:0][31:0] wb_wdata,

    input  logic             dmem_we,
    input  logic [3:0]       dmem_be,
    input  logic [31:0]      dmem_addr,
    input  logic [31:0]      dmem_wdata,
    input  logic             dmem_we_b,
    input  logic [31:0]      dmem_addr_b,
    input  logic [31:0]      dmem_wdata_b
);

localparam int MAX_EV = 512;

// Evento: {tipo, puerto o byte enable, dirección o registro, dato}
//   tipo 1 = banco, 2 = memoria puerto A, 3 = memoria puerto B
logic [71:0] ev [0:MAX_EV-1];
int          n_ev          = 0;

int          cycle         = 0;     // flancos de clk desde que bajó el reset
int          stall_cycles  = 0;     // flancos en que el núcleo no avanzó
int          accesses      = 0;     // accesos de la LSU que terminaron
int          trap_cycle    = -1;    // flanco en que el manejador llegó a EX
int          freeze_errors = 0;     // stalls en que cambió el PC, IF/ID o ID/EX

logic        was_stalled   = 1'b0;
logic [95:0] frozen;

task automatic add_event(input logic [71:0] e);

    if (trap_cycle < 0) begin

        if (n_ev < MAX_EV)
            ev[n_ev] = e;

        n_ev++;
    end
endtask

always @(posedge clk) begin

    if (!reset) begin

        cycle++;

        if (core_en) begin

            for (int p = 0; p < 5; p++)
                if (wb_we[p])
                    add_event({4'h1, 4'(p), 27'b0, wb_waddr[p], wb_wdata[p]});

            if (mem_re || mem_we)
                accesses++;
        end
        else
            stall_cycles++;

        if (dmem_we)
            add_event({4'h2, dmem_be, dmem_addr, dmem_wdata});

        if (dmem_we_b)
            add_event({4'h3, 4'hF, dmem_addr_b, dmem_wdata_b});

        was_stalled = !core_en;
        frozen      = {pc, id_pc, ex_pc};
    end
end

// Después del flanco: si el núcleo estaba detenido, nada pudo cambiar
always @(negedge clk) begin

    if (!reset) begin

        if (was_stalled && {pc, id_pc, ex_pc} !== frozen)
            freeze_errors++;

        if (id_ex_valid && ex_pc == TRAP_VECTOR && trap_cycle < 0)
            trap_cycle = cycle;
    end
end

endmodule


module tb_pipeline_stall;

`include "tb_utils.svh"


logic clk;
logic reset;

top REF (.clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write());

top #(.MEM_MODE(1), .STALL_CYCLES(1)) DUT1 (
    .clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write()
);

top #(.MEM_MODE(1), .STALL_CYCLES(4)) DUT4 (
    .clk(clk), .reset(reset), .debug_result(), .debug_rd(), .debug_write()
);

always #5 clk = ~clk;


`define MONITOR(NAME, D) \
monitor_stall NAME ( \
    .clk(clk), .reset(reset), \
    .core_en(D.core_en), .id_ex_valid(D.id_ex_valid), \
    .pc(D.pc), .id_pc(D.id_pc), .ex_pc(D.ex_pc), \
    .mem_re(D.mem_re), .mem_we(D.mem_we), \
    .wb_we(D.wb_we), .wb_waddr(D.wb_waddr), .wb_wdata(D.wb_wdata), \
    .dmem_we(D.dmem_we), .dmem_be(D.dmem_be), .dmem_addr(D.dmem_addr), .dmem_wdata(D.dmem_wdata), \
    .dmem_we_b(D.dmem_we_b), .dmem_addr_b(D.dmem_addr_b), .dmem_wdata_b(D.dmem_wdata_b) \
);

`MONITOR(M_REF,  REF)
`MONITOR(M_DUT1, DUT1)
`MONITOR(M_DUT4, DUT4)


// ============================================================================
// Modelo de referencia de Feistel4 (igual al de tb_pipeline_cripto)
// ============================================================================

function automatic logic [31:0] ref_rol(input logic [31:0] x, input int r);

    r = r % 32;
    return (r == 0) ? x : ((x << r) | (x >> (32 - r)));
endfunction

// F(x, k) = (ROL(x, 5) + k) ^ ROL(x, 13)
function automatic logic [31:0] ref_f(input logic [31:0] x, input logic [31:0] k);

    return (ref_rol(x, 5) + k) ^ ref_rol(x, 13);
endfunction

// Cifrado completo: 4 rondas (L, R) -> (R, L ^ F(R, Ki))
function automatic logic [63:0] ref_encrypt(input logic [31:0] l, input logic [31:0] r,
                                            input logic [3:0][31:0] key);

    logic [63:0] lr;

    lr = {l, r};
    for (int i = 0; i < 4; i++)
        lr = {lr[31:0], lr[63:32] ^ ref_f(lr[31:0], key[i])};

    return lr;
endfunction


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
// Programa y datos
//
// Respeta la regla N+3 del banco (sin bypass), la de la bóveda (N+1) y la de
// ESTADO (N+3), igual que cualquier programa del proyecto 1.
// ============================================================================

localparam logic [31:0] PWD     = 32'h5EC2_E7A1;
localparam logic [31:0] WRONG   = 32'h0BAD_0BAD;
localparam int          ACCESOS = 19;   // accesos de la LSU que el programa ejecuta

// Manejador en TRAP_VECTOR: x30 = 99 y se queda en un bucle
localparam logic [127:0] HANDLER = {NOP, sye(5'd0, 16'd0), NOP, sumai(5'd30, 5'd0, 11'd99)};

logic [127:0]     prog [0:63];
logic [3:0][31:0] key;
logic [31:0]      plain [0:3];      // "HOLA2026Proc" + "esad": 2 bloques

task automatic build_program();

    for (int i = 0; i < 64; i++)
        prog[i] = 128'b0;

    // Contraseña y llave (5 cargas); setpwd y vcr van en bundles con una carga
    prog[0]  = bundle(sumai(5'd16, 5'd0, 11'h200), lsu(OP_CARGAI, 5'd0, 5'd6,  11'h100), NOP, NOP);
    prog[1]  = bundle(sumai(5'd17, 5'd0, 11'h210), lsu(OP_CARGAI, 5'd0, 5'd8,  11'h110), NOP, NOP);
    prog[2]  = solo_lsu(lsu(OP_CARGAI, 5'd0, 5'd9,  11'h114));
    prog[3]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd10, 11'h118), NOP, setpwd(5'd6));
    prog[4]  = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd11, 11'h11C), NOP, vcr(16'h104));
    prog[7]  = solo_cri(ell(2'd0, 2'd0, 5'd8,  5'd9));
    prog[8]  = solo_cri(ell(2'd0, 2'd2, 5'd10, 5'd11));

    // Bucle: cifra el bloque en M[x16] y suma L en x20 y R en x21 (4 accesos por vuelta)
    prog[9]  = solo_lsu(lsu(OP_CARGAI, 5'd16, 5'd4, 11'd0));
    prog[10] = solo_lsu(lsu(OP_CARGAI, 5'd16, 5'd5, 11'd4));
    prog[11] = solo_alu(sumai(5'd16, 5'd16, 11'd8));
    prog[12] = solo_alu(suma(5'd20, 5'd20, 5'd4));
    prog[13] = bundle(suma(5'd21, 5'd21, 5'd5), NOP, NOP, fsl(5'd4, 5'd4, 2'd0, 2'd0));
    prog[16] = solo_cri(fsl(5'd4, 5'd4, 2'd0, 2'd1));
    prog[19] = solo_cri(fsl(5'd4, 5'd4, 2'd0, 2'd2));
    prog[22] = solo_cri(fsl(5'd4, 5'd4, 2'd0, 2'd3));
    prog[25] = solo_lsu(lsu(OP_GUARDAP, 5'd16, 5'd4, -11'sd8));
    prog[26] = bundle(NOP, lsu(OP_GUARDAP, 5'd16, 5'd5, -11'sd4),
                      branch(OP_MENORA, 5'd16, 5'd17, 11'((9 - 26) * 16)), NOP);

    // Palabras y bytes (6 accesos)
    prog[27] = solo_alu(sumai(5'd22, 5'd0, -11'sd5));                       // x22 = -5
    prog[30] = solo_lsu(lsu(OP_GUARDAP,  5'd0, 5'd22, 11'h300));            // M[0x300] = -5
    prog[31] = solo_lsu(lsu(OP_CARGAI,   5'd0, 5'd23, 11'h300));            // x23 = -5
    prog[32] = solo_lsu(lsu(OP_GUARDAB,  5'd0, 5'd22, 11'h305));            // M[0x305] = 0xFB
    prog[33] = solo_lsu(lsu(OP_CARGABAI, 5'd0, 5'd24, 11'h305));            // x24 = -5
    // camcon rota M[0x300] 4 bits; la carga del mismo bundle lee el valor anterior
    prog[34] = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd25, 11'h300), NOP, camcon(16'h300, 5'd4));
    // x26 = valor rotado; sye salta al bundle 37 y deja x1 = 0x240
    prog[35] = bundle(NOP, lsu(OP_CARGAI, 5'd0, 5'd26, 11'h300), sye(5'd1, 16'd32), NOP);
    prog[36] = solo_alu(sumai(5'd29, 5'd0, 11'd1));                         // anulado por el sye

    // Excepción: vcr con la candidata incorrecta y fsl 3 bundles después
    prog[37] = solo_cri(vcr(16'h108));
    prog[40] = bundle(sumai(5'd27, 5'd0, 11'd7), lsu(OP_CARGAI, 5'd0, 5'd28, 11'h200), NOP,
                      fsl(5'd4, 5'd4, 2'd0, 2'd0));
    prog[41] = solo_alu(sumai(5'd29, 5'd0, 11'd2));                         // anulado
    prog[42] = solo_alu(sumai(5'd29, 5'd0, 11'd3));                         // anulado
endtask

`define LOAD(D) \
    for (int i = 0; i < 64; i++) D.IMEM.memory[i] = prog[i]; \
    D.IMEM.memory[TRAP_VECTOR / BUNDLE_BYTES] = HANDLER; \
    D.DMEM.mem[32'h100 >> 2] = PWD; \
    D.DMEM.mem[32'h104 >> 2] = PWD; \
    D.DMEM.mem[32'h108 >> 2] = WRONG; \
    for (int i = 0; i < 4; i++) D.DMEM.mem[(32'h110 >> 2) + i] = key[i]; \
    for (int i = 0; i < 4; i++) D.DMEM.mem[(32'h200 >> 2) + i] = plain[i];


// ============================================================================
// Comparaciones entre una copia con stalls y REF
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
    check({NAME, ": mismo número de escrituras que REF"}, M.n_ev, M_REF.n_ev); \
    check({NAME, ": escrituras distintas o en otro orden"}, diff_ev, 0); \
end

`define STALL_CYCLES_OK(M, N, NAME) \
begin \
    check({NAME, ": accesos de la LSU"}, M.accesses, ACCESOS); \
    check({NAME, ": ciclos de stall = N x accesos"}, M.stall_cycles, (N) * ACCESOS); \
    check({NAME, ": termina N x accesos ciclos después que REF"}, \
          M.trap_cycle - M_REF.trap_cycle, (N) * ACCESOS); \
    check({NAME, ": PC, IF/ID e ID/EX quietos en cada stall"}, M.freeze_errors, 0); \
end


initial begin

    $dumpfile("tb_pipeline_stall.vcd");
    $dumpvars(0, tb_pipeline_stall);

    clk   = 0;
    reset = 1;

    key = {32'hC3D2_E1F0, 32'h8796_A5B4, 32'h4B5A_6978, 32'h0F1E_2D3C};

    plain[0] = 32'h414C_4F48;  plain[1] = 32'h3632_3032;     // "HOLA" "2026"
    plain[2] = 32'h636F_7250;  plain[3] = 32'h6461_7365;     // "Proc" "esad"

    // Esperar a que instruction_memory y memory terminen su inicialización
    #1;

    build_program();
    `LOAD(REF)
    `LOAD(DUT1)
    `LOAD(DUT4)

    repeat (2) @(negedge clk);
    reset = 0;

    // REF termina en unos 70 ciclos y DUT4 unos 76 después
    repeat (400) @(negedge clk);


    // ========================================================================
    tb_section("A. Programa del proyecto 1 en REF");
    // ========================================================================

    begin
        logic [63:0] c0, c1;

        c0 = ref_encrypt(plain[0], plain[1], key);
        c1 = ref_encrypt(plain[2], plain[3], key);

        check("bloque 0: L = 03D44466 (HOLA2026)", REF.DMEM.mem[32'h200 >> 2], 32'h03D4_4466);
        check("bloque 0: R = D685AFAF",            REF.DMEM.mem[32'h204 >> 2], 32'hD685_AFAF);
        check("bloque 1: L como la referencia",    REF.DMEM.mem[32'h208 >> 2], c1[63:32]);
        check("bloque 1: R como la referencia",    REF.DMEM.mem[32'h20C >> 2], c1[31:0]);
        check_true("bloque 0 = referencia", c0 == {32'h03D4_4466, 32'hD685_AFAF});
    end

    check("x20 = suma de las L leídas",            REF.REGFILE.regs[20], plain[0] + plain[2]);
    check("x21 = suma de las R leídas",            REF.REGFILE.regs[21], plain[1] + plain[3]);
    check("x23 = -5 (guardap y cargai seguidos)",  REF.REGFILE.regs[23], 32'hFFFF_FFFB);
    check("x24 = -5 (guardab y cargabai)",         REF.REGFILE.regs[24], 32'hFFFF_FFFB);
    check("M[0x304] = 0000FB00",                   REF.DMEM.mem[32'h304 >> 2], 32'h0000_FB00);
    check("x25 = M[0x300] antes de camcon",        REF.REGFILE.regs[25], 32'hFFFF_FFFB);
    check("M[0x300] = ROL(-5, 4) (camcon)",        REF.DMEM.mem[32'h300 >> 2], 32'hFFFF_FFBF);
    check("x26 = M[0x300] después de camcon",      REF.REGFILE.regs[26], 32'hFFFF_FFBF);
    check("x1 = 0x240 (enlace del sye)",           REF.REGFILE.regs[1], 32'h240);
    check("x29 = 0 (bundles anulados)",            REF.REGFILE.regs[29], 32'd0);
    check("x27 = 0 (ALU del bundle con excepción)", REF.REGFILE.regs[27], 32'd0);
    check("x28 = 0 (carga del bundle con excepción)", REF.REGFILE.regs[28], 32'd0);
    check("x30 = 99 (manejador)",                  REF.REGFILE.regs[30], 32'd99);
    check("AUTH = 0 después del vcr fallido",      REF.crypto_estado[0], 1'b0);
    check("trap_pc = 0x280",                       REF.trap_pc, 32'h280);
    check("REF sin ciclos de stall",               M_REF.stall_cycles, 0);
    check("REF: accesos de la LSU",                M_REF.accesses, ACCESOS);
    check_true("REF llegó al manejador",           M_REF.trap_cycle > 0);


    // ========================================================================
    tb_section("B. Con stalls, el mismo estado final que REF");
    // ========================================================================

    `SAME_STATE(DUT1, "DUT1")
    `SAME_STATE(DUT4, "DUT4")


    // ========================================================================
    tb_section("C. Las mismas escrituras, en el mismo orden");
    // ========================================================================

    check_true("REF tiene escrituras para comparar", M_REF.n_ev > 40);
    `SAME_EVENTS(M_DUT1, "DUT1")
    `SAME_EVENTS(M_DUT4, "DUT4")


    // ========================================================================
    tb_section("D. Ciclos de stall y congelamiento");
    // ========================================================================

    `STALL_CYCLES_OK(M_DUT1, 1, "DUT1")
    `STALL_CYCLES_OK(M_DUT4, 4, "DUT4")

    $display("    REF llega al manejador en el ciclo %0d, DUT1 en el %0d y DUT4 en el %0d (%0d accesos)",
             M_REF.trap_cycle, M_DUT1.trap_cycle, M_DUT4.trap_cycle, M_REF.accesses);


    tb_finish("tb_pipeline_stall");
end

endmodule
