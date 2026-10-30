`include "isa_defs.sv"

// D1: reconoce operaciones de la ISA, no su ejecución ni finalización.
// No valida operandos, permisos cripto ni validez del bundle.
module perf_slot_mask (
    input  logic [BUNDLE_W-1:0] bundle_in,
    output logic [NUM_SLOTS-1:0] non_nop_mask
);

// Comparaciones exactas de tipo + ID. Los IDs reservados, TYPE_NOP y
// tipos de otra unidad no cuentan, aunque algún decoder tenga un fallback.
always @(*) begin
    non_nop_mask = 4'b0000;

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

    case (bundle_in[63:53]) // Slot 1: loads y stores, sin depender de wb_we.
        {TYPE_LSU, OP_GUARDAP}, {TYPE_LSU, OP_GUARDAB},
        {TYPE_LSU, OP_CARGAI},  {TYPE_LSU, OP_CARGABAI}: non_nop_mask[1] = 1'b1;
        default: non_nop_mask[1] = 1'b0;
    endcase

    case (bundle_in[95:85]) // Slot 2: condicionales, sye y syer.
        {TYPE_BRU_COND, OP_IGUALSI}, {TYPE_BRU_COND, OP_IGUALNO},
        {TYPE_BRU_COND, OP_MENORA},  {TYPE_BRU_COND, OP_MAYOROIGUAL},
        {TYPE_BRU_JUMP, OP_SYE},     {TYPE_BRU_JUMP, OP_SYER}: non_nop_mask[2] = 1'b1;
        default: non_nop_mask[2] = 1'b0;
    endcase

    case (bundle_in[127:117]) // Slot 3: reconocer no implica autorización.
        {TYPE_CRYPTO, OP_FSL},    {TYPE_CRYPTO, OP_FSLI},
        {TYPE_CRYPTO, OP_ELL},    {TYPE_CRYPTO, OP_VCR},
        {TYPE_CRYPTO, OP_CAMCON}, {TYPE_CRYPTO, OP_SETPWD}: non_nop_mask[3] = 1'b1;
        default: non_nop_mask[3] = 1'b0;
    endcase
end

endmodule
