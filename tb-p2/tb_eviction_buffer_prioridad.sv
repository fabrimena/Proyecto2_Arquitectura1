`timescale 1ns/1ps
`default_nettype none

// Verifica la prioridad de lecturas y el manejo de errores
// del eviction buffer.
//
// Prueba 1:
// Una lectura pendiente debe atenderse antes del siguiente
// drenado, sin interrumpir una escritura ya iniciada.
//
// Prueba 2:
// Una lectura que falla debe terminar con una indicacion
// de error y no debe repetirse indefinidamente.
//
// La segunda prueba permite detectar una limitacion
// conocida de la implementacion actual.

module tb_eviction_buffer_prioridad;

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

    integer cycles;
    integer error_count;

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

    // Avanza un ciclo y espera las actualizaciones secuenciales.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Inserta una linea sucia en el buffer.
    task enqueue;
        input [31:0] address_value;
        input [255:0] line_value;

        begin
            @(negedge clk);

            evict_addr = address_value;
            evict_line = line_value;
            evict_valid = 1'b1;

            #1;

            if (!evict_ready) begin
                $display("[FAIL] No hay espacio en la FIFO");
                $fatal(1);
            end

            tick();

            @(negedge clk);
            evict_valid = 1'b0;
        end
    endtask

    // Aplica reset sin introducir carreras de simulacion.
    task reset_dut;
        begin
            @(negedge clk);

            reset = 1'b1;
            evict_valid = 1'b0;
            read_req = 1'b0;
            ram_ready = 1'b0;
            ram_error = 1'b0;

            repeat (3) tick();

            @(negedge clk);
            reset = 1'b0;

            tick();
        end
    endtask

    // Espera una solicitud hacia RAM con el tipo indicado.
    // El limite evita que la simulacion quede bloqueada.
    task wait_ram_request;
        input expected_we;

        begin
            cycles = 0;

            while (!(ram_req && ram_we == expected_we)) begin
                tick();

                cycles = cycles + 1;

                if (cycles > 100) begin
                    $display(
                        "[FAIL] No aparece solicitud RAM, we=%0d",
                        expected_we
                    );
                    $fatal(1);
                end
            end
        end
    endtask

    initial begin

        // Inicializar el buffer.
        reset_dut();

        // Insertar dos lineas sucias.
        enqueue(
            32'h00000100,
            {8{32'h11111111}}
        );

        enqueue(
            32'h00000120,
            {8{32'h22222222}}
        );

        // Esperar el inicio de la primera escritura.
        wait_ram_request(1'b1);

        if (ram_addr !== 32'h00000100) begin
            $display("[FAIL] Primera escritura incorrecta");
            $fatal(1);
        end

        // Solicitar una lectura de una linea que no esta
        // almacenada en el eviction buffer.
        //
        // La escritura actual debe continuar.
        // La lectura debe quedar pendiente.
        @(negedge clk);

        read_addr = 32'h00000800;
        read_req = 1'b1;

        tick();

        if (!ram_req || !ram_we) begin
            $display("[FAIL] Se interrumpio una escritura activa");
            $fatal(1);
        end

        // Retirar la solicitud de lectura.
        // El buffer ya debe haberla registrado.
        @(negedge clk);
        read_req = 1'b0;

        // Finalizar la escritura que estaba en curso.
        ram_ready = 1'b1;

        tick();

        if (occupancy !== 1) begin
            $display("[FAIL] No se retiro la primera victima");
            $fatal(1);
        end

        @(negedge clk);
        ram_ready = 1'b0;

        // Antes de comenzar la segunda escritura,
        // el buffer debe seleccionar la lectura pendiente.
        wait_ram_request(1'b0);

        if (ram_addr !== 32'h00000800) begin
            $display("[FAIL] La lectura no tuvo prioridad");
            $fatal(1);
        end

        $display("[PASS] Prioridad de lectura sobre drenado");

        // Simular la respuesta correcta de RAM.
        @(negedge clk);

        ram_rline = {8{32'hAABBCCDD}};
        ram_ready = 1'b1;

        tick();

        if (!read_ready ||
            read_forwarded ||
            read_line !== {8{32'hAABBCCDD}}) begin

            $display("[FAIL] Respuesta de lectura incorrecta");
            $fatal(1);
        end

        $display("[PASS] Lectura completada desde RAM");

        @(negedge clk);
        ram_ready = 1'b0;

        // Reiniciar antes de verificar el manejo de errores.
        reset_dut();

        // Solicitar una lectura que no puede resolverse
        // mediante forwarding.
        @(negedge clk);

        read_addr = 32'h00000A00;
        read_req = 1'b1;

        tick();

        @(negedge clk);
        read_req = 1'b0;

        wait_ram_request(1'b0);

        // Simular un error definitivo del controlador RAM.
        // En esta interfaz ram_error representa el error
        // despues de agotar los reintentos del controlador.
        @(negedge clk);
        ram_error = 1'b1;

        tick();

        if (!ev_error) begin
            $display("[FAIL] No se reporto el error de RAM");
            $fatal(1);
        end

        $display("[PASS] Deteccion de error de RAM");

        @(negedge clk);
        ram_error = 1'b0;

        // Observar si el buffer vuelve a solicitar la misma
        // lectura sin que L2 haya emitido otra solicitud.
        error_count = 0;

        repeat (10) begin
            tick();

            if (ram_req && !ram_we)
                error_count = error_count + 1;
        end

        // Una lectura que termino con error no debe
        // permanecer pendiente ni repetirse automaticamente.
        if (error_count != 0) begin
            $display(
                "[FAIL] Lectura repetida despues de error: %0d ciclos",
                error_count
            );

            $fatal(1);
        end

        $display("[PASS] Lectura no se repite despues del error");

        $display("[PASS] tb_eviction_buffer_prioridad");
        $finish;
    end

    // Limite de seguridad de la simulacion.
    initial begin
        #100000;

        $display("[FAIL] Timeout general");
        $fatal(1);
    end

endmodule

`default_nettype wire