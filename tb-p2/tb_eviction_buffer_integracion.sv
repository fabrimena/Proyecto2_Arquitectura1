`timescale 1ns/1ps
`default_nettype none

// Verifica la integracion del eviction buffer con el
// controlador real de memoria principal.
//
// La RAM simulada contiene 16384 palabras de 32 bits.
// El controlador utiliza un reloj de memoria derivado
// del reloj principal mediante MEM_DIV.
//
// Se verifican escrituras de lineas completas,
// lecturas desde RAM, forwarding y drenado posterior.
//
// Tambien se comprueba que cada linea genere
// exactamente ocho escrituras de palabra en RAM.

module tb_eviction_buffer_integracion;

    localparam integer MEM_DIV = 4;
    localparam integer MEM_TIMEOUT = 256;
    localparam integer TMEM = 25 + 7 * MEM_DIV;

    reg clk = 1'b0;

    always #5 clk = ~clk;

    reg reset = 1'b1;

    // Señal de recuperacion del eviction buffer.
    reg clear_write_error = 1'b0;

    // Señales de escritura desde la L2 simulada.
    reg evict_valid = 1'b0;
    reg [31:0] evict_addr = 32'd0;
    reg [255:0] evict_line = 256'd0;

    wire evict_ready;

    // Señales de lectura desde la L2 simulada.
    reg read_req = 1'b0;
    reg [31:0] read_addr = 32'd0;

    wire read_ready;
    wire [255:0] read_line;
    wire read_forwarded;

    // Señales compartidas entre el eviction buffer
    // y el controlador real de memoria.
    wire ram_req;
    wire ram_we;
    wire [31:0] ram_addr;
    wire [255:0] ram_wline;

    wire ram_ready;
    wire [255:0] ram_rline;
    wire ram_error;

    // Señales de estado del eviction buffer.
    wire empty;
    wire full;
    wire busy;
    wire [31:0] occupancy;
    wire write_error_blocked;

    wire ev_push;
    wire ev_pop;
    wire ev_forward;
    wire ev_error;

    // Señales adicionales del controlador.
    wire req_accept;
    wire req_we_accepted;
    wire transfer_busy;
    wire timeout_event;
    wire error_event;

    // Señales del puerto fisico de RAM.
    wire clk_mem;
    wire [13:0] mem_word_addr;
    wire [31:0] mem_word_wdata;
    wire mem_word_we;
    wire [31:0] mem_word_rdata;

    // Permite detener temporalmente el acceso a RAM.
    reg mem_hold = 1'b0;

    // RAM de 64 KB organizada como palabras de 32 bits.
    reg [31:0] memory [0:16383];

    // Direcciones alineadas a lineas de 32 bytes.
    localparam [31:0] ADDR_A = 32'h00000100;
    localparam [31:0] ADDR_B = 32'h00000200;

    // Dos lineas con ocho palabras diferentes.
    localparam [255:0] LINE_A = {
        32'hA0000007,
        32'hA0000006,
        32'hA0000005,
        32'hA0000004,
        32'hA0000003,
        32'hA0000002,
        32'hA0000001,
        32'hA0000000
    };

    localparam [255:0] LINE_B = {
        32'hB0000007,
        32'hB0000006,
        32'hB0000005,
        32'hB0000004,
        32'hB0000003,
        32'hB0000002,
        32'hB0000001,
        32'hB0000000
    };

    integer i;
    integer cycles;
    integer physical_writes;
    integer accepted_writes;
    integer accepted_reads;

    // Instanciar el eviction buffer real.
    eviction_buffer #(
        .EB_DEPTH(4)
    ) DUT_BUFFER (
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

    // Instanciar el controlador real de memoria.
    mem_controller #(
        .MEM_DIV(MEM_DIV),
        .MEM_TIMEOUT(MEM_TIMEOUT),
        .TMEM(TMEM)
    ) DUT_CONTROLLER (
        .clk(clk),
        .reset(reset),

        .ram_req(ram_req),
        .ram_we(ram_we),
        .ram_addr(ram_addr),
        .ram_wline(ram_wline),

        .ram_ready(ram_ready),
        .ram_rline(ram_rline),
        .mem_error(ram_error),

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

    // La lectura de palabras de RAM es combinacional.
    // El controlador captura cada palabra en clk_mem.
    assign mem_word_rdata = memory[mem_word_addr];

    // Las escrituras fisicas se realizan con el
    // reloj lento generado por mem_controller.
    always @(posedge clk_mem) begin

        if (!reset && mem_word_we) begin

            memory[mem_word_addr] <= mem_word_wdata;

            physical_writes = physical_writes + 1;
        end
    end

    // Contar solicitudes efectivamente aceptadas
    // por el controlador de memoria principal.
    always @(posedge clk) begin

        if (!reset && req_accept) begin

            if (req_we_accepted)
                accepted_writes = accepted_writes + 1;
            else
                accepted_reads = accepted_reads + 1;
        end
    end

    // Esperar un ciclo de CPU y permitir que
    // terminen las actualizaciones secuenciales.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Insertar una linea sucia desde la L2 simulada.
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

                $display(
                    "[FAIL] Eviction buffer no acepta la linea"
                );

                $fatal(1);
            end

            tick();

            @(negedge clk);
            evict_valid = 1'b0;
        end
    endtask

    // Esperar hasta que el buffer quede vacio
    // y el controlador termine su transferencia.
    task wait_drain;
        integer timeout_cycles;

        begin

            timeout_cycles = 0;

            while (!empty ||
                   ram_req ||
                   transfer_busy) begin

                tick();

                timeout_cycles = timeout_cycles + 1;

                if (timeout_cycles > 1500) begin

                    $display(
                        "[FAIL] Timeout esperando drenado"
                    );

                    $display(
                        "occupancy=%0d ram_req=%0b transfer_busy=%0b",
                        occupancy,
                        ram_req,
                        transfer_busy
                    );

                    $fatal(1);
                end
            end

            // Esperar a que el controlador vuelva
            // a estar completamente disponible.
            repeat (3) tick();
        end
    endtask

    // Comprobar las ocho palabras almacenadas
    // en una direccion de RAM.
    task check_memory_line;
        input [31:0] address_value;
        input [255:0] expected_line;

        integer word_base;
        integer word_number;

        begin

            word_base = address_value >> 2;

            for (word_number = 0;
                 word_number < 8;
                 word_number = word_number + 1) begin

                if (memory[word_base + word_number] !==
                    expected_line[word_number*32 +: 32]) begin

                    $display(
                        "[FAIL] Palabra incorrecta en RAM"
                    );

                    $display(
                        "Direccion=%h palabra=%0d",
                        address_value,
                        word_number
                    );

                    $display(
                        "Esperado=%h recibido=%h",
                        expected_line[word_number*32 +: 32],
                        memory[word_base + word_number]
                    );

                    $fatal(1);
                end
            end
        end
    endtask

    // Solicitar una lectura y comprobar la
    // linea completa recibida desde el buffer.
    task read_and_check;
        input [31:0] address_value;
        input [255:0] expected_line;
        input expected_forwarding;

        integer timeout_cycles;

        begin

            @(negedge clk);

            read_addr = address_value;
            read_req = 1'b1;

            timeout_cycles = 0;

            // Mantener la solicitud hasta recibir respuesta.
            begin : wait_read_response

                while (1) begin

                    tick();

                    if (read_ready)
                        disable wait_read_response;

                    timeout_cycles = timeout_cycles + 1;

                    if (timeout_cycles > 1500) begin

                        $display(
                            "[FAIL] Timeout esperando lectura"
                        );

                        $fatal(1);
                    end
                end
            end

            // Comprobar los 256 bits de respuesta.
            if (read_line !== expected_line) begin

                $display(
                    "[FAIL] Datos incorrectos en lectura"
                );

                $display(
                    "Direccion=%h",
                    address_value
                );

                $display(
                    "Esperado=%h",
                    expected_line
                );

                $display(
                    "Recibido=%h",
                    read_line
                );

                $fatal(1);
            end

            // Verificar el origen de la respuesta.
            if (read_forwarded !== expected_forwarding) begin

                $display(
                    "[FAIL] Origen incorrecto de lectura"
                );

                $display(
                    "forwarding esperado=%0b recibido=%0b",
                    expected_forwarding,
                    read_forwarded
                );

                $fatal(1);
            end

            // Retirar la solicitud y permitir que
            // el buffer acepte una lectura posterior.
            @(negedge clk);
            read_req = 1'b0;

            repeat (3) tick();
        end
    endtask

    // Detectar errores inesperados del controlador.
    // Esta prueba no inyecta errores definitivos.
    always @(posedge clk) begin

        if (!reset && (timeout_event || error_event)) begin

            $display(
                "[FAIL] Timeout o error durante integracion"
            );

            $fatal(1);
        end
    end

    initial begin

        // Inicializar la RAM con un patron conocido.
        // Esto permite detectar escrituras incompletas.
        for (i = 0; i < 16384; i = i + 1)
            memory[i] = 32'hDEADBEEF;

        physical_writes = 0;
        accepted_writes = 0;
        accepted_reads = 0;

        // Aplicar reset al sistema.
        repeat (5) tick();

        @(negedge clk);
        reset = 1'b0;

        repeat (5) tick();

        // Comprobar que ambos modulos inician disponibles.
        if (!empty || occupancy !== 0) begin

            $display(
                "[FAIL] Eviction buffer no inicia vacio"
            );

            $fatal(1);
        end

        $display("[PASS] Inicializacion de modulos");

        // Insertar la primera linea sucia.
        enqueue(ADDR_A, LINE_A);

        // Esperar su escritura completa en memoria.
        wait_drain();

        // Comprobar el contenido fisico de RAM.
        check_memory_line(ADDR_A, LINE_A);

        if (physical_writes != 8) begin

            $display(
                "[FAIL] Primera linea genero %0d escrituras fisicas",
                physical_writes
            );

            $fatal(1);
        end

        if (accepted_writes != 1) begin

            $display(
                "[FAIL] Primera linea genero %0d solicitudes de escritura",
                accepted_writes
            );

            $fatal(1);
        end

        $display(
            "[PASS] Escritura de 256 bits hacia RAM real simulada"
        );

        // Leer desde RAM una linea ya drenada.
        // No debe encontrarse dentro del eviction buffer.
        read_and_check(
            ADDR_A,
            LINE_A,
            1'b0
        );

        if (accepted_reads != 1) begin

            $display(
                "[FAIL] Lectura no llego correctamente al controlador"
            );

            $fatal(1);
        end

        $display(
            "[PASS] Lectura completa desde RAM"
        );

        // Detener temporalmente la RAM.
        // La linea B debe permanecer en el eviction buffer.
        @(negedge clk);
        mem_hold = 1'b1;

        enqueue(ADDR_B, LINE_B);

        // Permitir que comience la solicitud de escritura.
        cycles = 0;

        while (!(ram_req && ram_we)) begin

            tick();

            cycles = cycles + 1;

            if (cycles > 100) begin

                $display(
                    "[FAIL] No se inicio drenado de linea B"
                );

                $fatal(1);
            end
        end

        // Solicitar la misma linea mientras RAM esta detenida.
        // La lectura debe resolverse desde el eviction buffer.
        read_and_check(
            ADDR_B,
            LINE_B,
            1'b1
        );

        // La RAM no debe haber recibido la linea B.
        if (physical_writes != 8) begin

            $display(
                "[FAIL] RAM escribio durante mem_hold"
            );

            $fatal(1);
        end

        if (occupancy !== 1) begin

            $display(
                "[FAIL] La linea B desaparecio antes del drenado"
            );

            $fatal(1);
        end

        $display(
            "[PASS] Forwarding durante escritura pendiente"
        );

        // Permitir que el controlador termine la escritura.
        @(negedge clk);
        mem_hold = 1'b0;

        wait_drain();

        // Verificar que los ocho datos de B llegaron a RAM.
        check_memory_line(ADDR_B, LINE_B);

        if (physical_writes != 16) begin

            $display(
                "[FAIL] Total de escrituras fisicas=%0d esperado=16",
                physical_writes
            );

            $fatal(1);
        end

        if (accepted_writes != 2) begin

            $display(
                "[FAIL] Solicitudes de escritura=%0d esperado=2",
                accepted_writes
            );

            $fatal(1);
        end

        $display(
            "[PASS] Drenado completo despues de mem_hold"
        );

        // Leer B nuevamente, ahora desde memoria principal.
        read_and_check(
            ADDR_B,
            LINE_B,
            1'b0
        );

        if (accepted_reads != 2) begin

            $display(
                "[FAIL] Solicitudes de lectura=%0d esperado=2",
                accepted_reads
            );

            $fatal(1);
        end

        $display(
            "[PASS] Lectura posterior al drenado"
        );

        // Comprobar que el sistema queda sin datos pendientes.
        if (!empty ||
            occupancy !== 0 ||
            write_error_blocked ||
            mem_hold) begin

            $display(
                "[FAIL] Estado final incorrecto"
            );

            $fatal(1);
        end

        $display(
            "[PASS] Sin perdida ni duplicacion de palabras"
        );

        $display(
            "[PASS] tb_eviction_buffer_integracion"
        );

        $finish;
    end

    // Finalizar ante un bloqueo de simulacion.
    initial begin

        #200000;

        $display(
            "[FAIL] Timeout general de integracion"
        );

        $fatal(1);
    end

endmodule

`default_nettype wire