`timescale 1ns/1ps

/*
================================================================================
 Testbench: tb_mem_hierarchy

 Descripción:
 ------------------------------------------------------------------------------
 Prueba mem_hierarchy (MEM_MODE = 2 de top) sin el procesador. Un manejador
 hace lo mismo que el núcleo en EX: pone el acceso de los puertos A (LSU) y
 B (cripto) y lo mantiene mientras stall = 1. Un modelo de referencia hace
 lo que hacía la memoria del proyecto 1 con el mismo bundle: todo el bundle
 lee antes de escribir y, si A y B escriben la misma palabra, gana B.

 La jerarquía es la de top: l1d_port_arbiter, l1d_cache con su configuración
 por defecto (write-back, write-allocate, exclusiva, LRU, write buffer de 4,
 2 MSHR y bus versión 2) y l2_model sobre una instancia de rtl/memory.sv.

 Casos:
   A. Latencias: carga que falla 8 ciclos; carga y store que aciertan 0;
      store que falla con un MSHR libre 0; vcr igual que una carga.
   B. Puerto B: vcr y camcon solos y con un acceso de A en el mismo bundle
      (1 y 2 ciclos más si todo acierta); camcon rota la palabra una sola
      vez; vcr y camcon leen el valor de antes del store de A en la misma
      palabra y camcon gana si los dos escriben; vcr y camcon ven un valor
      que solo está en la L1-D (sucio).
   C. Vaciado: DMEM no tiene los stores hasta el vaciado; con flush_done,
      DMEM es igual a la referencia; flush_done se mantiene mientras
      flush_req siga en 1 y la caché sigue funcionando después.
   D. Prueba aleatoria: cargas, stores de palabra y de byte, vcr y camcon
      sobre 32 líneas que compiten por 4 conjuntos (víctimas, MSHR,
      llenados); cada dato leído se compara con la referencia; un vaciado a
      la mitad y otro al final.
================================================================================
*/

`include "isa_defs.sv"


module tb_mem_hierarchy;

`define TB_TIMEOUT 5000000
`include "tb_utils.svh"


logic clk   = 1'b0;
logic reset = 1'b1;

always #5 clk = ~clk;

// Núcleo, puertos A y B
logic        re   = 1'b0;
logic        we   = 1'b0;
logic [3:0]  be   = 4'b0;
logic [31:0] addr = 32'b0;
logic [31:0] wdata = 32'b0;
logic [31:0] rdata;

logic        re_b   = 1'b0;
logic        we_b   = 1'b0;
logic [31:0] addr_b = 32'b0;
logic [4:0]  imm_b  = 5'd0;
logic [31:0] wdata_b;
logic [31:0] rdata_b;

logic        stall;
logic        flush_req = 1'b0;
logic        flush_done;

// Puerto de DMEM
logic        m_we;
logic [3:0]  m_be;
logic [31:0] m_addr;
logic [31:0] m_wdata;
logic [31:0] m_rdata;


function automatic logic [31:0] rol(input logic [31:0] x, input logic [4:0] r);

    return (r == 0) ? x : ((x << r) | (x >> (32 - r)));
endfunction

// Igual que crypto_unit: camcon escribe ROL(M[dir], imm) con el dato leído
assign wdata_b = rol(rdata_b, imm_b);


mem_hierarchy DUT (
    .clk(clk), .reset(reset),
    .re(re), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata),
    .re_b(re_b), .we_b(we_b), .addr_b(addr_b), .wdata_b(wdata_b), .rdata_b(rdata_b),
    .stall(stall),
    .flush_req(flush_req), .flush_done(flush_done),
    .m_we(m_we), .m_be(m_be), .m_addr(m_addr), .m_wdata(m_wdata), .m_rdata(m_rdata)
);

memory #(.SIZE_WORDS(DMEM_BYTES / 4)) DMEM (
    .clk(clk), .we(m_we), .be(m_be), .addr(m_addr), .wdata(m_wdata), .rdata(m_rdata)
);


// ============================================================================
// Referencia: la memoria del proyecto 1
// ============================================================================

localparam int WORDS = DMEM_BYTES / 4;

logic [31:0] ref_mem [0:WORDS-1];

