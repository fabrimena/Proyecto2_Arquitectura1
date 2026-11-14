/*
================================================================================
 Cuerpo compartido de los testbenches de la caché L2
================================================================================
 Descripción:
 ------------------------------------------------------------------------------
 Este archivo NO es un testbench por sí mismo: es el cuerpo que comparten
 tb-p2/tb_l2_cache.sv (política EXCLUSIVE, la de por defecto) y
 tb-p2/tb_l2_cache_nine.sv (política NINE). Cada uno de esos archivos define
 las macros L2_TB_MODULE (nombre del módulo) y L2_TB_INCL (política de
 inclusión) y luego incluye este archivo.

 El motivo de compartirlo es que las dos políticas se prueban con el MISMO
 estímulo: solo cambian las expectativas, y esas se deciden con IS_EXCL dentro
 del propio cuerpo. Duplicar 600 líneas de testbench para cambiar una
 constante es una fuente de errores que no compensa.

 Qué se comprueba (las dos políticas):
   0. Estado inicial: la L2 arranca libre y acepta peticiones.
   1. Fallo de lectura: 8 + Tmem = 61 ciclos y la línea viene del nivel
      inferior.
   2. Acierto de lectura: 8 ciclos exactos.
   3. Política de inclusión: en exclusiva la línea se MUEVE (el segundo acceso
      vuelve a fallar) y en NINE la L2 la CONSERVA (el segundo acceso acierta).
   4. Escritura parcial: write-allocate (trae la línea vieja) y mezcla de
      bytes (los bytes no escritos se conservan).
   5. Conflicto: 4 vías, desalojo de la víctima del pseudo-LRU y write-back de
      la línea sucia al nivel inferior.
   6. Línea reenviada por el eviction buffer (read_forwarded): el bit sucio
      se propaga. En NINE la copia guardada queda sucia y baja a la memoria
      cuando se desaloja; en exclusiva la línea va sucia a la L1-D y la L2 no
      la guarda.
   7. La L2 vuelve a estar libre.

 Nota sobre la latencia: el enunciado dice que el acierto de la L2 son 8
 ciclos y el fallo son 8 + Tmem. La latencia del fallo NO depende de que haya
 que desalojar una línea antes: el contador interno sigue corriendo durante el
 desalojo, así que un fallo con desalojo también dura 8 + Tmem.

 Uso: make tb_l2_cache / make tb_l2_cache_nine
================================================================================
*/

`ifndef L2_TB_MODULE
`define L2_TB_MODULE tb_l2_cache
`endif

`ifndef L2_TB_INCL
`define L2_TB_INCL INCL_EXCLUSIVE
`endif

// Nombre del testbench como texto (para el resumen y el archivo de ondas).
`ifndef L2_TB_NAME
`define L2_TB_NAME "tb_l2_cache"
`endif

`timescale 1ns/1ps

