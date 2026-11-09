/*
================================================================================
 Módulo: rom_sync

 Descripción:
 ------------------------------------------------------------------------------
 Memoria de instrucciones síncrona del proyecto 2 (enunciado 3.2.1;
 decisiones-importantes.md 3.1, D1). Reemplaza en top a la memoria
 combinacional del proyecto 1 (rtl/instruction_memory.sv) con el mismo
 nombre de instancia (IMEM), el mismo arreglo memory, la misma carga con
 +IMEM= y la misma función count_bundles, así que los testbenches y las
 herramientas la cargan y la leen igual que antes.

 Lectura síncrona sin cambiar los tiempos:
     Si la lectura se registrara con el PC, el bundle llegaría un ciclo tarde
     y cambiaría la penalización de los saltos. Por eso se registra con el
     SIGUIENTE PC (next_address), que top calcula con la misma regla de
     rtl/pc_branch.sv:

         next_pc = reset ? 0 : (redirect ? redirect_pc : pc + 16)

     En el mismo flanco en que pc toma next_pc, la ROM toma memory[next_pc].
     Durante todo el ciclo el bundle es memory[pc], igual que con la memoria
     combinacional: siguen iguales la penalización de 2 ciclos de los saltos,
     la regla N+3, el ensamblador y el compilador.

     clk es core_clk: durante un stall de la caché la ROM se congela junto
     con el PC y sigue entregando el mismo bundle.

 Parámetro SYNC:
     1  lectura registrada (por defecto en top, ROM_SYNC = 1)
     0  lectura combinacional con address, como en el proyecto 1; sirve para
        comparar las dos en tb_rom_sync

 Carga del programa (igual que rtl/instruction_memory.sv):
     Al iniciar la simulación toda la memoria queda en NOP (0). Con el
     plusarg +IMEM=<archivo.mem> se carga con $readmemh (una línea por
     bundle, 32 dígitos hexadecimales, slot CRIPTO en los bits altos).
     Los testbenches también pueden escribir memory[] por jerarquía después
     del tiempo 0. Con SYNC = 1 el programa tiene que estar escrito antes de
     un flanco con reset = 1, que es cuando la ROM lee el bundle 0; todos los
     testbenches lo cargan así (durante el reset).

 Direccionamiento:
     El índice es address[...:4] (el PC avanza BUNDLE_BYTES = 16 por bundle).
     Una dirección fuera de la memoria vuelve a empezar desde el inicio.

 Tamaño: 1024 bundles (16 KB, IMEM_BUNDLES), dentro del máximo de 64 KB del
 enunciado. Agrandarla cambiaría IMEM_BUNDLES y TRAP_VECTOR en isa_defs.sv,
 que también usa el ensamblador.
================================================================================
*/
`include "isa_defs.sv"

module rom_sync #(

    parameter int DEPTH = IMEM_BUNDLES,         // cantidad de bundles
    parameter bit SYNC  = 1'b1                  // 1: lectura registrada; 0: combinacional
) (

    input  logic                 clk,           // core_clk
    input  logic [31:0]          address,       // pc (lectura combinacional)
    input  logic [31:0]          next_address,  // siguiente pc (lectura registrada)

    output logic [BUNDLE_W-1:0]  instruction_bundle
);


localparam int OFFSET_W = $clog2(BUNDLE_BYTES);  // 4: bits de byte dentro del bundle
localparam int INDEX_W  = $clog2(DEPTH);

logic [BUNDLE_W-1:0] memory [0:DEPTH-1];
logic [BUNDLE_W-1:0] bundle_q = '0;             // bundle leído en el último flanco

string program_file;
int    program_bundles;


// Cuenta las líneas del archivo que empiezan con un dígito hexadecimal (los
// bundles), para cargar con $readmemh exactamente ese rango. -1 si no existe.
function automatic int count_bundles(input string path);

    integer           fd, r;
    reg [8*512-1:0]   line;
    reg [7:0]         c;
    int               n;

    n  = 0;
    fd = $fopen(path, "r");

    if (fd == 0)
        return -1;

    while (!$feof(fd)) begin

        r = $fgets(line, fd);

        if (r > 0) begin

            c = line[8*r-1 -: 8];               // primer carácter de la línea
            if ((c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F"))
                n++;
        end
    end

    $fclose(fd);
    return n;
endfunction


initial begin

    for (int i = 0; i < DEPTH; i++)
        memory[i] = '0;                          // NOP en los 4 slots

    if ($value$plusargs("IMEM=%s", program_file)) begin

        program_bundles = count_bundles(program_file);

        if (program_bundles < 0)
            $fatal(1, "[IMEM] no se encontró el programa %s", program_file);
        else if (program_bundles > DEPTH)
            $fatal(1, "[IMEM] %s tiene %0d bundles; la memoria admite %0d",
                   program_file, program_bundles, DEPTH);
        else if (program_bundles > 0)
            $readmemh(program_file, memory, 0, program_bundles - 1);

        $display("[IMEM] %0d bundles cargados desde %s", program_bundles, program_file);
    end
end


// Lectura síncrona: en el flanco en que el PC toma next_address
always @(posedge clk)
    bundle_q <= memory[next_address[INDEX_W+OFFSET_W-1:OFFSET_W]];

assign instruction_bundle = SYNC ? bundle_q
                                 : memory[address[INDEX_W+OFFSET_W-1:OFFSET_W]];


endmodule
