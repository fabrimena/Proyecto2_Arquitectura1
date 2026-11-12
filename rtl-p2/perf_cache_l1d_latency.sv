/*
 * perf_cache_l1d_latency: servicio de demandas en el puerto único de L1-D.
 *
 * Complementa K1-A con cohortes de accesos completos: cuenta sus flancos de
 * espera y el flanco de terminación, separados por lectura/escritura e hit/miss.
 * re/we son entradas públicas de demanda; stall y los cuatro eventos son
 * salidas públicas de L1-D. Observamos ese mismo contrato por sus puertos;
 * no se consultan etiquetas, MSHR ni registros privados. En EXCLUSIVA con WB/WA
 * un store puede terminar al reservar un MSHR: su llenado posterior no prolonga
 * el servicio al núcleo ni representa una segunda demanda.
 *
 * El reloj es clk general. Entradas conocidas y estables PRE describen el
 * acceso consumido en el flanco; las salidas registradas cambian después de NBA.
 * El productor mantiene la petición durante stall y no la cancela sin reset.
 * Cada evento consecutivo puede terminar otra operación, incluso del mismo tipo.
 *
 * Seguimiento y acumulación son distintos: pausar conserva la identidad pendiente,
 * pero excluye esa operación de la cohorte completa. Reset desconoce su inicio;
 * un reposo o una terminación recuperan la frontera para el acceso siguiente.
 * No hay realimentación, divisor ni dependencias de políticas o modelos L2.
 * La latencia pública no mide persistencia ni AMAT definitivo de la jerarquía.
 */
module perf_cache_l1d_latency (
    input logic clk,
    input logic reset,          // Síncrono y prioritario, también en pausa.
    input logic measure_enable,
    input logic re, we, stall,  // Una sola demanda; se conserva mientras espera.
    input logic ev_rd_hit, ev_rd_miss, ev_wr_hit, ev_wr_miss,
    // Índices de clase: 0 lectura hit, 1 lectura miss, 2 store hit, 3 store miss.
    // Solo incluyen operaciones íntegramente observadas dentro de la medición.
    output logic [3:0][63:0] completed_by_class,
    output logic [3:0][63:0] service_by_class,
    output logic [3:0][63:0] wait_by_class,
    output wire [63:0] completed_accesses, completed_reads, completed_writes,
    output wire [63:0] completed_hits, completed_misses, service_cycles, wait_cycles,
    output logic [63:0] no_wait_accesses,
    // Finalizaciones habilitadas que se excluyen por inicio desconocido o pausa.
    // Una finalización apagada no suma este contador; tampoco se recupera luego.
    output logic [63:0] excluded_accesses,
    // Diagnóstico del contrato, independiente de ventana: un error por flanco
    // incoherente. No es una estadística de rendimiento ni corrige al productor.
    output logic [63:0] protocol_errors,
    // Observación POST del acceso aún retenido, incluso con ventana apagada.
    // pending_wait_cycles cuenta desde el primer PRE observado, no historia perdida.
    output logic pending,
    output wire pending_eligible,
    output logic [63:0] pending_wait_cycles
);

// Una frontera conocida significa que vimos reposo o el final del acceso previo.
// No usamos re/we como pulsos: pueden mantenerse al pasar a la siguiente demanda.
logic boundary_known, eligible, pending_read;
wire request_present = re || we;
wire [3:0] completion = {ev_wr_miss, ev_wr_hit, ev_rd_miss, ev_rd_hit};
logic class_valid;
logic [1:0] class_index;

// Reconocemos un único evento exacto. Una doble clasificación nunca se suma
// en dos clases ni se resuelve mediante una prioridad que oculte el defecto.
always @(*) begin
    class_valid = 1'b1;
    class_index = 2'd0;
    case (completion)
        4'b0001: class_index = 2'd0;
        4'b0010: class_index = 2'd1;
        4'b0100: class_index = 2'd2;
        4'b1000: class_index = 2'd3;
        default: class_valid = 1'b0;
    endcase
end