`include "cache_defs.sv"


// =============================================================================
// Módulo auxiliar: el nivel inferior de la L2, simulado
// =============================================================================
//
// Sustituye al eviction buffer + controlador de memoria con un modelo simple:
//   - acepta las líneas que la L2 desaloja (write-back) y las guarda en la
//     memoria simulada;
//   - responde a las peticiones de línea con una latencia fija (LAT) y el
//     contenido de esa memoria;
//   - puede responder "reenviada" (read_forwarded) para simular el caso en que
//     el eviction buffer reenvía una línea sucia que tiene pendiente.
//
// La latencia por omisión es T_MEM_CYCLES (53, el valor del enunciado), con lo
// que un fallo de lectura dura 8 + 53 = 61 ciclos.

module l2_lower_model #(
    parameter integer LAT = 53
) (
    input  logic        clk,
    input  logic        reset,

    // Interfaz de víctimas (la L2 desaloja una línea sucia).
    input  logic        evict_valid,
    input  logic [31:0] evict_addr,
    input  logic [255:0] evict_line,
    output logic        evict_ready,

    // Interfaz de lectura de líneas.
    input  logic        read_req,
    input  logic [31:0] read_addr,
    output logic        read_ready,
    output logic [255:0] read_line,
    output logic        read_forwarded,

    // Control del testbench: si está activo, la próxima respuesta llega
    // marcada como reenviada (línea sucia pendiente en el buffer).
    input  logic        force_forwarded,

    // Observabilidad para las comprobaciones.
    output integer      evict_count,
    output logic [31:0] evict_last_addr,
    output logic [255:0] evict_last_line,
    output integer      read_count,
    output logic [31:0] read_last_addr
);

    // Memoria simulada: 2^11 líneas (la dirección física son 16 bits y la
    // línea son 32 bytes).
    localparam integer MEM_LINES = 2048;

    logic [255:0] mem [0:MEM_LINES-1];

    logic        busy;
    integer      cnt;
    logic [31:0] addr_q;

    integer i;
    integer j;
    logic [255:0] tmp;

    // El buffer de desalojo siempre tiene sitio en este modelo.
    assign evict_ready = 1'b1;

    // Contenido de la memoria: cada palabra depende de la línea y del número
    // de palabra, para que el testbench pueda calcularlo por su cuenta.
    initial begin
        for (i = 0; i < MEM_LINES; i = i + 1) begin
            tmp = '0;
            for (j = 0; j < 8; j = j + 1)
                tmp[32*j +: 32] = 32'hC0DE0000 + i*8 + j;
            mem[i] = tmp;
        end
    end

    always @(posedge clk) begin

        read_ready     <= 1'b0;
        read_forwarded <= 1'b0;

        if (reset) begin
            busy            <= 1'b0;
            cnt             <= 0;
            evict_count     <= 0;
            read_count      <= 0;
            evict_last_addr <= 32'd0;
            evict_last_line <= '0;
            read_last_addr  <= 32'd0;
        end
        else begin

            // ---- La L2 desaloja una línea: se escribe en la memoria ---------
            if (evict_valid && evict_ready) begin
                mem[evict_addr[15:5]] <= evict_line;
                evict_count     <= evict_count + 1;
                evict_last_addr <= evict_addr;
                evict_last_line <= evict_line;
            end

            // ---- Petición de línea ------------------------------------------
            if (read_req && !busy) begin
                busy           <= 1'b1;
                cnt            <= LAT;
                addr_q         <= read_addr;
                read_count     <= read_count + 1;
                read_last_addr <= read_addr;
            end
            else if (busy) begin
                if (cnt <= 1) begin
                    busy           <= 1'b0;
                    read_ready     <= 1'b1;
                    read_line      <= mem[addr_q[15:5]];
                    read_forwarded <= force_forwarded;
                end
                else begin
                    cnt <= cnt - 1;
                end
            end
        end
    end

endmodule


// =============================================================================
// Testbench
// =============================================================================

module `L2_TB_MODULE;

