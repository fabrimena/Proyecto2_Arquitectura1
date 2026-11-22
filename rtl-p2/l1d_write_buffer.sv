/*
================================================================================
 Módulo: l1d_write_buffer

 Descripción:
 ------------------------------------------------------------------------------
 Write buffer obligatorio entre la L1-D y la L2 (enunciado 3.4; notas de
 clase, sección 6.3.5; bloque de José, Proyecto Grupal II).

 ¿Para qué sirve?
   Escribir en la L2 tarda 8 ciclos. Si cada escritura que sale de la L1-D
   tuviera que esperar a la L2, el procesador se detendría 8 ciclos en cada
   una. El write buffer es una cola FIFO entre la L1-D y la L2 (notas,
   figura 6.12): la L1-D deja la escritura aquí en 1 ciclo y sigue; el buffer
   la "drena" (la manda a la L2) por su cuenta, cuando el bus está libre.
   Solo si el buffer se llena la L1-D tiene que esperar (riesgo estructural,
   notas 6.3.5). El enunciado lo pide sin importar la política de escritura.

 ¿Qué se guarda en cada entrada? (formato de cache_defs.sv, punto 4)

   +----------------------+---------------------+------------------------+-------+
   | dirección de línea   | máscara de bytes    | datos de la línea      | sucia |
   | (11 bits: addr[15:5])| (32 bits, 1 por     | (256 bits = 8 palabras;| (1)   |
   |                      |  byte de la línea)  |  solo valen los bytes  |       |
   |                      |                     |  marcados)             |       |
   +----------------------+---------------------+------------------------+-------+

   Según la política de la L1-D (cache_defs.sv), una entrada es:
     - write-through: UN store. guardap marca 4 bytes, guardab marca 1.
     - write-back: UNA víctima, la línea completa que sale de la L1-D (los 32
       bytes marcados). Con NINE solo salen las víctimas sucias; con la
       política exclusiva salen todas, y el bit "sucia" le dice a la L2 si la
       línea tiene datos que la RAM no tiene (señal l2_wdirty del bus
       versión 2).
   En los dos casos la entrada ya tiene el formato del bus hacia la L2
   (l2_wline, l2_be, l2_wdirty): "escribe estos bytes de esta línea".

 Riesgo RAW en memoria (Read After Write, enunciado 3.4; notas 6.3.5,
 figura 6.13)
   Si la L1-D tiene un miss y va a pedirle a la L2 una línea que todavía
   tiene escrituras esperando en este buffer, la L2 devolvería datos VIEJOS.
   Este módulo ofrece las dos herramientas; l1d_cache.sv elige cuál usar:

     - fwd_hit:  búsqueda por línea. Indica si la línea consultada aparece
                 en alguna entrada (incluida la cabeza que se está drenando).
                 La L1-D no pide la línea hasta que fwd_hit sea 0 (el buffer
                 drenó esas entradas). Se usa:
                   * con RAW_STALL ("Stall" en las notas), y
                   * SIEMPRE con la política exclusiva: si la línea fuera
                     una víctima en camino y se reenviara desde aquí,
                     quedaría en la L1-D y, al drenarse, también en la L2.
     - fwd_line: store-to-load forwarding (la estrategia que prefieren los
                 procesadores modernos, notas 6.3.5). Toma la línea que llegó
                 de la L2 (fwd_base_line) y le pone encima los bytes
                 pendientes del buffer, de la entrada más vieja a la más
                 nueva, así que si dos entradas escriben el mismo byte gana
                 la más reciente. Solo con NINE y RAW_FORWARD.

 Vaciado
   Para que la L2 quede al día hay que esperar a que este buffer quede
   vacío (empty = 1). Con write-back, antes la L1-D le manda sus líneas
   sucias (cache_defs.sv, punto 5).

 Organización interna: cola circular
   - head  : índice de la entrada más vieja (la próxima en drenarse).
   - tail  : índice donde se escribe la próxima entrada.
   - count : cuántas entradas hay (0 .. DEPTH).
   push escribe en tail; pop descarta la de head. Se pueden hacer los dos en
   el mismo ciclo.
   Las entradas se guardan en vectores "aplanados" (la entrada k ocupa su
   tramo del vector) en vez de arreglos. Así Icarus no avisa que la lógica
   combinacional es "sensible a todo un arreglo" (eran 60 warnings).

 Tiempos:
   - Las salidas (full, empty, head_*, fwd_*) son combinacionales y
     dependen solo de registros (y de la dirección consultada), así que se
     pueden usar dentro del mismo ciclo de EX sin romper la regla de que
     cache_stall dependa solo del acceso y de registros.
   - push y pop se aplican en el flanco positivo.

 Reglas de uso (las cumple l1d_cache.sv):
   - No hacer push si full = 1 (se detiene la L1-D en su lugar).
   - No hacer pop si empty = 1.

 Compatibilidad: push_dirty tiene valor por defecto 0 (como el puerto B de
 rtl/memory.sv), así un módulo que no lo conecte funciona igual que antes.

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
    input  logic [LINE_ADDR_W-1:0]  push_line_addr,  // addr[15:5] de la línea
    input  logic [LINE_MASK_W-1:0]  push_mask,       // bytes que se escriben
    input  logic [LINE_W-1:0]       push_data,       // datos (solo cuentan los de la máscara)
    input  logic                    push_dirty = 1'b0, // la víctima está sucia (write-back)

    // ------------------------------------------------------------------
    // Salida hacia la L2: la entrada más vieja (cabeza de la cola)
    // ------------------------------------------------------------------
    input  logic                    pop,             // la L2 aceptó la cabeza
    output logic [LINE_ADDR_W-1:0]  head_line_addr,
    output logic [LINE_MASK_W-1:0]  head_mask,
    output logic [LINE_W-1:0]       head_data,
    output logic                    head_dirty,      // -> l2_wdirty

    // ------------------------------------------------------------------
    // Estado de la cola
    // ------------------------------------------------------------------
    output logic                    full,
    output logic                    empty,
    output logic [$clog2(DEPTH+1)-1:0] count,

    // ------------------------------------------------------------------
    // Riesgo RAW: búsqueda por dirección de línea y forwarding
    // ------------------------------------------------------------------
    input  logic [LINE_ADDR_W-1:0]  fwd_line_addr,   // línea que la L1-D va a pedir
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
// Almacenamiento de las entradas (vectores aplanados: la entrada k ocupa el
// tramo [k*ANCHO +: ANCHO] de cada vector)
// ============================================================================

logic [DEPTH*LINE_ADDR_W-1:0] q_addr;   // direcciones de línea
logic [DEPTH*LINE_MASK_W-1:0] q_mask;   // máscaras de bytes
logic [DEPTH*LINE_W-1:0]      q_data;   // datos
logic [DEPTH-1:0]             q_dirty;  // bit "sucia" de cada entrada

logic [PTR_W-1:0]           head;
logic [PTR_W-1:0]           tail;
logic [$clog2(DEPTH+1)-1:0] n;          // número de entradas ocupadas


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

assign head_line_addr = q_addr[head*LINE_ADDR_W +: LINE_ADDR_W];
assign head_mask      = q_mask[head*LINE_MASK_W +: LINE_MASK_W];
assign head_data      = q_data[head*LINE_W      +: LINE_W];
assign head_dirty     = q_dirty[head];


// ============================================================================
// Push / pop (flanco positivo)
// ============================================================================

always @(posedge clk) begin

    if (reset) begin

        head    <= '0;
        tail    <= '0;
        n       <= '0;
        q_dirty <= '0;
    end
    else begin

        // Escritura de una entrada nueva al final de la cola
        if (push) begin

            q_addr[tail*LINE_ADDR_W +: LINE_ADDR_W] <= push_line_addr;
            q_mask[tail*LINE_MASK_W +: LINE_MASK_W] <= push_mask;
            q_data[tail*LINE_W      +: LINE_W]      <= push_data;
            q_dirty[tail]                           <= push_dirty;
            tail                                    <= next_ptr(tail);
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

int                     i, b;
logic [PTR_W-1:0]       idx;
logic [LINE_ADDR_W-1:0] e_addr;     // entrada que se está revisando
logic [LINE_MASK_W-1:0] e_mask;
logic [LINE_W-1:0]      e_data;

always @(*) begin

    fwd_hit  = 1'b0;
    fwd_mask = '0;
    fwd_line = fwd_base_line;
    idx      = head;

    for (i = 0; i < DEPTH; i++) begin

        e_addr = q_addr[idx*LINE_ADDR_W +: LINE_ADDR_W];
        e_mask = q_mask[idx*LINE_MASK_W +: LINE_MASK_W];
        e_data = q_data[idx*LINE_W      +: LINE_W];

        // Solo las primeras n posiciones a partir de head están ocupadas
        if (i < n && e_addr == fwd_line_addr) begin

            fwd_hit  = 1'b1;
            fwd_mask = fwd_mask | e_mask;

            for (b = 0; b < LINE_BYTES; b++)
                if (e_mask[b])
                    fwd_line[8*b +: 8] = e_data[8*b +: 8];
        end

        idx = next_ptr(idx);
    end
end


endmodule
