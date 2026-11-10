`timescale 1ns/1ps
`default_nettype none

// Controlador de memoria principal del Proyecto 2 de CE4301.
// Recibe solicitudes de lineas completas de 32 bytes.
// El procesador trabaja a 100 MHz.
// La memoria trabaja a una frecuencia definida por MEM_DIV.
// Cada linea contiene ocho palabras de 32 bits.
// La primera palabra se transfiere en el ciclo 25.
// Las siguientes palabras se transfieren cada MEM_DIV ciclos.
// La respuesta completa se entrega en el ciclo TMEM.
// El timeout permite un reintento antes de reportar un error.

module mem_controller #(
    parameter integer MEM_DIV = 4,
    parameter integer MEM_TIMEOUT = 256,
    parameter integer TMEM = 25 + 7 * MEM_DIV
) (
    input  wire         clk,
    input  wire         reset,

    input  wire         ram_req,
    input  wire         ram_we,
    input  wire [31:0]  ram_addr,
    input  wire [255:0] ram_wline,

    output reg          ram_ready,
    output wire [255:0] ram_rline,
    output reg          mem_error,

    output wire         req_accept,
    output wire         req_we_accepted,
    output wire         transfer_busy,

    output reg          timeout_event,
    output reg          error_event,

    input  wire         mem_hold,

    output reg          clk_mem,

    output wire [13:0]  mem_word_addr,
    output wire [31:0]  mem_word_wdata,
    output wire         mem_word_we,
    input  wire [31:0]  mem_word_rdata
);

    // Estados del controlador en el dominio del procesador.
    localparam [1:0] CPU_IDLE    = 2'd0;
    localparam [1:0] CPU_ACTIVE  = 2'd1;
    localparam [1:0] CPU_RELEASE = 2'd2;

    // Estados del controlador en el dominio de memoria.
    // MEM_BURST conserva el valor 1 para los testbenches existentes.
    localparam [1:0] MEM_IDLE  = 2'd0;
    localparam [1:0] MEM_BURST = 2'd1;
    localparam [1:0] MEM_WAIT  = 2'd2;

    // Numero de flancos de memoria necesarios para llegar al ciclo 25.
    localparam integer FIRST_BEAT_EDGE =
        (25 + MEM_DIV - 1) / MEM_DIV;

    // Primer flanco del reloj lento respecto al inicio de la solicitud.
    localparam integer FIRST_EDGE_DELAY =
        ((25 % MEM_DIV) == 0) ? MEM_DIV : (25 % MEM_DIV);

    // Flancos de espera posteriores al reconocimiento de la solicitud.
    // El reconocimiento ocurre en el tercer flanco del reloj lento.
    localparam integer WAIT_EDGES = FIRST_BEAT_EDGE - 4;

    reg [1:0] cpu_state;
    reg [1:0] mem_state;

    reg [31:0] elapsed;
    reg retry_used;

    reg [31:0] addr_saved;
    reg [255:0] wline_saved;
    reg we_saved;

    reg [31:0] edge_countdown;

    reg req_toggle;
    reg req_sync1;
    reg req_sync2;
    reg req_seen;

    reg done_toggle;
    reg done_sync1;
    reg done_sync2;

    reg [31:0] wait_left;
    reg [2:0] word_index;

    reg [255:0] read_line_mem;

    // La direccion de memoria se alinea a una linea de 32 bytes.
    // Cada incremento de word_index selecciona una palabra.
    assign mem_word_addr =
        addr_saved[15:2] + {11'd0, word_index};

    // Selecciona una palabra de 32 bits de la linea de escritura.
    assign mem_word_wdata =
        wline_saved[word_index * 32 +: 32];

    // La escritura solo se habilita durante una transferencia valida.
    // La RAM externa escribe en el flanco positivo de clk_mem.
    assign mem_word_we =
        (mem_state == MEM_BURST) &&
        we_saved &&
        !mem_hold &&
        (req_sync2 == req_seen);

    // La linea de lectura se construye palabra por palabra.
    // Se entrega desde el registro del dominio de memoria.
    assign ram_rline = read_line_mem;

    // Una solicitud se acepta solamente cuando el controlador esta libre.
    assign req_accept =
        (cpu_state == CPU_IDLE) && ram_req;

    // Indica si la solicitud aceptada corresponde a una escritura.
    assign req_we_accepted =
        req_accept && ram_we;

    // Indica que existe una transferencia pendiente.
    assign transfer_busy =
        (cpu_state == CPU_ACTIVE);

    // Verifica que los parametros utilizados sean validos.
    initial begin
        if (MEM_DIV < 2)
            $fatal(1, "MEM_DIV debe ser mayor o igual a 2");

        if (MEM_DIV > 5)
            $fatal(1, "MEM_DIV debe estar entre 2 y 5");

        if (TMEM != 25 + 7 * MEM_DIV)
            $fatal(1, "TMEM no coincide con la frecuencia de memoria");

        if (MEM_TIMEOUT <= TMEM)
            $fatal(1, "MEM_TIMEOUT debe ser mayor que TMEM");

        if (WAIT_EDGES < 1)
            $fatal(1, "Configuracion de espera no valida");
    end

    // Genera un pulso de reloj lento cada MEM_DIV ciclos.
    // El contador se realinea al aceptar cada solicitud.
    // Esto permite colocar el ultimo flanco del burst en TMEM.
    // Para MEM_DIV impar, el ciclo de trabajo no es simetrico.
    // Esta generacion de reloj es un modelo orientado a simulacion.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            edge_countdown <= 0;
            clk_mem <= 1'b1;
        end else begin
            if (req_accept) begin
                edge_countdown <= FIRST_EDGE_DELAY;
                clk_mem <= 1'b0;
            end else if (cpu_state == CPU_ACTIVE) begin
                if (edge_countdown <= 1) begin
                    edge_countdown <= MEM_DIV;
                    clk_mem <= 1'b1;
                end else begin
                    edge_countdown <= edge_countdown - 1'b1;
                    clk_mem <= 1'b0;
                end
            end else begin
                clk_mem <= 1'b0;
            end
        end
    end

    // Sincroniza la solicitud hacia el dominio de memoria.
    // req_toggle cambia cada vez que comienza una solicitud o reintento.
    always @(posedge clk_mem or posedge reset) begin
        if (reset) begin
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;
        end
    end

    // Sincroniza la confirmacion hacia el dominio del procesador.
    // La confirmacion queda disponible para observacion y diagnostico.
    // La respuesta temporizada no espera este sincronizador.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            done_sync1 <= 1'b0;
            done_sync2 <= 1'b0;
        end else begin
            done_sync1 <= done_toggle;
            done_sync2 <= done_sync1;
        end
    end

    // Controla el acceso a las palabras de memoria.
    // La solicitud se reconoce despues de atravesar el sincronizador.
    // Luego se espera hasta el flanco anterior a la primera palabra.
    // La primera palabra se transfiere exactamente en el ciclo 25.
    // Cada palabra posterior se transfiere en un nuevo flanco lento.
    always @(posedge clk_mem or posedge reset) begin
        if (reset) begin
            mem_state <= MEM_IDLE;
            req_seen <= 1'b0;
            done_toggle <= 1'b0;
            word_index <= 3'd0;
            wait_left <= 0;
            read_line_mem <= 256'd0;
        end else if (!mem_hold) begin
            case (mem_state)

                MEM_IDLE: begin
                    if (req_sync2 != req_seen) begin
                        req_seen <= req_sync2;
                        word_index <= 3'd0;
                        wait_left <= WAIT_EDGES;
                        read_line_mem <= 256'd0;
                        mem_state <= MEM_WAIT;
                    end
                end

                MEM_WAIT: begin
                    if (req_sync2 != req_seen) begin
                        // Reinicia la espera si llega un nuevo intento.
                        req_seen <= req_sync2;
                        word_index <= 3'd0;
                        wait_left <= WAIT_EDGES;
                        read_line_mem <= 256'd0;
                    end else if (wait_left <= 1) begin
                        // El proximo flanco transferira la primera palabra.
                        wait_left <= 0;
                        mem_state <= MEM_BURST;
                    end else begin
                        wait_left <= wait_left - 1'b1;
                    end
                end

                MEM_BURST: begin
                    if (req_sync2 != req_seen) begin
                        // Cancela el burst anterior si llega un reintento.
                        req_seen <= req_sync2;
                        word_index <= 3'd0;
                        wait_left <= WAIT_EDGES;
                        read_line_mem <= 256'd0;
                        mem_state <= MEM_WAIT;
                    end else begin

                        // En una lectura se registra una palabra de RAM.
                        // En una escritura la RAM utiliza mem_word_we.
                        if (!we_saved) begin
                            read_line_mem[word_index * 32 +: 32]
                                <= mem_word_rdata;
                        end

                        if (word_index == 3'd7) begin
                            // La octava palabra completa la transferencia.
                            word_index <= 3'd0;
                            done_toggle <= ~done_toggle;
                            mem_state <= MEM_IDLE;
                        end else begin
                            word_index <= word_index + 1'b1;
                        end
                    end
                end

                default: begin
                    mem_state <= MEM_IDLE;
                end

            endcase
        end
    end

    // Controla la aceptacion, temporizacion y finalizacion.
    // El tiempo se mide en ciclos del procesador.
    // La solicitud permanece almacenada durante toda la operacion.
    // ram_ready es un pulso de un ciclo.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            cpu_state <= CPU_IDLE;
            elapsed <= 0;
            retry_used <= 1'b0;

            addr_saved <= 32'd0;
            wline_saved <= 256'd0;
            we_saved <= 1'b0;

            req_toggle <= 1'b0;

            ram_ready <= 1'b0;
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
                        // Guarda la solicitud antes de iniciar el acceso.
                        addr_saved <= {ram_addr[31:5], 5'b0};
                        wline_saved <= ram_wline;
                        we_saved <= ram_we;

                        // Cambia el toggle para iniciar la transferencia.
                        req_toggle <= ~req_toggle;

                        elapsed <= 0;
                        retry_used <= 1'b0;

                        cpu_state <= CPU_ACTIVE;
                    end
                end

                CPU_ACTIVE: begin
                    elapsed <= elapsed + 1'b1;

                    // El modelo entrega la linea en el ciclo TMEM.
                    // El ultimo flanco de memoria ocurre en este ciclo.
                    // La linea de lectura se actualiza desde clk_mem.
                    if ((elapsed >= TMEM - 1) && !mem_hold) begin
                        ram_ready <= 1'b1;
                        cpu_state <= CPU_RELEASE;
                    end

                    // Si no existe respuesta, se controla el timeout.
                    else if (elapsed >= MEM_TIMEOUT - 1) begin
                        timeout_event <= 1'b1;

                        if (!retry_used) begin
                            // Se permite exactamente un reintento.
                            retry_used <= 1'b1;
                            elapsed <= 0;

                            // Se mantiene la direccion y la linea guardada.
                            // Solamente se vuelve a emitir la solicitud.
                            req_toggle <= ~req_toggle;
                        end else begin
                            // El segundo timeout termina con un error.
                            mem_error <= 1'b1;
                            error_event <= 1'b1;
                            cpu_state <= CPU_RELEASE;
                        end
                    end
                end

                CPU_RELEASE: begin
                    // No aceptar otra solicitud hasta que ram_req baje.
                    if (!ram_req)
                        cpu_state <= CPU_IDLE;
                end

                default: begin
                    cpu_state <= CPU_IDLE;
                end

            endcase
        end
    end

endmodule

`default_nettype wire