// Operaciones de cada puerto
localparam int A_NADA = 0, A_CARGA = 1, A_GUARDAP = 2, A_GUARDAB = 3;
localparam int B_NADA = 0, B_VCR = 1, B_CAMCON = 2;

int          n_stalls;      // ciclos de stall del último bundle
logic [31:0] got_a;         // lo que leyó A en el último bundle
logic [31:0] got_b;         // lo que leyó B
logic [31:0] exp_a;         // lo que debía leer según la referencia
logic [31:0] exp_b;
int          errors_a = 0;  // lecturas distintas de la referencia (prueba D)
int          errors_b = 0;
int          total_stalls = 0;


// Un bundle: pone el acceso después del flanco, como ID/EX, y lo mantiene
// hasta el ciclo en que stall = 0 (el núcleo avanza en ese flanco).
task automatic run_bundle(input int a_op, input logic [31:0] a_addr, input logic [31:0] a_data,
                          input int b_op, input logic [31:0] b_addr, input logic [4:0] b_imm);

    exp_a = ref_mem[a_addr[15:2]];
    exp_b = ref_mem[b_addr[15:2]];

    re     = (a_op == A_CARGA);
    we     = (a_op == A_GUARDAP || a_op == A_GUARDAB);
    addr   = a_addr;
    be     = (a_op == A_GUARDAB) ? (4'b0001 << a_addr[1:0]) : 4'b1111;
    wdata  = (a_op == A_GUARDAB) ? ({24'b0, a_data[7:0]} << (8 * a_addr[1:0])) : a_data;
    re_b   = (b_op != B_NADA);
    we_b   = (b_op == B_CAMCON);
    addr_b = b_addr;
    imm_b  = b_imm;

    n_stalls = 0;

    @(negedge clk);
    while (stall) begin
        n_stalls++;
        @(negedge clk);
    end

    got_a = rdata;
    got_b = rdata_b;
    total_stalls += n_stalls;

    // El bundle lee antes de escribir; camcon escribe después de A
    if (a_op == A_GUARDAP)
        ref_mem[a_addr[15:2]] = a_data;
    if (a_op == A_GUARDAB)
        ref_mem[a_addr[15:2]][8 * a_addr[1:0] +: 8] = a_data[7:0];
    if (b_op == B_CAMCON)
        ref_mem[b_addr[15:2]] = rol(exp_b, b_imm);

    @(posedge clk);
    #1;
    re   = 1'b0;
    we   = 1'b0;
    re_b = 1'b0;
    we_b = 1'b0;
endtask

task automatic idle(input int n);

    repeat (n) @(posedge clk);
    #1;
endtask

// Vaciado completo; devuelve los ciclos hasta flush_done
task automatic flush(output int cycles);

    flush_req = 1'b1;
    cycles    = 0;

    while (!flush_done) begin
        @(posedge clk);
        #1;
        cycles++;
    end
endtask

function automatic int dmem_diffs();

    int n;

    n = 0;
    for (int i = 0; i < WORDS; i++)
        if (DMEM.mem[i] !== ref_mem[i])
            n++;

    return n;
endfunction


// ============================================================================

int          miss_lat;
int          fl_cycles;
logic [31:0] old;
int          seed = 7;

initial begin

    $dumpfile("tb_mem_hierarchy.vcd");
    $dumpvars(0, tb_mem_hierarchy);

    // Esperar a que memory termine su inicialización
    #1;

    for (int i = 0; i < WORDS; i++) begin
        DMEM.mem[i] = {i[15:0], ~i[15:0]};
        ref_mem[i]  = {i[15:0], ~i[15:0]};
    end

    repeat (3) @(posedge clk);
    #1;
    reset = 1'b0;


    // ========================================================================
    tb_section("A. Latencias de la L1-D a través del árbitro");
    // ========================================================================

    run_bundle(A_CARGA, 32'h1000, 0, B_NADA, 0, 0);
    miss_lat = n_stalls;
    check("carga que falla: 8 ciclos de stall", n_stalls, 8);
    check("carga que falla: dato", got_a, exp_a);

    run_bundle(A_CARGA, 32'h1004, 0, B_NADA, 0, 0);
    check("carga que acierta: 0 ciclos", n_stalls, 0);
    check("carga que acierta: dato", got_a, exp_a);

    run_bundle(A_GUARDAP, 32'h1008, 32'h1111_2222, B_NADA, 0, 0);
    check("store que acierta: 0 ciclos", n_stalls, 0);

    run_bundle(A_GUARDAP, 32'h2040, 32'h3333_4444, B_NADA, 0, 0);
    check("store que falla con un MSHR libre: 0 ciclos", n_stalls, 0);

    idle(20);

    run_bundle(A_NADA, 0, 0, B_VCR, 32'h3080, 0);
    check("vcr que falla: lo mismo que una carga", n_stalls, miss_lat);
    check("vcr que falla: dato", got_b, exp_b);

    run_bundle(A_NADA, 0, 0, B_VCR, 32'h3084, 0);
    check("vcr que acierta: 0 ciclos", n_stalls, 0);
    check("vcr que acierta: dato", got_b, exp_b);

    run_bundle(A_CARGA, 32'h2040, 0, B_NADA, 0, 0);
    check("carga de la línea del MSHR, ya llena: 0 ciclos", n_stalls, 0);
    check("carga del store que falló: dato", got_a, 32'h3333_4444);


    // ========================================================================
    tb_section("B. Puerto B junto con el puerto A");
    // ========================================================================

    run_bundle(A_CARGA, 32'h1000, 0, B_VCR, 32'h1004, 0);
    check("carga y vcr que aciertan: 1 ciclo", n_stalls, 1);
    check("carga y vcr: dato de A", got_a, exp_a);
    check("carga y vcr: dato de B", got_b, exp_b);

    old = ref_mem[32'h100C >> 2];
    run_bundle(A_NADA, 0, 0, B_CAMCON, 32'h100C, 5'd4);
    check("camcon solo que acierta: 1 ciclo", n_stalls, 1);
    run_bundle(A_CARGA, 32'h100C, 0, B_NADA, 0, 0);
    check("camcon rota la palabra una sola vez", got_a, rol(old, 4));

    old = ref_mem[32'h1010 >> 2];
    run_bundle(A_CARGA, 32'h1010, 0, B_CAMCON, 32'h1010, 5'd8);
    check("carga y camcon en la misma palabra: 2 ciclos", n_stalls, 2);
    check("la carga lee el valor de antes de camcon", got_a, old);
    run_bundle(A_CARGA, 32'h1010, 0, B_NADA, 0, 0);
    check("después: valor rotado", got_a, rol(old, 8));

    old = ref_mem[32'h1014 >> 2];
    run_bundle(A_GUARDAP, 32'h1014, 32'hAAAA_5555, B_CAMCON, 32'h1014, 5'd1);
    check("store y camcon en la misma palabra: 2 ciclos", n_stalls, 2);
    check("camcon lee el valor de antes del store", got_b, old);
    run_bundle(A_CARGA, 32'h1014, 0, B_NADA, 0, 0);
    check("gana camcon (puerto B)", got_a, rol(old, 1));

    old = ref_mem[32'h1018 >> 2];
    run_bundle(A_GUARDAP, 32'h1018, 32'hCAFE_F00D, B_VCR, 32'h1018, 0);
    check("store y vcr en la misma palabra: 1 ciclo", n_stalls, 1);
    check("vcr lee el valor de antes del store", got_b, old);

    check_true("DMEM todavía no tiene el store (está sucio en la L1-D)",
               DMEM.mem[32'h1018 >> 2] !== 32'hCAFE_F00D);
    run_bundle(A_NADA, 0, 0, B_VCR, 32'h1018, 0);
    check("vcr ve el valor que solo está en la L1-D", got_b, 32'hCAFE_F00D);
    run_bundle(A_NADA, 0, 0, B_CAMCON, 32'h1018, 5'd8);
    run_bundle(A_CARGA, 32'h1018, 0, B_NADA, 0, 0);
    check("camcon rota el valor que solo estaba en la L1-D", got_a, rol(32'hCAFE_F00D, 8));

    run_bundle(A_CARGA, 32'h1000, 0, B_VCR, 32'h5000, 0);
    check("vcr que falla y carga que acierta: miss + 1", n_stalls, miss_lat + 1);
    check("dato de A", got_a, exp_a);
    check("dato de B", got_b, exp_b);

    idle(20);
    run_bundle(A_CARGA, 32'h6100, 0, B_CAMCON, 32'h7140, 5'd3);
    check("carga y camcon que fallan: 2 misses + 2", n_stalls, 2 * miss_lat + 2);
    check("dato de A", got_a, exp_a);
    check("dato de B", got_b, exp_b);


    // ========================================================================
    tb_section("C. Vaciado");
    // ========================================================================

    check_true("antes del vaciado DMEM es distinta de la referencia", dmem_diffs() > 0);

    flush(fl_cycles);
    check("con flush_done, DMEM igual a la referencia (palabras distintas)", dmem_diffs(), 0);

    idle(3);
    check("flush_done se mantiene mientras flush_req = 1", flush_done, 1'b1);

    flush_req = 1'b0;
    idle(2);
    check("flush_done baja con flush_req", flush_done, 1'b0);

    run_bundle(A_CARGA, 32'h1018, 0, B_NADA, 0, 0);
    check("después del vaciado la caché sigue: dato", got_a, rol(32'hCAFE_F00D, 8));
    $display("    vaciado en %0d ciclos", fl_cycles);


    // ========================================================================
    tb_section("D. Prueba aleatoria contra la referencia");
    // ========================================================================

    // El VCD guarda solo A, B y C: con esta parte pesaría más de 80 MB
    $dumpoff;

    // 32 líneas: 8 etiquetas (cada 2 KB caen en el mismo conjunto) x 4 conjuntos
    for (int n = 0; n < 3000; n++) begin

        int          a_op, b_op, r;
        logic [31:0] a_ad, b_ad, dat;

        a_ad = 32'h4000 + ($unsigned($random(seed)) % 8) * 32'h800
                        + ($unsigned($random(seed)) % 4) * 32'h20
                        + ($unsigned($random(seed)) % 8) * 4;
        b_ad = 32'h4000 + ($unsigned($random(seed)) % 8) * 32'h800
                        + ($unsigned($random(seed)) % 4) * 32'h20
                        + ($unsigned($random(seed)) % 8) * 4;

        // A veces B usa la misma palabra que A
        if ($unsigned($random(seed)) % 8 == 0)
            b_ad = a_ad;

        a_op = $unsigned($random(seed)) % 4;
        if (a_op == A_GUARDAB)
            a_ad[1:0] = $unsigned($random(seed)) % 4;

        r    = $unsigned($random(seed)) % 10;
        b_op = (r < 6) ? B_NADA : (r < 8) ? B_VCR : B_CAMCON;
        dat  = $random(seed);

        run_bundle(a_op, a_ad, dat, b_op, b_ad, 5'($unsigned($random(seed)) % 32));

        if (a_op == A_CARGA && got_a !== exp_a) begin
            if (errors_a < 5)
                $display("  bundle %0d: A leyó %h en %h, esperado %h", n, got_a, a_ad, exp_a);
            errors_a++;
        end

        if (b_op != B_NADA && got_b !== exp_b) begin
            if (errors_b < 5)
                $display("  bundle %0d: B leyó %h en %h, esperado %h", n, got_b, b_ad, exp_b);
            errors_b++;
        end

        if ($unsigned($random(seed)) % 16 == 0)
            idle($unsigned($random(seed)) % 12);

        if (n == 1500) begin
            flush(fl_cycles);
            check("vaciado a la mitad: DMEM igual a la referencia", dmem_diffs(), 0);
            flush_req = 1'b0;
            idle(2);
        end
    end

    check("cargas de A distintas de la referencia", errors_a, 0);
    check("lecturas de B distintas de la referencia", errors_b, 0);

    flush(fl_cycles);
    check("vaciado final: DMEM igual a la referencia", dmem_diffs(), 0);
    flush_req = 1'b0;

    $display("    3000 bundles, %0d ciclos de stall en total", total_stalls);


    tb_finish("tb_mem_hierarchy");
end

endmodule
