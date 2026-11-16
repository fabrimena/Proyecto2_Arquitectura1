/*
================================================================================
 Módulo: excl_checker (solo simulación)

 Descripción:
 ------------------------------------------------------------------------------
 Revisa en cada ciclo la regla de la política exclusiva (D3, crédito extra):
 ninguna línea puede estar válida en la L1-D y en la L2 a la vez
 (L1-D ∩ L2 = ∅). mem_hierarchy lo instancia junto a la L2 real cuando la
 política es exclusiva y le conecta, solo en simulación, los bits de validez y
 las etiquetas de las dos cachés.

 Cómo revisa (en el flanco de bajada, con los arreglos ya actualizados):
   para cada casilla válida de la L1-D (2 vías × 64 conjuntos) arma la
   dirección de su línea, addr[15:5] = {etiqueta de 5 bits, conjunto de 6},
   y la busca en la L2: conjunto addr[11:5] (7 bits), etiqueta addr[15:12]
   (4 bits), en sus 4 vías. Si alguna vía de la L2 la tiene válida, es una
   violación: se cuenta y se avisa con $error (solo las 10 primeras).

 Las líneas que están en un buffer (write buffer o eviction buffer) no cuentan:
 van de camino y no están en ninguno de los dos arreglos.

 Salidas para los testbenches:
   violations      cantidad de veces que se encontró una línea en los dos niveles
   checked_cycles  ciclos revisados (para comprobar que el checker estuvo activo)
================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module excl_checker (

    input  logic                                 clk,
    input  logic                                 reset,

    // L1-D: casilla i = vía * L1D_SETS + conjunto
    input  logic [L1D_WAYS*L1D_SETS-1:0]           l1_valid,
    input  logic [L1D_WAYS*L1D_SETS*L1D_TAG_W-1:0] l1_tag,

    // L2: casilla j = vía * L2_SETS + conjunto
    input  logic [L2_WAYS*L2_SETS-1:0]             l2_valid,
    input  logic [L2_WAYS*L2_SETS*L2_TAG_W-1:0]    l2_tag,

    output int                                   violations,
    output int                                   checked_cycles
);


logic [L1D_INDEX_W-1:0] set1;       // conjunto de la casilla de la L1-D
logic [LINE_ADDR_W-1:0] line;       // addr[15:5] de esa línea
logic [L2_INDEX_W-1:0]  set2;       // su conjunto en la L2
logic [L2_TAG_W-1:0]    tag2;       // y su etiqueta en la L2
int                     j;          // casilla de la L2

initial begin
    violations     = 0;
    checked_cycles = 0;
end

always @(negedge clk) begin

    if (!reset) begin

        checked_cycles = checked_cycles + 1;

        for (int i = 0; i < L1D_WAYS * L1D_SETS; i++) begin

            if (l1_valid[i]) begin

                set1 = i % L1D_SETS;
                line = {l1_tag[i*L1D_TAG_W +: L1D_TAG_W], set1};
                set2 = line[L2_INDEX_W-1:0];
                tag2 = line[LINE_ADDR_W-1 -: L2_TAG_W];

                for (int v = 0; v < L2_WAYS; v++) begin

                    j = v * L2_SETS + set2;

                    if (l2_valid[j] && l2_tag[j*L2_TAG_W +: L2_TAG_W] == tag2) begin
                        violations = violations + 1;
                        if (violations <= 10)       // las primeras; después solo se cuentan
                            $error("excl_checker: la línea 0x%04h está en la L1-D y en la L2 (vía %0d)",
                                   {line, 5'b0}, v);
                    end
                end
            end
        end
    end
end


endmodule