`include "tb_utils.svh"

    // Política de inclusión que se está probando.
    localparam logic [1:0] INCL    = `L2_TB_INCL;
    localparam logic        IS_EXCL = (INCL == INCL_EXCLUSIVE);

    // ------------------------------------------------------------------
    // Reloj y reinicio
    // ------------------------------------------------------------------

    logic clk   = 1'b0;
    logic reset = 1'b1;

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Bus L1-D <-> L2 (versión 2)
    // ------------------------------------------------------------------

    logic                   l2_req    = 1'b0;
    logic                   l2_we     = 1'b0;
    logic [31:0]            l2_addr   = 32'd0;
    logic [LINE_W-1:0]      l2_wline  = '0;
    logic [LINE_MASK_W-1:0] l2_be     = '0;
    logic                   l2_wdirty = 1'b0;

    logic                   l2_gnt;
    logic                   l2_rvalid;
    logic [LINE_W-1:0]      l2_rline;
    logic                   l2_rdirty;
    logic                   idle;

    // ------------------------------------------------------------------
    // Bus L2 <-> eviction buffer
    // ------------------------------------------------------------------

    logic                   evict_valid;
    logic [31:0]            evict_addr;
    logic [LINE_W-1:0]      evict_line;
    logic                   evict_ready;

    logic                   read_req;
    logic [31:0]            read_addr;
    logic                   read_ready;
    logic [LINE_W-1:0]      read_line;
    logic                   read_forwarded;

    logic                   force_forwarded = 1'b0;

    // Observabilidad del nivel inferior.
    integer                 lower_evict_count;
    logic [31:0]            lower_evict_addr;
    logic [LINE_W-1:0]      lower_evict_line;
    integer                 lower_read_count;
    logic [31:0]            lower_read_addr;

    // ------------------------------------------------------------------
    // La caché L2 bajo prueba
    // ------------------------------------------------------------------

    l2_cache #(
        .REPL_POLICY(RP2_PLRU),
        .INCL_POLICY(INCL)
    ) DUT (
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
        .idle(idle),

        .evict_valid(evict_valid),
        .evict_addr(evict_addr),
        .evict_line(evict_line),
        .evict_ready(evict_ready),

        .read_req(read_req),
        .read_addr(read_addr),
        .read_ready(read_ready),
        .read_line(read_line),
        .read_forwarded(read_forwarded)
    );

    // ------------------------------------------------------------------
    // El nivel inferior simulado
    // ------------------------------------------------------------------

    l2_lower_model #(
        .LAT(T_MEM_CYCLES)
    ) LOWER (
        .clk(clk),
        .reset(reset),

        .evict_valid(evict_valid),
        .evict_addr(evict_addr),
        .evict_line(evict_line),
        .evict_ready(evict_ready),

        .read_req(read_req),
        .read_addr(read_addr),
        .read_ready(read_ready),
        .read_line(read_line),
        .read_forwarded(read_forwarded),

        .force_forwarded(force_forwarded),

        .evict_count(lower_evict_count),
        .evict_last_addr(lower_evict_addr),
        .evict_last_line(lower_evict_line),
        .read_count(lower_read_count),
        .read_last_addr(lower_read_addr)
    );


    // ======================================================================
    // Direcciones de prueba
    // ======================================================================
    //
    // La dirección física son 16 bits: la etiqueta es addr[15:12], el
    // conjunto es addr[11:5] y el desplazamiento dentro de la línea es
    // addr[4:0]. Las direcciones 0x?200 comparten el conjunto 0x10 y se
    // distinguen por la etiqueta, así que todas compiten por las mismas 4
    // vías: es el conflicto que se quiere provocar.

    localparam logic [31:0] ADDR_A = 32'h0000_0200;   // conjunto 0x10, etiqueta 0
    localparam logic [31:0] ADDR_B = 32'h0000_1200;   // conjunto 0x10, etiqueta 1
    localparam logic [31:0] ADDR_C = 32'h0000_2200;   // conjunto 0x10, etiqueta 2
    localparam logic [31:0] ADDR_D = 32'h0000_3200;   // conjunto 0x10, etiqueta 3
    localparam logic [31:0] ADDR_E = 32'h0000_4200;   // conjunto 0x10, etiqueta 4

    localparam logic [31:0] ADDR_F = 32'h0000_0400;   // conjunto 0x20, etiqueta 0
    localparam logic [31:0] ADDR_G = 32'h0000_0600;   // conjunto 0x30, etiqueta 0
    localparam logic [31:0] ADDR_H = 32'h0000_1600;   // conjunto 0x30, etiqueta 1
    localparam logic [31:0] ADDR_I = 32'h0000_2600;   // conjunto 0x30, etiqueta 2
    localparam logic [31:0] ADDR_J = 32'h0000_3600;   // conjunto 0x30, etiqueta 3
    localparam logic [31:0] ADDR_K = 32'h0000_4600;   // conjunto 0x30, etiqueta 4

    // Máscara de un solo byte (el primero de la línea) y máscara completa.
    localparam logic [LINE_MASK_W-1:0] BE_BYTE0 = {{(LINE_MASK_W-1){1'b0}}, 1'b1};
    localparam logic [LINE_MASK_W-1:0] BE_ALL   = {LINE_MASK_W{1'b1}};

    // El valor que se escribe en el primer byte de la línea.
    localparam logic [7:0] BYTE0_VALUE = 8'hAB;


    // ======================================================================
    // Utilidades
    // ======================================================================

    // El contenido de la línea que está en la memoria simulada.
    function automatic logic [LINE_W-1:0] mem_pattern(input logic [31:0] addr);

        logic [LINE_W-1:0] r;
        integer idx;
        integer j;

        begin
            idx = addr[15:5];
            r   = '0;
            for (j = 0; j < LINE_WORDS; j = j + 1)
                r[32*j +: 32] = 32'hC0DE0000 + idx*8 + j;
            mem_pattern = r;
        end
    endfunction

    // Igual, pero con el primer byte cambiado (para el write-allocate).
    function automatic logic [LINE_W-1:0] pattern_with_byte0(input logic [31:0] addr);

        logic [LINE_W-1:0] r;

        begin
            r = mem_pattern(addr);
            r[7:0] = BYTE0_VALUE;
            pattern_with_byte0 = r;
        end
    endfunction

    // Comparación de líneas completas (check() solo admite 32 bits).
    task automatic check_line(input string name,
                               input logic [LINE_W-1:0] got,
                               input logic [LINE_W-1:0] exp);

        tb_checks++;

        if (got !== exp) begin
            tb_errors++;
            $display("  [FAIL] %s: obtenido=0x%064h esperado=0x%064h", name, got, exp);
        end
        else if (tb_verbose)
            $display("  [ ok ] %s", name);
    endtask

    // Espera a que la L2 vuelva a estar libre.
    task automatic wait_idle;

        integer guard;

        begin
            guard = 0;
            while (!idle && guard < 1000) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end

            if (guard >= 1000) begin
                tb_errors++;
                $display("  [FAIL] la L2 no vuelve a estado libre");
            end
        end
    endtask

    // Una lectura por el bus versión 2. Devuelve la línea, el bit sucio y el
    // número de ciclos que tardó desde la aceptación.
    task automatic do_read(input  logic [31:0] addr,
                           output logic [LINE_W-1:0] rline,
                           output logic         rdirty,
                           output integer       cycles);

        integer guard;

        begin
            wait_idle();

            @(negedge clk);
            l2_req    = 1'b1;
            l2_we     = 1'b0;
            l2_addr   = addr;
            l2_be     = '0;
            l2_wline  = '0;
            l2_wdirty = 1'b0;

            @(posedge clk); #1;                 // ciclo de aceptación

            check("la L2 no acepta otra petición mientras está ocupada",
                  l2_gnt, 32'd0);

            @(negedge clk);
            l2_req = 1'b0;

            cycles = 1;
            guard  = 0;

            while (!l2_rvalid && guard < 2000) begin
                @(posedge clk); #1;
                cycles = cycles + 1;
                guard  = guard + 1;
            end

            if (guard >= 2000) begin
                tb_errors++;
                $display("  [FAIL] timeout esperando la respuesta de la lectura");
            end

            rline  = l2_rline;
            rdirty = l2_rdirty;

            check("la L2 vuelve a aceptar peticiones", l2_gnt, 32'd1);

            wait_idle();
        end
    endtask

    // Una escritura por el bus versión 2. La escritura termina al ser
    // aceptada: no hay respuesta.
    task automatic do_write(input logic [31:0]           addr,
                            input logic [LINE_W-1:0]      wline,
                            input logic [LINE_MASK_W-1:0] be,
                            input logic                   wdirty);

        begin
            wait_idle();

            @(negedge clk);
            l2_req    = 1'b1;
            l2_we     = 1'b1;
            l2_addr   = addr;
            l2_wline  = wline;
            l2_be     = be;
            l2_wdirty = wdirty;

            @(posedge clk); #1;                 // ciclo de aceptación

            check("la L2 no acepta otra petición mientras está ocupada",
                  l2_gnt, 32'd0);

            @(negedge clk);
            l2_req = 1'b0;

            wait_idle();

            check("la L2 vuelve a aceptar peticiones", l2_gnt, 32'd1);
        end
    endtask


    // ======================================================================
    // Secuencia de pruebas
    // ======================================================================

    logic [LINE_W-1:0] line;
    logic              dirty;
    integer            cycles;

    // Desalojos contados justo antes de la sección 6, para poder comparar
    // con un delta y no con un total absoluto. En NINE el conjunto de la
    // sección 5 se llena con un fallo de lectura, y ese desalojo también
    // cuenta: el total absoluto depende de cuántas líneas se han guardado
    // antes.
    integer            evict_count_prev;

    initial begin

        $dumpfile($sformatf("%s.vcd", `L2_TB_NAME));
        $dumpvars(0, `L2_TB_MODULE);

        // ------------------------------------------------------------------
        tb_section("0. Reinicio");
        // ------------------------------------------------------------------

        reset = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        @(negedge clk);

        check_true("la L2 está libre después del reinicio", idle);
        check_true("la L2 acepta peticiones", l2_gnt);
        check("no hay respuesta pendiente", l2_rvalid, 32'd0);

        // ------------------------------------------------------------------
        tb_section("1. Fallo de lectura: 8 + Tmem ciclos");
        // ------------------------------------------------------------------

        do_read(ADDR_A, line, dirty, cycles);

        check("el fallo dura 8 + Tmem ciclos", cycles, 8 + T_MEM_CYCLES);
        check_line("la línea viene del nivel inferior", line, mem_pattern(ADDR_A));
        check("la línea viene limpia", dirty, 32'd0);
        check("el nivel inferior recibió una petición", lower_read_count, 1);
        check("la petición es por la dirección de la línea",
              lower_read_addr, ADDR_A & 32'hFFFF_FFE0);
        check_true("la L2 vuelve a estar libre", idle);

        // ------------------------------------------------------------------
        tb_section("2. Acierto de lectura: 8 ciclos");
        // ------------------------------------------------------------------
        //
        // Se escribe la línea completa: en exclusiva es una víctima de la
        // L1-D y en NINE es una copia. En los dos casos la L2 la guarda, así
        // que la lectura siguiente acierta.

        do_write(ADDR_A, mem_pattern(ADDR_A), BE_ALL, 1'b1);

        do_read(ADDR_A, line, dirty, cycles);

        check("el acierto dura 8 ciclos", cycles, 8);
        check_line("la línea devuelta es la que se escribió", line, mem_pattern(ADDR_A));

        if (IS_EXCL)
            check("en exclusiva la línea se entrega sucia", dirty, 32'd1);
        else
            check("en NINE la copia se entrega limpia", dirty, 32'd0);

        // ------------------------------------------------------------------
        tb_section("3. Política de inclusión");
        // ------------------------------------------------------------------

        do_read(ADDR_A, line, dirty, cycles);

        if (IS_EXCL) begin
            check("en exclusiva la línea se MUEVE: el segundo acceso falla",
                  cycles, 8 + T_MEM_CYCLES);
            check_line("y trae la línea de la memoria", line, mem_pattern(ADDR_A));
        end
        else begin
            check("en NINE la L2 CONSERVA la línea: el segundo acceso acierta",
                  cycles, 8);
            check_line("y devuelve lo mismo", line, mem_pattern(ADDR_A));
        end

        // ------------------------------------------------------------------
        tb_section("4. Escritura parcial: write-allocate y mezcla de bytes");
        // ------------------------------------------------------------------
        //
        // ADDR_F no está en la L2. Una escritura parcial no trae los datos:
        // la L2 tiene que traer la línea vieja (write-allocate), mezclarla y
        // guardarla.

        do_write(ADDR_F, pattern_with_byte0(ADDR_F), BE_BYTE0, 1'b0);

        do_read(ADDR_F, line, dirty, cycles);

        check("tras la escritura parcial la línea está en la L2", cycles, 8);
        check_line("los bytes no escritos se conservan",
                   line, pattern_with_byte0(ADDR_F));

        // ------------------------------------------------------------------
        tb_section("5. Conflicto: 4 vías y desalojo con write-back");
        // ------------------------------------------------------------------
        //
        // Se llenan las cuatro vías del conjunto 0x10 con líneas sucias. La
        // quinta no cabe: la L2 desaloja la víctima que propone el
        // pseudo-LRU y, como está sucia, la baja al nivel inferior.

        do_write(ADDR_A, mem_pattern(ADDR_A), BE_ALL, 1'b1);   // vía 0
        do_write(ADDR_B, mem_pattern(ADDR_B), BE_ALL, 1'b1);   // vía 1
        do_write(ADDR_C, mem_pattern(ADDR_C), BE_ALL, 1'b1);   // vía 2
        do_write(ADDR_D, mem_pattern(ADDR_D), BE_ALL, 1'b1);   // vía 3

        do_write(ADDR_E, mem_pattern(ADDR_E), BE_ALL, 1'b1);   // desaloja

        check("la línea desalojada bajó al nivel inferior", lower_evict_count, 1);
        check("es la línea de la vía que propone el pseudo-LRU",
              lower_evict_addr, ADDR_A & 32'hFFFF_FFE0);
        check_line("y baja con los datos que tenía", lower_evict_line, mem_pattern(ADDR_A));

        do_read(ADDR_E, line, dirty, cycles);
        check("la línea nueva está en la L2", cycles, 8);

        do_read(ADDR_A, line, dirty, cycles);
        check("la línea desalojada ya no está", cycles, 8 + T_MEM_CYCLES);

        // ------------------------------------------------------------------
        tb_section("6. Línea reenviada por el eviction buffer");
        // ------------------------------------------------------------------
        //
        // El buffer solo guarda líneas sucias: cuando reenvía una de ellas
        // al que la pide, la respuesta va marcada (read_forwarded).

        force_forwarded = 1'b1;
        do_read(ADDR_G, line, dirty, cycles);
        force_forwarded = 1'b0;

        check("el fallo de una línea reenviada dura 8 + Tmem",
              cycles, 8 + T_MEM_CYCLES);
        check_line("la línea reenviada es la de la memoria", line, mem_pattern(ADDR_G));

        if (IS_EXCL) begin

            check("en exclusiva la línea reenviada se entrega sucia", dirty, 32'd1);

            do_read(ADDR_G, line, dirty, cycles);
            check("en exclusiva la L2 no guarda la línea",
                  cycles, 8 + T_MEM_CYCLES);
        end
        else begin

            check("en NINE la copia se entrega limpia", dirty, 32'd0);

            // La copia que se guarda tiene que quedar SUCIA: si se guardara
            // limpia, al desalojarla se perderían los datos. Para verlo hace
            // falta desalojarla, y para desalojar ESA línea concreta hay que
            // llenar el conjunto: con las cuatro vías ocupadas en orden, el
            // árbol del pseudo-LRU deja como víctima la primera que entró,
            // que es justo la línea reenviada.
            //
            // El conteo se compara con un delta, no con un total: en NINE la
            // sección 5 ya dejó un desalojo más (el del fallo de lectura que
            // vuelve a llenar el conjunto), así que el total depende del
            // camino recorrido y no de esta sección.
            evict_count_prev = lower_evict_count;

            do_write(ADDR_H, mem_pattern(ADDR_H), BE_ALL, 1'b1);   // vía 1
            do_write(ADDR_I, mem_pattern(ADDR_I), BE_ALL, 1'b1);   // vía 2
            do_write(ADDR_J, mem_pattern(ADDR_J), BE_ALL, 1'b1);   // vía 3

            do_write(ADDR_K, mem_pattern(ADDR_K), BE_ALL, 1'b1);   // desaloja

            check("la línea reenviada bajó sucia al nivel inferior",
                  lower_evict_count - evict_count_prev, 1);
            check("y es la línea reenviada",
                  lower_evict_addr, ADDR_G & 32'hFFFF_FFE0);
            check_line("con sus datos", lower_evict_line, mem_pattern(ADDR_G));
        end

        // ------------------------------------------------------------------
        tb_section("7. La L2 vuelve a estar libre");
        // ------------------------------------------------------------------

        wait_idle();
        check_true("la L2 está libre", idle);
        check_true("y acepta peticiones", l2_gnt);

        tb_finish(`L2_TB_NAME);
    end

endmodule
