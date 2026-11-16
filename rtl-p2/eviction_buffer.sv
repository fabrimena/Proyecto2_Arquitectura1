`timescale 1ns/1ps
`default_nettype none

// Eviction buffer entre la cache L2 y la memoria principal.
// Almacena lineas sucias desalojadas por L2.
// Las entradas se atienden en orden FIFO.
// Las lecturas tienen prioridad sobre nuevos drenados.
// Si una lectura coincide con una linea pendiente,
// se devuelve la version mas reciente mediante forwarding.
// Las lineas se mantienen en el buffer hasta que RAM
// confirma que la escritura termino correctamente.

module eviction_buffer #(
    parameter integer EB_DEPTH = 4
) (
    input wire clk,
    input wire reset,

    // Interfaz para recibir victimas sucias de L2.
    input wire evict_valid,
    input wire [31:0] evict_addr,
    input wire [255:0] evict_line,
    output wire evict_ready,

    // Interfaz para solicitudes de lectura de L2.
    input wire read_req,
    input wire [31:0] read_addr,
    output reg read_ready,
    output reg [255:0] read_line,
    output reg read_forwarded,

    // Interfaz hacia el controlador de memoria principal.
    output wire ram_req,
    output wire ram_we,
    output wire [31:0] ram_addr,
    output wire [255:0] ram_wline,
    input wire ram_ready,
    input wire [255:0] ram_rline,
    input wire ram_error,

    // Autoriza reanudar los drenados despues de un error.
    // Debe activarse durante un ciclo cuando RAM este disponible.
    input wire clear_write_error,

    // Señales de estado para integracion y vaciado.
    output wire empty,
    output wire full,
    output wire busy,
    output wire [31:0] occupancy,

    // Indica que los drenados estan suspendidos por un error.
    output wire write_error_blocked,

    // Eventos para depuracion y metricas.
    output reg ev_push,
    output reg ev_pop,
    output reg ev_forward,
    output reg ev_error
);

    localparam integer PTR_W = (EB_DEPTH > 1) ? $clog2(EB_DEPTH) : 1;

    localparam [1:0] MEM_IDLE  = 2'd0;
    localparam [1:0] MEM_WRITE = 2'd1;
    localparam [1:0] MEM_READ  = 2'd2;

    reg [1:0] mem_state;

    // Indica que una escritura fallo definitivamente.
    // Mientras este activo, no se inician nuevos drenados.
    // Las lineas pendientes permanecen almacenadas.
    reg write_error_hold;

    // Exponer el estado de bloqueo a la logica de integracion.
    assign write_error_blocked = write_error_hold;

    // Almacenamiento de las direcciones y lineas pendientes.
    reg [31:0] fifo_addr [0:EB_DEPTH-1];
    reg [255:0] fifo_line [0:EB_DEPTH-1];

    // Punteros de entrada y salida de la FIFO.
    reg [PTR_W-1:0] head;
    reg [PTR_W-1:0] tail;

    // Cantidad de entradas almacenadas.
    reg [31:0] count;

    // Lectura pendiente de ser enviada a memoria.
    reg read_pending;
    reg read_busy;
    reg [31:0] saved_read_addr;

    // Resultado de la busqueda de forwarding.
    reg forward_hit;
    reg [255:0] forward_line;

    // Señales internas para modificar la FIFO.
    wire push;
    wire pop;

    integer i;
    integer search_index;

    // Verificar que la profundidad cumpla el enunciado.
    initial begin
        if (EB_DEPTH < 4 || EB_DEPTH > 16)
            $fatal(1, "EB_DEPTH debe estar entre 4 y 16");
    end

    // Avanzar un puntero y regresar al inicio al llegar al final.
    function [PTR_W-1:0] next_ptr;
        input [PTR_W-1:0] ptr;

        begin
            if (ptr == EB_DEPTH - 1)
                next_ptr = {PTR_W{1'b0}};
            else
                next_ptr = ptr + 1'b1;
        end
    endfunction

    // Indicar el estado de ocupacion de la FIFO.
    assign empty = (count == 0);
    assign full = (count == EB_DEPTH);
    assign occupancy = count;

    // La L2 puede ingresar una nueva linea si existe espacio.
    assign evict_ready = !full;

    // Una entrada se acepta cuando valid y ready estan activos.
    assign push = evict_valid && evict_ready;

    // La cabeza se elimina solamente despues de una
    // confirmacion exitosa de escritura desde memoria.
    assign pop =
        (mem_state == MEM_WRITE) &&
        ram_ready &&
        !ram_error;

    // La memoria recibe una solicitud mientras existe una
    // transferencia activa de lectura o escritura.
    assign ram_req =
        (mem_state == MEM_WRITE) ||
        (mem_state == MEM_READ);

    // MEM_WRITE representa el drenado de una linea sucia.
    assign ram_we = (mem_state == MEM_WRITE);

    // Seleccionar la direccion de la operacion actual.
    assign ram_addr =
        (mem_state == MEM_WRITE) ?
        fifo_addr[head] : saved_read_addr;

    // Entregar la linea completa para escritura.
    assign ram_wline = fifo_line[head];

    // El buffer esta ocupado si existen datos pendientes
    // o una operacion de memoria en progreso.
    assign busy =
        !empty ||
        read_pending ||
        (mem_state != MEM_IDLE);

    // Buscar si la direccion solicitada existe en la FIFO.
    // Se recorren las entradas desde la mas antigua.
    // Si hay varias coincidencias, gana la mas reciente.
    // La cabeza sigue disponible durante su escritura a RAM.
    always @* begin
        forward_hit = 1'b0;
        forward_line = 256'd0;

        search_index = 0;

        for (integer k = 0; k < EB_DEPTH; k = k + 1) begin
            if (k < count) begin
                search_index = head + k;

                if (search_index >= EB_DEPTH)
                    search_index = search_index - EB_DEPTH;

                if (fifo_addr[search_index] ==
                    {read_addr[31:5], 5'b0}) begin

                    forward_hit = 1'b1;
                    forward_line = fifo_line[search_index];
                end
            end
        end
    end

    // Administrar las entradas de la FIFO.
    // Se permite insertar y retirar una linea en el mismo ciclo.
    // Cuando el buffer esta lleno, se espera hasta liberar espacio.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            head <= {PTR_W{1'b0}};
            tail <= {PTR_W{1'b0}};
            count <= 0;

            ev_push <= 1'b0;
            ev_pop <= 1'b0;
        end else begin

            ev_push <= push;
            ev_pop <= pop;

            if (push) begin
                fifo_addr[tail] <= {evict_addr[31:5], 5'b0};
                fifo_line[tail] <= evict_line;
                tail <= next_ptr(tail);
            end

            if (pop) begin
                head <= next_ptr(head);
            end

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

    // Atender solicitudes de lectura de L2.
    // El forwarding puede responder incluso cuando
    // una escritura anterior sigue pendiente en RAM.
    // Si no hay coincidencia, se solicita la linea a memoria.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            read_pending <= 1'b0;
            read_busy <= 1'b0;
            saved_read_addr <= 32'd0;

            read_ready <= 1'b0;
            read_line <= 256'd0;
            read_forwarded <= 1'b0;

            ev_forward <= 1'b0;
        end else begin

            read_ready <= 1'b0;
            read_forwarded <= 1'b0;
            ev_forward <= 1'b0;

            // Permitir una nueva lectura cuando la solicitud
            // anterior ya fue retirada por el solicitante.
            if (!read_req &&
                !read_pending &&
                mem_state != MEM_READ) begin

                read_busy <= 1'b0;
            end

            // Capturar una nueva lectura.
            if (read_req &&
                !read_busy &&
                !read_pending &&
                mem_state != MEM_READ) begin

                read_busy <= 1'b1;

                if (forward_hit) begin

                    // Resolver RAW utilizando la linea pendiente.
                    read_line <= forward_line;
                    read_ready <= 1'b1;
                    read_forwarded <= 1'b1;
                    ev_forward <= 1'b1;

                end else begin

                    // La linea no esta en el buffer.
                    // Guardar la solicitud para leer desde RAM.
                    saved_read_addr <=
                        {read_addr[31:5], 5'b0};

                    read_pending <= 1'b1;
                end
            end

            // Finalizar una lectura realizada desde RAM.
            // Una lectura exitosa entrega los datos recibidos.
            // Si ocurre un error, se cancela la solicitud pendiente.
            // Esto evita repetir indefinidamente una lectura fallida.
            if (mem_state == MEM_READ) begin

                if (ram_error) begin
                    // Cancelar la lectura que fallo.
                    // El error se reporta mediante ev_error.
                    // No se entregan datos validos a la L2.
                    read_pending <= 1'b0;
                    read_ready <= 1'b0;
                    read_forwarded <= 1'b0;

                end else if (ram_ready) begin
                    // La lectura termino correctamente.
                    read_line <= ram_rline;
                    read_ready <= 1'b1;
                    read_pending <= 1'b0;
                end
            end
            
        end
    end


    // Arbitrar el acceso al controlador de memoria.
    // Las lecturas pendientes tienen prioridad sobre
    // los nuevos drenados del eviction buffer.
    // Si una escritura falla definitivamente, se activa
    // un bloqueo para evitar reintentos automaticos.
    // Las lineas sucias permanecen almacenadas.
    // El bloqueo no impide atender solicitudes de lectura.
    // Esto permite realizar forwarding y lecturas de RAM
    // mientras se mantiene la informacion pendiente.

    always @(posedge clk or posedge reset) begin
        if (reset) begin

            mem_state <= MEM_IDLE;
            ev_error <= 1'b0;
            write_error_hold <= 1'b0;

        end else begin

        ev_error <= 1'b0;

        // Permitir la recuperacion solamente cuando no existe
        // una transferencia activa y RAM no mantiene una respuesta.
        // La solicitud de drenado comenzara en un ciclo posterior.
        if (clear_write_error &&
            write_error_hold &&
            mem_state == MEM_IDLE &&
            !ram_error &&
            !ram_ready) begin

            write_error_hold <= 1'b0;
        end

        case (mem_state)

                MEM_IDLE: begin

                    // Las lecturas pendientes tienen prioridad.
                    if (read_pending) begin

                        mem_state <= MEM_READ;

                    end else if (!read_req &&
                                !empty &&
                                !write_error_hold) begin

                        // Iniciar un drenado solamente cuando
                        // no existe un bloqueo por error.
                        mem_state <= MEM_WRITE;

                    end
                end

                MEM_WRITE: begin

                    if (ram_error) begin

                        // La escritura fallo definitivamente.
                        // Mantener la linea en la FIFO.
                        // Evitar nuevos intentos automaticos.
                        ev_error <= 1'b1;
                        write_error_hold <= 1'b1;
                        mem_state <= MEM_IDLE;

                    end else if (ram_ready) begin

                        // La escritura termino correctamente.
                        // La logica FIFO retirara la cabeza.
                        mem_state <= MEM_IDLE;

                    end
                end

                MEM_READ: begin

                    if (ram_error) begin

                        // Reportar el error definitivo de lectura.
                        // La logica de lectura cancela la solicitud.
                        ev_error <= 1'b1;
                        mem_state <= MEM_IDLE;

                    end else if (ram_ready) begin

                        // La lectura termino correctamente.
                        // La logica de lectura entrega los datos.
                        mem_state <= MEM_IDLE;

                    end
                end

                default: begin

                    mem_state <= MEM_IDLE;

                end

            endcase
        end
    end

endmodule

`default_nettype wire