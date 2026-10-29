/*
================================================================================
 Módulo: mem_stall_model

 Descripción:
 ------------------------------------------------------------------------------
 Modelo de prueba para el congelamiento del procesador (proyecto 2,
 iteración 1). Se coloca entre el núcleo y la memoria de datos con la misma
 interfaz que va a tener la jerarquía de caché (docs/memory-interfaces.md) y
 hace que cada acceso de la LSU tarde STALL_CYCLES ciclos más, como si todos
 fueran un miss. Sirve para probar el congelamiento antes de tener las cachés.

 No guarda datos: la memoria sigue siendo rtl/memory.sv (instancia DMEM de
 top). Este módulo sólo genera cache_stall y retiene las escrituras hasta el
 último ciclo del acceso, para que cada guardap, guardab o camcon escriba una
 sola vez.

 Acceso de la LSU en EX con STALL_CYCLES = N:
     ciclos 1..N   stall = 1: el núcleo no avanza y mantiene el acceso
     ciclo  N+1    stall = 0: se escribe la memoria (si es un store) y el
                   núcleo avanza con el dato leído
 Con STALL_CYCLES = 0 el módulo es transparente.

 El puerto B (vcr, camcon) no genera stalls, pero su escritura también espera
 al último ciclo: camcon escribe ROL(M[dir], imm) y, si se repitiera durante
 un stall de la LSU del mismo bundle, rotaría la palabra varias veces.

 stall depende sólo del acceso (que sale de ID/EX) y de count, que cambia en
 el flanco positivo. Así está estable antes del flanco de bajada, que es
 cuando top lo toma para detener el reloj del núcleo.

================================================================================
*/

`default_nettype none


module mem_stall_model #(

    parameter int STALL_CYCLES = 3      // ciclos de stall por acceso de la LSU
) (

    input  logic         clk,           // reloj sin detener (no core_clk)
    input  logic         reset,

    // Núcleo, puerto A (LSU)
    input  logic         re,            // carga en EX (cargai, cargabai)
    input  logic         we,            // store en EX (guardap, guardab)
    input  logic [3:0]   be,
    input  logic [31:0]  addr,
    input  logic [31:0]  wdata,
    output logic [31:0]  rdata,

    // Núcleo, puerto B (unidad criptográfica)
    input  logic         we_b,
    input  logic [31:0]  addr_b,
    input  logic [31:0]  wdata_b,
    output logic [31:0]  rdata_b,

    output logic         stall,         // 1: el acceso no termina en este ciclo

    // Memoria de datos (rtl/memory.sv)
    output logic         m_we,
    output logic [3:0]   m_be,
    output logic [31:0]  m_addr,
    output logic [31:0]  m_wdata,
    input  logic [31:0]  m_rdata,

    output logic         m_we_b,
    output logic [31:0]  m_addr_b,
    output logic [31:0]  m_wdata_b,
    input  logic [31:0]  m_rdata_b
);


logic        req;
logic [15:0] count;     // ciclos de stall ya cumplidos por el acceso actual

assign req   = re || we;
assign stall = !reset && req && (count < STALL_CYCLES);


// count vuelve a 0 en el ciclo en que el acceso termina (stall = 0): en ese
// flanco el núcleo avanza y el siguiente acceso empieza desde cero.
always @(posedge clk) begin

    if (reset || !stall)
        count <= 16'd0;
    else
        count <= count + 16'd1;
end


// ------------------------------------------------------------------
// Paso hacia la memoria: las escrituras esperan al último ciclo.
// ------------------------------------------------------------------
assign m_we    = we && !stall;
assign m_be    = be;
assign m_addr  = addr;
assign m_wdata = wdata;
assign rdata   = m_rdata;

assign m_we_b    = we_b && !stall;
assign m_addr_b  = addr_b;
assign m_wdata_b = wdata_b;
assign rdata_b   = m_rdata_b;


endmodule
