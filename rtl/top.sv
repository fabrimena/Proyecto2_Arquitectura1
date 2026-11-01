/*
================================================================================
 Módulo: top

 Descripción:
 ------------------------------------------------------------------------------
 Módulo superior del procesador VLIW.

 Pipeline IF / ID / EX / WB (4 etapas, 3 registros de segmentación):
     IF:  PC → instruction_memory → fetch (combinacional)
          ── IF/ID ──
     ID:  dispatch + decoders de los slots + lectura del banco de registros
          ── ID/EX ──   (señales decodificadas y operandos leídos)
     EX:  ALU, LSU + memoria de datos, BRU, CRIPTO (no hay etapa MEM: el
          acceso a memoria se hace dentro de EX)
          ── EX/WB ──   (pipeline_ex_wb para la ALU; LSU, BRU y CRIPTO
                         registran su resultado internamente)
     WB:  wb → banco de registros

 Las unidades de EX toman todos sus operandos de ID/EX. Las lecturas del banco
 (reg_rdata) corresponden al bundle que está en ID, no al que está en EX.

 Slots del bundle (fijos):
     slot 0 = ALU       (suma, resta, AND, OR, XOR, shifts, comparaciones,
                          instrucciones tipo registro y tipo inmediato)
     slot 1 = LSU       (guardap, guardab, cargai, cargabai)
     slot 2 = BRU       (igualsi, igualno, menora, mayoroigual, sye, syer)
     slot 3 = CRIPTO    (fsl, fsli, ell, vcr, camcon, setpwd)

 Banco de registros (rtl/regfile.sv): 8 lecturas (2 por slot) y 5 escrituras.
 Memoria de instrucciones (rtl/instruction_memory.sv): IMEM_BUNDLES bundles
     (16 KB); el programa se carga con +IMEM=<archivo.mem>.
 Memoria de datos (rtl/memory.sv): DMEM_BYTES = 64 KB byte-addressable little-endian,
     de doble puerto: el puerto A es de la LSU y el puerto B de la unidad
     criptográfica (vcr y camcon).

 Saltos:
     El BRU (en EX) produce branch_flush + target_pc. Esas señales se
     conectan a:
         - pipeline_if_id.flush_in   (descarta el bundle que está en IF)
         - pipeline_id_ex.flush      (descarta el bundle que está en ID)
         - pc_branch.branch_flush    (carga el PC con target_pc)
     Penalización: 2 ciclos (los dos bundles detrás del salto se descartan,
     sin delay slots). Si el salto no se toma, 0 ciclos.
     Sin forwarding ni scoreboarding entre bundles (regla del proyecto).

 Unidad criptográfica (rtl/crypto_unit.sv):
     Contiene la bóveda de llaves (rtl/key_vault.sv) y el registro ESTADO
     (AUTH, INIT). La bóveda sólo es accesible desde crypto_unit: no tiene
     ningún camino hacia el banco de registros ni hacia la memoria.

 Excepción de privilegio:
     decoder_crypto valida en ID cada instrucción cripto con el ESTADO actual
     (fsl, fsli, ell y camcon necesitan AUTH = 1; setpwd necesita INIT = 1).
     ESTADO se escribe en WB, como en el diagrama de organización del grupo.
     Si la instrucción no tiene permiso, la marca viaja por ID/EX y en EX
     crypto_unit activa crypto_fault. Entonces:
         - Se anula el bundle completo que está en EX: no escriben la ALU,
           la LSU, el BRU ni la cripto, y el salto del BRU no se toma.
         - Se descartan los 2 bundles que están en IF e ID, igual que en un
           salto tomado.
         - El PC salta a TRAP_VECTOR (isa_defs.sv), donde el programa debe
           tener su manejador: el último bundle de la memoria de
           instrucciones (0x3FF0 con IMEM_BUNDLES = 1024).
         - trap_pc guarda el PC del bundle que causó la excepción y
           trap_count cuenta las excepciones (sólo para observación; el ISA
           no define cómo leerlos).

 Proyecto 2, memoria de datos y congelamiento (docs/memory-interfaces.md):
     Entre el núcleo y DMEM se engancha la jerarquía de memoria según
     MEM_MODE. Con el valor por defecto (0) la conexión es directa y el
     procesador es el mismo del proyecto 1.
     Si la memoria no resuelve un acceso en el ciclo, cache_stall = 1 y se
     detiene core_clk, el reloj de todos los registros del núcleo (PC, IF/ID,
     ID/EX, EX/WB, banco, LSU, BRU, CRIPTO y bóveda): el bundle completo
     queda congelado y al terminar sigue igual, con más ciclos. DMEM y lo que
     se agregue para la jerarquía siguen con clk.

================================================================================
*/

