/* Decodifica el tipo de caché y medición del slot LSU, sin alterar el decoder
 * original. Solo acepta los campos definidos en decisiones-importantes §4.4.
 * Es combinacional: no agrega latencia ni verifica la posición en el bundle;
 * el integrador debe suministrar exclusivamente el slot 1 desde ID. */
module decoder_cache_isa (
    input  logic [31:0] instruction,  // Palabra del slot LSU; NOP no es válida aquí.
    output logic        valid,       // Autoriza transportar los controles hacia EX.
    output logic [3:0]  operation,   // IDs: 0 vaciarc, 1 medir, 2 lcont; usar con valid.
    output logic [4:0]  rd,          // Destino de lcont; x0 es una codificación válida.
    output logic [5:0]  selector,    // [5] mitad alta; [4:0] contador, incluso reservado.
    output logic        measure_imm  // Nuevo enable de medir; no es un pulso de reset.
);

    always @(*) begin
        // Una palabra ilegal deja todas las salidas inactivas. Las comparaciones
        // exactas impiden aceptar X/Z en campos reservados o en operandos.
        valid = 1'b0;
        operation = 4'd0;
        rd = 5'd0;
        selector = 6'd0;
        measure_imm = 1'b0;
        if (instruction[31:25] == 7'b1001101) begin
            case (instruction[24:21])
                4'd0: begin
                    if (instruction[20:0] === 21'd0)
                        valid = 1'b1;
                end
                4'd1: begin
                    if ((instruction[20:1] === 20'd0) &&
                        ((instruction[0] === 1'b0) || (instruction[0] === 1'b1))) begin
                        valid = 1'b1;
                        operation = 4'd1;
                        measure_imm = instruction[0];
                    end
                end
                4'd2: begin
                    // Los selectores 13–31 son legales y se leen como cero en
                    // ejecución. Son distintos de los bits de codificación RSV.
                    if ((instruction[20:16] === 5'd0) &&
                        (instruction[10:6] === 5'd0) &&
                        (^instruction[15:11] !== 1'bx) &&
                        (^instruction[5:0] !== 1'bx)) begin
                        valid = 1'b1;
                        operation = 4'd2;
                        rd = instruction[15:11];
                        selector = instruction[5:0];
                    end
                end
                default: begin end // IDs 3–15 reservados, sin efectos laterales.
            endcase
        end
    end
endmodule
