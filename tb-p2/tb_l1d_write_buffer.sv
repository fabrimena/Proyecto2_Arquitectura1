/*
================================================================================
 Testbench: tb_l1d_write_buffer

 Descripción:
 ------------------------------------------------------------------------------
 Pruebas de rtl-p2/l1d_write_buffer.sv, el write buffer L1-D -> L2 (notas
 de clase 6.3.5). Las entradas de prueba se arman igual que en la L1-D:
   - st_entry():  un store de write-through (guardap = 4 bytes marcados,
                  guardab = 1 byte marcado), con el bit sucio en 0;
   - vic_entry(): una víctima de write-back (la línea completa, los 32
                  bytes marcados), limpia o sucia.

   1. Cola FIFO: las entradas salen en el mismo orden en que entraron.
   2. full / empty / count, incluido push y pop en el mismo ciclo.
   3. Vuelta circular de los punteros (con una profundidad que no es
      potencia de 2).
   4. Búsqueda por dirección (fwd_hit) y store-to-load forwarding (notas,
      figura 6.13): los bytes pendientes se ponen encima de la línea de la
      L2 y, si dos stores escriben el mismo byte, gana el más nuevo.
   5. Prueba aleatoria contra un modelo de referencia escrito en el propio
      testbench (una lista por instancia), para DEPTH = 2, 3, 4 y 8, con
      stores y víctimas mezclados.
   6. Víctimas de línea completa: el bit sucio sale por head_dirty en orden
      (va a l2_wdirty), y la búsqueda por línea (fwd_hit) encuentra tanto
      stores como víctimas, que es lo que usa la política exclusiva para
      esperar a que una víctima llegue a la L2.

 Uso: make tb_l1d_write_buffer
================================================================================
*/

`timescale 1ns/1ps
`include "cache_defs.sv"

module tb_l1d_write_buffer;

