/*
 * Clasificador combinacional de las 34 operaciones de la ISA del VLIW.
 * Recibe un bundle y activa un bit por cada operación reconocida en su slot.
 * No valida operandos, permisos cripto ni validez del bundle; reconocer una
 * operación no significa que haya sido ejecutada o completada.
 */
`include "isa_defs.sv"

module perf_slot_mask (
    input  logic [BUNDLE_W-1:0] bundle_in,
    output logic [NUM_SLOTS-1:0] non_nop_mask // Bits 0..3: ALU, LSU, BRU y CRIPTO.
);

// Cada prefijo reúne tipo [31:25] e ID [24:21] de la instrucción de su slot.
// Se comparan ambos campos completos; una palabra no cero también puede ser NOP
// o pertenecer a una unidad distinta. Los operandos no intervienen en la máscara.
always @(*) begin
    // Toda salida tiene valor por defecto: no queda retenida la máscara anterior.
    non_nop_mask = 4'b0000;

    // Solo se incluyen las 18 operaciones ALU de la ISA, incluso con destino x0.
    // Los IDs reservados se excluyen aunque decoder_alu los traduzca a ALU_ADD;
    // esa exclusión no elimina los efectos que puedan tener en el hardware actual.
    case (bundle_in[31:21]) // Slot 0: 10 operaciones REG y 8 IMM.
        {TYPE_REG, OP_SUM},   {TYPE_REG, OP_RESTA},
        {TYPE_REG, OP_CADER}, {TYPE_REG, OP_CIZQ},
        {TYPE_REG, OP_AND},   {TYPE_REG, OP_OR},
        {TYPE_REG, OP_XOR},   {TYPE_REG, OP_CDER},
        {TYPE_REG, OP_MRQ},   {TYPE_REG, OP_MYQ},
        {TYPE_IMM, OP_SUMI},  {TYPE_IMM, OP_RESTAI},
        {TYPE_IMM, OP_CIZQI}, {TYPE_IMM, OP_CDERI},
        {TYPE_IMM, OP_CADERI}, {TYPE_IMM, OP_XORI},
        {TYPE_IMM, OP_ANDI},  {TYPE_IMM, OP_ORI}: non_nop_mask[0] = 1'b1;
        default: non_nop_mask[0] = 1'b0;
    endcase

    // Tanto cargas como stores son instrucciones; no se usa una escritura de WB
    // para decidir si el slot contiene una operación.
    case (bundle_in[63:53]) // Slot 1: cuatro operaciones LSU.
        {TYPE_LSU, OP_GUARDAP}, {TYPE_LSU, OP_GUARDAB},
        {TYPE_LSU, OP_CARGAI},  {TYPE_LSU, OP_CARGABAI}: non_nop_mask[1] = 1'b1;
        default: non_nop_mask[1] = 1'b0;
    endcase

    // Un salto condicional cuenta por su operación, independientemente de que
    // se tome. Los IDs COND y JUMP no definidos quedan fuera de la máscara.
    case (bundle_in[95:85]) // Slot 2: condicionales, sye y syer.
        {TYPE_BRU_COND, OP_IGUALSI}, {TYPE_BRU_COND, OP_IGUALNO},
        {TYPE_BRU_COND, OP_MENORA},  {TYPE_BRU_COND, OP_MAYOROIGUAL},
        {TYPE_BRU_JUMP, OP_SYE},     {TYPE_BRU_JUMP, OP_SYER}: non_nop_mask[2] = 1'b1;
        default: non_nop_mask[2] = 1'b0;
    endcase

    // Cada operación cripto ocupa un bit aunque escriba un par de registros o
    // solo la bóveda/ESTADO. La anulación por excepción se resuelve posteriormente.
    case (bundle_in[127:117]) // Slot 3: reconocer no implica autorización.
        {TYPE_CRYPTO, OP_FSL},    {TYPE_CRYPTO, OP_FSLI},
        {TYPE_CRYPTO, OP_ELL},    {TYPE_CRYPTO, OP_VCR},
        {TYPE_CRYPTO, OP_CAMCON}, {TYPE_CRYPTO, OP_SETPWD}: non_nop_mask[3] = 1'b1;
        default: non_nop_mask[3] = 1'b0;
    endcase
end

endmodule
