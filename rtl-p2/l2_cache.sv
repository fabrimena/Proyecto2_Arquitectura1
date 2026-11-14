/*
================================================================================
 Módulo: l2_cache

 Descripción:
 ------------------------------------------------------------------------------
 Caché L2 unificada del Proyecto Grupal II (bloque de Alejandro).

 Sustituye a rtl-p2/l2_model.sv, que era un stub que siempre acertaba. Esta es
 la L2 de verdad: guarda líneas, aplica la política de reemplazo, cumple la
 política de inclusión L1-D/L2 y habla con el eviction buffer.

 Geometría (enunciado 3.2.3, fijada; NO es una decisión de diseño):
     16 KB, 4 vías, líneas de 32 B, hit de 8 ciclos, write-back.
     512 líneas, 128 conjuntos, índice addr[11:5], etiqueta addr[15:12].

 Bus hacia arriba (L1-D <-> L2, versión 2 de cache_defs.sv):
     Mismos nombres y polaridad que l2_model.sv, para que la L2 se pueda
     poner en su lugar en rtl-p2/mem_hierarchy.sv sin tocar el resto.
       l2_req, l2_we, l2_addr[31:0], l2_wline[255:0], l2_be[32], l2_wdirty
       l2_gnt, l2_rvalid, l2_rline[255:0], l2_rdirty
     La aceptación es l2_req && l2_gnt. Las escrituras terminan al ser
     aceptadas (no tienen respuesta). Las salidas salen de registros, porque el
     stall de la L1-D tiene que depender solo de registros.

 Bus hacia abajo (eviction buffer, sección 6.7 de docs/memory-interfaces.md):
     La L2 no habla con la RAM: le pide las líneas al eviction buffer, que a su
     vez habla con el controlador de memoria principal. Los nombres de las
     señales son los del buffer, sin adaptadores:
       evict_valid, evict_addr, evict_line  ->  evict_ready
       read_req, read_addr                   ->  read_ready, read_line,
                                                 read_forwarded

 Política de inclusión (INCL_POLICY):
     INCL_EXCLUSIVE (por defecto): L1-D ∩ L2 = vacío.
         - Un acierto en la L2 ante un fallo en la L1-D MUEVE la línea: la L2
           invalida su copia y se la entrega a la L1-D con su bit sucio
           (l2_rdirty). La L2 deja de tener esa línea.
         - Un fallo en la L2 entrega la línea SOLO a la L1-D: la L2 no se
           guarda nada, porque si lo guardara la línea estaría en los dos
           niveles (notas de clase, figura 6.6).
         - Toda víctima de la L1-D (limpia o sucia) entra a la L2, que funciona
           como caché víctima de la L1-D (lección 14b).
     INCL_NINE: la L2 se queda con una copia de todo. Un acierto copia la línea
           y la L2 la conserva; un fallo la guarda en la L2.

 Política de escritura: write-back. Una línea solo baja a la RAM cuando sale
 sucia de la L2 (por el eviction buffer) o en el vaciado.

 Política de reemplazo (REPL_POLICY): la decide rtl-p2/l2_replacement.sv.
     RP2_PLRU (por defecto) es un pseudo-LRU de árbol: una APROXIMACIÓN del LRU
     exacto, no el LRU exacto. RP2_RANDOM usa un LFSR.

 Tiempos:
     Acierto: la petición se acepta en el ciclo t y l2_rvalid sale en t+8.
     Fallo:   la petición se acepta en t, la L2 pide la línea en t+5, el nivel
              inferior tarda Tmem y l2_rvalid sale en t+8+Tmem. Con Tmem = 53
              son 61 ciclos, que es el 8 + Tmem del enunciado.

     El acierto tarda 8 ciclos porque la L1-D exige que las salidas de la L2
     salgan de registros: hay 7 ciclos de trabajo interno (comparación de
     etiqueta, lectura de la línea, actualización del reemplazo) y 1 ciclo de
     registro para presentar la respuesta.

 La L2 es BLOQUEANTE (decisiones-importantes.md, 4.3): acepta una petición
 cada vez y la termina antes de aceptar la siguiente. Fabricio la segmentará
 después, si da tiempo; el bus versión 2 ya lo permite (la aceptación está
 separada de la respuesta).

 ==============================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l2_cache #(

    // Política de reemplazo: RP2_PLRU o RP2_RANDOM (cache_defs.sv)
    parameter logic [1:0] REPL_POLICY = L2_DEFAULT_REPL_POLICY,

    // Política de inclusión L1-D/L2: INCL_EXCLUSIVE (por defecto) o INCL_NINE
    parameter logic [1:0] INCL_POLICY = L2_DEFAULT_INCL_POLICY

) (

    input  logic                   clk,
    input  logic                   reset,

    // ------------------------------------------------------------------
    // Bus L1-D <-> L2, versión 2 (idéntico al de l2_model.sv)
    // ------------------------------------------------------------------
    input  logic                   l2_req,
    input  logic                   l2_we,
    input  logic [31:0]            l2_addr,
    input  logic [LINE_W-1:0]      l2_wline,
    input  logic [LINE_MASK_W-1:0] l2_be,
    input  logic                   l2_wdirty,
    output logic                   l2_gnt,
    output logic                   l2_rvalid,
    output logic [LINE_W-1:0]      l2_rline,
    output logic                   l2_rdirty,
    output logic                   idle,

    // ------------------------------------------------------------------
    // Hacia el eviction buffer (docs/memory-interfaces.md, sección 6.7)
    // ------------------------------------------------------------------
    output logic                   evict_valid,
    output logic [31:0]            evict_addr,
    output logic [LINE_W-1:0]      evict_line,
    input  logic                   evict_ready,

    // ------------------------------------------------------------------
    // Petición de una línea al nivel inferior (el eviction buffer)
    // ------------------------------------------------------------------
    output logic                   read_req,
    output logic [31:0]            read_addr,
    input  logic                   read_ready,
    input  logic [LINE_W-1:0]      read_line,
    input  logic                   read_forwarded
);


// ============================================================================
// Verificación de los parámetros (solo en simulación)
// ============================================================================

localparam logic IS_EXCL = (INCL_POLICY == INCL_EXCLUSIVE);

initial begin

    if (INCL_POLICY != INCL_EXCLUSIVE && INCL_POLICY != INCL_NINE)
        $fatal(1, "l2_cache: INCL_POLICY = %0d no es una política valida", INCL_POLICY);

    if (REPL_POLICY != RP2_PLRU && REPL_POLICY != RP2_RANDOM)
        $fatal(1, "l2_cache: REPL_POLICY = %0d no es una politica valida", REPL_POLICY);
end


// ============================================================================
// Estados
// ============================================================================
//
//   S_IDLE     libre, puede aceptar una petición
//   S_EVICT    está sacando una línea sucia al eviction buffer
//   S_RD_WAIT  espera el momento de presentar la respuesta de un acierto
//   S_RD_FETCH espera la línea del nivel inferior (fallo de lectura)
//   S_WR_FETCH espera la línea del nivel inferior (write-allocate)
//   S_WR_STORE escribe la línea en la L2
//   S_WR_COMMIT deja pasar un ciclo para que los arreglos queden actualizados

localparam logic [2:0] S_IDLE       = 3'd0;
localparam logic [2:0] S_EVICT      = 3'd1;
localparam logic [2:0] S_RD_WAIT    = 3'd2;
localparam logic [2:0] S_RD_FETCH   = 3'd3;
localparam logic [2:0] S_WR_FETCH   = 3'd4;
localparam logic [2:0] S_WR_STORE   = 3'd5;
localparam logic [2:0] S_WR_COMMIT  = 3'd6;


// ============================================================================
// Arreglos de la caché
// ============================================================================
//
// Una tabla de 128 conjuntos por 4 vías. Cada vía tiene sus propios arreglos de
// 128 posiciones (como l1d_arrays.sv): es la forma que no dispara los avisos
// de Icarus Verilog por "@* sensible a todo un arreglo".

wire [L2_WAYS-1:0]          bus_valid;   // V de cada vía del conjunto mirado
wire [L2_WAYS*L2_TAG_W-1:0] bus_tag;     // vía w en [w*TAG_W +: TAG_W]
wire [L2_WAYS*LINE_W-1:0]   bus_line;    // vía w en [w*LINE_W +: LINE_W]
wire [L2_WAYS-1:0]          bus_dirty;   // D de cada vía del conjunto mirado

genvar gw;
generate
    for (gw = 0; gw < L2_WAYS; gw = gw + 1) begin : g_way

        // Ojo: hay que darle ancho explícito. "logic" a secas es de UN bit,
        // y con 4 vías las vías 2 y 3 se quedarían con WAY_ID = 0 y 1.
        localparam logic [L2_WAY_W-1:0] WAY_ID = gw;

        logic [L2_SETS-1:0]  valid_bits;
        logic [L2_SETS-1:0]  dirty_bits;
        logic [L2_TAG_W-1:0] tag_mem  [0:L2_SETS-1];
        logic [LINE_W-1:0]    data_mem [0:L2_SETS-1];

        // ---- Lectura combinacional del conjunto que se está mirando ------
        assign bus_valid[WAY_ID]                       = valid_bits[bus_set];
        assign bus_tag  [WAY_ID*L2_TAG_W +: L2_TAG_W]  = tag_mem[bus_set];
        assign bus_line [WAY_ID*LINE_W    +: LINE_W]   = data_mem[bus_set];
        assign bus_dirty[WAY_ID]                       = dirty_bits[bus_set];

        // ---- Escritura de una vía completa ------------------------------
        always @(posedge clk) begin

            if (reset) begin
                valid_bits <= '0;
                dirty_bits <= '0;
            end
            else if (wr_en && (wr_way == WAY_ID)) begin
                valid_bits[wr_set] <= wr_valid;
                dirty_bits[wr_set] <= wr_dirty;
                tag_mem[wr_set]    <= wr_tag;
                data_mem[wr_set]   <= wr_line;
            end
        end

        // Valores iniciales (solo para no ver X en las ondas)
        integer s;
        initial begin
            for (s = 0; s < L2_SETS; s = s + 1) begin
                tag_mem[s]  = '0;
                data_mem[s] = '0;
            end
        end
    end
endgenerate


// ============================================================================
// Puerto de escritura de los arreglos
// ============================================================================

logic                   wr_en;
logic [L2_INDEX_W-1:0] wr_set;
logic [L2_WAY_W-1:0]   wr_way;
logic [L2_TAG_W-1:0]   wr_tag;
logic [LINE_W-1:0]     wr_line;
logic                   wr_dirty;
logic                   wr_valid;


// ============================================================================
// Decodificación de la dirección del bus
// ============================================================================

logic [L2_INDEX_W-1:0] bus_set;
logic [L2_TAG_W-1:0]   addr_tag;   // etiqueta de la dirección del bus

assign bus_set  = l2_addr[L2_INDEX_MSB:L2_INDEX_LSB];
assign addr_tag = l2_addr[L2_TAG_MSB:L2_TAG_LSB];


// ============================================================================
// Acierto, vía libre y víctima
// ============================================================================

logic               hit;
logic [L2_WAY_W-1:0] hit_way;
logic [LINE_W-1:0]   hit_line;
logic               hit_dirty;

logic               free_found;
logic [L2_WAY_W-1:0] free_way;
logic [L2_WAY_W-1:0] fill_way_sel;

integer wi;

always @(*) begin

    hit       = 1'b0;
    hit_way   = '0;
    hit_line  = '0;
    hit_dirty = 1'b0;

    for (wi = 0; wi < L2_WAYS; wi = wi + 1) begin
        if (!hit && bus_valid[wi] && (bus_tag[wi*L2_TAG_W +: L2_TAG_W] == addr_tag)) begin
            hit       = 1'b1;
            hit_way   = wi[L2_WAY_W-1:0];
            hit_line  = bus_line[wi*LINE_W +: LINE_W];
            hit_dirty = bus_dirty[wi];
        end
    end
end

always @(*) begin

    free_found = 1'b0;
    free_way   = '0;

    for (wi = 0; wi < L2_WAYS; wi = wi + 1) begin
        if (!free_found && !bus_valid[wi]) begin
            free_found = 1'b1;
            free_way   = wi[L2_WAY_W-1:0];
        end
    end
end

// Una vía vacía tiene prioridad sobre la política de reemplazo: si hay sitio,
// no se desaloja a nadie.
assign fill_way_sel = free_found ? free_way : repl_victim;


// ============================================================================
// Política de reemplazo (rtl-p2/l2_replacement.sv)
// ============================================================================

logic [L2_WAY_W-1:0] repl_victim;
logic                touch_pulse;
logic [L2_INDEX_W-1:0] touch_set;
logic [L2_WAY_W-1:0] touch_way;
logic                fill_pulse;
logic [L2_INDEX_W-1:0] fill_set;
logic [L2_WAY_W-1:0] fill_way;

l2_replacement #(.REPL_POLICY(REPL_POLICY)) REPL (

    .clk        (clk),
    .reset      (reset),

    .lookup_set (bus_set),
    .victim_way (repl_victim),

    .touch      (touch_pulse),
    .touch_set  (touch_set),
    .touch_way  (touch_way),

    .fill       (fill_pulse),
    .fill_set   (fill_set),
    .fill_way   (fill_way)
);


// ============================================================================
// Estado de la máquina
// ============================================================================

logic [2:0]           state;
logic [7:0]           cnt;          // cuenta los 8 ciclos del acceso

logic                 is_read_q;    // la petición en curso es una lectura
logic                 rd_hit_q;     // y fue un acierto
logic                 wr_hit_q;     // la escritura en curso fue un acierto
logic                 w_fetch_q;    // la escritura necesita la línea vieja

logic [L2_INDEX_W-1:0] req_set;
logic [L2_TAG_W-1:0]   req_tag;
logic [31:0]           req_addr;    // dirección de línea de la petición
logic [L2_WAY_W-1:0]   req_way;     // vía donde entra o donde estaba la línea

logic [LINE_W-1:0]     resp_line;   // línea de la respuesta (acierto)
logic                 resp_dirty;

logic [LINE_W-1:0]     vic_line;    // línea sucia que va al eviction buffer
logic [L2_TAG_W-1:0]   vic_tag;

logic [LINE_W-1:0]     w_line;      // escritura pendiente
logic [LINE_MASK_W-1:0] w_be;
logic [LINE_W-1:0]     store_line;  // línea que se va a escribir en la L2
logic                 store_dirty;
logic [LINE_W-1:0]     fetch_line;  // línea vieja + escritura parcial


// ============================================================================
// Aceptación de la petición
// ============================================================================

logic accept;

assign accept = l2_req && l2_gnt;

assign idle = (state == S_IDLE) && !l2_rvalid;


// ============================================================================
// Mezcla de bytes: la línea vieja con los bytes marcados en la máscara
// ============================================================================

function automatic [LINE_W-1:0] merge_bytes(
    input [LINE_W-1:0]     old_line,
    input [LINE_W-1:0]     new_line,
    input [LINE_MASK_W-1:0] be_mask);

    integer b;

    begin
        for (b = 0; b < LINE_BYTES; b = b + 1) begin
            if (be_mask[b])
                merge_bytes[8*b +: 8] = new_line[8*b +: 8];
            else
                merge_bytes[8*b +: 8] = old_line[8*b +: 8];
        end
    end
endfunction


// ============================================================================
// Máquina de estados
// ============================================================================

always @(posedge clk) begin

    // ---- valores por defecto de las salidas de un ciclo -------------------
    l2_rvalid   <= 1'b0;
    read_req    <= 1'b0;
    evict_valid <= 1'b0;
    touch_pulse <= 1'b0;
    fill_pulse  <= 1'b0;
    wr_en       <= 1'b0;
    l2_gnt      <= 1'b0;

    if (reset) begin

        state     <= S_IDLE;
        l2_gnt    <= 1'b1;
        cnt       <= 8'd0;
        is_read_q <= 1'b0;
        rd_hit_q  <= 1'b0;
        wr_hit_q  <= 1'b0;
        w_fetch_q <= 1'b0;
        req_way   <= '0;
    end
    else begin

        case (state)

        // ------------------------------------------------------------------
        // S_IDLE: libre. Se acepta una petición como máximo por ciclo.
        // ------------------------------------------------------------------
        S_IDLE: begin

            l2_gnt <= 1'b1;

            if (accept) begin

                l2_gnt    <= 1'b0;
                cnt       <= 8'd1;
                req_set   <= bus_set;
                req_tag   <= addr_tag;
                req_addr  <= l2_addr;
                is_read_q <= !l2_we;

                if (!l2_we) begin
                    // ================= LECTURA =============================

                    if (hit) begin

                        // ---- Acierto ----
                        rd_hit_q <= 1'b1;
                        req_way  <= hit_way;
                        resp_line  <= hit_line;
                        resp_dirty <= IS_EXCL ? hit_dirty : 1'b0;

                        // El uso de la vía se avisa al reemplazo. Con exclusiva
                        // la vía además se invalida (la línea se MUEVE).
                        touch_pulse <= 1'b1;
                        touch_set   <= bus_set;
                        touch_way   <= hit_way;

                        if (IS_EXCL) begin
                            wr_en    <= 1'b1;
                            wr_set   <= bus_set;
                            wr_way   <= hit_way;
                            wr_tag   <= addr_tag;
                            wr_line  <= hit_line;
                            wr_dirty <= 1'b0;
                            wr_valid <= 1'b0;    // la L2 ya no tiene la línea
                        end

                        state <= S_RD_WAIT;
                    end
                    else begin

                        // ---- Fallo: hay que traer la línea ----
                        rd_hit_q <= 1'b0;

                        if (IS_EXCL) begin
                            // Con exclusiva la línea va SOLO a la L1-D: la L2
                            // no se guarda nada, para que L1-D ∩ L2 = ∅.
                            req_way <= '0;
                            state   <= S_RD_WAIT;
                        end
                        else begin
                            req_way <= fill_way_sel;

                            if (!free_found && bus_dirty[repl_victim]) begin
                                // El conjunto está lleno y su víctima está
                                // sucia: hay que mandarla al eviction buffer
                                // antes de poder meter la línea nueva.
                                vic_line <= bus_line[repl_victim*LINE_W +: LINE_W];
                                vic_tag  <= bus_tag[repl_victim*L2_TAG_W +: L2_TAG_W];
                                state    <= S_EVICT;
                            end
                            else begin
                                state <= S_RD_WAIT;
                            end
                        end
                    end
                end
                else begin
                    // ================= ESCRITURA ===========================

                    w_fetch_q <= 1'b0;

                    if (hit) begin

                        // ---- Acierto: se mezclan los bytes ----
                        wr_hit_q   <= 1'b1;
                        req_way    <= hit_way;
                        store_line <= merge_bytes(hit_line, l2_wline, l2_be);

                        // Una escritura parcial siempre deja la línea sucia
                        // (tiene datos que la RAM no tiene). Una escritura de
                        // la línea completa conserva el bit sucio que trae.
                        store_dirty <= (l2_be == {LINE_MASK_W{1'b1}})
                                       ? (hit_dirty | l2_wdirty)
                                       : 1'b1;

                        state <= S_WR_STORE;
                    end
                    else begin

                        // ---- Fallo: hay que guardar la línea ----
                        wr_hit_q <= 1'b0;
                        req_way  <= fill_way_sel;
                        w_line   <= l2_wline;
                        w_be     <= l2_be;

                        if (l2_be == {LINE_MASK_W{1'b1}}) begin

                            // Línea completa: no hace falta traer nada, los
                            // datos ya vienen. Con exclusiva es el caso normal:
                            // la L1-D desaloja y manda la línea entera.
                            store_line  <= l2_wline;
                            store_dirty <= l2_wdirty | (free_found ? 1'b0
                                                                   : bus_dirty[repl_victim]);

                            if (!free_found && bus_dirty[repl_victim]) begin
                                vic_line <= bus_line[repl_victim*LINE_W +: LINE_W];
                                vic_tag  <= bus_tag[repl_victim*L2_TAG_W +: L2_TAG_W];
                                state    <= S_EVICT;
                            end
                            else begin
                                state <= S_WR_STORE;
                            end
                        end
                        else begin

                            // Escritura parcial: hay que traer la línea vieja
                            // (write-allocate) y mezclarla.
                            w_fetch_q <= 1'b1;

                            if (!free_found && bus_dirty[repl_victim]) begin
                                vic_line <= bus_line[repl_victim*LINE_W +: LINE_W];
                                vic_tag  <= bus_tag[repl_victim*L2_TAG_W +: L2_TAG_W];
                                state    <= S_EVICT;
                            end
                            else begin
                                // Se pide la línea vieja al nivel inferior.
                                // Ojo: aquí l2_addr es la dirección de la
                                // petición en curso; req_addr todavía vale la
                                // de la petición anterior (se actualiza en
                                // este mismo ciclo).
                                state     <= S_WR_FETCH;
                                read_req  <= 1'b1;
                                read_addr <= {l2_addr[31:L2_INDEX_LSB], {L2_INDEX_LSB{1'b0}}};
                            end
                        end
                    end
                end
            end
        end

        // ------------------------------------------------------------------
        // S_EVICT: la línea sucia sale al eviction buffer.
        // ------------------------------------------------------------------
        //
        // El contador sigue corriendo durante el desalojo: así la latencia de
        // un fallo NO depende de que haya que desalojar una línea antes. El
        // desalojo se paga con el presupuesto de 8 ciclos del acceso.

        S_EVICT: begin

            // La línea sucia se mantiene en el bus hasta que el nivel inferior
            // la acepte. Ojo: evict_valid es un pulso de UN ciclo, pero no
            // puede aparecer en el mismo ciclo en que se decide desalojar, porque
            // es una salida registrada: aquí se pone en alto y el handshake se
            // mira en el ciclo SIGUIENTE. Si se comprobara evict_ready en el
            // ciclo de entrada, el pulso se cancelaría solo y el nivel inferior
            // no vería nunca la línea.
            evict_valid <= 1'b1;
            cnt        <= cnt + 8'd1;

            if (evict_valid && evict_ready) begin

                // La línea ya está en el buffer: se puede seguir.
                evict_valid <= 1'b0;

                if (is_read_q) begin
                    state <= S_RD_WAIT;
                end
                else begin
                    if (w_fetch_q) begin
                        state     <= S_WR_FETCH;
                        read_req  <= 1'b1;
                        read_addr <= {req_addr[31:L2_INDEX_LSB], {L2_INDEX_LSB{1'b0}}};
                    end
                    else begin
                        state <= S_WR_STORE;
                    end
                end
            end
        end

        // ------------------------------------------------------------------
        // S_RD_WAIT: cuenta los 8 ciclos del acceso.
        // ------------------------------------------------------------------
        S_RD_WAIT: begin

            cnt <= cnt + 8'd1;

            if (rd_hit_q) begin
                // Acierto: la respuesta sale en el ciclo t+8.
                if (cnt >= L2_HIT_CYCLES-1) begin
                    l2_rvalid <= 1'b1;
                    l2_rline  <= resp_line;
                    l2_rdirty <= resp_dirty;
                    state     <= S_IDLE;
                    l2_gnt    <= 1'b1;
                end
            end
            else begin
                // Fallo: se pide la línea al nivel inferior en t+5, para que
                // la respuesta total sea t + 8 + Tmem. La latencia del nivel
                // inferior es Tmem y el ciclo final lo pone el registro de la
                // respuesta.
                if (cnt >= L2_HIT_CYCLES-3) begin
                    read_req  <= 1'b1;
                    read_addr <= {req_addr[31:L2_INDEX_LSB], {L2_INDEX_LSB{1'b0}}};
                    state     <= S_RD_FETCH;
                end
            end
        end

        // ------------------------------------------------------------------
        // S_RD_FETCH: llega la línea del nivel inferior.
        // ------------------------------------------------------------------
        S_RD_FETCH: begin

            if (read_ready) begin

                if (!IS_EXCL) begin
                    // Con NINE la L2 guarda su copia de la línea.
                    wr_en    <= 1'b1;
                    wr_set   <= req_set;
                    wr_way   <= req_way;
                    wr_tag   <= req_tag;
                    wr_line  <= read_line;
                    wr_dirty <= read_forwarded;   // el buffer solo guarda sucias
                    wr_valid <= 1'b1;

                    fill_pulse <= 1'b1;
                    fill_set   <= req_set;
                    fill_way   <= req_way;
                end

                // Con exclusiva l2_rdirty dice si la línea venía sucia del
                // buffer (el buffer solo guarda líneas sucias).
                l2_rvalid <= 1'b1;
                l2_rline  <= read_line;
                l2_rdirty <= IS_EXCL ? read_forwarded : 1'b0;

                state  <= S_IDLE;
                l2_gnt <= 1'b1;
            end
        end

        // ------------------------------------------------------------------
        // S_WR_FETCH: llega la línea vieja para el write-allocate.
        // ------------------------------------------------------------------
        S_WR_FETCH: begin

            if (read_ready) begin
                fetch_line <= merge_bytes(read_line, w_line, w_be);
                store_line <= merge_bytes(read_line, w_line, w_be);
                store_dirty <= 1'b1;
                state <= S_WR_STORE;
            end
        end

        // ------------------------------------------------------------------
        // S_WR_STORE: la línea se escribe en la L2.
        // ------------------------------------------------------------------
        S_WR_STORE: begin

            wr_en    <= 1'b1;
            wr_set   <= req_set;
            wr_way   <= req_way;
            wr_tag   <= req_tag;
            wr_line  <= store_line;
            wr_dirty <= store_dirty;
            wr_valid <= 1'b1;

            if (wr_hit_q) begin
                // Ya estaba en la caché: es un uso, no un llenado.
                touch_pulse <= 1'b1;
                touch_set   <= req_set;
                touch_way   <= req_way;
            end
            else begin
                fill_pulse <= 1'b1;
                fill_set   <= req_set;
                fill_way   <= req_way;
            end

            // Ojo: aquí NO se vuelve a dar el permiso. La escritura en los
            // arreglos ocurre en el flanco que cierra S_WR_COMMIT, así que
            // hasta ese momento la L2 todavía tiene la línea vieja. Aceptar
            // una petición en ese instante compararía la etiqueta contra el
            // contenido viejo (fallaría el acierto) y, en un llenado, mandaría
            // dos líneas a la misma vía.
            state <= S_WR_COMMIT;
        end

        // ------------------------------------------------------------------
        // S_WR_COMMIT: la línea ya está en los arreglos.
        // ------------------------------------------------------------------
        //
        // En este ciclo ocurre el flanco que escribe los arreglos, porque
        // wr_en se puso en alto al final de S_WR_STORE. Al terminar, la L2
        // vuelve a estar libre y puede volver a dar el permiso.

        S_WR_COMMIT: begin

            state  <= S_IDLE;
            l2_gnt <= 1'b1;
        end

        default: begin
            state  <= S_IDLE;
            l2_gnt <= 1'b1;
        end

        endcase
    end
end


// ============================================================================
// Salidas que dependen del estado
// ============================================================================

// La dirección de la línea que va al eviction buffer.
always @(*) begin
    if (state == S_EVICT) begin
        evict_addr = {{(32-PADDR_W){1'b0}}, vic_tag, req_set, {L2_INDEX_LSB{1'b0}}};
        evict_line = vic_line;
    end
    else begin
        evict_addr = 32'b0;
        evict_line = '0;
    end
end


endmodule
