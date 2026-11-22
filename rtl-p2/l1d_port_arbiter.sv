/*
================================================================================
 Módulo: l1d_port_arbiter

 Descripción:
 ------------------------------------------------------------------------------
 Junta los dos puertos de memoria del núcleo sobre el puerto único de la
 L1-D (decisiones-importantes.md 3.6, D17):

     A  LSU (slot 1): cargai, cargabai, guardap, guardab
     B  unidad criptográfica (slot 3): vcr lee una palabra; camcon la lee,
        la rota y la escribe

 Con la caché, el puerto B no puede ir directo a DMEM: con write-back la
 copia más nueva de una palabra puede estar sucia en la L1-D. Por eso entra
 a la L1-D como un acceso más.

 Un bundle puede traer un acceso en cada puerto. Se atienden en fases, de a
 una, y el núcleo sigue congelado hasta que termina la última:

     1. lectura de B    vcr o camcon       el dato queda en b_data
     2. acceso de A     carga o store      el dato de una carga queda en a_data
     3. escritura de B  solo camcon        ROL(b_data, imm), palabra completa

 Este orden da el mismo resultado que el proyecto 1, donde el bundle completo
 lee antes de escribir y, si A y B escriben la misma palabra, gana B:
   - vcr y camcon leen el valor de antes aunque A guarde en esa palabra;
   - una carga de A lee el valor de antes de camcon;
   - camcon escribe después del store de A.

 Cada fase es un acceso normal de la L1-D (hit sin stall, miss con los
 ciclos de la L1-D). Una fase que termina y no es la última deja stall = 1,
 así que, si todo acierta:
     solo A, o solo vcr          0 ciclos más
     A y vcr, o solo camcon      1 ciclo más
     A y camcon                  2 ciclos más
 camcon necesita dos accesos porque la L1-D hace una operación por acceso.
 Su lectura se trata como una carga (si falla, bloquea), como pide la L1-D
 para los MSHR (docs/l1d-cache.md, sección 6).

 Una fase que ya terminó no se repite aunque el núcleo siga detenido: cada
 store llega una sola vez a la L1-D y camcon rota M[dir] una sola vez.

 stall depende de las entradas (que salen de ID/EX), de a_done y b_rd_done
 (registros) y del stall de la L1-D, que también depende solo del acceso y
 de registros. Está estable antes del flanco de bajada, que es cuando top
 lo toma para detener el reloj del núcleo.
================================================================================
*/

`default_nettype none


module l1d_port_arbiter (

    input  logic         clk,           // reloj sin detener (no core_clk)
    input  logic         reset,

    // Núcleo, puerto A (LSU)
    input  logic         re,            // carga en EX
    input  logic         we,            // store en EX
    input  logic [3:0]   be,
    input  logic [31:0]  addr,
    input  logic [31:0]  wdata,
    output logic [31:0]  rdata,

    // Núcleo, puerto B (unidad criptográfica)
    input  logic         re_b,          // vcr o camcon en EX
    input  logic         we_b,          // camcon en EX
    input  logic [31:0]  addr_b,
    input  logic [31:0]  wdata_b,       // ROL(rdata_b, imm), lo calcula crypto_unit
    output logic [31:0]  rdata_b,

    output logic         stall,         // cache_stall del núcleo

    // Puerto único de la L1-D
    output logic         c_re,
    output logic         c_we,
    output logic [3:0]   c_be,
    output logic [31:0]  c_addr,
    output logic [31:0]  c_wdata,
    input  logic [31:0]  c_rdata,
    input  logic         c_stall
);


logic        b_rd_done;     // la lectura de B de este bundle ya terminó
logic        a_done;        // el acceso de A de este bundle ya terminó
logic [31:0] b_data;        // palabra leída por B
logic [31:0] a_data;        // palabra leída por una carga de A

logic a_acc, b_acc;         // el bundle trae un acceso en A / en B
logic ph_brd;               // fase 1: lectura de B
logic ph_a;                 // fase 2: acceso de A
logic ph_bwr;               // fase 3: escritura de B (camcon)
logic last;                 // la fase de este ciclo es la última del bundle

assign a_acc = re || we;
assign b_acc = re_b || we_b;

assign ph_brd = b_acc && !b_rd_done;
assign ph_a   = !ph_brd && a_acc && !a_done;
assign ph_bwr = !ph_brd && !ph_a && we_b;

assign last  = ph_bwr || (ph_a && !we_b) || (ph_brd && !a_acc && !we_b);
assign stall = (ph_brd || ph_a || ph_bwr) && (c_stall || !last);


// ------------------------------------------------------------------
// Acceso de la fase actual hacia la L1-D
// ------------------------------------------------------------------
assign c_re    = ph_brd || (ph_a && re);
assign c_we    = (ph_a && we) || ph_bwr;
assign c_be    = ph_a ? be   : 4'b1111;
assign c_addr  = ph_a ? addr : addr_b;
assign c_wdata = ph_bwr ? wdata_b : wdata;

// Cada puerto ve su dato durante todo el bundle: el de la L1-D en su
// fase y el guardado en las siguientes.
assign rdata   = a_done    ? a_data : c_rdata;
assign rdata_b = b_rd_done ? b_data : c_rdata;


// ------------------------------------------------------------------
// Las marcas se borran cuando el núcleo avanza (stall = 0): el bundle
// siguiente empieza desde la fase 1.
// ------------------------------------------------------------------
always @(posedge clk) begin

    if (reset || !stall) begin
        b_rd_done <= 1'b0;
        a_done    <= 1'b0;
    end
    else begin

        if (ph_brd && !c_stall) begin
            b_rd_done <= 1'b1;
            b_data    <= c_rdata;
        end

        if (ph_a && !c_stall) begin
            a_done <= 1'b1;
            a_data <= c_rdata;
        end
    end
end


endmodule
