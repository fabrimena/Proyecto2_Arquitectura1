`timescale 1ns/1ps
`default_nettype none

// Verifica el comportamiento del eviction buffer
// cuando una escritura hacia RAM termina con error.
//
// Se comprueba que:
// El error se reporte correctamente.
// La linea sucia permanezca almacenada.
// La ocupacion de la FIFO no disminuya.
// Los datos y la direccion se conserven.
// No se produzcan reintentos automaticos indefinidos.
//
// ram_error representa un error definitivo informado
// por el controlador despues de agotar sus reintentos.

module tb_eviction_buffer_error_escritura;

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

    reg [31:0] test_addr;
    reg [255:0] test_line;

    integer cycles;
    integer retry_count;

    // Instanciar el eviction buffer con cuatro entradas.
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

    // Esperar un flanco positivo y permitir que
    // se actualicen los registros del modulo.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Esperar una solicitud de escritura hacia RAM.
    // Se incluye un limite para evitar ciclos infinitos.
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

        // Preparar una linea de prueba.
        test_addr = 32'h00000100;

        test_line = {
            32'h11111111,
            32'h22222222,
            32'h33333333,
            32'h44444444,
            32'h55555555,
            32'h66666666,
            32'h77777777,
            32'h88888888
        };

        // Inicializar el buffer.
        repeat (3) tick();

        @(negedge clk);
        reset = 1'b0;

        tick();

        // Comprobar que la FIFO inicia vacia.
        if (!empty || occupancy !== 0) begin
            $display("[FAIL] Estado inicial incorrecto");
            $fatal(1);
        end

        // Insertar una linea sucia.
        @(negedge clk);

        evict_addr = test_addr;
        evict_line = test_line;
        evict_valid = 1'b1;

        #1;

        if (!evict_ready) begin
            $display("[FAIL] No se puede insertar la linea");
            $fatal(1);
        end

        tick();

        @(negedge clk);
        evict_valid = 1'b0;

        // Verificar que la linea se almaceno.
        if (occupancy !== 1 || empty) begin
            $display("[FAIL] La linea no quedo almacenada");
            $fatal(1);
        end

        $display("[PASS] Linea sucia almacenada");

        // Esperar el inicio de la escritura.
        wait_write_request();

        // Verificar que se envia la direccion correcta.
        if (ram_addr !== test_addr) begin
            $display("[FAIL] Direccion de escritura incorrecta");
            $fatal(1);
        end

        // Verificar que se envian los 256 bits correctos.
        if (ram_wline !== test_line) begin
            $display("[FAIL] Datos de escritura incorrectos");
            $fatal(1);
        end

        $display("[PASS] Solicitud de escritura correcta");

        // Simular un error definitivo durante la escritura.
        // No se activa ram_ready porque RAM no confirmo exito.
        @(negedge clk);

        ram_error = 1'b1;
        ram_ready = 1'b0;

        tick();

        // El eviction buffer debe reportar el fallo.
        if (!ev_error) begin
            $display("[FAIL] No se reporto el error de escritura");
            $fatal(1);
        end

        $display("[PASS] Error de escritura detectado");

        // Retirar la indicacion de error.
        @(negedge clk);

        ram_error = 1'b0;

        // La escritura fallo, por lo tanto no debe
        // eliminarse la linea de la FIFO.
        if (occupancy !== 1 || empty) begin
            $display(
                "[FAIL] La FIFO perdio una linea despues del error"
            );

            $fatal(1);
        end

        if (ev_pop) begin
            $display(
                "[FAIL] Se retiro una linea despues del error"
            );

            $fatal(1);
        end

        $display("[PASS] Linea conservada despues del error");

        // Verificar la integridad de la linea almacenada.
        // La cabeza de la FIFO continua apuntando
        // a la entrada que no pudo escribirse.
        if (DUT.fifo_addr[DUT.head] !== test_addr) begin
            $display(
                "[FAIL] La direccion almacenada fue modificada"
            );

            $fatal(1);
        end

        if (DUT.fifo_line[DUT.head] !== test_line) begin
            $display(
                "[FAIL] Los datos almacenados fueron modificados"
            );

            $fatal(1);
        end

        $display("[PASS] Integridad de direccion y datos");

        // Observar el comportamiento despues del error.
        // Un error definitivo no debe generar nuevos
        // intentos de escritura sin una recuperacion explicita.
        retry_count = 0;

        repeat (20) begin

            tick();

            if (ram_req && ram_we) begin
                retry_count = retry_count + 1;
            end

            // Comprobar que la linea nunca desaparezca.
            if (occupancy !== 1) begin
                $display(
                    "[FAIL] La ocupacion cambio despues del error"
                );

                $fatal(1);
            end

            // Comprobar que los datos no se modifiquen.
            if (DUT.fifo_addr[DUT.head] !== test_addr ||
                DUT.fifo_line[DUT.head] !== test_line) begin

                $display(
                    "[FAIL] La linea se modifico despues del error"
                );

                $fatal(1);
            end
        end

        // La escritura no debe reiniciarse automaticamente
        // despues de un error definitivo.
        if (retry_count != 0) begin
            $display(
                "[FAIL] Escritura repetida despues del error: %0d ciclos",
                retry_count
            );

            $fatal(1);
        end

        $display(
            "[PASS] No hay reintentos automaticos despues del error"
        );

        // Confirmar el estado final del buffer.
        if (empty || occupancy !== 1) begin
            $display("[FAIL] Estado final incorrecto");
            $fatal(1);
        end

        $display("[PASS] Estado final correcto");

        $display(
            "[PASS] tb_eviction_buffer_error_escritura"
        );

        $finish;
    end

    // Limite de seguridad para finalizar
    // si una prueba queda bloqueada.
    initial begin

        #100000;

        $display("[FAIL] Timeout general del testbench");

        $fatal(1);
    end

endmodule

`default_nettype wire