`include "tb_utils.svh"

localparam int LA_W = LINE_ADDR_W;   // ancho de la dirección de línea (11), cache_defs.sv

logic clk = 1'b0;
logic reset;
always #5 clk = ~clk;


// ============================================================================
// Una instancia por profundidad, todas con las mismas entradas.
// Las salidas se guardan en arreglos indexados por instancia (0..3).
// ============================================================================

localparam int N_DUT = 4;

logic              push, pop_req, push_dirty;
logic [LA_W-1:0]   push_line_addr, fwd_line_addr;
logic [31:0]       push_mask;
logic [255:0]      push_data, fwd_base_line;

logic              pop    [N_DUT];
logic              full   [N_DUT];
logic              empty  [N_DUT];
logic [3:0]        count  [N_DUT];
logic [LA_W-1:0]   h_addr [N_DUT];
logic [31:0]       h_mask [N_DUT];
logic [255:0]      h_data [N_DUT];
logic              h_dirty[N_DUT];
logic              f_hit  [N_DUT];
logic [31:0]       f_mask [N_DUT];
logic [255:0]      f_line [N_DUT];

// Cada instancia solo recibe push/pop cuando puede aceptarlos (como lo hace
// la L1-D): push si no está llena, pop si no está vacía.
logic              push_ok [N_DUT];

genvar g;
generate
    for (g = 0; g < N_DUT; g++) begin : g_dut

        localparam int D = (g == 0) ? 2 : (g == 1) ? 3 : (g == 2) ? 4 : 8;

        logic [$clog2(D+1)-1:0] cnt;

        assign push_ok[g] = push && !full[g];
        assign pop[g]     = pop_req && !empty[g];
        assign count[g]   = 4'(cnt);

        l1d_write_buffer #(.DEPTH(D)) DUT (
            .clk(clk), .reset(reset),
            .push(push_ok[g]), .push_line_addr(push_line_addr),
            .push_mask(push_mask), .push_data(push_data), .push_dirty(push_dirty),
            .pop(pop[g]),
            .head_line_addr(h_addr[g]), .head_mask(h_mask[g]), .head_data(h_data[g]),
            .head_dirty(h_dirty[g]),
            .full(full[g]), .empty(empty[g]), .count(cnt),
            .fwd_line_addr(fwd_line_addr), .fwd_base_line(fwd_base_line),
            .fwd_hit(f_hit[g]), .fwd_mask(f_mask[g]), .fwd_line(f_line[g])
        );
    end
endgenerate

function automatic int depth_of(input int k);
    return (k == 0) ? 2 : (k == 1) ? 3 : (k == 2) ? 4 : 8;
endfunction


// ============================================================================
// Modelo de referencia: una lista por instancia, posición 0 = la más vieja
// (arreglos simples, porque Icarus no acepta arreglos de colas)
// ============================================================================

logic [LA_W-1:0] ma [N_DUT][8];    // dirección de línea
logic [31:0]     mm [N_DUT][8];    // máscara
logic [255:0]    md [N_DUT][8];    // datos
logic            mdy[N_DUT][8];    // bit sucio
int              mn [N_DUT];       // entradas ocupadas

// Bit sucio de la próxima entrada (lo fijan st_entry y vic_entry, más abajo)
logic            e_dirty = 1'b0;


// Línea esperada del forwarding según el modelo
task automatic model_fwd(input int k, input logic [LA_W-1:0] a,
                         input logic [255:0] base,
                         output logic hit, output logic [31:0] mask,
                         output logic [255:0] r);
    logic [31:0]  m;
    logic [255:0] d;
    r = base; hit = 0; mask = 0;
    for (int j = 0; j < mn[k]; j++) begin
        m = mm[k][j];
        d = md[k][j];
        if (ma[k][j] == a) begin
            hit  = 1;
            mask = mask | m;
            for (int b = 0; b < 32; b++)
                if (m[b]) r[8*b +: 8] = d[8*b +: 8];
        end
    end
endtask


// Un ciclo con push y/o pop; actualiza también el modelo
task automatic cycle(input logic do_push, input logic [LA_W-1:0] a,
                     input logic [31:0] m, input logic [255:0] d,
                     input logic do_pop);
    push = do_push; push_line_addr = a; push_mask = m; push_data = d;
    push_dirty = e_dirty;
    pop_req = do_pop;
    #1;
    for (int k = 0; k < N_DUT; k++) begin
        if (pop[k]) begin                       // se va la más vieja
            for (int j = 0; j < 7; j++) begin
                ma[k][j] = ma[k][j+1]; mm[k][j] = mm[k][j+1]; md[k][j] = md[k][j+1];
                mdy[k][j] = mdy[k][j+1];
            end
            mn[k]--;
        end
        if (push_ok[k]) begin                   // la nueva queda al final
            ma[k][mn[k]] = a; mm[k][mn[k]] = m; md[k][mn[k]] = d; mdy[k][mn[k]] = e_dirty;
            mn[k]++;
        end
    end
    @(posedge clk); #1;
    push = 0; pop_req = 0; push_dirty = 0;
endtask


// Compara cada instancia con su modelo
task automatic compare_all(input string tag);
    logic         eh;
    logic [31:0]  em;
    logic [255:0] el;
    for (int k = 0; k < N_DUT; k++) begin
        check({tag, $sformatf(" D=%0d count", depth_of(k))}, count[k], mn[k]);
        check({tag, $sformatf(" D=%0d empty", depth_of(k))}, empty[k], mn[k] == 0);
        check({tag, $sformatf(" D=%0d full",  depth_of(k))}, full[k],  mn[k] == depth_of(k));
        if (mn[k] > 0) begin
            check({tag, $sformatf(" D=%0d head addr", depth_of(k))}, h_addr[k], ma[k][0]);
            check({tag, $sformatf(" D=%0d head mask", depth_of(k))}, h_mask[k], mm[k][0]);
            check_true({tag, $sformatf(" D=%0d head data", depth_of(k))}, h_data[k] === md[k][0]);
            check({tag, $sformatf(" D=%0d head dirty", depth_of(k))}, h_dirty[k], mdy[k][0]);
        end
        model_fwd(k, fwd_line_addr, fwd_base_line, eh, em, el);
        check({tag, $sformatf(" D=%0d fwd_hit",  depth_of(k))}, f_hit[k],  eh);
        check({tag, $sformatf(" D=%0d fwd_mask", depth_of(k))}, f_mask[k], em);
        check_true({tag, $sformatf(" D=%0d fwd_line", depth_of(k))}, f_line[k] === el);
    end
endtask


// ----------------------------------------------------------------------------
// Entrada de un store, armada igual que en la L1-D:
//   máscara = be corrido a la palabra (4 bits por palabra)
//   datos   = wdata repetido en las 8 palabras (solo cuentan los bytes marcados)
// guardab: be = 0001 << byte y wdata con el byte ya en su posición.
// ----------------------------------------------------------------------------
logic [31:0]  e_mask;
logic [255:0] e_data;

task automatic st_entry(input int word, input logic [3:0] be, input logic [31:0] wdata);
    e_mask  = {28'b0, be} << (word * 4);
    e_data  = {8{wdata}};
    e_dirty = 1'b0;                     // un store de write-through no lleva bit sucio
endtask

// ----------------------------------------------------------------------------
// Entrada de una víctima de write-back: la línea completa, con su bit sucio.
// (Con NINE solo salen sucias; con exclusiva también salen limpias.)
// ----------------------------------------------------------------------------
task automatic vic_entry(input logic [255:0] line, input logic dirty);
    e_mask  = '1;
    e_data  = line;
    e_dirty = dirty;
endtask

// Un store aleatorio: 60 % guardap, 40 % guardab
task automatic rand_store();
    int sh;
    sh = $urandom_range(0, 3);
    if ($urandom_range(0, 99) < 60)
        st_entry($urandom_range(0, 7), 4'b1111, $urandom);
    else
        st_entry($urandom_range(0, 7), 4'b0001 << sh, ($urandom & 32'hFF) << (8 * sh));
endtask


function automatic logic [255:0] rand_line();
    logic [255:0] r;
    for (int w = 0; w < 8; w++) r[32*w +: 32] = $urandom;
    return r;
endfunction


int it;
logic [255:0] base;

initial begin

    $dumpfile("tb_l1d_write_buffer.vcd");
    $dumpvars(0, tb_l1d_write_buffer);

    push = 0; pop_req = 0; push_line_addr = 0; push_mask = 0; push_data = 0; push_dirty = 0;
    fwd_line_addr = 0; fwd_base_line = 0;
    for (int k = 0; k < N_DUT; k++) mn[k] = 0;
    reset = 1;
    @(posedge clk); @(posedge clk); #1;
    reset = 0;
    #1;


    // ------------------------------------------------------------------
    tb_section("1-2. Orden FIFO, full, empty, push y pop simultáneos");
    // ------------------------------------------------------------------
    compare_all("vacío tras reset");
    st_entry(0, 4'b1111, 32'hAAAA_0001); cycle(1, 11'h001, e_mask, e_data, 0);  // guardap palabra 0
    st_entry(1, 4'b1111, 32'hBBBB_0002); cycle(1, 11'h002, e_mask, e_data, 0);  // guardap palabra 1
    compare_all("2 entradas");
    st_entry(7, 4'b1000, 32'hCC00_0000); cycle(1, 11'h003, e_mask, e_data, 0);  // guardab byte 3 (D=2 ya no acepta)
    compare_all("3 entradas (D=2 llena)");
    st_entry(0, 4'b0001, 32'h0000_00DD); cycle(1, 11'h004, e_mask, e_data, 1);  // push + pop a la vez
    compare_all("push y pop a la vez");
    cycle(0, 0, 0, 0, 1);
    cycle(0, 0, 0, 0, 1);
    compare_all("tras dos pop");
    for (it = 0; it < 6; it++) cycle(0, 0, 0, 0, 1);
    compare_all("vacías");


    // ------------------------------------------------------------------
    tb_section("4. Forwarding: gana la escritura más nueva");
    // ------------------------------------------------------------------
    base = {8{32'h1111_1111}};
    fwd_base_line = base;
    fwd_line_addr = 11'h055;
    // Store viejo: guardap en la palabra 1 = 0x22222222
    st_entry(1, 4'b1111, 32'h2222_2222); cycle(1, 11'h055, e_mask, e_data, 0);
    // Store a otra línea (no debe afectar)
    st_entry(1, 4'b1111, 32'h9999_9999); cycle(1, 11'h056, e_mask, e_data, 0);
    // Store nuevo: guardab en el byte 0 de la palabra 1 = 0x33
    st_entry(1, 4'b0001, 32'h0000_0033); cycle(1, 11'h055, e_mask, e_data, 0);
    #1;
    compare_all("forwarding");
    // Para D=4 y D=8 (caben las 3 entradas) la palabra 1 queda 0x22222233
    check("palabra 1 corregida (D=8)", f_line[3][63:32], 32'h2222_2233);
    check("palabra 0 sin tocar (D=8)", f_line[3][31:0],  32'h1111_1111);
    check("máscara (D=8)",             f_mask[3],        32'h0000_00F0);
    fwd_line_addr = 11'h7FF; #1;
    compare_all("línea ausente");
    check("sin hit para línea ausente (D=8)", f_hit[3], 1'b0);
    for (it = 0; it < 8; it++) cycle(0, 0, 0, 0, 1);


    // ------------------------------------------------------------------
    tb_section("3 y 5. Aleatoria contra el modelo (incluye vuelta circular)");
    // ------------------------------------------------------------------
    for (it = 0; it < 400; it++) begin
        // Pocas direcciones distintas para que haya muchas coincidencias
        fwd_line_addr = LA_W'($urandom_range(0, 3));
        fwd_base_line = rand_line();
        // 70 % stores (write-through), 30 % víctimas limpias o sucias
        if ($urandom_range(0, 99) < 70) rand_store();
        else                            vic_entry(rand_line(), $urandom_range(0, 1));
        cycle($urandom_range(0, 99) < 55, LA_W'($urandom_range(0, 3)),
              e_mask, e_data, $urandom_range(0, 99) < 45);
        compare_all($sformatf("it %0d", it));
    end


    // ------------------------------------------------------------------
    tb_section("6. Víctimas de línea completa: bit sucio y búsqueda por línea");
    // ------------------------------------------------------------------
    for (it = 0; it < 8; it++) cycle(0, 0, 0, 0, 1);     // vaciar las cuatro instancias
    fwd_base_line = {8{32'h1111_1111}};
    // Víctima limpia de la línea 0x10 (solo pasa con exclusiva)
    vic_entry({8{32'hAAAA_0000}}, 1'b0); cycle(1, 11'h010, e_mask, e_data, 0);
    // Víctima sucia de la línea 0x11
    vic_entry({8{32'hBBBB_0000}}, 1'b1); cycle(1, 11'h011, e_mask, e_data, 0);
    // Store más nuevo a la línea 0x10: guardab en el byte 1 de la palabra 2
    st_entry(2, 4'b0010, 32'h0000_CC00); cycle(1, 11'h010, e_mask, e_data, 0);
    fwd_line_addr = 11'h010; #1;
    compare_all("víctimas");
    check("cabeza: víctima limpia (D=8)", h_dirty[3], 1'b0);
    check("búsqueda: la línea 0x10 está pendiente (D=8)", f_hit[3], 1'b1);
    check("forwarding: la víctima reemplaza toda la línea (D=8)", f_line[3][31:0], 32'hAAAA_0000);
    check("forwarding: el store más nuevo queda encima (D=8)", f_line[3][95:64], 32'hAAAA_CC00);
    check("máscara completa (D=8)", f_mask[3], 32'hFFFF_FFFF);
    cycle(0, 0, 0, 0, 1);                                // se drena la víctima limpia
    check("cabeza: víctima sucia (D=8)", h_dirty[3], 1'b1);
    check("dirección de la víctima sucia (D=8)", h_addr[3], 11'h011);
    fwd_line_addr = 11'h011; #1;
    check("búsqueda: la víctima sucia sigue pendiente (D=8)", f_hit[3], 1'b1);
    cycle(0, 0, 0, 0, 1);                                // se drena la víctima sucia
    fwd_line_addr = 11'h011; #1;
    check("búsqueda: ya no está pendiente tras drenarse (D=8)", f_hit[3], 1'b0);
    compare_all("tras drenar las víctimas");


    tb_finish("tb_l1d_write_buffer");
end

endmodule
