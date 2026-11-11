`timescale 1ns/1ps
`default_nettype none

// Testbench de estres para el controlador de memoria principal.
// Verifica solicitudes consecutivas, diferentes fases del reloj,
// integridad de datos, timeout, reintento y recuperacion.
//
// La memoria contiene 16384 palabras de 32 bits.
// Las transferencias utilizan lineas completas de 256 bits.
//
// Las respuestas correctas deben provenir del handshake CDC.
// No se exige una latencia exacta de respuesta porque el reloj
// lento funciona continuamente y tiene una fase independiente.

module mem_controller_cdc_stress_case #(
    parameter integer MEM_DIV = 4
) (
    output reg finished
);

    localparam integer TMEM = 25 + 7 * MEM_DIV;
    localparam integer MEM_TIMEOUT = 256;

    // Generar el reloj del procesador de 100 MHz.
    reg clk = 1'b0;

    always #5 clk = ~clk;

    reg reset = 1'b1;

    // Interfaz de solicitudes del controlador.
    reg ram_req = 1'b0;
    reg ram_we = 1'b0;
    reg [31:0] ram_addr = 32'd0;
    reg [255:0] ram_wline = 256'd0;

    wire ram_ready;
    wire [255:0] ram_rline;
    wire mem_error;

    // Eventos y estado del controlador.
    wire req_accept;
    wire req_we_accepted;
    wire transfer_busy;

    wire timeout_event;
    wire error_event;

    // Control para detener temporalmente la memoria.
    reg mem_hold = 1'b0;

    // Interfaz fisica hacia la RAM simulada.
    wire clk_mem;
    wire [13:0] mem_word_addr;
    wire [31:0] mem_word_wdata;
    wire mem_word_we;
    wire [31:0] mem_word_rdata;

    // Memoria principal de 64 KB.
    reg [31:0] memory [0:16383];

    // Variables para generar y comprobar transacciones.
    reg [255:0] test_line;
    reg [255:0] expected_line;

    integer i;
    integer j;
    integer cycles;

    integer physical_writes;
    integer accepted_writes;
    integer accepted_reads;

    integer timeout_count;
    integer error_count;

    integer clock_edges;
    integer initial_edges;

    integer first_access_cycle;
    integer last_access_cycle;
    integer observed_words;

    reg transfer_observed;
    reg confirmed_this_request;

    // Instanciar el controlador real que se esta verificando.
    mem_controller #(
        .MEM_DIV(MEM_DIV),
        .MEM_TIMEOUT(MEM_TIMEOUT),
        .TMEM(TMEM)
    ) DUT (
        .clk(clk),
        .reset(reset),

        .ram_req(ram_req),
        .ram_we(ram_we),
        .ram_addr(ram_addr),
        .ram_wline(ram_wline),

        .ram_ready(ram_ready),
        .ram_rline(ram_rline),
        .mem_error(mem_error),

        .req_accept(req_accept),
        .req_we_accepted(req_we_accepted),
        .transfer_busy(transfer_busy),

        .timeout_event(timeout_event),
        .error_event(error_event),

        .mem_hold(mem_hold),

        .clk_mem(clk_mem),

        .mem_word_addr(mem_word_addr),
        .mem_word_wdata(mem_word_wdata),
        .mem_word_we(mem_word_we),
        .mem_word_rdata(mem_word_rdata)
    );

    // Modelar la lectura combinacional de la RAM.
    assign mem_word_rdata = memory[mem_word_addr];

    // Registrar escrituras fisicas en el reloj de memoria.
    always @(posedge clk_mem) begin

        if (!reset && mem_word_we) begin

            memory[mem_word_addr] <= mem_word_wdata;

            physical_writes = physical_writes + 1;
        end
    end

    // Contar los flancos del reloj lento.
    // Esto permite comprobar que sigue funcionando
    // incluso cuando no existen solicitudes.
    always @(posedge clk_mem) begin

        if (!reset)
            clock_edges = clock_edges + 1;
    end

    // Contar solicitudes aceptadas y eventos de error.
    always @(posedge clk) begin

        if (!reset) begin

            if (req_accept) begin

                if (req_we_accepted)
                    accepted_writes = accepted_writes + 1;
                else
                    accepted_reads = accepted_reads + 1;
            end

            if (timeout_event)
                timeout_count = timeout_count + 1;

            if (error_event)
                error_count = error_count + 1;
        end
    end

    // Verificar que cada respuesta de CPU este respaldada
    // por una confirmacion CDC de la solicitud vigente.
    //
    // Una confirmacion puede llegar antes de TMEM.
    // En ese caso se conserva hasta que CPU entregue
    // la respuesta mediante ram_ready.

    always @(posedge clk or posedge reset) begin

        if (reset) begin

            confirmed_this_request <= 1'b0;

        end else begin

            // Una solicitud nueva debe recibir su
            // propia confirmacion desde memoria.
            //
            // Un reintento tambien invalida la
            // confirmacion del intento anterior.
            if (req_accept || timeout_event) begin

                confirmed_this_request <= 1'b0;

            end else if ((DUT.done_sync2 != DUT.done_seen) &&
                        (DUT.done_id_sync2 == DUT.req_toggle)) begin

                // Registrar una confirmacion sincronizada
                // correspondiente al intento vigente.
                confirmed_this_request <= 1'b1;
            end

            // RAM no puede anunciar una respuesta correcta
            // si no existe una confirmacion CDC valida.
            if (ram_ready) begin

                if (!confirmed_this_request &&
                    !((DUT.done_sync2 != DUT.done_seen) &&
                    (DUT.done_id_sync2 == DUT.req_toggle))) begin

                    $display(
                        "[FAIL] DIV=%0d ram_ready sin confirmacion CDC",
                        MEM_DIV
                    );

                    $fatal(1);
                end

            end
        end
    end

    // Esperar un ciclo del procesador.
    task tick;

        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Generar ocho palabras distintas dentro de una linea.
    function [255:0] make_line;

        input [31:0] seed;

        integer word_number;

        begin

            make_line = 256'd0;

            for (word_number = 0;
                 word_number < 8;
                 word_number = word_number + 1) begin

                make_line[word_number*32 +: 32] =
                    seed + word_number;
            end
        end

    endfunction

    // Comprobar las ocho palabras almacenadas en RAM.
    task check_memory;

        input [31:0] address_value;
        input [255:0] line_value;

        integer base;
        integer word_number;

        begin

            base = address_value >> 2;

            for (word_number = 0;
                 word_number < 8;
                 word_number = word_number + 1) begin

                if (memory[base + word_number] !==
                    line_value[word_number*32 +: 32]) begin

                    $display(
                        "[FAIL] DIV=%0d datos RAM en palabra=%0d",
                        MEM_DIV,
                        word_number
                    );

                    $display(
                        "Esperado=%h recibido=%h",
                        line_value[word_number*32 +: 32],
                        memory[base + word_number]
                    );

                    $fatal(1);
                end
            end
        end

    endtask

    // Ejecutar una transaccion completa.
    // La solicitud permanece activa hasta la respuesta.
    // Se espera a que el controlador quede libre antes
    // de comenzar una nueva transferencia.
    task transaction;

        input operation_we;
        input [31:0] address_value;
        input [255:0] line_value;

        integer timeout_cycles;

        begin

            // Esperar a que termine la transaccion anterior.
            timeout_cycles = 0;

            while (DUT.cpu_state != 0) begin

                tick();

                timeout_cycles = timeout_cycles + 1;

                if (timeout_cycles > 100) begin

                    $display(
                        "[FAIL] DIV=%0d controlador no queda libre",
                        MEM_DIV
                    );

                    $fatal(1);
                end
            end

            // Presentar la nueva solicitud antes del flanco.
            @(negedge clk);

            ram_req = 1'b1;
            ram_we = operation_we;
            ram_addr = address_value;
            ram_wline = line_value;

            tick();

            timeout_cycles = 0;

            // Esperar una respuesta real del controlador.
            while (!ram_ready && !mem_error) begin

                tick();

                timeout_cycles = timeout_cycles + 1;

                if (timeout_cycles > MEM_TIMEOUT) begin

                    $display(
                        "[FAIL] DIV=%0d transaccion no termina",
                        MEM_DIV
                    );

                    $fatal(1);
                end
            end

            // Estas transacciones normales no deben fallar.
            if (!ram_ready || mem_error) begin

                $display(
                    "[FAIL] DIV=%0d error en transaccion normal",
                    MEM_DIV
                );

                $fatal(1);
            end

            // Verificar el contenido recibido en las lecturas.
            if (!operation_we &&
                ram_rline !== line_value) begin

                $display(
                    "[FAIL] DIV=%0d lectura incorrecta",
                    MEM_DIV
                );

                $display(
                    "Esperado=%h",
                    line_value
                );

                $display(
                    "Recibido=%h",
                    ram_rline
                );

                $fatal(1);
            end

            // Retirar la solicitud despues de la respuesta.
            @(negedge clk);

            ram_req = 1'b0;

            // Permitir que el controlador complete el
            // intercambio y vuelva a CPU_IDLE.
            repeat (4) tick();
        end

    endtask

    // Esperar hasta observar el numero indicado de timeouts.
    task wait_timeouts;

        input integer expected_timeouts;

        integer timeout_cycles;

        begin

            timeout_cycles = 0;

            while (timeout_count < expected_timeouts) begin

                tick();

                timeout_cycles = timeout_cycles + 1;

                if (timeout_cycles > 600) begin

                    $display(
                        "[FAIL] DIV=%0d no aparece timeout esperado",
                        MEM_DIV
                    );

                    $fatal(1);
                end
            end
        end

    endtask

    initial begin

        finished = 1'b0;

        physical_writes = 0;
        accepted_writes = 0;
        accepted_reads = 0;

        timeout_count = 0;
        error_count = 0;

        clock_edges = 0;
        initial_edges = 0;

        cycles = 0;
        first_access_cycle = -1;
        last_access_cycle = -1;
        observed_words = 0;
        transfer_observed = 1'b0;

        test_line = 256'd0;
        expected_line = 256'd0;

        // Inicializar todas las palabras de RAM.
        for (i = 0; i < 16384; i = i + 1)
            memory[i] = 32'hDEADBEEF;

        // Aplicar reset.
        repeat (5) tick();

        @(negedge clk);
        reset = 1'b0;

        repeat (5) tick();

        // Comprobar que el reloj lento funciona
        // continuamente incluso cuando CPU esta libre.
        initial_edges = clock_edges;

        repeat (MEM_DIV * 5) tick();

        if (clock_edges - initial_edges < 4) begin

            $display(
                "[FAIL] DIV=%0d reloj lento detenido en reposo",
                MEM_DIV
            );

            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d reloj de memoria continuo",
            MEM_DIV
        );

        // Ejecutar ocho escrituras y ocho lecturas.
        // Cada operacion utiliza una direccion diferente.
        // Las esperas variables cambian la fase de inicio.
        for (j = 0; j < 8; j = j + 1) begin

            test_line = make_line(32'hA0000000 + j * 32);

            // Cambiar la fase de llegada de la solicitud.
            repeat (j + 1) tick();

            transaction(
                1'b1,
                32'h00001000 + j * 32,
                test_line
            );

            check_memory(
                32'h00001000 + j * 32,
                test_line
            );

            // Cambiar nuevamente la fase antes de leer.
            repeat ((j % MEM_DIV) + 1) tick();

            transaction(
                1'b0,
                32'h00001000 + j * 32,
                test_line
            );
        end

        // Cada linea escrita contiene ocho palabras.
        if (physical_writes != 64) begin

            $display(
                "[FAIL] DIV=%0d escrituras fisicas=%0d esperado=64",
                MEM_DIV,
                physical_writes
            );

            $fatal(1);
        end

        if (accepted_writes != 8 ||
            accepted_reads != 8) begin

            $display(
                "[FAIL] DIV=%0d solicitudes aceptadas: W=%0d R=%0d",
                MEM_DIV,
                accepted_writes,
                accepted_reads
            );

            $fatal(1);
        end

        if (timeout_count != 0 || error_count != 0) begin

            $display(
                "[FAIL] DIV=%0d error inesperado en operaciones normales",
                MEM_DIV
            );

            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d solicitudes consecutivas y fases distintas",
            MEM_DIV
        );

        $display(
            "[PASS] DIV=%0d integridad de 16 transacciones",
            MEM_DIV
        );

        // Detener la RAM antes de iniciar una lectura.
        // Esto debe provocar el primer timeout.
        @(negedge clk);

        mem_hold = 1'b1;

        ram_req = 1'b1;
        ram_we = 1'b0;
        ram_addr = 32'h00001000;
        ram_wline = 256'd0;

        tick();

        // Esperar un timeout para activar el reintento.
        wait_timeouts(1);

        // El primer timeout no debe ser definitivo.
        if (mem_error || error_count != 0) begin

            $display(
                "[FAIL] DIV=%0d error definitivo prematuro",
                MEM_DIV
            );

            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d primer timeout genera reintento",
            MEM_DIV
        );

        // Liberar la memoria despues del primer timeout.
        // El reintento debe completar la lectura pendiente.
        @(negedge clk);

        mem_hold = 1'b0;

        cycles = 0;

        while (!ram_ready && !mem_error) begin

            tick();
            cycles = cycles + 1;

            if (cycles > MEM_TIMEOUT) begin

                $display(
                    "[FAIL] DIV=%0d reintento no termina",
                    MEM_DIV
                );

                $fatal(1);
            end
        end

        if (!ram_ready || mem_error) begin

            $display(
                "[FAIL] DIV=%0d fallo la recuperacion del reintento",
                MEM_DIV
            );

            $fatal(1);
        end

        expected_line = make_line(32'hA0000000);

        if (ram_rline !== expected_line) begin

            $display(
                "[FAIL] DIV=%0d datos incorrectos despues del reintento",
                MEM_DIV
            );

            $fatal(1);
        end

        @(negedge clk);
        ram_req = 1'b0;

        repeat (8) tick();

        if (timeout_count != 1 || error_count != 0) begin

            $display(
                "[FAIL] DIV=%0d cantidad incorrecta de reintentos",
                MEM_DIV
            );

            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d transferencia recuperada tras timeout",
            MEM_DIV
        );

        // Provocar un error definitivo deteniendo RAM
        // durante los dos intentos de una nueva solicitud.
        @(negedge clk);

        mem_hold = 1'b1;

        ram_req = 1'b1;
        ram_we = 1'b0;
        ram_addr = 32'h00001020;
        ram_wline = 256'd0;

        tick();

        cycles = 0;

        while (!mem_error) begin

            tick();

            cycles = cycles + 1;

            if (cycles > 530) begin

                $display(
                    "[FAIL] DIV=%0d no aparece error definitivo",
                    MEM_DIV
                );

                $fatal(1);
            end
        end

        // Esperar un ciclo adicional para que los contadores
        // registren los pulsos de timeout_event y error_event.
        //
        // El controlador genera mem_error y los eventos en el
        // mismo flanco. Los contadores los observan en el
        // siguiente flanco positivo del reloj.

        tick();

        // Comprobar que el error definitivo sigue activo
        // y que no se genero una respuesta exitosa.
        if (!mem_error || ram_ready) begin

            $display(
                "[FAIL] DIV=%0d estado incorrecto despues del timeout",
                MEM_DIV
            );

            $fatal(1);
        end

        // Comprobar los eventos una vez actualizados
        // los contadores del testbench.
        if (timeout_count != 3 || error_count != 1) begin

            $display(
                "[FAIL] DIV=%0d conteo incorrecto de timeout",
                MEM_DIV
            );

            $display(
                "timeouts=%0d errores=%0d",
                timeout_count,
                error_count
            );

            $fatal(1);
        end

        $display(
            "[PASS] DIV=%0d segundo timeout genera error definitivo",
            MEM_DIV
        );

        // Retirar la solicitud fallida.
        // La cancelacion debe cruzar al dominio RAM.
        @(negedge clk);

        ram_req = 1'b0;
        mem_hold = 1'b0;

        repeat (MEM_DIV * 6 + 8) tick();

        // Una confirmacion antigua no debe producir
        // una respuesta espontanea despues del error.
        repeat (10) begin

            tick();

            if (ram_ready) begin

                $display(
                    "[FAIL] DIV=%0d respuesta atrasada inesperada",
                    MEM_DIV
                );

                $fatal(1);
            end
        end

        // Comprobar que una lectura nueva funciona
        // despues de la cancelacion definitiva.
        expected_line = make_line(32'hA0000000 + 32);

        transaction(
            1'b0,
            32'h00001020,
            expected_line
        );

        $display(
            "[PASS] DIV=%0d operacion nueva despues de cancelacion",
            MEM_DIV
        );

        $display(
            "[PASS] DIV=%0d todas las pruebas de estres",
            MEM_DIV
        );

        finished = 1'b1;
    end

endmodule

// Ejecutar las pruebas con las tres configuraciones
// de frecuencia previstas para la memoria principal.
module tb_mem_controller_cdc_estres;

    wire done2;
    wire done4;
    wire done5;

    mem_controller_cdc_stress_case #(
        .MEM_DIV(2)
    ) case2 (
        .finished(done2)
    );

    mem_controller_cdc_stress_case #(
        .MEM_DIV(4)
    ) case4 (
        .finished(done4)
    );

    mem_controller_cdc_stress_case #(
        .MEM_DIV(5)
    ) case5 (
        .finished(done5)
    );

    // Finalizar cuando todas las configuraciones
    // terminen sus verificaciones correctamente.
    initial begin

        wait(done2 && done4 && done5);

        $display("[PASS] tb_mem_controller_cdc_estres");

        $finish;
    end

    // Evitar una simulacion bloqueada indefinidamente.
    initial begin

        #300000;

        $display("[FAIL] Timeout general del testbench CDC");

        $fatal(1);
    end

endmodule

`default_nettype wire