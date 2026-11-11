`timescale 1ns/1ps
`default_nettype none

// Controlador de RAM de 64 KB por palabras de 32 bits.
// La interfaz CPU transmite lineas de 256 bits.
// clk_mem se obtiene por division continua del reloj CPU.
// Un handshake de toggles sincronizados protege la solicitud,
// la respuesta y la cancelacion entre los dos dominios.
// La transferencia fisica se anticipa para que la respuesta
// externa pueda respetar la latencia nominal TMEM.

module mem_controller #(
    parameter integer MEM_DIV = 4,
    parameter integer MEM_TIMEOUT = 256,
    parameter integer TMEM = 25 + 7 * MEM_DIV
) (
    input wire clk,
    input wire reset,
    input wire ram_req,
    input wire ram_we,
    input wire [31:0] ram_addr,
    input wire [255:0] ram_wline,
    output reg ram_ready,
    output reg [255:0] ram_rline,
    output reg mem_error,
    output reg ram_word_valid,
    output reg [31:0] ram_word_data,
    output reg [2:0] ram_word_index,
    output wire req_accept,
    output wire req_we_accepted,
    output wire transfer_busy,
    output reg timeout_event,
    output reg error_event,
    input wire mem_hold,
    output reg clk_mem,
    output wire [13:0] mem_word_addr,
    output wire [31:0] mem_word_wdata,
    output wire mem_word_we,
    input wire [31:0] mem_word_rdata
);
    localparam [1:0] CPU_IDLE = 2'd0;
    localparam [1:0] CPU_ACTIVE = 2'd1;
    localparam [1:0] CPU_RELEASE = 2'd2;

    localparam [1:0] MEM_IDLE = 2'd0;
    localparam [1:0] MEM_BURST = 2'd1;

    reg [1:0] cpu_state;
    reg [1:0] mem_state;
    reg [31:0] divider_phase;
    reg [31:0] elapsed;
    reg retry_used;
    reg abort_pending;
    reg transfer_confirmed;

    // Avance de la entrega de palabras al procesador.
    reg [3:0] word_delivery_count;
    reg [7:0] beat_baseline;
    reg [31:0] retry_next_word_cycle;

    // Cada palabra genera un evento de disponibilidad en RAM.
    // Los eventos se sincronizan individualmente al dominio CPU.
    reg [7:0] beat_toggle_mem;
    reg [7:0] beat_id_mem;
    reg [7:0] beat_sync1;
    reg [7:0] beat_sync2;
    reg [7:0] beat_id_sync1;
    reg [7:0] beat_id_sync2;

    // El bundle de solicitud se mantiene estable hasta completar
    // su respuesta o la confirmacion de cancelacion.
    reg [31:0] addr_saved;
    reg [255:0] wline_saved;
    reg we_saved;

    reg req_toggle;
    reg req_sync1;
    reg req_sync2;
    reg req_seen;

    reg done_toggle;
    reg done_sync1;
    reg done_sync2;
    reg done_seen;
    reg done_id_mem;
    reg done_id_sync1;
    reg done_id_sync2;

    reg cancel_toggle;
    reg cancel_sync1;
    reg cancel_sync2;
    reg cancel_seen;
    reg cancel_ack;
    reg cancel_ack_sync1;
    reg cancel_ack_sync2;

    reg [2:0] word_index;
    reg [255:0] read_line_mem;
    reg [255:0] result_line_mem;

    wire completion_now;
    wire completion_valid;
    wire release_due;
    wire next_word_available;
    wire next_word_due;
    wire word_delivery_now;

    assign req_accept = (cpu_state == CPU_IDLE) && ram_req;
    assign req_we_accepted = req_accept && ram_we;
    assign transfer_busy = (cpu_state == CPU_ACTIVE);

    assign mem_word_addr = addr_saved[15:2] + {11'd0, word_index};
    assign mem_word_wdata = wline_saved[word_index * 32 +: 32];
    assign mem_word_we =
        (mem_state == MEM_BURST) && we_saved && !mem_hold &&
        (req_sync2 == req_seen) &&
        (cancel_sync2 == cancel_seen);

    assign completion_now = (done_sync2 != done_seen);
    assign completion_valid = completion_now &&
                              (done_id_sync2 == req_toggle);
    assign release_due = (elapsed >= TMEM - 1);

    // La palabra solo puede entregarse despues de su captura real,
    // sincronizacion y fecha nominal de llegada al procesador.
    // En un intento normal se usan los eventos individuales CDC.
    // En un reintento, una parte del burst anterior pudo quedar
    // en vuelo. Se espera la confirmacion de la linea completa
    // del intento vigente para no reutilizar eventos antiguos.
    assign next_word_available = (word_delivery_count < 8) &&
        (retry_used ? (transfer_confirmed || completion_valid) :
        ((beat_sync2[word_delivery_count[2:0]] !=
          beat_baseline[word_delivery_count[2:0]]) &&
         (beat_id_sync2[word_delivery_count[2:0]] == req_toggle)));
    // La entrega normal conserva el calendario 25 + i*MEM_DIV.
    // En un reintento puede comenzar despues de TMEM si la
    // transferencia estuvo detenida, pero mantiene la cadencia.
    assign next_word_due = retry_used ?
        ((word_delivery_count == 0) ||
         (elapsed >= retry_next_word_cycle)) :
        (elapsed >= 24 + word_delivery_count * MEM_DIV);
    assign word_delivery_now =
        (cpu_state == CPU_ACTIVE) && !we_saved &&
        next_word_available && next_word_due;

    initial begin
        if (MEM_DIV < 2 || MEM_DIV > 5)
            $fatal(1, "MEM_DIV debe estar entre 2 y 5");
        if (TMEM != 25 + 7 * MEM_DIV)
            $fatal(1, "TMEM no coincide con MEM_DIV");
        if (MEM_TIMEOUT <= TMEM + 2 * MEM_DIV + 4)
            $fatal(1, "MEM_TIMEOUT demasiado pequeno");
    end

    // Un flanco positivo de memoria cada MEM_DIV flancos CPU.
    // El divisor nunca se reinicia cuando llega una solicitud.
    // En FPGA se recomienda implementarlo mediante recursos
    // de reloj dedicados o PLL, con restricciones de temporizacion.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            divider_phase <= 0;
            clk_mem <= 1'b1;
        end else if (divider_phase == MEM_DIV - 1) begin
            divider_phase <= 0;
            clk_mem <= 1'b1;
        end else begin
            divider_phase <= divider_phase + 1'b1;
            clk_mem <= 1'b0;
        end
    end

    // Sincronizacion del control desde CPU hacia RAM.
    always @(posedge clk_mem or posedge reset) begin
        if (reset) begin
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            cancel_sync1 <= 1'b0;
            cancel_sync2 <= 1'b0;
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;
            cancel_sync1 <= cancel_toggle;
            cancel_sync2 <= cancel_sync1;
        end
    end

    // Sincronizacion del control desde RAM hacia CPU.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            done_sync1 <= 1'b0;
            done_sync2 <= 1'b0;
            done_id_sync1 <= 1'b0;
            done_id_sync2 <= 1'b0;
            cancel_ack_sync1 <= 1'b0;
            cancel_ack_sync2 <= 1'b0;
            beat_sync1 <= 8'd0;
            beat_sync2 <= 8'd0;
            beat_id_sync1 <= 8'd0;
            beat_id_sync2 <= 8'd0;
        end else begin
            done_sync1 <= done_toggle;
            done_sync2 <= done_sync1;
            done_id_sync1 <= done_id_mem;
            done_id_sync2 <= done_id_sync1;
            cancel_ack_sync1 <= cancel_ack;
            cancel_ack_sync2 <= cancel_ack_sync1;
            beat_sync1 <= beat_toggle_mem;
            beat_sync2 <= beat_sync1;
            beat_id_sync1 <= beat_id_mem;
            beat_id_sync2 <= beat_id_sync1;
        end
    end

    // Acceso fisico a la RAM a frecuencia reducida.
    // Se hace una palabra por cada flanco de clk_mem.
    // Un reintento reemplaza el burst anterior.
    always @(posedge clk_mem or posedge reset) begin
        if (reset) begin
            mem_state <= MEM_IDLE;
            req_seen <= 1'b0;
            cancel_seen <= 1'b0;
            cancel_ack <= 1'b0;
            done_toggle <= 1'b0;
            done_id_mem <= 1'b0;
            word_index <= 3'd0;
            read_line_mem <= 256'd0;
            result_line_mem <= 256'd0;
            beat_toggle_mem <= 8'd0;
            beat_id_mem <= 8'd0;
        end else if (cancel_sync2 != cancel_seen) begin
            cancel_seen <= cancel_sync2;
            cancel_ack <= cancel_sync2;
            req_seen <= req_sync2;
            mem_state <= MEM_IDLE;
            word_index <= 3'd0;
        end else if (req_sync2 != req_seen) begin
            req_seen <= req_sync2;
            word_index <= 3'd0;
            read_line_mem <= 256'd0;
            mem_state <= MEM_BURST;
        end else if (!mem_hold) begin
            case (mem_state)
                MEM_IDLE: begin
                    mem_state <= MEM_IDLE;
                end
                MEM_BURST: begin
                    // Publicar la captura de la palabra como evento CDC.
                    // El dato permanece en read_line_mem hasta la siguiente
                    // transaccion, por lo que no cruza como bus cambiante.
                    beat_toggle_mem[word_index] <=
                        ~beat_toggle_mem[word_index];
                    beat_id_mem[word_index] <= req_seen;
                    if (!we_saved)
                        read_line_mem[word_index * 32 +: 32]
                            <= mem_word_rdata;
                    if (word_index == 3'd7) begin
                        if (!we_saved)
                            result_line_mem <= {
                                mem_word_rdata,
                                read_line_mem[223:0]
                            };
                        done_id_mem <= req_seen;
                        done_toggle <= ~done_toggle;
                        word_index <= 3'd0;
                        mem_state <= MEM_IDLE;
                    end else begin
                        word_index <= word_index + 1'b1;
                    end
                end
                default: mem_state <= MEM_IDLE;
            endcase
        end
    end

    // Gestion de la latencia visible por CPU y de los errores.
    // La finalizacion se guarda porque RAM puede terminar
    // antes de que transcurra TMEM.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            cpu_state <= CPU_IDLE;
            elapsed <= 0;
            retry_used <= 1'b0;
            abort_pending <= 1'b0;
            transfer_confirmed <= 1'b0;
            word_delivery_count <= 4'd0;
            beat_baseline <= 8'd0;
            retry_next_word_cycle <= 0;
            ram_word_valid <= 1'b0;
            ram_word_data <= 32'd0;
            ram_word_index <= 3'd0;
            addr_saved <= 32'd0;
            wline_saved <= 256'd0;
            we_saved <= 1'b0;
            req_toggle <= 1'b0;
            cancel_toggle <= 1'b0;
            done_seen <= 1'b0;
            ram_ready <= 1'b0;
            ram_rline <= 256'd0;
            mem_error <= 1'b0;
            timeout_event <= 1'b0;
            error_event <= 1'b0;
        end else begin
            ram_ready <= 1'b0;
            ram_word_valid <= 1'b0;
            timeout_event <= 1'b0;
            error_event <= 1'b0;

            case (cpu_state)
                CPU_IDLE: begin
                    mem_error <= 1'b0;
                    if (ram_req) begin
                        addr_saved <= {ram_addr[31:5], 5'b0};
                        wline_saved <= ram_wline;
                        we_saved <= ram_we;
                        req_toggle <= ~req_toggle;
                        done_seen <= done_sync2;
                        elapsed <= 0;
                        retry_used <= 1'b0;
                        transfer_confirmed <= 1'b0;
                        word_delivery_count <= 4'd0;
                        beat_baseline <= beat_sync2;
                        retry_next_word_cycle <= 0;
                        cpu_state <= CPU_ACTIVE;
                    end
                end
                CPU_ACTIVE: begin
                    elapsed <= elapsed + 1'b1;

                    // La entrega se inicia en el ciclo 25 y continua
                    // cada MEM_DIV ciclos, siempre que el dato real
                    // haya cruzado al dominio CPU.
                    if (word_delivery_now) begin
                        ram_word_valid <= 1'b1;
                        ram_word_index <= word_delivery_count[2:0];
                        ram_word_data <= retry_used ?
                            result_line_mem[word_delivery_count * 32 +: 32] :
                            read_line_mem[word_delivery_count * 32 +: 32];
                        word_delivery_count <= word_delivery_count + 1'b1;
                        if (retry_used)
                            retry_next_word_cycle <= elapsed + MEM_DIV;
                    end
                    if (completion_now) begin
                        done_seen <= done_sync2;
                        if (completion_valid)
                            transfer_confirmed <= 1'b1;
                    end
                    if ((transfer_confirmed || completion_valid) &&
                        release_due &&
                        (we_saved || word_delivery_count == 8 ||
                         (word_delivery_count == 7 && word_delivery_now))) begin
                        if (!we_saved)
                            ram_rline <= result_line_mem;
                        ram_ready <= 1'b1;
                        transfer_confirmed <= 1'b0;
                        cpu_state <= CPU_RELEASE;
                    end else if (elapsed >= MEM_TIMEOUT - 1) begin
                        timeout_event <= 1'b1;
                        if (!retry_used) begin
                            retry_used <= 1'b1;
                            elapsed <= 0;
                            done_seen <= done_sync2;
                            transfer_confirmed <= 1'b0;
                            word_delivery_count <= 4'd0;
                            beat_baseline <= beat_sync2;
                            retry_next_word_cycle <= 0;
                            req_toggle <= ~req_toggle;
                        end else begin
                            cancel_toggle <= ~cancel_toggle;
                            abort_pending <= 1'b1;
                            mem_error <= 1'b1;
                            error_event <= 1'b1;
                            transfer_confirmed <= 1'b0;
                            cpu_state <= CPU_RELEASE;
                        end
                    end
                end
                CPU_RELEASE: begin
                    if (!ram_req &&
                        (!abort_pending ||
                         cancel_ack_sync2 == cancel_toggle)) begin
                        abort_pending <= 1'b0;
                        cpu_state <= CPU_IDLE;
                    end
                end
                default: cpu_state <= CPU_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
