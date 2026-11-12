`timescale 1ns/1ps

/*
================================================================================
 Testbench: tb_archivo

 Descripción:
 ------------------------------------------------------------------------------
 Cifra y descifra un archivo real en el procesador. Lo ejecuta "make archivo"
 (ver Makefile), que antes prepara los archivos de entrada:

     tools/assembler.py   examples/cifrar_archivo.asm    -> cifrar.mem
     tools/assembler.py   examples/descifrar_archivo.asm -> descifrar.mem
     tools/load_file.py   --input <archivo> --address 0x200 -> datos.mem

 Pasos:
   1. Carga datos.mem en la memoria de datos y escribe en 0x100..0x11F la
      contraseña, la candidata, la dirección de fin (0x200 + tamaño
      redondeado a 8 bytes) y la llave.
   2. Ejecuta el programa de cifrado hasta su bucle final (sye x0, fin) y
      vacía la caché y guarda la memoria en cifrado.mem con $writememh.
   3. Aplica reset (borra el banco y la bóveda; la memoria de datos se
      mantiene), ejecuta descifrado, vacía de nuevo y guarda descifrado.mem.
      Vaciar ANTES del reset evita perder líneas sucias y stores con MSHR.
   4. Verifica que ningún programa generó una excepción, que el cifrado
      cambió el archivo, que no se tocó la memoria después del archivo y que
      el descifrado devolvió exactamente el original.

 Después, "make archivo" extrae cifrado.bin y descifrado.bin con
 tools/extract_data.py y compara descifrado.bin con el archivo original.

 Con +SOLO_DESCIFRAR ("make descifrar") el archivo cargado ya viene cifrado:
 solo se ejecuta el programa de descifrado, se verifica que no haya
 excepciones ni cambios fuera del archivo y se guarda descifrado.mem.

 Plusargs:
     +CIFRAR=<.mem>  +DESCIFRAR=<.mem>  +DATOS=<.mem>  +BYTES=<tamaño en bytes>
     +K0=<hex> ... +K3=<hex>  llave (K0 es la de la primera ronda); si no se
                     indica, se usa la llave fija de los ejemplos
     +SOLO_DESCIFRAR solo descifra (no necesita +CIFRAR)
     +MAXCICLOS=<n>  límite de ciclos por programa (por defecto 1000000)

================================================================================
*/

`include "isa_defs.sv"


