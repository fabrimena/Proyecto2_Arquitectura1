/*
 * Monitor de metadatos del pipeline VLIW (ID -> EX -> WB).
 * Mantiene la validez y la máscara de cada bundle, registra anulaciones por
 * salto o excepción y señala la finalización del bundle presente en WB.
 * No modifica el datapath ni calcula ciclos de penalización por saltos.
 */
module perf_pipeline_monitor (
    input  logic       clk,
    input  logic       reset,
    input  logic       advance, // Avance efectivo conjunto de las etapas en este flanco.
    input  logic       id_valid, // Describe ID antes del flanco, junto con su máscara.
    input  logic [3:0] id_non_nop_mask,
    input  logic       ex_branch_taken, // Resultado del salto del bundle actual de EX.
    input  logic       ex_exception, // Excepción ya determinada por el control del núcleo.
    output logic       ex_valid,
    output logic [3:0] ex_non_nop_mask,
    output logic [1:0] ex_cancel_cause,
    output logic       wb_valid,
    output logic [3:0] wb_non_nop_mask,
    output logic [1:0] wb_cancel_cause,
    output logic       bundle_complete
);

// Una causa distinta de cero identifica una posición anulada, no una instrucción
// completada. Estos códigos de observación no pertenecen a la ISA.
localparam logic [1:0] CANCEL_NONE = 2'd0;
localparam logic [1:0] CANCEL_BRANCH = 2'd1;
localparam logic [1:0] CANCEL_EXCEPTION = 2'd2;

logic [1:0] redirect_cause;
logic [1:0] id_cancel_cause; // Conserva la causa del hueco de IF que aparecerá en ID.

// Los controles solo tienen efecto si EX contiene un bundle válido.
// Si coinciden salto y excepción, la excepción determina la causa del vaciado.
always @(*) begin
    redirect_cause = CANCEL_NONE;
    if (ex_valid) begin
        if (ex_exception)
            redirect_cause = CANCEL_EXCEPTION;
        else if (ex_branch_taken)
            redirect_cause = CANCEL_BRANCH;
    end
end

// El evento corresponde al bundle que ya está en WB antes del flanco.
// Se desactiva durante reset o cuando el pipeline no puede avanzar. El contador
// consume este nivel y wb_non_nop_mask; después de NBA, WB contiene otro bundle.
assign bundle_complete = !reset && advance && wb_valid;

always @(posedge clk) begin
    if (reset) begin
        // Borra validez, máscaras y causas, incluso si el pipeline está detenido.
        ex_valid <= 1'b0;
        ex_non_nop_mask <= 4'b0;
        ex_cancel_cause <= CANCEL_NONE;
        wb_valid <= 1'b0;
        wb_non_nop_mask <= 4'b0;
        wb_cancel_cause <= CANCEL_NONE;
        id_cancel_cause <= CANCEL_NONE;
    end
    else if (advance) begin
        // Copia a WB el bundle que estaba en EX antes de este flanco.
        // Si EX presenta una excepción, su bundle no puede finalizar. Esto no
        // anula al WB anterior, que puede ser consumido en el mismo flanco.
        wb_valid <= ex_valid && !ex_exception;
        wb_non_nop_mask <= (ex_valid && !ex_exception) ? ex_non_nop_mask : 4'b0;
        wb_cancel_cause <= (ex_valid && ex_exception) ? CANCEL_EXCEPTION : ex_cancel_cause;

        // Guarda la causa del descarte de IF. Ese hueco llegará a ID en el próximo
        // avance; solo se transporta su causa, no la instrucción descartada.
        id_cancel_cause <= redirect_cause;

        if (redirect_cause != CANCEL_NONE) begin
            // El bundle que está en ID se descarta: entra una posición inválida a EX.
            ex_valid <= 1'b0;
            ex_non_nop_mask <= 4'b0;
            ex_cancel_cause <= redirect_cause;
        end
        else if (id_cancel_cause != CANCEL_NONE) begin
            // Descarta la siguiente posición, correspondiente al bundle que estaba en IF.
            // La marca conserva la causa sin convertirla en ciclos perdidos.
            ex_valid <= 1'b0;
            ex_non_nop_mask <= 4'b0;
            ex_cancel_cause <= id_cancel_cause;
        end
        else begin
            // En flujo normal, ID entra a EX. Un NOP válido conserva su validez;
            // una entrada inválida tiene máscara cero y no podrá finalizar.
            ex_valid <= id_valid;
            ex_non_nop_mask <= id_valid ? id_non_nop_mask : 4'b0;
            ex_cancel_cause <= CANCEL_NONE;
        end
    end
    // Sin avance se mantienen también las marcas pendientes. Los controles
    // deben seguir presentes al reanudar si el núcleo aún necesita aceptarlos.
end

endmodule
