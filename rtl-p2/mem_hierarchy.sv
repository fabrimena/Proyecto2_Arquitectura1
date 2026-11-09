/*
================================================================================
 Módulo: mem_hierarchy

 Descripción:
 ------------------------------------------------------------------------------
 Jerarquía de memoria de datos del proyecto 2 (MEM_MODE = 2 en top). Tiene
 los dos puertos de rtl/memory.sv (A para la LSU y B para la cripto) más
 cache_stall y el vaciado, y por dentro:

     puerto A (LSU) ----+
                        +--> l1d_port_arbiter --> l1d_cache --> l2_model --> DMEM
     puerto B (cripto) -+

 La L1-D va sin parámetros, con su configuración por defecto (cache_defs.sv):
 write-back, write-allocate, exclusiva, LRU, write buffer de 4 entradas,
 2 MSHR y bus versión 2. Mientras no esté la L2 real, l2_model hace de L2:
 siempre acierta en 8 ciclos y lee y escribe DMEM. Después se conectan aquí
 la L2, el eviction buffer y el controlador de memoria, sin cambiar top.

 Vaciado: con flush_req = 1 la L1-D manda sus líneas sucias a la L2.
 flush_done = 1 cuando la L1-D terminó y la L2 de prueba ya escribió todo en
 DMEM, y se mantiene mientras flush_req siga en 1. Lo usan los testbenches
 antes de leer DUT.DMEM.mem.

 Todo trabaja con clk, no con core_clk: la caché sigue mientras el núcleo
 está detenido.
================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module mem_hierarchy (

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
    input  logic         re_b,          // vcr o camcon en EX
    input  logic         we_b,          // camcon en EX
    input  logic [31:0]  addr_b,
    input  logic [31:0]  wdata_b,
    output logic [31:0]  rdata_b,

    output logic         stall,         // cache_stall

    // Vaciado de las líneas sucias (testbenches)
    input  logic         flush_req,
    output logic         flush_done,

    // Memoria de datos (puerto A de rtl/memory.sv)
    output logic         m_we,
    output logic [3:0]   m_be,
    output logic [31:0]  m_addr,
    output logic [31:0]  m_wdata,
    input  logic [31:0]  m_rdata
);


// Puerto único de la L1-D
logic        c_re;
logic        c_we;
logic [3:0]  c_be;
logic [31:0] c_addr;
logic [31:0] c_wdata;
logic [31:0] c_rdata;
logic        c_stall;

// Bus L1-D <-> L2, versión 2
logic                   l2_req;
logic                   l2_we;
logic [31:0]            l2_addr;
logic [LINE_W-1:0]      l2_wline;
logic [LINE_MASK_W-1:0] l2_be;
logic                   l2_wdirty;
logic                   l2_gnt;
logic                   l2_rvalid;
logic [LINE_W-1:0]      l2_rline;
logic                   l2_rdirty;

logic l1_flush_done;
logic l2_idle;


l1d_port_arbiter ARB (
    .clk(clk),
    .reset(reset),
    .re(re),
    .we(we),
    .be(be),
    .addr(addr),
    .wdata(wdata),
    .rdata(rdata),
    .re_b(re_b),
    .we_b(we_b),
    .addr_b(addr_b),
    .wdata_b(wdata_b),
    .rdata_b(rdata_b),
    .stall(stall),
    .c_re(c_re),
    .c_we(c_we),
    .c_be(c_be),
    .c_addr(c_addr),
    .c_wdata(c_wdata),
    .c_rdata(c_rdata),
    .c_stall(c_stall)
);

// Los eventos ev_* quedan para los contadores (L1D.ev_*)
l1d_cache L1D (
    .clk(clk),
    .reset(reset),
    .re(c_re),
    .we(c_we),
    .be(c_be),
    .addr(c_addr),
    .wdata(c_wdata),
    .rdata(c_rdata),
    .stall(c_stall),
    .flush_req(flush_req),
    .flush_done(l1_flush_done),
    .l2_req(l2_req),
    .l2_we(l2_we),
    .l2_addr(l2_addr),
    .l2_wline(l2_wline),
    .l2_be(l2_be),
    .l2_wdirty(l2_wdirty),
    .l2_gnt(l2_gnt),
    .l2_rvalid(l2_rvalid),
    .l2_rdirty(l2_rdirty),
    .l2_rline(l2_rline)
);

l2_model L2 (
    .clk(clk),
    .reset(reset),
    .l2_req(l2_req),
    .l2_we(l2_we),
    .l2_addr(l2_addr),
    .l2_wline(l2_wline),
    .l2_be(l2_be),
    .l2_wdirty(l2_wdirty),
    .l2_gnt(l2_gnt),
    .l2_rvalid(l2_rvalid),
    .l2_rline(l2_rline),
    .l2_rdirty(l2_rdirty),
    .idle(l2_idle),
    .m_we(m_we),
    .m_be(m_be),
    .m_addr(m_addr),
    .m_wdata(m_wdata),
    .m_rdata(m_rdata)
);

assign flush_done = l1_flush_done && l2_idle;


endmodule
