`timescale 1ns/1ps
`default_nettype none

// Verifica que el controlador no acepte una confirmacion
// de memoria correspondiente a un intento anterior.
//
// Se detiene la memoria antes de transferir la octava palabra.
// Cuando aparece el primer timeout, se libera la memoria.
// La prueba observa si llega una confirmacion atrasada.
// Esa confirmacion no debe producir ram_ready.
//
// El controlador debe completar el reintento y devolver
// la linea correcta sin generar un error definitivo.

module tb_mem_controller_cdc_respuesta_tardia;

    localparam integer MEM_DIV = 4;
    localparam integer MEM_TIMEOUT = 256;
    localparam integer TMEM = 25 + 7 * MEM_DIV;

    localparam [31:0] TEST_ADDR = 32'h00000400;

    reg clk = 1'b0;

    always #5 clk = ~clk;

    reg reset = 1'b1;

    reg ram_req = 1'b0;
    reg ram_we = 1'b0;

    reg [31:0] ram_addr = 32'd0;
    reg [255:0] ram_wline = 256'd0;

    wire ram_ready;
    wire [255:0] ram_rline;
    wire mem_error;

    wire req_accept;
    wire req_we_accepted;
    wire transfer_busy;

    wire timeout_event;
    wire error_event;

    reg mem_hold = 1'b0;

    wire clk_mem;

    wire [13:0] mem_word_addr;
    wire [31:0] mem_word_wdata;
    wire mem_word_we;
    wire [31:0] mem_word_rdata;

    // RAM simulada de 64 KB.
    reg [31:0] memory [0:16383];

    reg [255:0] expected_line;

    integer i;
    integer cycles;

    integer timeout_count;
    integer error_count;

    integer stale_done_events;
    integer fresh_done_events;

    // Valores anteriores para detectar los cambios
    // del toggle de confirmacion.
    reg previous_done_toggle;

    // Registra si ya se observo una confirmacion
    // correspondiente al intento vigente.
    reg fresh_done_seen;

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

    // La RAM entrega la palabra correspondiente
    // a la direccion solicitada por el controlador.
    assign mem_word_rdata = memory[mem_word_addr];

    // Registrar eventos de timeout y error.
    always @(posedge clk) begin

        if (!reset) begin

            if (timeout_event)
                timeout_count = timeout_count + 1;

            if (error_event)
                error_count = error_count + 1;
        end
    end

    // Observar las confirmaciones generadas en RAM.
    // El test utiliza senales internas del controlador
    // solamente para verificar el protocolo CDC.
    always @(posedge clk_mem) begin

        #1;

        if (!reset) begin

            if (DUT.done_toggle != previous_done_toggle) begin

                previous_done_toggle = DUT.done_toggle;

                if (DUT.done_id_mem != DUT.req_toggle) begin

                    // Esta respuesta pertenece a un intento
                    // anterior al que CPU considera vigente.
                    stale_done_events = stale_done_events + 1;

                    $display(
                        "[INFO] Confirmacion atrasada detectada"
                    );

                end else begin

                    // Esta respuesta corresponde al intento
                    // actualmente solicitado por CPU.
                    fresh_done_events = fresh_done_events + 1;
                    fresh_done_seen = 1'b1;

                    $display(
                        "[INFO] Confirmacion del intento vigente"
                    );
                end
            end
        end
    end

    // Comprobar que CPU no anuncie una respuesta
    // antes de que RAM confirme el intento vigente.
    always @(posedge clk) begin

        #2;

        if (!reset && ram_ready && !fresh_done_seen) begin

            $display(
                "[FAIL] CPU acepto una confirmacion atrasada"
            );

            $fatal(1);
        end
    end

    // Esperar un ciclo de CPU.
    task tick;

        begin
            @(posedge clk);
            #3;
        end

    endtask

    initial begin

        timeout_count = 0;
        error_count = 0;

        stale_done_events = 0;
        fresh_done_events = 0;

        previous_done_toggle = 1'b0;
        fresh_done_seen = 1'b0;

        expected_line = 256'd0;

        // Inicializar la RAM.
        for (i = 0; i < 16384; i = i + 1)
            memory[i] = 32'hDEADBEEF;

        // Preparar una linea con ocho palabras distintas.
        for (i = 0; i < 8; i = i + 1) begin

            memory[(TEST_ADDR >> 2) + i] =
                32'hABCD0000 + i;

            expected_line[i*32 +: 32] =
                32'hABCD0000 + i;
        end

        // Aplicar reset inicial.
        repeat (5) tick();

        @(negedge clk);
        reset = 1'b0;

        repeat (5) tick();

        // Solicitar la lectura de la linea preparada.
        @(negedge clk);

        ram_req = 1'b1;
        ram_we = 1'b0;
        ram_addr = TEST_ADDR;

        // Esperar hasta que el primer intento
        // termine de transferir siete palabras.
        cycles = 0;

        begin : wait_seventh_word

            while (1) begin

                tick();

                if (DUT.mem_state == 1 &&
                    DUT.word_index == 3'd7) begin

                    disable wait_seventh_word;
                end

                cycles = cycles + 1;

                if (cycles > 150) begin

                    $display(
                        "[FAIL] No se alcanzo la octava palabra"
                    );

                    $fatal(1);
                end
            end
        end

        // Detener el dominio de memoria antes
        // de completar la octava palabra.
        @(negedge clk);
        mem_hold = 1'b1;

        // Comprobar que no haya terminado la lectura.
        repeat (10) tick();

        if (ram_ready || mem_error) begin

            $display(
                "[FAIL] Lectura termino durante mem_hold"
            );

            $fatal(1);
        end

        $display(
            "[PASS] Transferencia detenida antes de finalizar"
        );

        // Esperar el primer timeout de 256 ciclos.
        cycles = 0;

        begin : wait_first_timeout

            while (1) begin

                tick();

                if (timeout_event)
                    disable wait_first_timeout;

                cycles = cycles + 1;

                if (cycles > MEM_TIMEOUT + 20) begin

                    $display(
                        "[FAIL] No aparecio el primer timeout"
                    );

                    $fatal(1);
                end
            end
        end

        if (mem_error) begin

            $display(
                "[FAIL] Error definitivo en el primer timeout"
            );

            $fatal(1);
        end

        $display(
            "[PASS] Primer timeout detectado"
        );

        // Liberar RAM inmediatamente despues del timeout.
        // El intento anterior estaba pendiente de su
        // octava palabra, por lo que podria finalizar tarde.
        @(negedge clk);
        mem_hold = 1'b0;

        // Esperar a que el intento vigente complete
        // su transferencia y responda a CPU.
        cycles = 0;

        begin : wait_final_response

            while (1) begin

                tick();

                if (ram_ready || mem_error)
                    disable wait_final_response;

                cycles = cycles + 1;

                if (cycles > MEM_TIMEOUT) begin

                    $display(
                        "[FAIL] Reintento bloqueado"
                    );

                    $fatal(1);
                end
            end
        end

        // Una confirmacion atrasada no debe provocar
        // un error ni finalizar indebidamente la lectura.
        if (mem_error || !ram_ready) begin

            $display(
                "[FAIL] Reintento no finalizo correctamente"
            );

            $fatal(1);
        end

        if (ram_rline !== expected_line) begin

            $display(
                "[FAIL] Datos incorrectos tras el reintento"
            );

            $display(
                "Esperado=%h",
                expected_line
            );

            $display(
                "Recibido=%h",
                ram_rline
            );

            $fatal(1);
        end

        $display(
            "[PASS] Reintento completo con datos correctos"
        );

        // Comprobar que existio una confirmacion vigente.
        if (fresh_done_events < 1) begin

            $display(
                "[FAIL] No se observo confirmacion vigente"
            );

            $fatal(1);
        end

        // Para validar el caso especifico de esta prueba,
        // tambien debemos haber provocado una respuesta
        // antigua que llego despues de iniciar el reintento.
        if (stale_done_events < 1) begin

            $display(
                "[FAIL] No se reprodujo la confirmacion atrasada"
            );

            $display(
                "La fase elegida no alcanzo el caso limite"
            );

            $fatal(1);
        end

        $display(
            "[PASS] Confirmacion atrasada rechazada"
        );

        // Retirar la solicitud de CPU.
        @(negedge clk);
        ram_req = 1'b0;

        repeat (10) tick();

        // Comprobar que no se produjeron errores definitivos.
        if (error_count != 0) begin

            $display(
                "[FAIL] Error definitivo inesperado"
            );

            $fatal(1);
        end

        // No deben aparecer respuestas adicionales.
        repeat (10) begin

            tick();

            if (ram_ready) begin

                $display(
                    "[FAIL] Respuesta duplicada"
                );

                $fatal(1);
            end
        end

        $display(
            "[PASS] Sin respuestas duplicadas"
        );

        $display(
            "[PASS] tb_mem_controller_cdc_respuesta_tardia"
        );

        $finish;
    end

    // Limite general para evitar simulaciones bloqueadas.
    initial begin

        #100000;

        $display(
            "[FAIL] Timeout general del testbench"
        );

        $fatal(1);
    end

endmodule

`default_nettype wire