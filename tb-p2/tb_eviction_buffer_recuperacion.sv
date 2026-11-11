`timescale 1ns/1ps
`default_nettype none

// Verifica la recuperacion del eviction buffer despues
// de un error definitivo de escritura hacia RAM.
//
// La prueba comprueba que el buffer conserva la linea,
// suspende los drenados, permite forwarding durante
// el bloqueo y reanuda la escritura cuando recibe
// clear_write_error.
//
// La linea solamente debe eliminarse cuando RAM
// confirma que la escritura termino correctamente.

module tb_eviction_buffer_recuperacion;

    reg clk = 1'b0;

    always #5 clk = ~clk;

    reg reset = 1'b1;

    // Control de recuperacion desde la logica superior.
    reg clear_write_error = 1'b0;

    // Interfaz para recibir lineas sucias.
    reg evict_valid = 1'b0;
    reg [31:0] evict_addr = 32'd0;
    reg [255:0] evict_line = 256'd0;

    wire evict_ready;

    // Interfaz de lectura para comprobar forwarding.
    reg read_req = 1'b0;
    reg [31:0] read_addr = 32'd0;

    wire read_ready;
    wire [255:0] read_line;
    wire read_forwarded;

    // Interfaz hacia la RAM simulada.
    wire ram_req;
    wire ram_we;
    wire [31:0] ram_addr;
    wire [255:0] ram_wline;

    reg ram_ready = 1'b0;
    reg [255:0] ram_rline = 256'd0;
    reg ram_error = 1'b0;

    // Senales de estado del buffer.
    wire empty;
    wire full;
    wire busy;
    wire [31:0] occupancy;
    wire write_error_blocked;

    // Eventos del buffer.
    wire ev_push;
    wire ev_pop;
    wire ev_forward;
    wire ev_error;

    // Datos de la linea utilizada durante la prueba.
    reg [31:0] test_addr;
    reg [255:0] test_line;

    integer cycles;

    eviction_buffer #(
        .EB_DEPTH(4)
    ) DUT (
        .clk(clk),
        .reset(reset),

        .clear_write_error(clear_write_error),

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
        .write_error_blocked(write_error_blocked),

        .ev_push(ev_push),
        .ev_pop(ev_pop),
        .ev_forward(ev_forward),
        .ev_error(ev_error)
    );

    // Esperar un flanco positivo y permitir que
    // los registros del modulo se actualicen.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Esperar una solicitud de escritura hacia RAM.
    // Se utiliza un limite para detectar bloqueos.
    task wait_write_request;
        integer timeout_cycles;

        begin
            timeout_cycles = 0;

            while (!(ram_req && ram_we)) begin

                tick();

                timeout_cycles = timeout_cycles + 1;

                if (timeout_cycles > 100) begin

                    $display(
                        "[FAIL] No se inicio la escritura hacia RAM"
                    );

                    $fatal(1);
                end
            end
        end
    endtask

    initial begin

        // Preparar una direccion alineada a 32 bytes.
        test_addr = 32'h00000400;

        // Preparar una linea completa de 256 bits.
        test_line = {
            32'hAABBCCDD,
            32'h11223344,
            32'h55667788,
            32'h99AABBCC,
            32'hDEADBEEF,
            32'hCAFEBABE,
            32'h12345678,
            32'h87654321
        };

        // Aplicar reset inicial.
        repeat (3) tick();

        @(negedge clk);
        reset = 1'b0;

        tick();

        // Verificar que el buffer inicia vacio
        // y sin un bloqueo por error.
        if (!empty ||
            occupancy !== 0 ||
            write_error_blocked) begin

            $display("[FAIL] Estado inicial incorrecto");
            $fatal(1);
        end

        // Insertar una linea sucia en el eviction buffer.
        @(negedge clk);

        evict_valid = 1'b1;
        evict_addr = test_addr;
        evict_line = test_line;

        #1;

        if (!evict_ready) begin
            $display("[FAIL] No se puede insertar la linea");
            $fatal(1);
        end

        tick();

        @(negedge clk);
        evict_valid = 1'b0;

        // La linea debe permanecer almacenada.
        if (empty || occupancy !== 1) begin
            $display("[FAIL] La linea no quedo almacenada");
            $fatal(1);
        end

        $display("[PASS] Linea almacenada inicialmente");

        // Esperar a que comience el primer drenado.
        wait_write_request();

        // Comprobar que RAM recibe la linea correcta.
        if (ram_addr !== test_addr ||
            ram_wline !== test_line) begin

            $display("[FAIL] Primera escritura incorrecta");
            $fatal(1);
        end

        $display("[PASS] Primera solicitud de escritura");

        // Simular un error definitivo de escritura.
        // El controlador ya habria agotado sus reintentos.
        @(negedge clk);

        ram_error = 1'b1;
        ram_ready = 1'b0;

        tick();

        // Comprobar que el buffer detecto el error.
        if (!ev_error || !write_error_blocked) begin

            $display(
                "[FAIL] No se activo el bloqueo por error"
            );

            $fatal(1);
        end

        $display("[PASS] Bloqueo activado por error");

        // Retirar la indicacion de error.
        @(negedge clk);
        ram_error = 1'b0;

        // Comprobar que los datos no fueron eliminados.
        if (empty || occupancy !== 1) begin

            $display(
                "[FAIL] Se perdio la linea durante el error"
            );

            $fatal(1);
        end

        if (ev_pop) begin

            $display(
                "[FAIL] Se retiro la linea sin escritura exitosa"
            );

            $fatal(1);
        end

        $display("[PASS] Linea conservada despues del error");

        // Mantener la recuperacion desactivada.
        // No deben producirse nuevos drenados.
        repeat (10) begin

            tick();

            if (ram_req && ram_we) begin

                $display(
                    "[FAIL] Escritura reiniciada sin autorizacion"
                );

                $fatal(1);
            end

            if (!write_error_blocked || occupancy !== 1) begin

                $display(
                    "[FAIL] El buffer cambio durante el bloqueo"
                );

                $fatal(1);
            end
        end

        $display("[PASS] Drenados suspendidos");

        // Solicitar una lectura de la misma linea.
        // El buffer debe responder mediante forwarding,
        // aunque las escrituras hacia RAM esten bloqueadas.
        @(negedge clk);

        read_addr = test_addr;
        read_req = 1'b1;

        tick();

        if (!read_ready ||
            !read_forwarded ||
            read_line !== test_line) begin

            $display(
                "[FAIL] Forwarding durante el bloqueo"
            );

            $fatal(1);
        end

        $display("[PASS] Forwarding durante el bloqueo");

        // Retirar la solicitud de lectura.
        @(negedge clk);
        read_req = 1'b0;

        // Dar tiempo para finalizar el pulso de lectura.
        repeat (2) tick();

        // Autorizar la recuperacion durante un ciclo.
        // No se aplica reset para conservar la FIFO.
        @(negedge clk);
        clear_write_error = 1'b1;

        tick();

        // El registro de bloqueo debe quedar limpio.
        if (write_error_blocked) begin

            $display(
                "[FAIL] No se libero el bloqueo"
            );

            $fatal(1);
        end

        // La linea debe continuar almacenada.
        if (empty || occupancy !== 1) begin

            $display(
                "[FAIL] La recuperacion elimino la linea"
            );

            $fatal(1);
        end

        $display("[PASS] Recuperacion autorizada");

        // Finalizar el pulso de recuperacion.
        @(negedge clk);
        clear_write_error = 1'b0;

        // El buffer debe reanudar el drenado.
        wait_write_request();

        // Confirmar que se recupera exactamente
        // la misma direccion y linea de datos.
        if (ram_addr !== test_addr ||
            ram_wline !== test_line) begin

            $display(
                "[FAIL] Datos incorrectos despues de recuperar"
            );

            $fatal(1);
        end

        $display("[PASS] Escritura reanudada correctamente");

        // Antes de confirmar la escritura, la linea
        // debe continuar almacenada.
        if (occupancy !== 1 || empty) begin

            $display(
                "[FAIL] Linea retirada antes de ram_ready"
            );

            $fatal(1);
        end

        // Simular que RAM completo la escritura.
        @(negedge clk);

        ram_ready = 1'b1;
        ram_error = 1'b0;

        tick();

        // La confirmacion exitosa debe retirar la linea.
        if (!ev_pop) begin

            $display(
                "[FAIL] No se registro el drenado exitoso"
            );

            $fatal(1);
        end

        if (!empty || occupancy !== 0) begin

            $display(
                "[FAIL] La FIFO no quedo vacia"
            );

            $fatal(1);
        end

        $display("[PASS] Linea retirada despues de ram_ready");

        // Retirar la respuesta de RAM.
        @(negedge clk);
        ram_ready = 1'b0;

        // Comprobar que no quedan solicitudes pendientes.
        repeat (5) begin

            tick();

            if (ram_req) begin

                $display(
                    "[FAIL] Solicitud inesperada despues del drenado"
                );

                $fatal(1);
            end
        end

        if (!empty ||
            occupancy !== 0 ||
            write_error_blocked) begin

            $display("[FAIL] Estado final incorrecto");
            $fatal(1);
        end

        $display("[PASS] Estado final correcto");

        $display(
            "[PASS] tb_eviction_buffer_recuperacion"
        );

        $finish;
    end

    // Evitar que la simulacion quede bloqueada.
    initial begin

        #100000;

        $display("[FAIL] Timeout general del testbench");

        $fatal(1);
    end

endmodule

`default_nettype wire