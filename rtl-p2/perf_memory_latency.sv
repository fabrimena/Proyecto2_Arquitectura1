/* Asocia la aceptación pública del controlador con éxito o error definitivo.
 *
 * El controlador permite una transferencia pendiente; ram_ready es su pulso de
 * éxito y error_event el fracaso final, no el nivel persistente mem_error.
 * timeout_event sin error_event inicia el único reintento del contrato actual;
 * timeout y error simultáneos terminan ese mismo acceso, no aceptan otro.
 * No se consulta ningún estado privado ni se controla RAM o clk_mem.
 *
 * clk general fecha los flancos PRE de aceptación y consumo de respuesta. La
 * media incluye CDC, espera y reintento. No es busy/accesos: busy termina antes
 * de consumir la respuesta registrada y puede cruzar la ventana de medición.
 * Solo éxitos completos e íntegramente habilitados entran en la media exitosa.
 * Fallos tienen población y tiempos separados. Pausar conserva identidad pero
 * excluye irreversiblemente el acceso; los diagnósticos continúan en pausa.
 * Reset síncrono prioritario se aplica también al productor. Errores observables
 * de asociación invalidan el seguimiento hasta reset, sin corregir al productor.
 * Contadores unsigned de 64 bits; la interpretación exige no desbordarlos.
 */
module perf_memory_latency (
    input wire clk, reset, measure_enable,
    input wire req_accept, req_we_accepted, transfer_busy,
    input wire ram_ready, timeout_event, error_event,
    // 0/1: éxitos read/write; 2/3: servicio read/write; 4: espera exitosa T-1.
    // 5/6: fallos/servicio fallido; 7/8: éxitos/fallos excluidos;
    // 9/10: timeouts de éxitos/fallos; 11/12: reintentos de éxitos/fallos;
    // 13: errores de protocolo; 14/15: pendiente/pendiente elegible;
    // 16/17: aceptaciones/finales observados; 18..21: último tiempo, tipo,
    // flanco de aceptación y flanco final. Índices 7/8 y 13..21 son diagnóstico.
    output reg [21:0][63:0] counts
);
    reg [63:0] tick, started, timeouts, retries, elapsed;
    reg pending, eligible, write_op, desynced;

    // Un único proceso ordena finalización y aceptación. El productor actual no
    // acepta otra transacción al responder (CPU_RELEASE exige retirar req).
    // Las asignaciones bloqueantes son internas al observador; sus salidas solo
    // se consultan POST y no alimentan decisiones del camino funcional.
    always @(posedge clk) begin
        if (reset) begin
            counts='0; tick=0; started=0; timeouts=0; retries=0;
            pending=0; eligible=0; write_op=0; desynced=0;
        end else begin
            if (!measure_enable) eligible=0;
            if (!desynced) begin
                if ((req_we_accepted && !req_accept) ||
                    (req_accept && pending) || (ram_ready && error_event) ||
                    ((ram_ready || timeout_event || error_event) && !pending) ||
                    (req_accept && (ram_ready || timeout_event || error_event))) begin
                    counts[13]=counts[13]+1; desynced=1;
                end else begin
                    if (timeout_event) begin
                        timeouts=timeouts+1;
                        if (!error_event) retries=retries+1;
                    end
                    if (ram_ready || error_event) begin
                        elapsed=tick-started;
                        if (elapsed==0) begin counts[13]=counts[13]+1; desynced=1; end
                        else begin
                            counts[17]=counts[17]+1;
                            counts[18]=elapsed; counts[19]=write_op;
                            counts[20]=started; counts[21]=tick;
                            if (eligible && measure_enable) begin
                                if (error_event) begin
                                    counts[5]=counts[5]+1; counts[6]=counts[6]+elapsed;
                                    counts[10]=counts[10]+timeouts; counts[12]=counts[12]+retries;
                                end else begin
                                    if (write_op) begin counts[1]=counts[1]+1; counts[3]=counts[3]+elapsed; end
                                    else begin counts[0]=counts[0]+1; counts[2]=counts[2]+elapsed; end
                                    counts[4]=counts[4]+elapsed-1;
                                    counts[9]=counts[9]+timeouts; counts[11]=counts[11]+retries;
                                end
                            end else if (error_event) counts[8]=counts[8]+1;
                            else counts[7]=counts[7]+1;
                            pending=0; eligible=0;
                        end
                    end
                    if (req_accept) begin
                        pending=1; eligible=measure_enable; write_op=req_we_accepted;
                        started=tick; timeouts=0; retries=0; counts[16]=counts[16]+1;
                    end
                end
                counts[14]=pending; counts[15]=pending && eligible;
            end
            // transfer_busy es actividad física, no condición de finalización.
            // Se conserva como entrada contractual; nunca acorta la duración.
            tick=tick+1;
        end
    end
endmodule
