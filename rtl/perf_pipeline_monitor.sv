// D2: observador abstracto del pipeline IF/ID/EX/WB, sin controlar el núcleo.
// id_* describe ID antes del flanco. advance habilita TODOS los metadatos.
module perf_pipeline_monitor (
    input  logic       clk,
    input  logic       reset,
    input  logic       advance,
    input  logic       id_valid,
    input  logic [3:0] id_non_nop_mask,
    input  logic       ex_branch_taken,
    input  logic       ex_exception,
    output logic       ex_valid,
    output logic [3:0] ex_non_nop_mask,
    output logic [1:0] ex_cancel_cause,
    output logic       wb_valid,
    output logic [3:0] wb_non_nop_mask,
    output logic [1:0] wb_cancel_cause,
    output logic       bundle_complete
);

// Causas de observación, no opcodes ni ciclos de penalización.
localparam logic [1:0] CANCEL_NONE = 2'd0;
localparam logic [1:0] CANCEL_BRANCH = 2'd1;
localparam logic [1:0] CANCEL_EXCEPTION = 2'd2;

logic [1:0] redirect_cause;
logic [1:0] id_cancel_cause; // Posición de IF descartada: aparecerá en ID.

always @(*) begin
    redirect_cause = CANCEL_NONE;
    if (ex_valid) begin
        if (ex_exception)
            redirect_cause = CANCEL_EXCEPTION;
        else if (ex_branch_taken)
            redirect_cause = CANCEL_BRANCH;
    end
end

// Nivel consumible en el próximo flanco, NO un pulso registrado después de WB.
// La máscara del evento es wb_non_nop_mask. Se conserva durante retenciones.
assign bundle_complete = !reset && advance && wb_valid;

always @(posedge clk) begin
    if (reset) begin
        ex_valid <= 1'b0;
        ex_non_nop_mask <= 4'b0;
        ex_cancel_cause <= CANCEL_NONE;
        wb_valid <= 1'b0;
        wb_non_nop_mask <= 4'b0;
        wb_cancel_cause <= CANCEL_NONE;
        id_cancel_cause <= CANCEL_NONE;
    end
    else if (advance) begin
        // EX anterior pasa a WB. Un redirect no mata al bundle anterior en WB.
        wb_valid <= ex_valid && !ex_exception;
        wb_non_nop_mask <= (ex_valid && !ex_exception) ? ex_non_nop_mask : 4'b0;
        wb_cancel_cause <= (ex_valid && ex_exception) ? CANCEL_EXCEPTION : ex_cancel_cause;

        // Refleja el vaciado de IF/ID: la segunda posición joven se observa
        // en ID en el siguiente avance. No almacena otra instrucción de IF.
        id_cancel_cause <= redirect_cause;

        if (redirect_cause != CANCEL_NONE) begin
            // El bundle joven que estaba en ID queda anulado al entrar a EX.
            ex_valid <= 1'b0;
            ex_non_nop_mask <= 4'b0;
            ex_cancel_cause <= redirect_cause;
        end
        else if (id_cancel_cause != CANCEL_NONE) begin
            // Hueco de IF descartado por el redirect anterior.
            ex_valid <= 1'b0;
            ex_non_nop_mask <= 4'b0;
            ex_cancel_cause <= id_cancel_cause;
        end
        else begin
            ex_valid <= id_valid;
            ex_non_nop_mask <= id_valid ? id_non_nop_mask : 4'b0;
            ex_cancel_cause <= CANCEL_NONE;
        end
    end
end

endmodule