module tb_archivo;

    // El límite protege la simulación sin sustituir el protocolo por un retardo.
    // Se configura solo para pruebas/diagnóstico; la persistencia siempre exige done=1.
    integer flush_limit = 10000;
    // req nace inactivo; done pertenece al productor y confirma DMEM persistente.
    logic flush_req = 1'b0;
    wire flush_done;

    // Rechaza actividad útil mientras el vaciado necesita avanzar clk. La caché
    // no detiene un pipeline que solo ejecuta ALU o saltos: no existe un halt en
    // esta interfaz. Permitimos NOP y saltos sin enlace, pero no nuevas demandas,
    // escrituras GPR, operaciones cripto ni excepciones que cambiarían el corte.
    // Solo observa señales del núcleo; las escrituras de mantenimiento a DMEM
    // deben seguir funcionando y no se confunden con stores nuevos de CPU.
    task automatic check_flush_quiescence(input string phase);
        begin
            if ({DUT.mem_re,DUT.mem_we,DUT.mem_re_b,DUT.crypto_mem_we} !== 4'b0000 ||
                DUT.crypto_fault !== 1'b0 ||
                (DUT.id_ex_valid && DUT.ex_crypto_valid))
                $fatal(1,"[FAIL] programa no quiescente durante vaciado fase=%s pc=%h ex=%h",phase,DUT.pc,DUT.ex_pc);
            for (int p=0;p<5;p++)
                if (DUT.wb_we[p] !== 1'b0 && DUT.wb_waddr[p] !== 5'd0)
                    $fatal(1,"[FAIL] escritura GPR durante vaciado fase=%s puerto=%0d",phase,p);
        end
    endtask

    // Contrato local del issue28: el llamador ya alcanzó su corte y terminó las
    // lecturas/escrituras útiles. Recibe la fase para diagnosticar cada programa;
    // modifica solo flush_req y consume clk general, nunca core_clk ni reset.
    // #1 sitúa la solicitud fuera del flanco que pudo aceptar el último bundle.
    // Otro #1 deja propagar done combinacional en modos0/1 sin añadir un ciclo.
    // En modo2 esperamos posedge y observamos POST-NBA: MSHR, scan, WBUF y la
    // última palabra de l2_model deben terminar antes de leer DUT.DMEM.mem.
    task automatic flush_cache(input string phase);
        // waited mide mantenimiento hasta done; released mide retorno a FL_IDLE.
        // Ninguno se suma al presupuesto de ejecución útil del programa.
        int waited, released;
        begin
            if ($value$plusargs("FLUSH_MAXCYCLES=%d",flush_limit)) begin end
            if (flush_limit<1) $fatal(1,"[FAIL] límite de vaciado inválido");
            if (flush_req !== 1'b0)
                $fatal(1,"[FAIL] solicitud de vaciado ya activa fase=%s",phase);
            #1; flush_req=1'b1; #1;
            waited=0; released=0;
            // X/Z no son ni espera normal ni éxito. Se informa antes de permitir
            // cualquier dump, manteniendo el diagnóstico de la señal observable.
            while (flush_done !== 1'b1) begin
                if (flush_done !== 1'b0)
                    $fatal(1,"[FAIL] flush_done desconocido fase=%s espera=%0d limite=%0d req=%b done=%b etapa=espera",
                           phase,waited,flush_limit,flush_req,flush_done);
                if (waited>=flush_limit)
                    $fatal(1,"[FAIL] vaciado de caché no completado fase=%s espera=%0d limite=%0d req=%b done=%b etapa=espera",
                           phase,waited,flush_limit,flush_req,flush_done);
                @(posedge clk);
                check_flush_quiescence(phase); // PRE: evita aceptar efectos del programa durante mantenimiento.
                #1; waited++;
            end
            // Bajamos la solicitud después de confirmar persistencia. FL_DONE
            // del productor vuelve a FL_IDLE en el siguiente posedge; en0/1 la
            // respuesta baja combinacionalmente. No se agregan ciclos ficticios.
            flush_req=1'b0; #1;
            while (flush_done !== 1'b0) begin
                if (flush_done !== 1'b1 || released>=flush_limit)
                    $fatal(1,"[FAIL] retorno de vaciado inválido fase=%s espera=%0d limite=%0d req=%b done=%b etapa=salida",
                           phase,released,flush_limit,flush_req,flush_done);
                @(posedge clk); check_flush_quiescence(phase);
                #1; released++;
            end
            $display("[FLUSH] fase=%s modo=%0d espera=%0d salida=%0d",phase,DUT.MEM_MODE,waited,released);
        end
    endtask


// El archivo más grande (64 KB menos 0x200) necesita unos 165 000 ciclos por
// programa; el watchdog de tb_utils.svh debe cubrir los dos programas.
`define TB_TIMEOUT 50000000
`include "tb_utils.svh"


logic clk;
logic reset;

top DUT (
    .clk(clk),
    .reset(reset), .flush_req(flush_req), .flush_done(flush_done),
    .debug_result(),
    .debug_rd(),
    .debug_write()
);

always #5 clk = ~clk;


// ============================================================================
// Contraseña fija y llave (por defecto, la de los ejemplos de docs)
// ============================================================================

localparam logic [31:0] BASE = 32'h200;
localparam logic [31:0] PWD  = 32'h5EC2_E7A1;

logic [3:0][31:0] key;

string  cifrar_file, descifrar_file, datos_file;
integer bytes, max_cycles;
logic [31:0] fin;

logic [31:0] original [0:DMEM_BYTES/4-1];     // memoria de datos antes de cifrar


// Carga un programa en la memoria de instrucciones (el resto queda en NOP)
task automatic load_program(input string path);

    int n;

    for (int i = 0; i < IMEM_BUNDLES; i++)
        DUT.IMEM.memory[i] = '0;

    n = DUT.IMEM.count_bundles(path);
    if (n <= 0)
        $fatal(1, "[FAIL] no se pudo leer el programa %s", path);

    $readmemh(path, DUT.IMEM.memory, 0, n - 1);
    $display("tb_archivo: programa %s (%0d bundles)", path, n);
endtask

// Aplica reset, ejecuta hasta el bucle final (un sye que salta a sí mismo)
// y devuelve los ciclos usados
task automatic run_until_end(input string name, output int cycles);

    @(negedge clk);
    reset = 1;
    repeat (2) @(negedge clk);
    reset = 0;

    cycles = 0;
    while (!(DUT.branch_flush && DUT.bru_target_pc == DUT.ex_pc) && cycles < max_cycles) begin

        @(negedge clk);
        cycles++;
    end

    // El criterio es el salto final observado en EX; no promete retiro de main.
    // Si no llega, no se permite producir un dump ni reiniciar otra ejecución.
    if (cycles>=max_cycles)
        $fatal(1,"[FAIL] programa no alcanza fin fase=%s ciclos=%0d limite=%0d",name,cycles,max_cycles);
    check_true({name, ": llegó al final del programa"}, cycles < max_cycles);
    check({name, ": sin excepciones"}, DUT.trap_count, 32'd0);
endtask


initial begin

    int   cycles_enc, cycles_dec;
    int   changed, wrong, outside, k_given;
    bit   solo_descifrar;
    logic [31:0] k;

    clk   = 0;
    reset = 1;

    solo_descifrar = $test$plusargs("SOLO_DESCIFRAR");

    if ((!solo_descifrar && !$value$plusargs("CIFRAR=%s", cifrar_file)) ||
        !$value$plusargs("DESCIFRAR=%s", descifrar_file) ||
        !$value$plusargs("DATOS=%s", datos_file) ||
        !$value$plusargs("BYTES=%d", bytes))
        $fatal(1, "[FAIL] faltan +CIFRAR, +DESCIFRAR, +DATOS o +BYTES (use make archivo o make descifrar)");

    if (!$value$plusargs("MAXCICLOS=%d", max_cycles))
        max_cycles = 1000000;

    fin = BASE + ((bytes + 7) / 8) * 8;

    if (bytes <= 0 || fin > DMEM_BYTES)
        $fatal(1, "[FAIL] el archivo debe medir entre 1 y %0d bytes", DMEM_BYTES - BASE);

    key = {32'hC3D2_E1F0, 32'h8796_A5B4, 32'h4B5A_6978, 32'h0F1E_2D3C};

    // Llave por parámetro: las 4 palabras o ninguna
    k_given = 0;
    if ($value$plusargs("K0=%h", k)) begin key[0] = k; k_given++; end
    if ($value$plusargs("K1=%h", k)) begin key[1] = k; k_given++; end
    if ($value$plusargs("K2=%h", k)) begin key[2] = k; k_given++; end
    if ($value$plusargs("K3=%h", k)) begin key[3] = k; k_given++; end

    if (k_given != 0 && (k_given != 4 || $isunknown(key)))
        $fatal(1, "[FAIL] la llave necesita 4 palabras hexadecimales: +K0 +K1 +K2 +K3");

    if (solo_descifrar && bytes % 8 != 0)
        $display("tb_archivo: aviso: un archivo cifrado con Feistel4 mide un múltiplo de 8 bytes");

    // Esperar la inicialización de las memorias
    #1;


    tb_section("1. Carga del archivo");

    $readmemh(datos_file, DUT.DMEM.mem);

    DUT.DMEM.mem[32'h100 >> 2] = PWD;           // contraseña inicial
    DUT.DMEM.mem[32'h104 >> 2] = PWD;           // candidata
    DUT.DMEM.mem[32'h108 >> 2] = fin;           // fin del archivo
    for (int i = 0; i < 4; i++)
        DUT.DMEM.mem[(32'h110 >> 2) + i] = key[i];

    for (int a = 0; a < DMEM_BYTES / 4; a++)
        original[a] = DUT.DMEM.mem[a];

    $display("tb_archivo: %0d bytes en 0x%0h..0x%0h (%0d bloques)", bytes, BASE, fin - 1,
             (fin - BASE) / 8);
    $display("tb_archivo: llave K0..K3 = %08h %08h %08h %08h", key[0], key[1], key[2], key[3]);


    if (solo_descifrar) begin

        tb_section("2. Descifrado");

        load_program(descifrar_file);
        run_until_end("descifrado", cycles_dec);
        // También SOLO_DESCIFRAR necesita persistencia, aunque no haya una
        // segunda ejecución. El fin del bucle no sustituye el handshake.
        flush_cache("descifrado");
        $writememh("descifrado.mem", DUT.DMEM.mem);

        outside = 0;
        for (int a = fin / 4; a < DMEM_BYTES / 4; a++)
            if (DUT.DMEM.mem[a] !== original[a])
                outside++;

        check("palabras modificadas después del archivo", outside, 0);
        $display("tb_archivo: descifrado en %0d ciclos", cycles_dec);
    end
    else begin

        tb_section("2. Cifrado");

        load_program(cifrar_file);
        run_until_end("cifrado", cycles_enc);
        // El cifrado puede seguir solo en líneas dirty. Confirmamos persistencia
        // antes del dump y, especialmente, antes del reset que inicia descifrado.
        flush_cache("cifrado");
        $writememh("cifrado.mem", DUT.DMEM.mem);

        changed = 0;
        for (int a = BASE / 4; a < fin / 4; a++)
            if (DUT.DMEM.mem[a] !== original[a])
                changed++;

        check_true("el cifrado cambió el archivo", changed > 0);


        tb_section("3. Descifrado");

        load_program(descifrar_file);
        run_until_end("descifrado", cycles_dec);
        // Después del segundo programa también exigimos persistencia antes de
        // comparar el round-trip; terminar el bucle no garantiza DMEM actualizada.
        flush_cache("descifrado");
        $writememh("descifrado.mem", DUT.DMEM.mem);


        tb_section("4. Comparación con el original");

        wrong   = 0;
        outside = 0;

        for (int a = BASE / 4; a < fin / 4; a++)
            if (DUT.DMEM.mem[a] !== original[a])
                wrong++;

        for (int a = fin / 4; a < DMEM_BYTES / 4; a++)
            if (DUT.DMEM.mem[a] !== original[a])
                outside++;

        check("palabras del archivo distintas al original", wrong, 0);
        check("palabras modificadas después del archivo", outside, 0);

        $display("tb_archivo: cifrado en %0d ciclos, descifrado en %0d ciclos", cycles_enc, cycles_dec);
    end


    tb_finish("tb_archivo");
end

endmodule
