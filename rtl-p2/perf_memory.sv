`default_nettype none

// Contadores de rendimiento de la memoria principal del Proyecto.
// Este modulo mide solicitudes de lectura y escritura aceptadas por el
// controlador, ciclos de transferencia y ciclos totales observados.
//
// Todos los contadores usan clk, el reloj de 100 MHz del procesador.
// No se debe usar core_clk porque se congela durante los stalls.
//
// Una solicitud cuenta cuando req_accept vale 1 durante un flanco de clk.
// El controlador genera req_accept una sola vez por solicitud, aunque
// el emisor mantenga ram_req activo hasta recibir una respuesta.
//
// transfer_busy vale 1 en cada ciclo que pertenece a una transferencia.
// Para una operacion no solapada cuya latencia es Tmem = 53 ciclos,
// transfer_busy debe estar activo durante exactamente 53 ciclos.
// Este modulo cuenta ciclos reales; no supone que siempre sean 53.
//
// Utilizacion del ancho de banda = busy_cycles / total_cycles.
// Se entregan numerador y denominador para calcularla sin introducir
// un divisor combinacional costoso dentro del hardware.
//
// El contador transfer_cycles acumula los ciclos realmente ocupados.
// Si se implementan reintentos o transferencias fallidas, tambien se
// cuentan los ciclos ocupados, pero no como un acceso adicional salvo
// que el controlador emita de nuevo req_accept deliberadamente.
//
// La entrada clear pone todos los contadores en cero sin reiniciar
// el resto de la jerarquia. Tiene prioridad sobre el conteo.
module perf_memory (
    input  logic        clk,
    input  logic        reset,
    input  logic        clear,
    input  logic        measure_enable,
    input  logic        req_accept,
    input  logic        req_we,
    input  logic        transfer_busy,
    input  logic        timeout_event,
    input  logic        error_event,

    output logic [63:0] read_accesses,
    output logic [63:0] write_accesses,
    output logic [63:0] transfer_cycles,
    output logic [63:0] total_cycles,
    output logic [63:0] timeout_count,
    output logic [63:0] error_count
);

    // El reset es sincrono con el reloj del procesador.
    // measure_enable permite excluir la inicializacion de benchmarks.
    always @(posedge clk) begin
        if (reset || clear) begin
            read_accesses  <= 64'd0;
            write_accesses <= 64'd0;
            transfer_cycles <= 64'd0;
            total_cycles    <= 64'd0;
            timeout_count   <= 64'd0;
            error_count     <= 64'd0;
        end
        else if (measure_enable) begin
            total_cycles <= total_cycles + 64'd1;

            // Una escritura y una lectura no se cuentan a la vez.
            if (req_accept) begin
                if (req_we)
                    write_accesses <= write_accesses + 64'd1;
                else
                    read_accesses <= read_accesses + 64'd1;
            end

            // Ocupacion del bus de RAM, incluida la latencia inicial.
            if (transfer_busy)
                transfer_cycles <= transfer_cycles + 64'd1;

            // Diagnosticos utiles para validar el timeout y el reintento.
            if (timeout_event)
                timeout_count <= timeout_count + 64'd1;
            if (error_event)
                error_count <= error_count + 64'd1;
        end
    end

endmodule

`default_nettype wire