`include "isa_defs.sv"


module top #(

    // Memoria de datos:
    //   0  conexión directa con DMEM, como en el proyecto 1 (por defecto)
    //   1  modelo de stalls (rtl/mem_stall_model.sv): cada acceso de la LSU
    //      tarda STALL_CYCLES ciclos más, para probar el congelamiento
    parameter int MEM_MODE     = 0,
    parameter int STALL_CYCLES = 3
) (

    input  logic         clk,
    input  logic         reset,

    output logic [31:0]  debug_result,
    output logic [4:0]   debug_rd,
    output logic         debug_write

);


// =============================================================================
// Wires globales
// =============================================================================

// PC e instruction memory
logic [31:0]  pc;
logic [BUNDLE_W-1:0] instruction_bundle;

// FETCH → IF/ID
logic [31:0]  fetch_pc;
logic [BUNDLE_W-1:0] fetch_bundle;
logic         fetch_valid;
logic         branch_flush;     // salto tomado en EX (BRU)
logic         redirect;         // salto tomado o excepción: anula IF e ID y carga el PC
logic [31:0]  redirect_pc;      // destino del salto o TRAP_VECTOR

// IF/ID → ID (dispatch)
logic [31:0]  id_pc;
logic [BUNDLE_W-1:0] id_bundle;
logic         id_valid;

// ID (dispatch) → 4 slots
logic [31:0]  slot0_instr, slot1_instr, slot2_instr, slot3_instr;
logic         dispatch_valid;

// Banco de registros (compartido entre los 4 slots)
logic [7:0][4:0]  reg_raddr;
logic [7:0][31:0] reg_rdata;

// Decoders slot 0 (ALU)
logic [3:0]  alu_op;
logic [4:0]  alu_rd;
logic [10:0] alu_imm;
logic        alu_use_imm;
logic [4:0]  alu_rs1, alu_rs2;
logic [31:0] alu_rs1_data, alu_rs2_data;

// Decoders slot 1 (LSU)
logic        lsu_valid;
logic [3:0]  lsu_op;
logic [4:0]  lsu_rd;
logic [10:0] lsu_imm;
logic [4:0]  lsu_rs1, lsu_rs2;
logic [31:0] lsu_rs1_data, lsu_rs2_data;

// Decoders slot 2 (BRU)
logic [3:0]  bru_op;
logic [4:0]  bru_rd;
logic [10:0] bru_br_imm;
logic [15:0] bru_jmp_imm;
logic        bru_is_branch;
logic        bru_is_jump;
logic [4:0]  bru_rs1, bru_rs2;
logic [31:0] bru_rs1_data, bru_rs2_data;

// Decoders slot 3 (CRIPTO)
logic        crypto_valid;
logic [3:0]  crypto_op;
logic [1:0]  crypto_lk;
logic [1:0]  crypto_rk;
logic [4:0]  crypto_rd;
logic [15:0] crypto_addr;
logic [4:0]  crypto_imm;
logic        crypto_fault_id;   // validación de privilegios en ID
logic [4:0]  crypto_rs_a, crypto_rs_b;
logic [31:0] crypto_rs_a_data, crypto_rs_b_data;

// ID/EX
logic        id_ex_valid;
logic [3:0]  ex_alu_op;
logic [4:0]  ex_alu_rd;
logic [31:0] ex_alu_operand_a;
logic [31:0] ex_alu_operand_b;
logic [10:0] ex_alu_imm;
logic        ex_alu_use_imm;
logic        ex_lsu_valid;
logic [3:0]  ex_lsu_op;
logic [4:0]  ex_lsu_rd;
logic [10:0] ex_lsu_imm;
logic [31:0] ex_lsu_operand_a;
logic [31:0] ex_lsu_operand_b;
logic [3:0]  ex_bru_op;
logic [4:0]  ex_bru_rd;
logic [10:0] ex_bru_br_imm;
logic [15:0] ex_bru_jmp_imm;
logic        ex_bru_is_branch;
logic        ex_bru_is_jump;
logic [31:0] ex_bru_operand_a;
logic [31:0] ex_bru_operand_b;
logic        ex_crypto_valid;
logic        ex_crypto_fault;
logic [3:0]  ex_crypto_op;
logic [1:0]  ex_crypto_lk;
logic [1:0]  ex_crypto_rk;
logic [4:0]  ex_crypto_rd;
logic [15:0] ex_crypto_addr;
logic [4:0]  ex_crypto_imm;
logic [31:0] ex_crypto_operand_a;
logic [31:0] ex_crypto_operand_b;

// EX - ALU
logic [31:0] ex_operand_a;
logic [31:0] ex_operand_b;
logic [31:0] alu_result;

// EX - LSU
logic        mem_we;
logic [3:0]  mem_be;
logic [31:0] mem_addr;
logic [31:0] mem_wdata;
logic [31:0] mem_rdata;
logic        lsu_we_d;
logic [4:0]  lsu_rd_d;
logic [31:0] lsu_data_d;

// EX - BRU
logic [31:0] ex_pc_from_id_ex;
logic [31:0] ex_pc;
logic        bru_branch_flush;
logic [31:0] bru_target_pc;
logic        bru_link_we_d;
logic [4:0]  bru_link_rd_d;
logic [31:0] bru_link_value_d;

// EX - CRIPTO
logic        crypto_fault;      // excepción de privilegio en EX
logic [31:0] crypto_estado;     // ESTADO (sólo observación)
logic        crypto_mem_we;
logic [31:0] crypto_mem_addr;
logic [31:0] crypto_mem_wdata;
logic [31:0] crypto_mem_rdata;
logic        crypto_we_d;
logic [4:0]  crypto_rd_d;
logic [31:0] crypto_data_l_d;
logic [31:0] crypto_data_r_d;

// EX/WB → WB
logic [4:0]       wb_we;
logic [4:0][4:0]  wb_waddr;
logic [4:0][31:0] wb_wdata;
logic             wb_conflict;

// Memoria de datos y congelamiento (proyecto 2)
logic        cache_stall;       // el acceso a memoria de EX no termina en este ciclo
logic        core_en = 1'b1;    // cache_stall negado, tomado con clk en 0
logic        core_clk;          // reloj del núcleo: clk sin los ciclos de stall


// =============================================================================
// Reloj del núcleo
//
// core_en se toma mientras clk está en 0 (latch), así que un cambio de
// cache_stall con clk en 1 no produce flancos falsos en core_clk. Con
// cache_stall = 0 (MEM_MODE = 0), core_clk es igual a clk.
// =============================================================================

always @(*) begin

    if (!clk)
        core_en = !cache_stall;
end

assign core_clk = clk & core_en;


// =============================================================================
// PC + Memoria de instrucciones
// =============================================================================

instruction_memory IMEM(
    .address(pc),
    .instruction_bundle(instruction_bundle)
);

pc_branch PC_BRANCH (
    .clk(core_clk),
    .reset(reset),
    .branch_flush(redirect),
    .target_pc(redirect_pc),
    .pc_out(pc)
);


// =============================================================================
// FETCH
// =============================================================================

fetch FETCH (
    .reset(reset),
    .pc(pc),
    .instruction_bundle(instruction_bundle),
    .pc_out(fetch_pc),
    .bundle_out(fetch_bundle),
    .valid_out(fetch_valid)
);


// =============================================================================
// IF / ID
// =============================================================================

pipeline_if_id IF_ID (
    .clk(core_clk),
    .reset(reset),
    .pc_in(fetch_pc),
    .bundle_in(fetch_bundle),
    .valid_in(fetch_valid),
    .flush_in(redirect),
    .pc_out(id_pc),
    .bundle_out(id_bundle),
    .valid_out(id_valid)
);


// =============================================================================
// DISPATCH VLIW (4 slots fijos)
// =============================================================================

dispatch DISPATCH (
    .bundle_in(id_bundle),
    .valid_in(id_valid),
    .slot0_instr(slot0_instr),
    .slot1_instr(slot1_instr),
    .slot2_instr(slot2_instr),
    .slot3_instr(slot3_instr),
    .valid_out(dispatch_valid)
);


// =============================================================================
// ID: decoder_alu (slot 0)
// =============================================================================

decoder_alu DECODER_ALU (
    .instruction(slot0_instr),
    .alu_op(alu_op),
    .rd(alu_rd),
    .rs1(alu_rs1),
    .rs2(alu_rs2),
    .imm(alu_imm),
    .use_imm(alu_use_imm)
);

// Los operandos de la ALU en EX salen de ID/EX (ver la sección EX - ALU).


// =============================================================================
// ID: decoder_lsu (slot 1)
// =============================================================================

decoder_lsu DECODER_LSU (
    .instruction(slot1_instr),
    .lsu_op(lsu_op),
    .rd(lsu_rd),
    .rs1(lsu_rs1),
    .rs2(lsu_rs2),
    .imm(lsu_imm),
    .we(),                      // no se usa: la LSU distingue cargas por lsu_op
    .valid(lsu_valid)
);


// =============================================================================
// ID: decoder_bru (slot 2)
// =============================================================================

decoder_bru DECODER_BRU (
    .instruction(slot2_instr),
    .bru_op(bru_op),
    .rd(bru_rd),
    .rs1(bru_rs1),
    .rs2(bru_rs2),
    .br_imm(bru_br_imm),
    .jmp_imm(bru_jmp_imm),
    .is_branch(bru_is_branch),
    .is_jump(bru_is_jump),
    .we()                       // no se usa: el BRU escribe el enlace sólo en sye y syer
);


// =============================================================================
// ID: decoder_crypto (slot 3)
// =============================================================================

decoder_crypto DECODER_CRYPTO (
    .instruction(slot3_instr),
    .crypto_op(crypto_op),
    .lk(crypto_lk),
    .rk(crypto_rk),
    .rd(crypto_rd),
    .rs_a(crypto_rs_a),
    .rs_b(crypto_rs_b),
    .addr(crypto_addr),
    .imm(crypto_imm),
    .we(),                      // no se usa: la cripto escribe el par sólo en fsl/fsli
    .valid(crypto_valid),

    // Validación de privilegios con el ESTADO actual
    .auth(crypto_estado[0]),
    .init(crypto_estado[1]),
    .priv_fault(crypto_fault_id)
);


// =============================================================================
// Banco de registros (8 lecturas × 5 escrituras, compartido entre slots)
//
//   Lectura   0, 1   slot 0 ALU     rf1, rf2
//             2, 3   slot 1 LSU     rf1 (base), rf2 (dato de store)
//             4, 5   slot 2 BRU     rf1, rf2 de las comparaciones
//             6, 7   slot 3 CRIPTO  par (r1, r1+1) de fsl/fsli, (rs1, rs2) de ell, rs de setpwd
//
//   Escritura 0..4  slot 0..4 lógica     (ver wb.sv)
// =============================================================================

assign reg_raddr = {
    crypto_rs_b, crypto_rs_a,  // slot 3 CRIPTO
    bru_rs2, bru_rs1,      // slot 2 BRU
    lsu_rs2, lsu_rs1,      // slot 1 LSU
    alu_rs2, alu_rs1       // slot 0 ALU
};

assign alu_rs1_data = reg_rdata[0];
assign alu_rs2_data = reg_rdata[1];
assign lsu_rs1_data = reg_rdata[2];
assign lsu_rs2_data = reg_rdata[3];
assign bru_rs1_data = reg_rdata[4];
assign bru_rs2_data = reg_rdata[5];
assign crypto_rs_a_data = reg_rdata[6];
assign crypto_rs_b_data = reg_rdata[7];

regfile REGFILE (
    .clk(core_clk),
    .reset(reset),
    .raddr(reg_raddr),
    .rdata(reg_rdata),
    .we(wb_we),
    .waddr(wb_waddr),
    .wdata(wb_wdata)
);


// =============================================================================
// ID / EX (registros de segmentación)
// =============================================================================

pipeline_id_ex ID_EX (
    .clk(core_clk),
    .reset(reset),
    .flush(redirect),              // salto tomado o excepción en EX: anula el bundle de ID

    // ALU
    .alu_op(alu_op),
    .alu_rd(alu_rd),
    .alu_operand_a(alu_rs1_data),
    .alu_operand_b(alu_rs2_data),
    .alu_imm(alu_imm),
    .alu_use_imm(alu_use_imm),

    // LSU
    .lsu_valid(lsu_valid),
    .lsu_op(lsu_op),
    .lsu_rd(lsu_rd),
    .lsu_imm(lsu_imm),
    .lsu_operand_a(lsu_rs1_data),
    .lsu_operand_b(lsu_rs2_data),

    // BRU
    .bru_op(bru_op),
    .bru_rd(bru_rd),
    .bru_br_imm(bru_br_imm),
    .bru_jmp_imm(bru_jmp_imm),
    .bru_is_branch(bru_is_branch),
    .bru_is_jump(bru_is_jump),
    .bru_operand_a(bru_rs1_data),
    .bru_operand_b(bru_rs2_data),

    // CRIPTO
    .crypto_valid(crypto_valid),
    .crypto_fault(crypto_fault_id),
    .crypto_op(crypto_op),
    .crypto_lk(crypto_lk),
    .crypto_rk(crypto_rk),
    .crypto_rd(crypto_rd),
    .crypto_addr(crypto_addr),
    .crypto_imm(crypto_imm),
    .crypto_operand_a(crypto_rs_a_data),
    .crypto_operand_b(crypto_rs_b_data),

    .pc_in(id_pc),

    .valid_in(dispatch_valid),

    // Salidas
    .alu_op_out(ex_alu_op),
    .alu_rd_out(ex_alu_rd),
    .alu_operand_a_out(ex_alu_operand_a),
    .alu_operand_b_out(ex_alu_operand_b),
    .alu_imm_out(ex_alu_imm),
    .alu_use_imm_out(ex_alu_use_imm),

    .lsu_valid_out(ex_lsu_valid),
    .lsu_op_out(ex_lsu_op),
    .lsu_rd_out(ex_lsu_rd),
    .lsu_imm_out(ex_lsu_imm),
    .lsu_operand_a_out(ex_lsu_operand_a),
    .lsu_operand_b_out(ex_lsu_operand_b),

    .bru_op_out(ex_bru_op),
    .bru_rd_out(ex_bru_rd),
    .bru_br_imm_out(ex_bru_br_imm),
    .bru_jmp_imm_out(ex_bru_jmp_imm),
    .bru_is_branch_out(ex_bru_is_branch),
    .bru_is_jump_out(ex_bru_is_jump),
    .bru_operand_a_out(ex_bru_operand_a),
    .bru_operand_b_out(ex_bru_operand_b),

    .crypto_valid_out(ex_crypto_valid),
    .crypto_fault_out(ex_crypto_fault),
    .crypto_op_out(ex_crypto_op),
    .crypto_lk_out(ex_crypto_lk),
    .crypto_rk_out(ex_crypto_rk),
    .crypto_rd_out(ex_crypto_rd),
    .crypto_addr_out(ex_crypto_addr),
    .crypto_imm_out(ex_crypto_imm),
    .crypto_operand_a_out(ex_crypto_operand_a),
    .crypto_operand_b_out(ex_crypto_operand_b),

    .pc_out(ex_pc_from_id_ex),

    .valid_out(id_ex_valid)
);


// =============================================================================
// EX - ALU (slot 0)
// =============================================================================

// El inmediato de 11 bits se extiende con signo (convención del ISA)
assign ex_operand_a = ex_alu_operand_a;
assign ex_operand_b = ex_alu_use_imm ? {{21{ex_alu_imm[10]}}, ex_alu_imm} : ex_alu_operand_b;

alu ALU (
    .alu_op(ex_alu_op),
    .operand_a(ex_operand_a),
    .operand_b(ex_operand_b),
    .result(alu_result)
);


// =============================================================================
// EX - LSU (slot 1) + memoria
// =============================================================================

lsu LSU (
    .clk(core_clk),
    .reset(reset),
    .valid_in(id_ex_valid && ex_lsu_valid && !crypto_fault),   // sólo si el slot 1 trae una instrucción LSU
    .lsu_op(ex_lsu_op),
    .rd(ex_lsu_rd),
    .imm(ex_lsu_imm),
    .rf1_data(ex_lsu_operand_a),    // base address
    .rf2_data(ex_lsu_operand_b),    // dato store
    .mem_we(mem_we),
    .mem_be(mem_be),
    .mem_addr(mem_addr),
    .mem_wdata(mem_wdata),
    .mem_rdata(mem_rdata),
    .wb_we(lsu_we_d),
    .wb_rd(lsu_rd_d),
    .wb_data(lsu_data_d)
);

// La LSU no tiene salida de lectura porque la memoria del proyecto 1 lee en
// todos los ciclos. La jerarquía de memoria sí necesita saber cuándo el slot 1
// trae una carga válida (mismas condiciones que valid_in de la LSU).
logic mem_re;

assign mem_re = id_ex_valid && ex_lsu_valid && !crypto_fault &&
                (ex_lsu_op == OP_CARGAI || ex_lsu_op == OP_CARGABAI);


// -----------------------------------------------------------------------------
// Enganche de la memoria de datos (MEM_MODE). DMEM se queda aquí como el
// almacenamiento de 64 KB, así los testbenches y las herramientas siguen
// leyendo DUT.DMEM.mem.
// -----------------------------------------------------------------------------

logic        dmem_we;
logic [3:0]  dmem_be;
logic [31:0] dmem_addr;
logic [31:0] dmem_wdata;
logic [31:0] dmem_rdata;
logic        dmem_we_b;
logic [31:0] dmem_addr_b;
logic [31:0] dmem_wdata_b;
logic [31:0] dmem_rdata_b;

generate

    if (MEM_MODE == 1) begin : g_mem_stall

        mem_stall_model #(.STALL_CYCLES(STALL_CYCLES)) STALL_MODEL (
            .clk(clk),
            .reset(reset),

            .re(mem_re),
            .we(mem_we),
            .be(mem_be),
            .addr(mem_addr),
            .wdata(mem_wdata),
            .rdata(mem_rdata),

            .we_b(crypto_mem_we),
            .addr_b(crypto_mem_addr),
            .wdata_b(crypto_mem_wdata),
            .rdata_b(crypto_mem_rdata),

            .stall(cache_stall),

            .m_we(dmem_we),
            .m_be(dmem_be),
            .m_addr(dmem_addr),
            .m_wdata(dmem_wdata),
            .m_rdata(dmem_rdata),
            .m_we_b(dmem_we_b),
            .m_addr_b(dmem_addr_b),
            .m_wdata_b(dmem_wdata_b),
            .m_rdata_b(dmem_rdata_b)
        );
    end
    else begin : g_mem_directa

        // Proyecto 1: la LSU y la cripto van directo a DMEM, sin stalls
        assign cache_stall = 1'b0;

        assign dmem_we      = mem_we;
        assign dmem_be      = mem_be;
        assign dmem_addr    = mem_addr;
        assign dmem_wdata   = mem_wdata;
        assign mem_rdata    = dmem_rdata;

        assign dmem_we_b    = crypto_mem_we;
        assign dmem_addr_b  = crypto_mem_addr;
        assign dmem_wdata_b = crypto_mem_wdata;
        assign crypto_mem_rdata = dmem_rdata_b;
    end
endgenerate

memory #(.SIZE_WORDS(DMEM_BYTES / 4)) DMEM (
    .clk(clk),
    .we(dmem_we),
    .be(dmem_be),
    .addr(dmem_addr),
    .wdata(dmem_wdata),
    .rdata(dmem_rdata),

    // Puerto B: unidad criptográfica (vcr, camcon)
    .we_b(dmem_we_b),
    .addr_b(dmem_addr_b),
    .wdata_b(dmem_wdata_b),
    .rdata_b(dmem_rdata_b)
);


// =============================================================================
// EX - BRU (slot 2)
// =============================================================================

// El PC del bundle en EX lo entrega pipeline_id_ex (lo captura del id_pc
// en ID y lo expone como ex_pc). El bru lo usa como base para calcular el
// target de los saltos condicionales y de sye (syer salta a rf1 + offset).
assign ex_pc = ex_pc_from_id_ex;

bru BRU (
    .clk(core_clk),
    .reset(reset),
    .rf1_data(ex_bru_operand_a),
    .rf2_data(ex_bru_operand_b),
    .pc_current(ex_pc),
    .bru_op(ex_bru_op),
    .is_branch(ex_bru_is_branch && !crypto_fault),   // una excepción anula el salto
    .is_jump(ex_bru_is_jump && !crypto_fault),
    .br_imm(ex_bru_br_imm),
    .jmp_imm(ex_bru_jmp_imm),
    .link_rd_in(ex_bru_rd),
    .branch_flush(bru_branch_flush),
    .target_pc(bru_target_pc),
    .link_we_d(bru_link_we_d),
    .link_rd_d(bru_link_rd_d),
    .link_value_d(bru_link_value_d)
);

assign branch_flush = bru_branch_flush;


// =============================================================================
// EX - CRIPTO (slot 3)
// =============================================================================

crypto_unit CRYPTO (
    .clk(core_clk),
    .reset(reset),
    .valid_in(id_ex_valid && ex_crypto_valid),
    .fault_in(ex_crypto_fault),
    .crypto_op(ex_crypto_op),
    .lk(ex_crypto_lk),
    .rk(ex_crypto_rk),
    .rd(ex_crypto_rd),
    .operand_a(ex_crypto_operand_a),
    .operand_b(ex_crypto_operand_b),
    .addr(ex_crypto_addr),
    .imm(ex_crypto_imm),
    .mem_we(crypto_mem_we),
    .mem_addr(crypto_mem_addr),
    .mem_wdata(crypto_mem_wdata),
    .mem_rdata(crypto_mem_rdata),
    .wb_we(crypto_we_d),
    .wb_rd(crypto_rd_d),
    .wb_data_l(crypto_data_l_d),
    .wb_data_r(crypto_data_r_d),
    .priv_fault(crypto_fault),
    .estado(crypto_estado)
);


// =============================================================================
// Cambio de flujo: salto tomado o excepción de privilegio
//
// Los dos anulan los bundles que están en IF e ID y cargan el PC. Si en el
// mismo bundle hay un salto y una excepción, gana la excepción (el BRU ya
// recibe is_branch/is_jump anulados).
// =============================================================================

assign redirect    = branch_flush || crypto_fault;
assign redirect_pc = crypto_fault ? TRAP_VECTOR : bru_target_pc;

// Registro de la última excepción (sólo para observación en simulación)
logic [31:0] trap_pc;
logic [31:0] trap_count;

always @(posedge core_clk) begin

    if (reset) begin

        trap_pc    <= 32'b0;
        trap_count <= 32'b0;
    end
    else if (crypto_fault) begin

        trap_pc    <= ex_pc;
        trap_count <= trap_count + 1;
    end
end


// =============================================================================
// EX / WB (sólo la ALU pasa por pipeline_ex_wb; LSU, BRU y CRIPTO escriben
// directo desde sus registros internos para igualar la latencia).
// =============================================================================

// ALU pasa por pipeline_ex_wb (igual que en el código del equipo)
logic        ex_wb_valid;
logic [4:0]  ex_wb_rd;
logic [31:0] ex_wb_alu_result;

pipeline_ex_wb EX_WB (
    .clk(core_clk),
    .reset(reset),
    .result_in(alu_result),
    .rd_in(ex_alu_rd),
    .valid_in(id_ex_valid && !crypto_fault),     // una excepción anula el bundle
    .result_out(ex_wb_alu_result),
    .rd_out(ex_wb_rd),
    .valid_out(ex_wb_valid)
);


// =============================================================================
// WB: ordena los 5 puertos de escritura y maneja conflictos
// =============================================================================

wb WB (
    .alu_we(ex_wb_valid),
    .alu_rd(ex_wb_rd),
    .alu_data(ex_wb_alu_result),

    .lsu_we(lsu_we_d),
    .lsu_rd(lsu_rd_d),
    .lsu_data(lsu_data_d),

    .bru_we(bru_link_we_d),
    .bru_rd(bru_link_rd_d),
    .bru_data(bru_link_value_d),

    .crypto_we(crypto_we_d),
    .crypto_rd(crypto_rd_d),
    .crypto_data_l(crypto_data_l_d),
    .crypto_data_r(crypto_data_r_d),

    .we(wb_we),
    .waddr(wb_waddr),
    .wdata(wb_wdata),
    .conflict(wb_conflict)
);


// =============================================================================
// Debug
// =============================================================================

assign debug_result = wb_wdata[0];
assign debug_rd     = wb_waddr[0];
assign debug_write  = wb_we[0];


endmodule