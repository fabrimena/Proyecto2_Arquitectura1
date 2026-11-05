/*
================================================================================
 Módulo: l1d_write_buffer

 Descripción:
 ------------------------------------------------------------------------------
 Write buffer obligatorio entre la L1-D y la L2 (enunciado 3.4; notas de
 clase, sección 6.3.5; bloque de José, Proyecto Grupal II).

 ¿Para qué sirve?
   La L1-D es write-through (cache_defs.sv): cada store tiene que llegar a
   la L2, y escribir en la L2 tarda 8 ciclos. Si cada store tuviera que
   esperar a la L2, el procesador se detendría 8 ciclos en cada uno. El
   write buffer es una cola FIFO entre la L1-D y la L2 (notas, figura 6.12):
   la L1-D deja el store aquí en 1 ciclo y el núcleo sigue; el buffer lo
   "drena" (lo manda a la L2) por su cuenta, cuando el bus está libre. Solo
   si el buffer se llena el núcleo tiene que esperar (riesgo estructural,
   notas 6.3.5).

 ¿Qué se guarda en cada entrada? (formato de cache_defs.sv, punto 4)

   +----------------------+---------------------+------------------------+
   | dirección de línea   | máscara de bytes    | datos de la línea      |
   | (11 bits: addr[15:5])| (32 bits, 1 por     | (256 bits = 8 palabras;|
   |                      |  byte de la línea)  |  solo valen los bytes  |
   |                      |                     |  marcados)             |
   +----------------------+---------------------+------------------------+

   Cada entrada es UN store:
     - guardap: 4 bits de la máscara en 1 (la palabra completa).
     - guardab: 1 bit de la máscara en 1 (el byte que tocó el store).
   La entrada ya tiene el formato del bus hacia la L2 (l2_wline y l2_be de
   docs/memory-interfaces.md, sección 5): "escribe estos bytes de esta
   línea".

 Vaciado
   Como la L1-D es write-through, nunca tiene datos que la L2 no tenga o que
   no estén en este buffer. Para que la L2 quede al día basta con esperar a
   que el buffer quede vacío (empty = 1).

 Riesgo RAW en memoria (Read After Write, enunciado 3.4; notas 6.3.5,
 figura 6.13)
   Si la L1-D tiene un miss y va a pedirle a la L2 una línea que todavía
   tiene escrituras esperando en este buffer, la L2 devolvería datos VIEJOS.
   Este módulo ofrece las dos herramientas para resolverlo; l1d_cache.sv
   elige cuál usar con el parámetro RAW_POLICY:

     - fwd_hit:  indica si la línea consultada aparece en alguna entrada.
                 Con RAW_STALL ("Stall" en las notas), la L1-D no pide la
                 línea hasta que fwd_hit sea 0 (el buffer drenó esas
                 entradas).
     - fwd_line: store-to-load forwarding (la estrategia que prefieren los
                 procesadores modernos, notas 6.3.5). Toma la línea que llegó de la L2
                 (fwd_base_line) y le pone encima los bytes pendientes del
                 buffer, de la entrada más vieja a la más nueva, así que si
                 dos entradas escriben el mismo byte gana la más reciente.
                 Con RAW_FORWARD, la L1-D guarda esta línea ya corregida y
                 no espera.

 Organización interna: cola circular
   - head  : índice de la entrada más vieja (la próxima en drenarse).
   - tail  : índice donde se escribe la próxima entrada.
   - count : cuántas entradas hay (0 .. DEPTH).
   push escribe en tail; pop descarta la de head. Se pueden hacer los dos en
   el mismo ciclo.

 Tiempos:
   - Las salidas (full, empty, head_*, fwd_*) son combinacionales y
     dependen solo de registros (y de la dirección consultada), así que se
     pueden usar dentro del mismo ciclo de EX sin romper la regla de que
     cache_stall dependa solo del acceso y de registros.
   - push y pop se aplican en el flanco positivo.

 Reglas de uso (las cumple l1d_cache.sv):
   - No hacer push si full = 1 (se detiene al procesador en su lugar).
   - No hacer pop si empty = 1.

================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l1d_write_buffer #(

    // Número de entradas: el enunciado pide entre 2 y 8
    parameter int DEPTH = WB_DEPTH_DEFAULT
) (

    input  logic                    clk,
    input  logic                    reset,

    // ------------------------------------------------------------------
    // Entrada de escrituras (desde la L1-D)
    // ------------------------------------------------------------------
    input  logic                    push,
    input  logic [LINE_ADDR_W-1:0] push_line_addr,  // addr[15:5] de la línea
    input  logic [LINE_MASK_W-1:0]  push_mask,       // bytes que se escriben
    input  logic [LINE_W-1:0]       push_data,       // datos (solo cuentan los de la máscara)

    // ------------------------------------------------------------------
    // Salida hacia la L2: la entrada más vieja (cabeza de la cola)
    // ------------------------------------------------------------------
    input  logic                    pop,             // la L2 terminó de escribir la cabeza
    output logic [LINE_ADDR_W-1:0] head_line_addr,
    output logic [LINE_MASK_W-1:0]  head_mask,
    output logic [LINE_W-1:0]       head_data,

    // ------------------------------------------------------------------
    // Estado de la cola
    // ------------------------------------------------------------------
    output logic                    full,
    output logic                    empty,
    output logic [$clog2(DEPTH+1)-1:0] count,

    // ------------------------------------------------------------------
    // Riesgo RAW: búsqueda por dirección de línea y forwarding
    // ------------------------------------------------------------------
    input  logic [LINE_ADDR_W-1:0] fwd_line_addr,   // línea que la L1-D va a pedir
    input  logic [LINE_W-1:0]       fwd_base_line,   // línea tal como llegó de la L2
    output logic                    fwd_hit,         // hay escrituras pendientes de esa línea
    output logic [LINE_MASK_W-1:0]  fwd_mask,        // unión de los bytes pendientes
    output logic [LINE_W-1:0]       fwd_line         // fwd_base_line con esos bytes encima
);


// LINE_ADDR_W (ancho de la dirección de línea, 11 bits = addr[15:5]) viene
// de cache_defs.sv.

// Ancho de los punteros de la cola
localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;


// ============================================================================
// Verificación de parámetros (solo en simulación)
// ============================================================================

initial begin

    if (DEPTH < WB_DEPTH_MIN || DEPTH > WB_DEPTH_MAX)
        $fatal(1, "l1d_write_buffer: DEPTH = %0d fuera del rango %0d..%0d del enunciado",
               DEPTH, WB_DEPTH_MIN, WB_DEPTH_MAX);
end


// ============================================================================
// Almacenamiento de las entradas
// ============================================================================

logic [LINE_ADDR_W-1:0] q_addr [0:DEPTH-1];
logic [LINE_MASK_W-1:0] q_mask [0:DEPTH-1];
logic [LINE_W-1:0]      q_data [0:DEPTH-1];

logic [PTR_W-1:0]          head;
logic [PTR_W-1:0]          tail;
logic [$clog2(DEPTH+1)-1:0] n;      // número de entradas ocupadas


// Avanza un puntero circular: DEPTH-1 vuelve a 0. (DEPTH no tiene que ser
// potencia de 2, por eso no basta con dejar que el contador se desborde.)
function automatic logic [PTR_W-1:0] next_ptr(input logic [PTR_W-1:0] p);
    if (p == PTR_W'(DEPTH - 1))
        return '0;
    else
        return p + 1'b1;
endfunction


// ============================================================================
// Estado y cabeza de la cola (combinacional, depende solo de registros)
// ============================================================================

assign count = n;
assign empty = (n == 0);
assign full  = (n == DEPTH);

assign head_line_addr = q_addr[head];
assign head_mask      = q_mask[head];
assign head_data      = q_data[head];


// ============================================================================
// Push / pop (flanco positivo)
// ============================================================================

always @(posedge clk) begin

    if (reset) begin

        head <= '0;
        tail <= '0;
        n    <= '0;
    end
    else begin

        // Escritura de una entrada nueva al final de la cola
        if (push) begin

            q_addr[tail] <= push_line_addr;
            q_mask[tail] <= push_mask;
            q_data[tail] <= push_data;
            tail         <= next_ptr(tail);
        end

        // La L2 aceptó la cabeza: se descarta
        if (pop)
            head <= next_ptr(head);

        // Contador: +1 por push, -1 por pop (si hay ambos, no cambia)
        case ({push, pop})
            2'b10:   n <= n + 1'b1;
            2'b01:   n <= n - 1'b1;
            default: n <= n;
        endcase
    end
end


// Avisos de uso incorrecto (no deberían ocurrir nunca con l1d_cache.sv)
always @(posedge clk) begin

    if (!reset && push && full && !pop)
        $error("l1d_write_buffer: push con el buffer lleno (se perdería una escritura)");

    if (!reset && pop && empty)
        $error("l1d_write_buffer: pop con el buffer vacío");
end


// ============================================================================
// Búsqueda por dirección y store-to-load forwarding (combinacional)
// ============================================================================
//
// Se recorren las entradas ocupadas de la MÁS VIEJA (head) a la MÁS NUEVA.
// Cada entrada que es de la línea buscada "pinta" sus bytes encima del
// resultado. Como las más nuevas se pintan después, son las que quedan.
//
// Ejemplo: la L2 devuelve la línea con el byte 4 = 0x11.
//          Entrada vieja escribe byte 4 = 0x22, entrada nueva byte 4 = 0x33.
//          fwd_line queda con byte 4 = 0x33, que es lo que el programa
//          escribió por última vez.

int           i, b;
logic [PTR_W-1:0] idx;

always @(*) begin

    fwd_hit  = 1'b0;
    fwd_mask = '0;
    fwd_line = fwd_base_line;
    idx      = head;

    for (i = 0; i < DEPTH; i++) begin

        // Solo las primeras n posiciones a partir de head están ocupadas
        if (i < n && q_addr[idx] == fwd_line_addr) begin

            fwd_hit  = 1'b1;
            fwd_mask = fwd_mask | q_mask[idx];

            for (b = 0; b < LINE_BYTES; b++)
                if (q_mask[idx][b])
                    fwd_line[8*b +: 8] = q_data[idx][8*b +: 8];
        end

        idx = next_ptr(idx);
    end
end


endmodule
