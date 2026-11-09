/*
================================================================================
 Módulo: l2_model

 Descripción:
 ------------------------------------------------------------------------------
 L2 de prueba con el bus versión 2 (cache_defs.sv, sección 4). Sirve para
 conectar la L1-D en top (MEM_MODE = 2) antes de tener la L2 real: siempre
 acierta y una lectura tarda 8 ciclos, el hit de L2 del enunciado. No guarda
 líneas: lee y escribe la memoria de datos (DMEM de top) por un puerto de una
 palabra, una palabra por ciclo, así que DMEM siempre tiene lo que la L1-D le
 mandó.

 Petición aceptada en el ciclo t (l2_req y l2_gnt en 1):
     lectura    el ciclo t lee la palabra 0 (la dirección sigue en el bus),
                los ciclos t+1 a t+7 leen las palabras 1 a 7 y en el ciclo
                t+8 sale l2_rvalid con la línea completa
     escritura  los ciclos t a t+7 escriben las palabras 0 a 7 (solo los
                bytes marcados en l2_be). Para la L1-D termina al ser
                aceptada; el modelo no acepta otra petición hasta t+8

 Los 8 ciclos del hit salen de leer las 8 palabras de la línea, una por
 ciclo. Es la misma latencia que la L2 de los testbenches de la L1-D
 (tb_l1d_writeback, LAT = 8), así que los stalls medidos ahí valen aquí.

 l2_gnt, l2_rvalid y l2_rline salen de registros, como pide la L1-D (su
 stall depende solo de registros). l2_rdirty siempre es 0: lo que entrega
 ya está en la RAM. Con la política exclusiva el modelo se comporta como una
 L2 vacía con la RAM detrás: toda víctima que recibe, limpia o sucia, queda
 escrita en la RAM y el modelo no se queda con ninguna copia, así que
 L1-D ∩ L2 = ∅ se cumple sola. Por lo mismo l2_wdirty no se usa.

 idle = 1 cuando no hay nada en curso. mem_hierarchy lo usa en el vaciado:
 una escritura aceptada todavía puede estar llegando a DMEM.

 Cuando esté la L2 real (Alejandro), mem_hierarchy la conecta en lugar de
 este modelo, con el mismo bus.
================================================================================
*/

`default_nettype none

`include "cache_defs.sv"


module l2_model (

    input  logic                   clk,
    input  logic                   reset,

    // Bus L1-D <-> L2, versión 2
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

    // Memoria de datos (puerto A de rtl/memory.sv)
    output logic                   m_we,
    output logic [3:0]             m_be,
    output logic [31:0]            m_addr,
    output logic [31:0]            m_wdata,
    input  logic [31:0]            m_rdata
);


logic                   busy;       // hay una petición aceptada en curso
logic                   op_we;      // y es una escritura
logic [2:0]             word;       // palabra de la línea que se atiende en este ciclo
logic [31:0]            base;       // dirección de la línea en curso
logic [LINE_W-1:0]      wline_q;    // línea que se escribe
logic [LINE_MASK_W-1:0] be_q;       // y sus bytes válidos
logic [LINE_W-1:0]      rline_q;    // palabras ya leídas

logic accept;   // la petición del bus se acepta en este ciclo
logic last;     // último ciclo de la petición en curso

assign accept    = l2_req && l2_gnt;
assign last      = busy && (word == 3'd7);
assign idle      = !busy;
assign l2_rdirty = 1'b0;


// ------------------------------------------------------------------
// Puerto de DMEM: la palabra 0 en el ciclo en que se acepta la
// petición (directo del bus) y las demás desde los registros.
// ------------------------------------------------------------------
always @(*) begin

    if (accept) begin
        m_we    = l2_we;
        m_be    = l2_be[3:0];
        m_addr  = {l2_addr[31:5], 5'b0};
        m_wdata = l2_wline[31:0];
    end
    else if (busy) begin
        m_we    = op_we;
        m_be    = be_q[word*4 +: 4];
        m_addr  = {base[31:5], word, 2'b00};
        m_wdata = wline_q[word*32 +: 32];
    end
    else begin
        m_we    = 1'b0;
        m_be    = 4'b0;
        m_addr  = 32'b0;
        m_wdata = 32'b0;
    end
end


always @(posedge clk) begin

    l2_rvalid <= 1'b0;

    if (reset) begin
        busy   <= 1'b0;
        word   <= 3'd0;
        l2_gnt <= 1'b1;
    end
    else begin

        if (accept) begin
            busy          <= 1'b1;
            op_we         <= l2_we;
            word          <= 3'd1;
            base          <= l2_addr;
            wline_q       <= l2_wline;
            be_q          <= l2_be;
            rline_q[31:0] <= m_rdata;
        end
        else if (busy) begin

            rline_q[word*32 +: 32] <= m_rdata;
            word                   <= word + 3'd1;

            if (last) begin
                busy <= 1'b0;

                if (!op_we) begin
                    l2_rvalid <= 1'b1;
                    l2_rline  <= {m_rdata, rline_q[LINE_W-33:0]};
                end
            end
        end

        // Acepta en el ciclo siguiente si para entonces está libre
        l2_gnt <= (!busy && !accept) || last;
    end
end


endmodule
