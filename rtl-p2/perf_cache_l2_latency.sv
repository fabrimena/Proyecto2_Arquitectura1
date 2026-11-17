/* Mide lecturas completas de L2 sin intervenir en solicitudes ni respuestas.
 *
 * Contrato público: req&&gnt acepta una transacción; las cuatro clasificaciones
 * aparecen posteriormente, en orden de aceptación. Solo las lecturas reciben
 * rvalid, también en orden. Una escritura es posted: su clasificación NO es una
 * respuesta ni prueba actualización de arrays o persistencia en RAM.
 *
 * clk es el reloj general. Se consumen entradas PRE; el banco consulta POST.
 * La duración es la distancia entre los flancos de aceptación y consumo de
 * rvalid: incluye colas y congestión, sin imponer los ocho ciclos nominales.
 * Dos FIFO separan clasificación y respuesta; DEPTH debe cubrir el máximo de
 * solicitudes pendientes del productor (16 supera las etapas/colas actuales).
 * Un overflow o un evento incoherente invalida el seguimiento hasta reset;
 * nunca se reasocian silenciosamente respuestas. No hay realimentación.
 *
 * La pausa conserva identidades pero invalida irreversiblemente la elegibilidad
 * de pendientes. Solo una lectura enteramente habilitada entra en count/service.
 * Diagnósticos, aceptaciones y pendientes siguen observándose durante pausas.
 * Reset síncrono prioritario borra todo: debe acompañar el reset del productor.
 * Aritmética unsigned de 64 bits; interpretar medias exige una época sin wrap.
 */
module perf_cache_l2_latency #(parameter integer DEPTH=16) (
    input wire clk, reset, measure_enable,
    input wire l2_req, l2_we, l2_gnt, l2_rvalid,
    input wire ev_rd_hit, ev_rd_miss, ev_wr_hit, ev_wr_miss,
    // 0/1: hits/misses completos; 2/3: servicio hit/miss; 4: espera (T-1).
    // 5: respuestas excluidas; 6: errores; 7: lecturas pendientes;
    // 8: clasificaciones pendientes; 9/10: lecturas/escrituras aceptadas;
    // 11: escrituras clasificadas; 12: respuestas observadas;
    // 13: lecturas pendientes no elegibles. Diagnósticos: índices 5..13.
    output reg [13:0][63:0] counts
);
    reg [63:0] tick, accepted_at [0:DEPTH-1], read_at [0:DEPTH-1];
    reg is_write [0:DEPTH-1], eligible [0:DEPTH-1];
    reg read_hit [0:DEPTH-1], read_eligible [0:DEPTH-1];
    integer ch, ct, cn, rh, rt, rn, pending_reads, ineligible_reads;
    integer k, event_count;
    reg desynced, classification_write;
    reg [63:0] elapsed;
    wire [3:0] events = {ev_wr_miss,ev_wr_hit,ev_rd_miss,ev_rd_hit};

    // Todo estado de observación pertenece a este único proceso. Asignaciones
    // bloqueantes expresan el orden clasificación -> respuesta -> aceptación:
    // una aceptación actual no puede justificar un evento anterior huérfano.
    // Ninguna salida se consume en el camino funcional; se lee después del flanco.
    always @(posedge clk) begin
        if (reset) begin
            counts='0; tick=0; ch=0; ct=0; cn=0; rh=0; rt=0; rn=0;
            pending_reads=0; desynced=0;
            for (k=0;k<DEPTH;k=k+1) begin
                accepted_at[k]=0; read_at[k]=0; is_write[k]=0;
                eligible[k]=0; read_hit[k]=0; read_eligible[k]=0;
            end
        end else begin
            if (!measure_enable)
                for (k=0;k<DEPTH;k=k+1) begin
                    eligible[k]=0; read_eligible[k]=0;
                end
            if (!desynced) begin
                event_count=0;
                for (k=0;k<4;k=k+1) if (events[k]) event_count=event_count+1;
                classification_write=ev_wr_hit || ev_wr_miss;
                if (event_count>1 || (event_count==1 &&
                        (cn==0 || is_write[ch]!=classification_write))) begin
                    counts[6]=counts[6]+1; desynced=1;
                end else if (event_count==1) begin
                    if (is_write[ch]) counts[11]=counts[11]+1;
                    else if (rn==DEPTH) begin
                        counts[6]=counts[6]+1; desynced=1;
                    end else begin
                        read_at[rt]=accepted_at[ch]; read_hit[rt]=ev_rd_hit;
                        read_eligible[rt]=eligible[ch]; rt=(rt+1)%DEPTH; rn=rn+1;
                    end
                    ch=(ch+1)%DEPTH; cn=cn-1;
                end
                if (l2_rvalid && !desynced) begin
                    elapsed=tick-read_at[rh];
                    if (rn==0 || elapsed==0) begin
                        counts[6]=counts[6]+1; desynced=1;
                    end else begin
                        counts[12]=counts[12]+1;
                        if (measure_enable && read_eligible[rh]) begin
                            if (read_hit[rh]) begin
                                counts[0]=counts[0]+1; counts[2]=counts[2]+elapsed;
                            end else begin
                                counts[1]=counts[1]+1; counts[3]=counts[3]+elapsed;
                            end
                            // T-1 es espera respecto de una transferencia de un
                            // ciclo; no equivale a stall del núcleo non-blocking.
                            counts[4]=counts[4]+elapsed-1;
                        end else counts[5]=counts[5]+1;
                        rh=(rh+1)%DEPTH; rn=rn-1; pending_reads=pending_reads-1;
                    end
                end
                if (l2_req && l2_gnt && !desynced) begin
                    if (cn==DEPTH) begin
                        counts[6]=counts[6]+1; desynced=1;
                    end else begin
                        accepted_at[ct]=tick; is_write[ct]=l2_we;
                        eligible[ct]=measure_enable; ct=(ct+1)%DEPTH; cn=cn+1;
                        if (l2_we) counts[10]=counts[10]+1;
                        else begin counts[9]=counts[9]+1; pending_reads=pending_reads+1; end
                    end
                end
                // Una lectura aún sin clasificación también cuenta como pendiente.
                // El recuento recorre solo entradas vivas, incluso al girar el FIFO.
                ineligible_reads=0;
                for (k=0;k<cn;k=k+1)
                    if (!is_write[(ch+k)%DEPTH] && !eligible[(ch+k)%DEPTH])
                        ineligible_reads=ineligible_reads+1;
                for (k=0;k<rn;k=k+1)
                    if (!read_eligible[(rh+k)%DEPTH]) ineligible_reads=ineligible_reads+1;
                counts[7]=pending_reads; counts[8]=cn; counts[13]=ineligible_reads;
            end
            tick=tick+1;
        end
    end
endmodule
