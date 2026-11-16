/* Ejecuta independientemente medir, lcont y el protocolo de vaciarc en EX.
 * Usa clk general, reset síncrono prioritario y transferencias explícitas;
 * no se conecta todavía al pipeline ni garantiza persistencia de la L2 real.
 * El integrador debe alinear ID/EX, consumir la respuesta en WB y generar el
 * stall de vaciarc sin detener este reloj ni su máquina de estados. */
module cache_isa_unit (
    input  logic        clk,
    input  logic        reset,          // Cancela incluso un vaciado pendiente; requiere reinicio conjunto.
    input  logic        valid_in,       // Controles decodificados y estables hasta su aceptación.
    input  logic        ex_advance,     // Permiso de emitir la instrucción actual; 0 durante freeze externo.
    output logic        issue_ready,    // Capacidad de aceptar, independiente de valid_in y ex_advance.
    input  logic [3:0]  operation,      // IDs de decoder_cache_isa; los desconocidos no se aceptan.
    input  logic [4:0]  rd,             // Destino de lcont, retenido junto con el resultado.
    input  logic [5:0]  selector,       // Mitad y contador; 13–31 devuelven cero, X/Z se rechaza.
    input  logic        measure_imm,    // medir 0 pausa sin borrar; medir 1 reanuda.
    // Instantáneas de 64 bits suministradas por el integrador, en el orden
    // contractual 0 ciclos, 1 bundles, 2 instrucciones, 3 stall memoria,
    // 4 saltos, 5/6 lecturas L1 hit/miss, 7/8 escrituras L1 hit/miss,
    // 9/10 L2 hit/miss, 11 accesos RAM, 12 ciclos de transferencia RAM.
    // Conectar cero explícito para fuentes no disponibles; no se estiman aquí.
    input  logic [63:0] counters [0:12],
    output logic        measure_enable,// Estado persistente: 1 al reset, cambia solo al aceptar medir.
    output logic        flush_req,     // Un único nivel de solicitud, retenido hasta flush_done conocido.
    input  logic        flush_done,    // El proveedor debe confirmar persistencia y bajar al retirar req.
    output logic        pending,       // Hay una instrucción aceptada aún sin consumir por completo.
    output logic        complete_valid,// Respuesta registrada, estable hasta complete_ready.
    input  logic        complete_ready,// Permiso real de consumir en WB; 0 conserva respuesta y datos.
    output logic        wb_we,         // Transferencia de lcont a rd != 0; no se repite durante pausa WB.
    output logic [4:0]  wb_rd,          // Destino registrado; se ignora salvo wb_we.
    output logic [31:0] wb_data         // Mitad capturada en EX; no sigue cambios posteriores del contador.
);
    // WAIT_DONE mantiene req; RELEASE espera la retirada de ack para separar
    // vaciados consecutivos. RESULT retiene también respuestas sin escritura.
    typedef enum logic [1:0] {IDLE, WAIT_DONE, RELEASE, RESULT} state_t;
    state_t state;
    logic result_is_read;             // Distingue lcont de respuestas de medir/vaciarc.
    logic operands_valid;             // Rechazo conservador de controles desconocidos.
    logic issue_fire;                 // Único flanco que ejecuta medir o captura lcont.
    logic [63:0] selected_counter;    // Mux combinacional de la instantánea contractual.

    always @(*) begin
        operands_valid = 1'b0;
        case (operation)
            // Un ack antiguo o desconocido impide iniciar otro vaciado, pero
            // no bloquea medir/lcont. Antes de pedir, done debe ser cero.
            4'd0: operands_valid = (flush_done === 1'b0);
            4'd1: operands_valid = (measure_imm === 1'b0) || (measure_imm === 1'b1);
            4'd2: operands_valid = (^rd !== 1'bx) && (^selector !== 1'bx);
            default: begin end
        endcase
        selected_counter = 64'd0;
        if ((^selector !== 1'bx) && selector[4:0] <= 5'd12)
            selected_counter = counters[selector[4:0]];

        // La respuesta anterior puede consumirse al mismo flanco que se emite
        // la siguiente instrucción. No se requiere un ciclo vacío entre ellas.
        issue_ready = (reset === 1'b0) && operands_valid &&
                      ((state == IDLE) || ((state == RESULT) && (complete_ready === 1'b1)));
        issue_fire = issue_ready && (valid_in === 1'b1) && (ex_advance === 1'b1);
        flush_req = (reset === 1'b0) && (state == WAIT_DONE);
        pending = (reset === 1'b0) && (state != IDLE);
        complete_valid = (reset === 1'b0) && (state == RESULT);
        // WB debe usar clk y este permiso de transferencia. Si el pipeline
        // consume la respuesta, debe avanzar EX o retirar valid_in para no
        // volver a emitir la misma instrucción; un nivel válido no es un ID.
        wb_we = complete_valid && (complete_ready === 1'b1) && result_is_read && (wb_rd != 0);
    end

    always @(posedge clk) begin
        // X/Z en reset se trata como reset, no como permiso de ejecución.
        // No modifica contadores externos ni completa persistencia pendiente.
        if (reset !== 1'b0) begin
            state <= IDLE;
            measure_enable <= 1'b1;
            result_is_read <= 1'b0;
            wb_rd <= 5'd0;
            wb_data <= 32'd0;
        end else begin
            case (state)
                WAIT_DONE: begin
                    // X/Z jamás confirma el vaciado. El primer ciclo con req
                    // admite una respuesta inmediata, sin exigir latencia fija.
                    if (flush_done === 1'b1) state <= RELEASE;
                end
                RELEASE: begin
                    if (flush_done === 1'b0) state <= RESULT;
                end
                RESULT: begin
                    if (complete_ready === 1'b1) state <= IDLE;
                end
                default: state <= IDLE;
            endcase
            if (issue_fire) begin
                result_is_read <= 1'b0;
                wb_rd <= 5'd0;
                wb_data <= 32'd0;
                case (operation)
                    4'd0: state <= WAIT_DONE;
                    4'd1: begin
                        // El nuevo enable rige después de este flanco; otros
                        // registros síncronos muestrean todavía el enable previo.
                        measure_enable <= measure_imm;
                        state <= RESULT;
                    end
                    4'd2: begin
                        result_is_read <= 1'b1;
                        wb_rd <= rd;
                        wb_data <= selector[5] ? selected_counter[63:32] : selected_counter[31:0];
                        state <= RESULT;
                    end
                    default: begin end // issue_fire excluye operaciones ilegales.
                endcase
            end
        end
    end
endmodule