// Los totales se derivan de la misma cohorte para impedir mezclar finalizaciones
// de K1-A con esperas parciales. Toda aritmética es unsigned módulo 2^64; después
// de overflow no deben interpretarse medias ni desigualdades como enteros ilimitados.
assign completed_reads = completed_by_class[0] + completed_by_class[1];
assign completed_writes = completed_by_class[2] + completed_by_class[3];
assign completed_hits = completed_by_class[0] + completed_by_class[2];
assign completed_misses = completed_by_class[1] + completed_by_class[3];
assign completed_accesses = completed_reads + completed_writes;
assign service_cycles = service_by_class[0] + service_by_class[1] +
                        service_by_class[2] + service_by_class[3];
assign wait_cycles = wait_by_class[0] + wait_by_class[1] +
                     wait_by_class[2] + wait_by_class[3];
assign pending_eligible = pending && eligible;

// La interfaz no publica IDs de transacción. Detectamos lo que sí es observable:
// eventos sin demanda, sin exclusión de tipos, durante stall, de otro tipo
// de operación, o una petición que desaparece/cambia de tipo estando pendiente.
// Dirección y datos estables siguen siendo responsabilidad del productor.
wire incoherent = (re && we) ||
    (request_present && !stall && !class_valid) ||
    ((|completion) && (!class_valid || !request_present || stall ||
                      (class_index[1] ? !we : !re))) ||
    (pending && (!request_present || re != pending_read));
wire [63:0] access_wait = pending ? pending_wait_cycles : 64'd0;
wire whole_access = measure_enable && (pending ? eligible : boundary_known);

// Consumimos exclusivamente el estado PRE en posedge clk; las NBA permiten que
// caché y monitor trabajen en paralelo. El banco debe leer resultados después
// de NBA, sin confundir los eventos recalculados POST con los recién consumidos.
always @(posedge clk) begin
    if (reset) begin
        // Un reset aislado no cancela una petición de la caché. Por eso no
        // declaramos conocido el primer acceso posterior: podría venir de antes.
        completed_by_class <= '0;
        service_by_class <= '0;
        wait_by_class <= '0;
        no_wait_accesses <= 64'd0;
        excluded_accesses <= 64'd0;
        protocol_errors <= 64'd0;
        pending <= 1'b0;
        pending_wait_cycles <= 64'd0;
        pending_read <= 1'b0;
        boundary_known <= 1'b0;
        eligible <= 1'b0;
    end else if (incoherent) begin
        // Invalidamos la observación, sin intervenir en la caché ni inventar
        // una terminación. Se exige recuperar frontera antes de otra cohorte.
        protocol_errors <= protocol_errors + 64'd1;
        pending <= 1'b0;
        pending_wait_cycles <= 64'd0;
        boundary_known <= !request_present;
        eligible <= 1'b0;
    end else if (!request_present) begin
        // Un flanco de reposo sincroniza aun en pausa o después de reset.
        boundary_known <= 1'b1;
        pending <= 1'b0;
        pending_wait_cycles <= 64'd0;
        eligible <= 1'b0;
    end else if (class_valid) begin
        // Solo el evento público termina servicio. No se usan caída de stall,
        // grant de L2 ni fill: esos hechos pueden pertenecer al trabajo de fondo.
        if (whole_access) begin
            completed_by_class[class_index] <= completed_by_class[class_index] + 64'd1;
            wait_by_class[class_index] <= wait_by_class[class_index] + access_wait;
            service_by_class[class_index] <= service_by_class[class_index] + access_wait + 64'd1;
            // pending distingue espera real incluso si su edad desbordó.
            if (!pending)
                no_wait_accesses <= no_wait_accesses + 64'd1;
        end else if (measure_enable) begin
            excluded_accesses <= excluded_accesses + 64'd1;
        end
        // El siguiente PRE puede ser otra demanda sin ningún ciclo intermedio.
        boundary_known <= 1'b1;
        pending <= 1'b0;
        pending_wait_cycles <= 64'd0;
        eligible <= 1'b0;
    end else begin
        // Sin evento, una demanda legal debe estar esperando. Conservamos su
        // tipo y su edad incluso durante pausas. Cualquier flanco apagado pierde
        // elegibilidad de modo irreversible hasta terminar ese mismo acceso.
        pending <= 1'b1;
        pending_read <= re;
        pending_wait_cycles <= access_wait + 64'd1;
        eligible <= pending ? (eligible && measure_enable) :
                              (boundary_known && measure_enable);
    end
end
endmodule
