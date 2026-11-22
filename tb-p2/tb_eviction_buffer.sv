`timescale 1ns/1ps
`default_nettype none

// Testbench del eviction buffer.
// Comprueba almacenamiento, orden FIFO, forwarding
// y acceso al controlador de memoria principal.

module tb_eviction_buffer;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;

    reg evict_valid = 1'b0;
    reg [31:0] evict_addr = 32'd0;
    reg [255:0] evict_line = 256'd0;
    wire evict_ready;

    reg read_req = 1'b0;
    reg [31:0] read_addr = 32'd0;
    wire read_ready;
    wire [255:0] read_line;
    wire read_forwarded;

    wire ram_req;
    wire ram_we;
    wire [31:0] ram_addr;
    wire [255:0] ram_wline;

    reg ram_ready = 1'b0;
    reg [255:0] ram_rline = 256'd0;
    reg ram_error = 1'b0;

    wire empty;
    wire full;
    wire busy;
    wire [31:0] occupancy;

    wire ev_push;
    wire ev_pop;
    wire ev_forward;
    wire ev_error;

    eviction_buffer #(
        .EB_DEPTH(4)
    ) DUT (
        .clk(clk),
        .reset(reset),

        // Mantener desactivada la recuperacion en estas pruebas.
        .clear_write_error(1'b0),

        // Esta salida no se utiliza en las pruebas anteriores.
        .write_error_blocked(),

        .evict_valid(evict_valid),
        .evict_addr(evict_addr),
        .evict_line(evict_line),
        .evict_ready(evict_ready),

        .read_req(read_req),
        .read_addr(read_addr),
        .read_ready(read_ready),
        .read_line(read_line),
        .read_forwarded(read_forwarded),

        .ram_req(ram_req),
        .ram_we(ram_we),
        .ram_addr(ram_addr),
        .ram_wline(ram_wline),
        .ram_ready(ram_ready),
        .ram_rline(ram_rline),
        .ram_error(ram_error),

        .empty(empty),
        .full(full),
        .busy(busy),
        .occupancy(occupancy),

        .ev_push(ev_push),
        .ev_pop(ev_pop),
        .ev_forward(ev_forward),
        .ev_error(ev_error)
    );

    // Insertar una linea sucia en la FIFO.
    task enqueue;
        input [31:0] addr;
        input [255:0] line_data;

        begin
            @(negedge clk);
            evict_addr = addr;
            evict_line = line_data;
            evict_valid = 1'b1;

            if (!evict_ready)
                $fatal(1, "No hay espacio para insertar");

            @(posedge clk);
            #1;

            @(negedge clk);
            evict_valid = 1'b0;
        end
    endtask

    initial begin

        // Inicializar el modulo.
        repeat (3) @(posedge clk);
        #1;
        reset = 1'b0;

        // Verificar que la FIFO comienza vacia.
        if (!empty || occupancy != 0)
            $fatal(1, "FIFO no comienza vacia");

        // Insertar cuatro lineas con direcciones diferentes.
        enqueue(32'h00000100, {8{32'h11111111}});
        enqueue(32'h00000120, {8{32'h22222222}});
        enqueue(32'h00000140, {8{32'h33333333}});
        enqueue(32'h00000160, {8{32'h44444444}});

        // Verificar que la FIFO esta llena.
        if (!full || occupancy != 4)
            $fatal(1, "FIFO no reporta estado lleno");

        $display("[PASS] FIFO llena con cuatro entradas");

        // Solicitar una linea que continua pendiente.
        @(negedge clk);
        read_addr = 32'h00000140;
        read_req = 1'b1;

        @(posedge clk);
        #1;

        // La lectura debe resolverse mediante forwarding.
        if (!read_ready ||
            !read_forwarded ||
            read_line !== {8{32'h33333333}}) begin

            $fatal(1, "Forwarding incorrecto");
        end

        $display("[PASS] Forwarding de linea completa");

        @(negedge clk);
        read_req = 1'b0;

        // Comprobar que el drenado comienza con la linea
        // mas antigua de la FIFO.
        if (!ram_req ||
            !ram_we ||
            ram_addr !== 32'h00000100 ||
            ram_wline !== {8{32'h11111111}}) begin

            $fatal(1, "Orden FIFO incorrecto");
        end

        $display("[PASS] Orden FIFO correcto");

        // Simular la finalizacion de la primera escritura.
        ram_ready = 1'b1;

        @(posedge clk);
        #1;

        if (occupancy != 3)
            $fatal(1, "La FIFO no retiro la linea escrita");

        @(negedge clk);
        ram_ready = 1'b0;

        $display("[PASS] Drenado de primera entrada");

        // Esperar a que el controlador quede libre.
        repeat (2) @(posedge clk);
        #1;

        // Finalizar correctamente la simulacion.
        $display("[PASS] tb_eviction_buffer");
        $finish;
    end

endmodule

`default_nettype wire