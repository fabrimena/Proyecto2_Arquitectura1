/* Verifica la decodificación combinacional con palabras de referencia propias.
 * Recorre tipos, IDs, operandos y bits reservados, incluyendo X/Z. No utiliza
 * las constantes ni las funciones del ensamblador para calcular los oráculos. */
`timescale 1ns/1ps
module tb_decoder_cache_isa;
    `include "tb_utils.svh"

    logic [31:0] instruction = 0; // Estímulo de un único slot, sin reloj ni reset.
    wire valid, measure_imm;      // Validez y control que deben quedar en cero al rechazar.
    wire [3:0] operation;         // ID reconocido, normalizado a cero si es inválido.
    wire [4:0] rd;                // Destino de lcont, independiente de si es x0.
    wire [5:0] selector;          // Incluye selectores legales que ejecutan una lectura cero.
    decoder_cache_isa DUT (.*);

    // Da tiempo al combinacional y compara todas las salidas con el contrato.
    // Una palabra inválida exige salidas cero, no solo valid=0.
    task automatic expect_word(input logic [31:0] word_value, input bit expected_valid,
                               input logic [3:0] expected_op, input logic [4:0] expected_rd,
                               input logic [5:0] expected_sel, input bit expected_imm);
        instruction = word_value;
        #1;
        check_true($sformatf("palabra %08h", word_value),
                   {valid, operation, rd, selector, measure_imm} ===
                   {expected_valid, expected_op, expected_rd, expected_sel, expected_imm});
    endtask

    // Iteradores y palabra adversarial: cada bit se cambia individualmente
    // para que otro campo válido no oculte un rechazo incorrecto.
    integer instruction_type, id, dest, sel, bit_index, op;
    logic [31:0] base_word, corrupt_word;
    initial begin
        tb_section("palabras exactas y ausencia de estado entre decodificaciones");
        expect_word(32'h9a000000, 1, 0, 0, 0, 0); // vaciarc.
        expect_word(32'h9a200000, 1, 1, 0, 0, 0); // medir 0.
        expect_word(32'h9a200001, 1, 1, 0, 0, 1); // medir 1.
        expect_word(32'h9a40f83f, 1, 2, 31, 63, 0); // lcont x31, mitad alta de reservado 31.
        expect_word(0, 0, 0, 0, 0, 0); // NOP y tipo LSU original no pertenecen a este decoder.
        expect_word(32'h93032804, 0, 0, 0, 0, 0);

        tb_section("todos los tipos e IDs con payload cero");
        for (instruction_type = 0; instruction_type < 128; instruction_type = instruction_type + 1)
            for (id = 0; id < 16; id = id + 1)
                expect_word((instruction_type << 25) | (id << 21),
                            instruction_type == 77 && id < 3,
                            (instruction_type == 77 && id < 3) ? id : 0, 0, 0, 0);

        tb_section("todos los destinos y las dos mitades de selectores 0 a 31");
        for (dest = 0; dest < 32; dest = dest + 1)
            for (sel = 0; sel < 64; sel = sel + 1)
                expect_word(32'h9a400000 | (dest << 11) | sel, 1, 2, dest, sel, 0);

        tb_section("cada bit reservado distinto de cero invalida la instrucción");
        for (bit_index = 0; bit_index < 21; bit_index = bit_index + 1) begin
            expect_word(32'h9a000000 | (32'd1 << bit_index), 0, 0, 0, 0, 0);
            if (bit_index != 0)
                expect_word(32'h9a200001 | (32'd1 << bit_index), 0, 0, 0, 0, 0);
            if ((bit_index >= 16) || (bit_index >= 6 && bit_index <= 10))
                expect_word(32'h9a40f83f | (32'd1 << bit_index), 0, 0, 0, 0, 0);
        end

        tb_section("X/Z en cualquier bit no produce una operación válida");
        for (op = 0; op < 3; op = op + 1) begin
            base_word = op == 0 ? 32'h9a000000 : op == 1 ? 32'h9a200001 : 32'h9a40f83f;
            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1) begin
                corrupt_word = base_word;
                corrupt_word[bit_index] = 1'bx;
                expect_word(corrupt_word, 0, 0, 0, 0, 0);
                corrupt_word[bit_index] = 1'bz;
                expect_word(corrupt_word, 0, 0, 0, 0, 0);
            end
        end
        tb_finish("tb_decoder_cache_isa");
    end
endmodule
