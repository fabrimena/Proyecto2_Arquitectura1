/*
================================================================================
 Módulo: l1d_replacement

 Descripción:
 ------------------------------------------------------------------------------
 Política de reemplazo de la caché L1-D (bloque de José, Proyecto Grupal II).

 Cuando la L1-D tiene un miss y las 2 vías del conjunto ya están ocupadas,
 hay que sacar una de las dos líneas para hacerle lugar a la nueva. Este
 módulo decide CUÁL vía se reemplaza (la "víctima"). Es la "política de
 reemplazo" de las notas de clase (sección 6.2.3): en correspondencia
 directa no hace falta, porque hay un solo candidato, pero en una caché
 asociativa por conjuntos de 2 vías (notas 6.2.2, figura 6.5) hay que
 elegir entre dos.

 Como la L1-D es write-through (cache_defs.sv), la línea víctima siempre
 está limpia: la caché simplemente la DESCARTA y escribe encima la nueva.
 Por eso este módulo solo tiene que decir cuál vía, sin preocuparse de
 guardar nada.

 La política se elige con el parámetro REPL_POLICY (constantes de
 cache_defs.sv), para poder comparar configuraciones sin cambiar código
 (las tres opciones que da el enunciado en 7.1.3):

   RP_LRU (Least Recently Used, "la usada hace más tiempo", notas 6.2.3)
       Se reemplaza la vía que lleva más tiempo SIN USARSE, aprovechando la
       localidad temporal (notas 6.1). Con 2 vías basta 1 bit por conjunto
       (enunciado 7.1.3): cada vez que se usa la vía w (hit o llenado), el
       bit pasa a apuntar a la OTRA vía (~w), que queda como la menos usada.
       Con más vías el LRU exacto se encarece, por eso las cachés reales
       usan aproximaciones; con 2 vías es exacto y barato.

   RP_FIFO (First In, First Out, "la que entró primero", notas 6.2.3)
       Se reemplaza la vía que lleva más tiempo DENTRO de la caché, aunque se
       haya usado hace un instante. También es 1 bit por conjunto, pero solo
       se actualiza cuando entra una línea nueva (llenado), no en los hits.
       Más barato de rastrear que LRU pero menos preciso.

   RP_RANDOM (aleatorio, notas 6.2.3)
       Se elige una vía con un LFSR (Linear Feedback Shift Register, lo que
       pide el enunciado en 7.1.3), un generador pseudoaleatorio de muy bajo
       costo en hardware: un registro de desplazamiento con una compuerta XOR
       de realimentación. No necesita estado por conjunto. Las notas lo
       describen como "simple de implementar, y sorprendentemente
       competitiva en la práctica".

 Observación útil para entender el código: LRU y FIFO usan EXACTAMENTE la
 misma fórmula (bit = ~w). Lo único que cambia es CUÁNDO se actualiza el bit:
   LRU  -> en cada acceso que encuentra la línea (hit) y en cada llenado.
   FIFO -> solo en cada llenado.

 Las vías inválidas (vacías) tienen prioridad sobre la política: si alguna
 vía del conjunto está vacía, se usa esa y no se saca a nadie. Esa decisión
 la toma l1d_cache.sv, porque es quien conoce los bits de validez; este
 módulo solo responde "si hubiera que sacar a alguien, sería esta vía".

 Tiempos:
   - victim_way es combinacional: depende del conjunto consultado y de
     registros que solo cambian en el flanco positivo. Por eso se puede usar
     en el mismo ciclo del acceso sin cambiar el tiempo de un hit.
   - Las actualizaciones (touch / fill) se aplican en el flanco positivo.

 Nota: el enunciado fija 2 vías para la L1-D (sección 3.2.2), así que el
 estado de LRU y FIFO es de 1 bit por conjunto. Si algún día se cambiara
 L1D_WAYS, habría que ampliar este módulo (por ejemplo, a pseudo-LRU de
 árbol); la verificación de abajo avisa si eso ocurre.

================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l1d_replacement #(

    // Política de reemplazo: RP_LRU, RP_FIFO o RP_RANDOM (cache_defs.sv)
    parameter logic [1:0] REPL_POLICY = L1D_DEFAULT_REPL_POLICY
) (

    input  logic                     clk,
    input  logic                     reset,

    // ------------------------------------------------------------------
    // Consulta: ¿qué vía se reemplazaría en este conjunto?
    // ------------------------------------------------------------------
    input  logic [L1D_INDEX_W-1:0]   lookup_set,    // conjunto del acceso actual
    output logic                     victim_way,    // vía propuesta como víctima

    // ------------------------------------------------------------------
    // Aviso de "uso": el acceso del núcleo terminó y encontró su línea en
    // la vía touch_way del conjunto touch_set (hit, o llenado con bypass).
    // Solo lo usa LRU.
    // ------------------------------------------------------------------
    input  logic                     touch,
    input  logic [L1D_INDEX_W-1:0]   touch_set,
    input  logic                     touch_way,

    // ------------------------------------------------------------------
    // Aviso de "llenado": entró una línea nueva en la vía fill_way del
    // conjunto fill_set. Lo usan LRU, FIFO y RANDOM.
    // ------------------------------------------------------------------
    input  logic                     fill,
    input  logic [L1D_INDEX_W-1:0]   fill_set,
    input  logic                     fill_way
);


// ============================================================================
// Verificación de los parámetros (solo en simulación)
// ============================================================================

initial begin

    if (L1D_WAYS != 2)
        $fatal(1, "l1d_replacement: este módulo asume 2 vías (L1D_WAYS = %0d)", L1D_WAYS);

    if (REPL_POLICY != RP_LRU && REPL_POLICY != RP_FIFO && REPL_POLICY != RP_RANDOM)
        $fatal(1, "l1d_replacement: REPL_POLICY = %0d no es una política válida", REPL_POLICY);
end


// ============================================================================
// Estado de LRU / FIFO: 1 bit por conjunto
// ============================================================================
//
// next_victim[s] = vía que se reemplazaría en el conjunto s.
//   LRU : la vía usada hace más tiempo.
//   FIFO: la vía que entró hace más tiempo.
// Al arrancar, todas las vías están vacías, así que el valor inicial (0) da
// igual: la primera línea de cada conjunto va a una vía inválida.

logic [L1D_SETS-1:0] next_victim;


// ============================================================================
// Estado de RANDOM: LFSR de 8 bits
// ============================================================================
//
// Polinomio x^8 + x^6 + x^5 + x^4 + 1 (de longitud máxima: recorre los 255
// valores distintos de 0 antes de repetirse). Forma de Fibonacci: el bit
// nuevo es el XOR de los bits 7, 5, 4 y 3, y entra por la derecha.
//
// Avanza solo cuando hay un llenado (no en cada ciclo). Así la secuencia de
// víctimas depende únicamente de la secuencia de misses del programa y la
// simulación es repetible: el mismo programa da siempre los mismos números.
// La semilla no puede ser 0 (el LFSR se quedaría en 0 para siempre).

localparam logic [7:0] LFSR_SEED = 8'hA5;

logic [7:0] lfsr;
logic       lfsr_feedback;

assign lfsr_feedback = lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3];


// ============================================================================
// Salida: la víctima propuesta para el conjunto consultado
// ============================================================================

always @(*) begin

    case (REPL_POLICY)

        RP_RANDOM: victim_way = lfsr[0];

        // LRU y FIFO leen el mismo bit; solo cambia cuándo se actualiza
        default:   victim_way = next_victim[lookup_set];
    endcase
end


// ============================================================================
// Actualización del estado (flanco positivo)
// ============================================================================

always @(posedge clk) begin

    if (reset) begin

        next_victim <= '0;
        lfsr        <= LFSR_SEED;
    end
    else begin

        // --- LRU: cada uso convierte a la otra vía en la menos usada ------
        // Si en el mismo ciclo hay touch y fill (un llenado que además
        // responde al núcleo), se refieren a la misma vía y conjunto, así
        // que el resultado es el mismo con cualquiera de los dos.
        if (REPL_POLICY == RP_LRU) begin

            if (touch)
                next_victim[touch_set] <= ~touch_way;

            if (fill)
                next_victim[fill_set]  <= ~fill_way;
        end

        // --- FIFO: solo los llenados cambian el orden de llegada ----------
        if (REPL_POLICY == RP_FIFO) begin

            if (fill)
                next_victim[fill_set] <= ~fill_way;
        end

        // --- RANDOM: el LFSR da un paso por cada llenado -------------------
        if (REPL_POLICY == RP_RANDOM) begin

            if (fill)
                lfsr <= {lfsr[6:0], lfsr_feedback};
        end
    end
end


endmodule
