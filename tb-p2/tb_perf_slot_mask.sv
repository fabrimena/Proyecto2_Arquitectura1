/*
 * Pruebas de clasificación de operaciones válidas por slot del bundle VLIW.
 * Contrasta las 34 instrucciones con palabras fijas y recorre todos los tipos
 * e IDs para detectar reservados y operaciones colocadas en unidades incorrectas.
 * Comprueba también el fallback del decoder ALU sin modificar su comportamiento.
 */
`timescale 1ns/1ps
`include "isa_defs.sv"

module tb_perf_slot_mask;

`include "tb_utils.svh"

logic [127:0] bundle_in;
logic [3:0] non_nop_mask;
logic [3:0] alu_op;
logic [4:0] alu_rd;
logic alu_use_imm;

perf_slot_mask DUT (.bundle_in(bundle_in), .non_nop_mask(non_nop_mask));

// Observa el decoder original para distinguir una operación reconocida por la ISA
// de un ID reservado que el hardware puede terminar ejecutando como ALU_ADD.
decoder_alu ALU_DEC (
    .instruction(bundle_in[31:0]), .alu_op(alu_op), .rd(alu_rd),
    .rs1(), .rs2(), .imm(), .use_imm(alu_use_imm)
);

// Palabras fijas de tests/test_assembler.py y tests/test_isa.py.
// No se construyen con las mismas constantes que usa el clasificador.
function automatic logic [31:0] isa_word(input int index);
    case (index)
         0: return 32'hd50510c0; // suma
         1: return 32'hd52510c0; // resta
         2: return 32'hd54510c0; // cader
         3: return 32'hd56510c0; // cizq
         4: return 32'hd58510c0; // and
         5: return 32'hd5a510c0; // or
         6: return 32'hd5c510c0; // xor
         7: return 32'hd5e510c0; // cder
         8: return 32'hd4a510c0; // mrq
         9: return 32'hd4c510c0; // myq
        10: return 32'h80022ff9; // sumai
        11: return 32'h80222ff9; // restai
        12: return 32'h80422807; // cizqi
        13: return 32'h80622807; // cderi
        14: return 32'h80822807; // caderi
        15: return 32'h80a22ff9; // xori
        16: return 32'h80c22ff9; // andi
        17: return 32'h80e22ff9; // ori
        18: return 32'h920327fc; // guardap
        19: return 32'h922327fc; // guardab
        20: return 32'h93032804; // cargai
        21: return 32'h93232804; // cargabai
        22: return 32'h82242ff0; // igualsi
        23: return 32'h82442ff0; // igualno
        24: return 32'h82842ff0; // menora
        25: return 32'h83042ff0; // mayoroigual
        26: return 32'h96010020; // sye
        27: return 32'h96200800; // syer (ret)
        28: return 32'h040e6100; // fsl
        29: return 32'h042e6100; // fsli
        30: return 32'h04544300; // ell
        31: return 32'h04640000; // vcr
        32: return 32'h04800207; // camcon
        33: return 32'h04a00005; // setpwd
        default: return 32'hxxxx_xxxx;
    endcase
endfunction

// Referencia numérica de la green card, independiente de las constantes del DUT.
// El bit n del bitmap indica si el ID n pertenece al tipo y slot consultados.
function automatic logic [15:0] reference_ids(input int slot, input int kind);
    case (slot)
        0: case (kind)
               7'h6a: return 16'hff60; // REG: 5, 6, 8..15
               7'h40: return 16'h00ff; // IMM: 0..7
               default: return 16'h0000;
           endcase
        1: return kind == 7'h49 ? 16'h0303 : 16'h0000; // LSU: 0, 1, 8, 9
        2: case (kind)
               7'h41: return 16'h0116; // COND: 1, 2, 4, 8
               7'h4b: return 16'h0003; // JUMP: 0, 1
               default: return 16'h0000;
           endcase
        3: return kind == 7'h02 ? 16'h003f : 16'h0000; // CRIPTO: 0..5
        default: return 16'h0000;
    endcase
endfunction

// Aplica un bundle y compara sus cuatro bits. No hace falta un flanco de reloj.
task automatic expect_mask(input string name, input logic [127:0] value,
                           input logic [3:0] expected);
    bundle_in = value;
    #1; // Solo propagación combinacional: el DUT no tiene reloj.
    check(name, {28'd0, non_nop_mask}, {28'd0, expected});
endtask

logic [127:0] value;
logic [3:0] expected;
logic [31:0] word;
logic [15:0] ids;
int correct_slot;
int recognized [0:3];

initial begin
    $dumpfile("tb_perf_slot_mask.vcd");
    $dumpvars(0, tb_perf_slot_mask);

    // Cada palabra se prueba en las cuatro posiciones. Solo su slot correcto
    // debe activar un bit, incluso si el tipo de esa operación existe en otro slot.
    tb_section("34 instrucciones: slot correcto y cada slot incorrecto");
    for (int i = 0; i < 34; i++) begin
        correct_slot = i < 18 ? 0 : i < 22 ? 1 : i < 28 ? 2 : 3;
        for (int slot = 0; slot < 4; slot++) begin
            value = '0;
            value[32*slot +: 32] = isa_word(i);
            expected = slot == correct_slot ? (4'b0001 << slot) : 4'b0000;
            expect_mask($sformatf("instrucción %0d en slot %0d", i, slot), value, expected);
        end
    end

    // Las 16 máscaras incluyen el bundle totalmente NOP y todas las mezclas de slots.
    // Volver a NOP después de cada caso comprueba que no se retenga el resultado previo.
    tb_section("Todas las combinaciones de slots activos: NOP, 1, 2, 3 y 4 operaciones");
    for (int mask = 0; mask < 16; mask++) begin
        value = '0;
        if (mask & 1) value[31:0] = isa_word(0);
        if (mask & 2) value[63:32] = isa_word(18);
        if (mask & 4) value[95:64] = isa_word(26);
        if (mask & 8) value[127:96] = isa_word(31);
        expect_mask($sformatf("máscara %04b", 4'(mask)), value, 4'(mask));
        expect_mask("volver a NOP elimina toda clasificación anterior", '0, 4'b0000);
    end

    // Los 2048 prefijos posibles cubren tipos desconocidos, IDs reservados y
    // códigos compartidos por familias distintas. Se comparan los cuatro slots.
    tb_section("Barrido exhaustivo de 128 tipos x 16 IDs, en los cuatro slots");
    for (int slot = 0; slot < 4; slot++) recognized[slot] = 0;
    for (int kind = 0; kind < 128; kind++) begin
        for (int id = 0; id < 16; id++) begin
            for (int slot = 0; slot < 4; slot++) begin
                ids = reference_ids(slot, kind);
                expected[slot] = ids[id];
                if (ids[id]) recognized[slot]++;
            end
            word = {7'(kind), 4'(id), 21'd0};
            expect_mask($sformatf("tipo=%02h ID=%h operandos=0", kind, id),
                        {4{word}}, expected);
            // Cambiar todos los bits de operandos no debe cambiar la clasificación:
            // D1 reconoce tipo e ID, no valida las restricciones de esos operandos.
            word[20:0] = 21'h1fffff;
            expect_mask($sformatf("tipo=%02h ID=%h operandos=1", kind, id),
                        {4{word}}, expected);
        end
    end
    // Confirma que la referencia enumera exactamente las 34 operaciones previstas.
    check("18 operaciones ALU", recognized[0], 18);
    check("4 operaciones LSU", recognized[1], 4);
    check("6 operaciones BRU", recognized[2], 6);
    check("6 operaciones CRIPTO", recognized[3], 6);

    // Escribir x0 no produce un valor arquitectural nuevo, pero sigue siendo una
    // operación de la ISA. Se prueba el campo de destino de los dos formatos ALU.
    tb_section("Destino x0 no convierte operaciones ALU en NOP");
    for (int i = 0; i < 18; i++) begin
        word = isa_word(i);
        if (i < 10) word[20:16] = 5'd0;
        else word[15:11] = 5'd0;
        expect_mask("ALU con rd=x0", {96'd0, word}, 4'b0001);
    end

    // Un REG o IMM reservado puede conservar ADD y rd=x5 en el decoder real.
    // La máscara debe excluirlo según la ISA, sin afirmar que sea un NOP de hardware.
    tb_section("Discrepancia explícita: fallback de ALU para IDs reservados");
    word = {TYPE_REG, 4'h0, 5'd5, 5'd2, 5'd3, 6'd0};
    expect_mask("REG reservado no es una operación de la ISA", {96'd0, word}, 0);
    check("decoder conserva ALU_ADD", alu_op, ALU_ADD);
    check("decoder conserva rd=x5", alu_rd, 5);
    word = {TYPE_IMM, 4'h8, 5'd2, 5'd5, 11'd3};
    expect_mask("IMM reservado no es una operación de la ISA", {96'd0, word}, 0);
    check("decoder conserva ALU_ADD", alu_op, ALU_ADD);
    check("decoder conserva rd=x5", alu_rd, 5);
    check_true("decoder conserva use_imm", alu_use_imm);

    // Distingue combinaciones no cero de operaciones válidas: colocar instrucciones
    // en otro slot o llenar campos bajos de un TYPE_NOP no debe activar la máscara.
    tb_section("Sin falsos positivos por mezcla de slots o códigos desconocidos");
    value = {isa_word(0), isa_word(18), isa_word(28), isa_word(26)};
    expect_mask("cuatro instrucciones en unidades equivocadas", value, 0);
    value = {isa_word(33), {TYPE_BRU_JUMP, 4'hf, 21'h1fffff},
             isa_word(21), {TYPE_IMM, 4'hf, 21'h1fffff}};
    expect_mask("válidas junto a IDs reservados", value, 4'b1010);
    expect_mask("palabras no cero con TYPE_NOP", {4{32'h01ffffff}}, 0);
    expect_mask("tipo desconocido con bits altos activos", '1, 0);
    // Los case exactos no deben tratar X/Z en el prefijo como comodines válidos.
    value = '0;
    value[31:21] = 11'bxxxxxxxxxxx;
    expect_mask("prefijo X no coincide con una operación", value, 0);
    value[31:21] = 11'bzzzzzzzzzzz;
    expect_mask("prefijo Z no coincide con una operación", value, 0);

    tb_finish("tb_perf_slot_mask");
end

endmodule
