/* Comprueba ejecución y transferencias de la unidad de caché aislada.
 * El banco suministra instantáneas independientes, simula pausas de EX/WB y
 * un proveedor de flush con cuatro fases; no representa persistencia real. */
`timescale 1ns/1ps
module tb_cache_isa_unit;
    `include "tb_utils.svh"

    logic clk = 0, reset = 1;         // Reloj general activo incluso durante las pausas.
    logic valid_in = 0, ex_advance = 1;// El emisor solo transfiere cuando ready y advance son uno.
    wire issue_ready;                // Capacidad de emisión para la operación presentada.
    logic [3:0] operation = 0;        // IDs literales del contrato, sin importar constantes del DUT.
    logic [4:0] rd = 0;               // Destino que acompaña al dato durante pausas de WB.
    logic [5:0] selector = 0;         // [5] alta/baja; [4:0] incluye reservados 13–31.
    logic measure_imm = 0;            // Habilitación solicitada, independiente de valid_in.
    logic [63:0] counters [0:12];     // Fuentes distintas para detectar errores en cualquier selector.
    wire measure_enable, flush_req;  // Efectos públicos, nunca se fuerzan desde la prueba.
    logic flush_done = 0;            // Confirmación simulada; X/Z no debe liberar una espera.
    wire pending, complete_valid;    // Operación pendiente y respuesta registrada retenida.
    logic complete_ready = 0;        // WB no consume hasta que el escenario lo permita.
    wire wb_we;                      // Escritura efectiva: coincide con el consumo de lcont.
    wire [4:0] wb_rd;
    wire [31:0] wb_data;
    cache_isa_unit DUT (.*);

    // Observadores externos de transferencias, sin inspeccionar estados internos.
    // Permiten detectar finalizaciones, escrituras y solicitudes duplicadas.
    integer retired = 0, writes = 0, requests = 0;
    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (reset === 1'b0) begin
            if (complete_valid && complete_ready === 1'b1) retired = retired + 1;
            if (wb_we === 1'b1) writes = writes + 1;
        end
    end
    always @(posedge flush_req) requests = requests + 1;

    // Todos los estímulos cambian en negedge; se comprueba después de NBA.
    // No altera entradas: el llamador prepara los controles antes de invocarla.
    task automatic tick;
        @(posedge clk); #1;
        @(negedge clk);
    endtask

    // Verifica una respuesta completa, incluyendo ausencia de efectos de flush.
    // expected_we supone ready conocido; los datos deben sobrevivir a stalls.
    task automatic response(input bit expected_we, input logic [4:0] expected_rd,
                            input logic [31:0] expected_data);
        check_true("respuesta pendiente y completa", pending === 1'b1 && complete_valid === 1'b1);
        check_true("flush retirado al responder", flush_req === 1'b0);
        check("permiso WB", wb_we, expected_we);
        check("destino registrado", wb_rd, expected_rd);
        check("dato registrado", wb_data, expected_data);
    endtask

    // Emite una sola operación con WB pausado. Debe producir respuesta tras el
    // flanco EX; el destino/dato serán consumidos en otro flanco, como una carga.
    task automatic read_counter(input integer sel, input logic [4:0] dest,
                                input logic [31:0] expected);
        operation = 2; selector = sel; rd = dest;
        valid_in = 1; complete_ready = 0; ex_advance = 1;
        #1; check_true("lcont aceptable en EX", issue_ready === 1'b1);
        tick();
        valid_in = 0;
        response(0, dest, expected);
        complete_ready = 1;
        #1; response(dest != 0, dest, expected);
        tick();
        complete_ready = 0;
        check_true("unidad libre después de consumo", pending === 1'b0 && complete_valid === 1'b0);
    endtask

    // Ejecuta medir con respuesta retenida y la retira al siguiente flanco.
    // La unidad no posee acumuladores: solo debe conservar/cambiar el enable.
    task automatic set_measure(input bit enabled);
        operation = 1; measure_imm = enabled; valid_in = 1;
        ex_advance = 1; complete_ready = 0;
        tick(); valid_in = 0;
        check("medir actualiza enable", measure_enable, enabled);
        response(0, 0, 0);
        complete_ready = 1; tick(); complete_ready = 0;
    endtask

    // Inicia una transacción sin ack previo. Tras la aceptación, req debe estar
    // alto una sola vez; ninguna respuesta ni escritura puede adelantarse.
    task automatic start_flush;
        operation = 0; flush_done = 0; valid_in = 1;
        ex_advance = 1; complete_ready = 0;
        #1; check_true("vaciado aceptable con done bajo", issue_ready === 1'b1);
        tick();
        valid_in = 0;
        check_true("solicitud retenida y sin respuesta", flush_req === 1'b1 &&
                   pending === 1'b1 && complete_valid === 1'b0 && wb_we === 1'b0);
    endtask

    // Confirma y retira ack, las dos fases que faltan. Exige retención mientras
    // done siga alto y una única respuesta sin escritura al volver a cero.
    task automatic finish_flush;
        flush_done = 1; tick();
        check_true("req baja al confirmar, sin reemitir", flush_req === 1'b0 && complete_valid === 1'b0);
        repeat (3) begin
            tick();
            check_true("espera retirada de confirmación", issue_ready === 1'b0 &&
                       complete_valid === 1'b0 && pending === 1'b1);
        end
        flush_done = 0; tick();
        response(0, 0, 0);
        complete_ready = 1; tick(); complete_ready = 0;
    endtask

    // Valores esperados guardados fuera del DUT y cuentas previas para demostrar
    // que un nivel sostenido no ocasiona transferencias ni escrituras adicionales.
    integer i, half, before_retired, before_writes, before_requests;
    logic [31:0] expected;
    initial begin
        for (i = 0; i < 13; i = i + 1)
            counters[i] = {32'hf0000000 + i, 32'h12340000 + i};
        @(negedge clk);
        tick(); reset = 0;
        check_true("reset libre y medición habilitada", pending === 1'b0 &&
                   measure_enable === 1'b1 && wb_we === 1'b0 && flush_req === 1'b0);

        tb_section("tabla completa, reservados y ambas mitades");
        for (half = 0; half < 2; half = half + 1)
            for (i = 0; i < 32; i = i + 1) begin
                expected = i > 12 ? 0 : half ? 32'hf0000000 + i : 32'h12340000 + i;
                read_counter(i + half * 32, 7, expected);
            end
        counters[0] = 64'hffffffffffffffff;
        read_counter(0, 31, 32'hffffffff);
        read_counter(32, 31, 32'hffffffff);
        counters[0] = 64'h8000000000000000;
        read_counter(0, 0, 0); // x0 no crea escritura aunque la lectura sea legal.
        read_counter(32, 1, 32'h80000000);
        counters[0] = 0;
        read_counter(0, 1, 0);
        read_counter(32, 1, 0);
        counters[0] = 64'h00000000ffffffff;
        read_counter(0, 1, 32'hffffffff);
        read_counter(32, 1, 0);
        counters[0] = 64'h0000000100000000;
        read_counter(0, 1, 0);
        read_counter(32, 1, 1);
        // Un contador mal conectado debe conservar X/Z como dato desconocido,
        // sin encubrirlo como un cero reservado ni alterar la mitad seleccionada.
        counters[0] = {32'h12345678, 32'hxxxxxxxx};
        read_counter(0, 1, 32'hxxxxxxxx);
        read_counter(32, 1, 32'h12345678);
        counters[0] = {32'hzzzzzzzz, 32'h89abcdef};
        read_counter(32, 1, 32'hzzzzzzzz);
        read_counter(0, 1, 32'h89abcdef);

        tb_section("medir, pausa, reanudación y captura durante la pausa");
        set_measure(0);
        repeat (4) begin tick(); check("pausa conserva enable", measure_enable, 0); end
        read_counter(33, 4, 32'hf0000001); // Pausar no impide consultar el acumulado.
        check_true("fuente externa no borrada", counters[1] === 64'hf000000112340001);
        set_measure(1);
        // Un medir válido retenido en EX sin permiso no puede cambiar enable.
        operation = 1; measure_imm = 0; valid_in = 1; ex_advance = 0;
        repeat (3) begin tick(); check("medir congelado conserva enable", measure_enable, 1); end
        valid_in = 0; ex_advance = 1;

        tb_section("stall de EX no emite; stall de WB conserva una sola lectura");
        operation = 2; rd = 9; selector = 2; valid_in = 1; ex_advance = 0;
        before_retired = retired; before_writes = writes;
        repeat (4) begin tick(); check_true("EX congelado sin efectos", pending === 1'b0 && wb_we === 1'b0); end
        ex_advance = 1; tick(); ex_advance = 0;
        counters[2] = 64'h1111111122222222; // El resultado debe seguir siendo la instantánea anterior.
        repeat (4) begin tick(); response(0, 9, 32'h12340002); end
        check("sin retiros durante freeze", retired, before_retired);
        check("sin escrituras durante freeze", writes, before_writes);
        complete_ready = 1; tick();
        check("una sola escritura al liberar WB", writes, before_writes + 1);
        repeat (3) tick(); // valid sigue alto, pero EX aún no permite reemisión.
        check("sin lectura repetida de EX retenido", retired, before_retired + 1);
        valid_in = 0; complete_ready = 0; ex_advance = 1;

        tb_section("operaciones consecutivas sin burbuja y sin perder destino");
        before_retired = retired; before_writes = writes;
        valid_in = 1; complete_ready = 1; operation = 2; rd = 10; selector = 3;
        tick(); response(1, 10, 32'h12340003);
        rd = 11; selector = 36;
        tick(); response(1, 11, 32'hf0000004);
        operation = 1; measure_imm = 0;
        tick(); response(0, 0, 0); check("medir consecutivo", measure_enable, 0);
        operation = 2; selector = 12; rd = 12;
        tick(); response(1, 12, 32'h1234000c);
        valid_in = 0; tick(); complete_ready = 0;
        check("cuatro respuestas consecutivas", retired, before_retired + 4);
        check("tres escrituras consecutivas", writes, before_writes + 3);

        tb_section("flush inmediato, retardado y consecutivo");
        before_requests = requests; before_retired = retired;
        start_flush(); finish_flush(); // Ack en el primer ciclo con req activo.
        start_flush();
        ex_advance = 0; valid_in = 1; // El freeze de EX no debe impedir terminar el vaciado.
        repeat (6) begin
            tick(); check_true("vaciado retardado permanece pendiente", flush_req === 1'b1 &&
                               issue_ready === 1'b0 && complete_valid === 1'b0);
        end
        finish_flush();
        repeat (3) tick();
        check("dos transacciones de flush", requests, before_requests + 2);
        check("dos finalizaciones de flush", retired, before_retired + 2);
        valid_in = 0; ex_advance = 1;

        tb_section("ack antiguo y señales X/Z jamás autorizan completar");
        operation = 0; valid_in = 1; flush_done = 1;
        repeat (3) begin tick(); check_true("no acepta ack anterior", issue_ready === 1'b0 && pending === 1'b0); end
        flush_done = 1'bx; tick(); check_true("ack X bloquea emisión", pending === 1'b0);
        flush_done = 1'bz; tick(); check_true("ack Z bloquea emisión", pending === 1'b0);
        start_flush();
        flush_done = 1'bx; tick(); check_true("ack X no finaliza", flush_req === 1'b1);
        flush_done = 1'bz; tick(); check_true("ack Z no finaliza", flush_req === 1'b1);
        flush_done = 1; tick();
        flush_done = 1'bx; tick(); check_true("retirada X no completa", complete_valid === 1'b0);
        flush_done = 1'bz; tick(); check_true("retirada Z no completa", complete_valid === 1'b0);
        flush_done = 0; tick(); response(0, 0, 0);
        complete_ready = 1'bx; tick(); check_true("ready X retiene respuesta", complete_valid === 1'b1);
        complete_ready = 1'bz; tick(); check_true("ready Z retiene respuesta", complete_valid === 1'b1);
        complete_ready = 1; tick(); complete_ready = 0;

        // Para lcont, ready desconocido tampoco puede habilitar el banco de
        // registros. La muestra y el destino permanecen estables hasta consumir.
        operation = 2; selector = 1; rd = 6; valid_in = 1; tick(); valid_in = 0;
        complete_ready = 1'bx; tick(); response(0, 6, 32'h12340001);
        complete_ready = 1'bz; tick(); response(0, 6, 32'h12340001);
        complete_ready = 1; tick(); complete_ready = 0;

        tb_section("controles desconocidos e instrucciones ilegales sin efectos");
        before_writes = writes; before_requests = requests; before_retired = retired;
        valid_in = 1;
        for (i = 3; i < 16; i = i + 1) begin
            operation = i; tick(); check_true("ID reservado rechazado", issue_ready === 1'b0 && pending === 1'b0);
        end
        operation = 4'bxxxx; tick(); check_true("ID X rechazado", pending === 1'b0);
        operation = 4'bzzzz; tick(); check_true("ID Z rechazado", pending === 1'b0);
        operation = 1; measure_imm = 1'bx; tick(); check("imm X conserva enable", measure_enable, 0);
        measure_imm = 1'bz; tick(); check("imm Z conserva enable", measure_enable, 0);
        operation = 2; selector = 6'bxxxxxx; tick(); check_true("selector X rechazado", pending === 1'b0);
        selector = 6'bzzzzzz; tick(); check_true("selector Z rechazado", pending === 1'b0);
        selector = 0; rd = 5'bxxxxx; tick(); check_true("rd X rechazado", pending === 1'b0);
        rd = 5'bzzzzz; tick(); check_true("rd Z rechazado", pending === 1'b0);
        rd = 7; valid_in = 1'bx; tick(); check_true("valid X no emite", pending === 1'b0);
        valid_in = 1'bz; tick(); check_true("valid Z no emite", pending === 1'b0);
        valid_in = 1; ex_advance = 1'bx; tick(); check_true("advance X no emite", pending === 1'b0);
        ex_advance = 1'bz; tick(); check_true("advance Z no emite", pending === 1'b0);
        valid_in = 0; ex_advance = 1;
        check("ilegales sin escrituras", writes, before_writes);
        check("ilegales sin vaciados", requests, before_requests);
        check("ilegales sin retiros", retired, before_retired);

        tb_section("reset prioritario cancela flush y respuesta sin escritura");
        start_flush(); reset = 1; flush_done = 1; complete_ready = 1; tick();
        check_true("reset cancela solicitud y respuesta", pending === 1'b0 &&
                   complete_valid === 1'b0 && flush_req === 1'b0 && wb_we === 1'b0);
        check("reset habilita medición", measure_enable, 1);
        reset = 0; flush_done = 0; complete_ready = 0;
        operation = 2; rd = 5; selector = 1; valid_in = 1; tick();
        reset = 1; tick(); valid_in = 0;
        check_true("reset elimina dato y destino pendientes", complete_valid === 1'b0 && wb_rd === 5'd0 && wb_data === 32'd0);
        reset = 0; tick();
        check_true("sin respuesta fantasma tras reset", complete_valid === 1'b0);
        operation = 1; measure_imm = 0; valid_in = 1; reset = 1; tick();
        check_true("reset prevalece sobre medir cero", measure_enable === 1'b1 && complete_valid === 1'b0);
        valid_in = 0;
        reset = 1'bx; tick(); check("reset X conserva estado seguro", measure_enable, 1);
        reset = 1'bz; tick(); check("reset Z conserva estado seguro", measure_enable, 1);
        reset = 0; tick();
        tb_finish("tb_cache_isa_unit");
    end
endmodule
