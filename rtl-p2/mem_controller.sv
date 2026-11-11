`timescale 1ns/1ps
`default_nettype none

// Controlador de memoria principal con cruce de dominios de reloj.
// El procesador trabaja con clk y la memoria con clk_mem.
// Las solicitudes y respuestas cruzan mediante toggles sincronizados.
// Los buses de datos permanecen estables durante cada intercambio.
// El timeout permite un reintento antes de reportar un error definitivo.

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

    // Estados del controlador en el dominio del procesador.
    localparam [1:0] CPU_IDLE = 2'd0;
    localparam [1:0] CPU_ACTIVE = 2'd1;
    localparam [1:0] CPU_RELEASE = 2'd2;

    // Estados del controlador en el dominio de memoria.
    localparam [1:0] MEM_IDLE = 2'd0;
    localparam [1:0] MEM_BURST = 2'd1;
    localparam [1:0] MEM_WAIT = 2'd2;

    // Calcular la espera inicial del dominio de memoria.
    // Se agrega un flanco adicional para MEM_DIV=2 porque
    // esa configuracion puede acceder antes del ciclo 25.
    // Las otras configuraciones ya respetan el minimo.
    localparam integer WAIT_EDGES = ((24 + MEM_DIV - 1) / MEM_DIV) - 3 + ((MEM_DIV == 2) ? 1 : 0);

    reg [1:0] cpu_state;
    reg [1:0] mem_state;

    // Contadores y control de reintentos.
    reg [31:0] elapsed;
    reg retry_used;
    reg abort_pending;

    // Registros estables durante la transferencia.
    reg [31:0] addr_saved;
    reg [255:0] wline_saved;
    reg we_saved;

    // Generacion continua del reloj lento.
    reg [31:0] divider_phase;

    // Solicitud desde CPU hacia RAM.
    reg req_toggle;
    reg req_sync1;
    reg req_sync2;
    reg req_seen;

    // Confirmacion desde RAM hacia CPU.
    reg done_toggle;
    reg done_sync1;
    reg done_sync2;
    reg done_seen;

    // Identifica el intento asociado a la confirmacion.
    // Permite descartar una respuesta tardia de otro intento.
    reg done_id_mem;
    reg done_id_sync1;
    reg done_id_sync2;

    // Solicitud de cancelacion desde CPU hacia RAM.
    reg cancel_toggle;
    reg cancel_sync1;
    reg cancel_sync2;
    reg cancel_seen;

    // Confirmacion de cancelacion desde RAM hacia CPU.
    reg cancel_ack;
    reg cancel_ack_sync1;
    reg cancel_ack_sync2;

    // Estado de transferencia de las ocho palabras.
    reg [31:0] wait_left;
    reg [2:0] word_index;

    // Linea en construccion y linea terminada.
    reg [255:0] read_line_mem;
    reg [255:0] result_line_mem;

    // La CPU acepta una solicitud solamente cuando esta libre.
    assign req_accept =
        (cpu_state == CPU_IDLE) && ram_req;

    assign req_we_accepted =
        req_accept && ram_we;

    assign transfer_busy =
        (cpu_state == CPU_ACTIVE);

    // Cada linea ocupa ocho palabras de 32 bits.
    assign mem_word_addr =
        addr_saved[15:2] + {11'd0, word_index};

    assign mem_word_wdata =
        wline_saved[word_index * 32 +: 32];

    // Una escritura fisica solamente se habilita durante
    // un burst valido que no este detenido ni cancelado.
    assign mem_word_we =
        (mem_state == MEM_BURST) &&
        we_saved &&
        !mem_hold &&
        (req_sync2 == req_seen) &&
        (cancel_sync2 == cancel_seen);

    // Verificar los parametros antes de comenzar la simulacion.
    initial begin

        if (MEM_DIV < 2 || MEM_DIV > 5)
            $fatal(1, "MEM_DIV debe estar entre 2 y 5");

        if (TMEM != 25 + 7 * MEM_DIV)
            $fatal(1, "TMEM no coincide con MEM_DIV");

        if (WAIT_EDGES < 1)
            $fatal(1, "Configuracion de espera invalida");

        if (MEM_TIMEOUT <= TMEM + 2 * MEM_DIV + 4)
            $fatal(1, "MEM_TIMEOUT es demasiado pequeno");
    end

    // Generar el reloj de memoria continuamente.
    // El reloj no se reinicia al aceptar una solicitud.
    // Se genera un flanco positivo cada MEM_DIV ciclos de CPU.
    // En una FPGA real debe utilizarse un recurso de reloj adecuado.
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

    // Sincronizar las solicitudes de CPU hacia memoria.
    // Cada toggle pasa por dos registros en el dominio destino.
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

    // Sincronizar las respuestas de memoria hacia CPU.
    // El identificador de intento acompana a la confirmacion.
    // La linea de datos se mantiene estable hasta su captura.
    always @(posedge clk or posedge reset) begin

        if (reset) begin
            done_sync1 <= 1'b0;
            done_sync2 <= 1'b0;

            done_id_sync1 <= 1'b0;
            done_id_sync2 <= 1'b0;

            cancel_ack_sync1 <= 1'b0;
            cancel_ack_sync2 <= 1'b0;

        end else begin
            done_sync1 <= done_toggle;
            done_sync2 <= done_sync1;

            done_id_sync1 <= done_id_mem;
            done_id_sync2 <= done_id_sync1;

            cancel_ack_sync1 <= cancel_ack;
            cancel_ack_sync2 <= cancel_ack_sync1;
        end
    end

    // Administrar las transferencias en el dominio de RAM.
    // Las solicitudes nuevas pueden reemplazar un intento vencido.
    // Una cancelacion definitiva elimina el trabajo pendiente.
    always @(posedge clk_mem or posedge reset) begin

        if (reset) begin
            mem_state <= MEM_IDLE;

            req_seen <= 1'b0;
            cancel_seen <= 1'b0;
            cancel_ack <= 1'b0;

            done_toggle <= 1'b0;
            done_id_mem <= 1'b0;

            word_index <= 3'd0;
            wait_left <= 0;

            read_line_mem <= 256'd0;
            result_line_mem <= 256'd0;

        end else if (cancel_sync2 != cancel_seen) begin

            // Invalidar una operacion que agoto los reintentos.
            // La cancelacion se reconoce aun cuando mem_hold esta activo.
            cancel_seen <= cancel_sync2;
            cancel_ack <= cancel_sync2;

            req_seen <= req_sync2;

            mem_state <= MEM_IDLE;
            word_index <= 3'd0;
            wait_left <= 0;

        end else if (req_sync2 != req_seen) begin

            // Una solicitud nueva tambien puede representar
            // un reintento de la operacion anterior.
            req_seen <= req_sync2;

            word_index <= 3'd0;
            wait_left <= WAIT_EDGES;

            read_line_mem <= 256'd0;

            mem_state <= MEM_WAIT;

        end else if (!mem_hold) begin

            case (mem_state)

                MEM_IDLE: begin
                    mem_state <= MEM_IDLE;
                end

                MEM_WAIT: begin

                    if (wait_left <= 1) begin
                        wait_left <= 0;
                        mem_state <= MEM_BURST;

                    end else begin
                        wait_left <= wait_left - 1'b1;
                    end
                end

                MEM_BURST: begin

                    // Capturar la palabra de lectura correspondiente.
                    // En escritura, RAM recibe mem_word_wdata.
                    if (!we_saved) begin
                        read_line_mem[word_index * 32 +: 32]
                            <= mem_word_rdata;
                    end

                    if (word_index == 3'd7) begin

                        // La octava palabra termina la transferencia.
                        // Construir la linea completa antes de avisar a CPU.
                        if (!we_saved) begin
                            result_line_mem <= {
                                mem_word_rdata,
                                read_line_mem[223:0]
                            };
                        end

                        // Asociar la respuesta con el intento actual.
                        done_id_mem <= req_seen;

                        // Avisar que los datos ya estan disponibles.
                        done_toggle <= ~done_toggle;

                        word_index <= 3'd0;
                        mem_state <= MEM_IDLE;

                    end else begin
                        word_index <= word_index + 1'b1;
                    end
                end

                default: begin
                    mem_state <= MEM_IDLE;
                end

            endcase
        end
    end

    // Administrar solicitudes y respuestas en el dominio de CPU.
    // ram_ready solo se activa al recibir una confirmacion sincronizada.
    // elapsed se utiliza exclusivamente para timeout y reintentos.
    always @(posedge clk or posedge reset) begin

        if (reset) begin
            cpu_state <= CPU_IDLE;

            elapsed <= 0;
            retry_used <= 1'b0;
            abort_pending <= 1'b0;

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
            timeout_event <= 1'b0;
            error_event <= 1'b0;

            case (cpu_state)

                CPU_IDLE: begin

                    mem_error <= 1'b0;

                    if (ram_req) begin

                        // Guardar la solicitud en registros de CPU.
                        // Estos buses permanecen estables mientras
                        // el dominio de RAM procesa la transferencia.
                        addr_saved <= {ram_addr[31:5], 5'b0};
                        wline_saved <= ram_wline;
                        we_saved <= ram_we;

                        // Emitir una nueva solicitud.
                        req_toggle <= ~req_toggle;

                        // Registrar la ultima respuesta conocida.
                        done_seen <= done_sync2;

                        elapsed <= 0;
                        retry_used <= 1'b0;

                        cpu_state <= CPU_ACTIVE;
                    end
                end

                CPU_ACTIVE: begin

                    elapsed <= elapsed + 1'b1;

                    if (done_sync2 != done_seen) begin

                        // Reconocer el evento para no procesarlo otra vez.
                        done_seen <= done_sync2;

                        if (done_id_sync2 == req_toggle) begin

                            // El intento confirmado es el vigente.
                            if (!we_saved)
                                ram_rline <= result_line_mem;

                            ram_ready <= 1'b1;
                            cpu_state <= CPU_RELEASE;
                        end

                        // Una respuesta con identificador antiguo
                        // se descarta sin finalizar la solicitud.
                    end

                    else if (elapsed >= MEM_TIMEOUT - 1) begin

                        timeout_event <= 1'b1;

                        if (!retry_used) begin

                            // Primer timeout: emitir un unico reintento.
                            retry_used <= 1'b1;
                            elapsed <= 0;

                            done_seen <= done_sync2;
                            req_toggle <= ~req_toggle;

                        end else begin

                            // Segundo timeout: cancelar definitivamente.
                            // Esperar la confirmacion de cancelacion
                            // antes de permitir otra solicitud.
                            cancel_toggle <= ~cancel_toggle;

                            abort_pending <= 1'b1;

                            mem_error <= 1'b1;
                            error_event <= 1'b1;

                            cpu_state <= CPU_RELEASE;
                        end
                    end
                end

                CPU_RELEASE: begin

                    // En una operacion exitosa solamente se espera
                    // que el solicitante retire ram_req.
                    //
                    // En una operacion fallida tambien se espera
                    // la confirmacion de cancelacion desde RAM.
                    // Asi no se acepta trabajo nuevo demasiado pronto.
                    if (!ram_req &&
                        (!abort_pending ||
                         cancel_ack_sync2 == cancel_toggle)) begin

                        abort_pending <= 1'b0;
                        cpu_state <= CPU_IDLE;
                    end
                end

                default: begin
                    cpu_state <= CPU_IDLE;
                end

            endcase
        end
    end

endmodule

`default_nettype wire