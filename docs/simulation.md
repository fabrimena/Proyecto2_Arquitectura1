# Simulación

Cómo se simula el procesador, cómo está modelado cada componente (banco de registros, unidades
funcionales, memoria y bóveda) y cómo el ensamblador y las herramientas de archivos se conectan con la
simulación.

## Contenido

1. [Herramientas](#1-herramientas)
2. [Comandos](#2-comandos)
3. [Programas y archivos](#3-programas-y-archivos)
4. [Flujo de compilación](#4-flujo-de-compilación)
5. [Formato estándar de testbench](#5-formato-estándar-de-testbench)
6. [Banco de registros (`regfile`)](#6-banco-de-registros-regfile)
7. [Writeback (`wb`)](#7-writeback-wb)
8. [ALU (`alu`)](#8-alu-alu)
9. [Unidad criptográfica (`crypto_unit`, `key_vault`)](#9-unidad-criptográfica-crypto_unit-key_vault)
10. [LSU y memoria de datos (`lsu`, `memory`)](#10-lsu-y-memoria-de-datos-lsu-memory)
11. [BRU (`bru`)](#11-bru-bru)
12. [Ensamblador y ejecución de programas](#12-ensamblador-y-ejecución-de-programas)
13. [Testbenches y cobertura](#13-testbenches-y-cobertura)

## 1. Herramientas

| Herramienta | Versión probada | Uso |
|:---|:---|:---|
| Icarus Verilog (`iverilog`, `vvp`) | 12.0 | Simulador (SystemVerilog con `-g2012`) |
| GTKWave | 3.3.116 | Ver los `.vcd` |
| GNU make y bash | 4.3 y 5 | `make sim` y un target por prueba |
| Python | 3.10 o posterior | Ensamblador y herramientas de archivos, sin paquetes externos |

```bash
sudo apt install iverilog gtkwave make python3
```

## 2. Comandos

| Comando | Qué hace |
|:---|:---|
| `make sim` | Compila y ejecuta todos los `tb/tb_*.sv` y muestra un resumen |
| `make tb_alu` | Ejecuta un solo testbench (recompila solo si cambió algo) |
| `make waves TB=tb_alu` | Abre su `.vcd` en GTKWave |
| `make archivo [ARCHIVO=ruta]` | Cifra y descifra un archivo en el procesador (sección 3) |
| `make descifrar ARCHIVO=ruta LLAVE=K0,K1,K2,K3` | Descifra un archivo que ya viene cifrado, con la llave dada (sección 3) |
| `make test-assembler`, `make test-programs` | Pruebas del ensamblador y de los programas de `examples/` sobre el RTL |
| `make list`, `make clean`, `make help` | Lista los testbenches, borra `build/`, muestra la ayuda |

`make sim` clasifica cada testbench como `PASS` (imprimió `[PASS]` y terminó con código 0), `FAIL`
(imprimió `[FAIL]` o terminó con error), `SIN-CHEQUEO` (corrió pero no se autoverifica) o `NO-COMPILA`
(detalle en `build/<tb>/compile.log`), y termina con error si hay algún `FAIL` o `NO-COMPILA`.
Resultado actual:

```
Resumen: 22 PASS, 0 FAIL, 0 NO-COMPILA, 0 SIN-CHEQUEO
```

Cada testbench deja en `build/<tb>/` el ejecutable (`sim.vvp`), `compile.log`, `sim.log` y su `.vcd`.

## 3. Programas y archivos

**Memoria de instrucciones.** Tiene `IMEM_BUNDLES` = 1024 bundles (16 KB) y arranca llena de NOP.
Con `+IMEM=<archivo.mem>` carga un programa con `$readmemh`: una línea por bundle, 32 dígitos
hexadecimales, con el slot CRIPTO en los bits altos (el formato del ensamblador). Los testbenches
también pueden escribir `DUT.IMEM.memory[]` directamente. Para correr un programa propio se usa
`tools/run_program.py` (sección 12).

**Cifrado de un archivo** (`make archivo`):

```bash
make archivo                                         # examples/archivos/mensaje.txt
make archivo ARCHIVO=examples/archivos/imagen.bmp    # cualquier archivo de hasta 65024 bytes
```

1. `tools/assembler.py` ensambla `examples/cifrar_archivo.asm` y `examples/descifrar_archivo.asm`.
2. `tools/load_file.py` carga el archivo en la memoria de datos desde `0x200`.
3. `tests/rtl/tb_archivo.sv` escribe la contraseña, la llave y la dirección de fin en `0x100`–`0x11F`,
   ejecuta el cifrado, guarda la memoria en `cifrado.mem`, aplica reset, ejecuta el descifrado y
   guarda `descifrado.mem`. Verifica que no haya excepciones, que el cifrado cambie el archivo y que
   no se toque memoria fuera de él.
4. `tools/extract_data.py` saca `cifrado.bin` y `descifrado.bin`, y `descifrado.bin` se compara con
   el original.

Todo queda en `build/archivo/`. Cada bloque de 8 bytes tarda 20 ciclos: 4 rondas, las esperas de la
regla N+3 y los 2 ciclos del salto del bucle. La comparación del cifrado contra la implementación de
referencia del enunciado la hacen `tb_crypto_unit` y `tb_pipeline_cripto`.

**Descifrar un archivo recibido** (`make descifrar ARCHIVO=ruta LLAVE=K0,K1,K2,K3`). El mismo testbench,
con `+SOLO_DESCIFRAR` y la llave en `+K0`…`+K3`, carga el archivo cifrado desde `0x200`, ejecuta solo
`examples/descifrar_archivo.asm`, verifica que no haya excepciones ni cambios fuera del archivo y guarda
`descifrado.mem`; `extract_data.py` lo deja en `build/descifrar/resultado.bin`. Supone bloques de 8
bytes con L y R en *little-endian*, como el código de referencia del enunciado.

## 4. Flujo de compilación

```bash
iverilog -g2012 -Wall -Wno-timescale -I rtl -I tb -s tb_x -o build/tb_x/sim.vvp rtl/*.sv tb/tb_x.sv
cd build/tb_x && vvp -n sim.vvp
```

- Todo `rtl/` se compila con cada testbench, así que un módulo o un testbench nuevo no requiere tocar
  el Makefile. `-s tb_x` fija el módulo superior.
- `-I rtl -I tb` resuelve los `` `include `` de `isa_defs.sv` y `tb_utils.svh`, que tienen guardas
  `` `ifndef ``.
- `-Wno-timescale`: el RTL no usa retardos; solo los testbenches declaran `` `timescale 1ns/1ps ``.
- `vvp` corre dentro de `build/tb_x/`, donde queda el `.vcd`; `-n` hace que `$stop` termine la
  simulación.

## 5. Formato estándar de testbench

Cada `tb/tb_<modulo>.sv` tiene `` `timescale 1ns/1ps ``, un encabezado con los casos que cubre,
`` `include "tb_utils.svh" `` y `$dumpfile`/`$dumpvars`. El estímulo cambia en el flanco de bajada y
el diseño captura en el de subida, para evitar carreras. Cada resultado se verifica con `check` o
`check_true`, los vectores aleatorios usan `$random(seed)` (`+seed=N`) y el testbench termina con
`tb_finish`.

| Utilidad de `tb/tb_utils.svh` | Qué hace |
|:---|:---|
| `check(nombre, obtenido, esperado)` | Compara con `!==` (un `X` o `Z` también falla) e imprime `[FAIL]` con ambos valores |
| `check_true(nombre, condición)` | Verifica que la condición sea 1 |
| `tb_section(nombre)` | Imprime el encabezado de un grupo de pruebas |
| `tb_finish(nombre)` | Imprime `[PASS] nombre: N verificaciones` y llama a `$finish`, o `[FAIL]` y `$fatal` |
| Watchdog | `[FAIL]` si se supera `` `TB_TIMEOUT `` (1 000 000 por defecto; se redefine antes del `` `include ``) |

**Parámetros** de `rtl/isa_defs.sv`, que los módulos usan en lugar de números fijos:

| Parámetro | Valor | Uso |
|:---|:---|:---|
| `NUM_SLOTS`, `SLOT_W` | 4, 32 | Slots por bundle y bits por slot |
| `BUNDLE_W`, `BUNDLE_BYTES` | 128, 16 | Ancho del bundle, avance del PC y enlace de `sye`/`syer` |
| `IMEM_BUNDLES` | 1024 | Memoria de instrucciones (también la leen las herramientas de Python) |
| `DMEM_BYTES` | 65536 | Memoria de datos |
| `TRAP_VECTOR` | `0x3FF0` | Manejador de excepciones: el último bundle |

El banco (`NUM_REGS` y puertos), la memoria (`SIZE_WORDS`) y la bóveda (`NUM_KEYS`) tienen además sus
propios parámetros.

## 6. Banco de registros (`regfile`)

`rtl/regfile.sv`: 32 registros de 32 bits, 8 puertos de lectura y 5 de escritura.

| Puerto | Slot | Uso |
|:---|:---|:---|
| Lectura 0, 1 | ALU | `rf1`, `rf2` |
| Lectura 2, 3 | LSU | Base y dato de `guardap`/`guardab` |
| Lectura 4, 5 | BRU | `rf1`, `rf2` de los saltos condicionales; `rf1` de `syer` |
| Lectura 6, 7 | CRIPTO | Par `(r1, r1+1)` de `fsl`/`fsli`, o `(rs1, rs2)` de `ell` |
| Escritura 0 | ALU | Tipo registro e inmediato |
| Escritura 1 | LSU | `cargai`, `cargabai` |
| Escritura 2 | BRU | Enlace de `sye` y `syer` |
| Escritura 3, 4 | CRIPTO | `L_out` en `rd` y `R_out` en `rd+1` |

- x0 siempre vale 0 y las escrituras a x0 se descartan.
- Reset síncrono: todos los registros en 0. El RTL no trae valores iniciales.
- Lectura combinacional en ID; escritura en el flanco de subida al final de WB.
- Sin bypass: una lectura en el mismo ciclo que una escritura entrega el valor anterior (el
  enunciado prohíbe el forwarding).
- Si dos puertos escriben el mismo registro en el mismo ciclo, gana el de índice mayor
  (CRIPTO > BRU > LSU > ALU). Es un error del software, y `wb` lo señala con `conflict`.

**Regla de dependencias (N+3).** El bundle N lee sus operandos en ID y escribe su resultado al final
de WB, dos ciclos después:

```
ciclo          c      c+1    c+2    c+3
bundle N       ID     EX     WB          <- escribe al final de c+2
bundle N+2                   ID          <- lee en c+2: todavía el valor anterior
bundle N+3                          ID   <- lee en c+3: valor nuevo
```

El valor que escribe el bundle N lo puede leer el bundle N+3 o uno posterior: entre productor y
consumidor van al menos 2 bundles, independientes o NOP. Dentro de un bundle, todos los slots leen
antes de que se escriba cualquier resultado; por ejemplo, `sumai x2, x2, 1` lee el valor anterior de
x2. La verifican `tb_regfile_pipeline` sobre `top` y el ensamblador en cada programa.

Lo leído en ID viaja por el registro ID/EX: las unidades de EX nunca leen `reg_rdata` directamente,
porque en ese ciclo ya corresponde al bundle siguiente.

## 7. Writeback (`wb`)

`rtl/wb.sv` es combinacional. Recibe de cada unidad (`alu`, `lsu`, `bru` y `crypto`) `we`, `rd` y el
dato (la cripto entrega `data_l` y `data_r`) y los pasa a los 5 puertos de escritura del banco.
`we` vale 0 si el slot es NOP, si el bundle se anuló por un salto o una excepción, o si la instrucción
no escribe registros (guardados, saltos condicionales, `ell`, `vcr`, `camcon`, `setpwd`). Un destino
x0 no habilita su puerto. Las cuatro unidades pueden escribir en el mismo ciclo si sus destinos son
distintos; si no, `conflict` vale 1.

## 8. ALU (`alu`)

`rtl/alu.sv` es combinacional y recibe el código interno `alu_op` que genera `decoder_alu`.

| Código | Instrucciones | Resultado |
|:---|:---|:---|
| `ALU_ADD`, `ALU_SUB` | `suma`/`sumai`, `resta`/`restai` | `a + b` o `a - b` módulo 2^32, sin banderas |
| `ALU_SLL`, `ALU_SRL`, `ALU_SRA` | `cizq(i)`, `cder(i)`, `cader(i)` | Desplaza `b[4:0]` posiciones (módulo 32); `cader` replica el signo |
| `ALU_XOR`, `ALU_AND`, `ALU_OR` | `xor(i)`, `and(i)`, `or(i)` | Operación bit a bit |
| `ALU_LT`, `ALU_GT` | `mrq`, `myq` | 1 si `a < b` (o `a > b`) con signo, 0 si no |
| Otro | — | 0 |

El inmediato de 11 bits se extiende con signo en `top`, antes de la ALU; por eso `xori rg, rf1, -1`
(la pseudoinstrucción `not`) invierte todos los bits.

## 9. Unidad criptográfica (`crypto_unit`, `key_vault`)

`rtl/decoder_crypto.sv` (ID), `rtl/crypto_unit.sv` (EX) y `rtl/key_vault.sv`, que solo se instancia
dentro de `crypto_unit`. Ocupa el slot 3.

| Instrucción | Hace | Requisito |
|:---|:---|:---|
| `fsl rd, r1, LK, RK` | `x[rd] = R`, `x[rd+1] = L ⊕ F(R, K)`, con L = `x[r1]` y R = `x[r1+1]` | AUTH = 1 |
| `fsli rd, r1, LK, RK` | `x[rd] = R ⊕ F(L, K)`, `x[rd+1] = L` | AUTH = 1 |
| `ell LK, off, rs1, rs2` | `bóveda[LK][off] = rs1`, `bóveda[LK][off+1] = rs2` | AUTH = 1 |
| `vcr dir` | `AUTH = (M[dir] == contraseña)` | Ninguno |
| `camcon dir, imm` | Rota `imm` bits a la izquierda la contraseña y `M[dir]` | AUTH = 1 |
| `setpwd rs` | `contraseña = rs`, `INIT = 0` | INIT = 1 |

K = `bóveda[LK][RK]` y F(x, K) = (ROL(x, 5) + K) ⊕ ROL(x, 13). Cifrar un bloque son 4 `fsl` con
RK = 0, 1, 2, 3 y descifrarlo, 4 `fsli` con RK = 3, 2, 1, 0: exactamente `feistel4_encrypt` y
`feistel4_decrypt` del enunciado. `tb_crypto_unit` y `tb_pipeline_cripto` comparan contra un modelo de
referencia independiente del RTL.

**Bóveda y ESTADO.**
- La bóveda guarda 4 llaves de 128 bits (4 subllaves de 32) y la contraseña. Sus únicas salidas son
  la subllave, que solo entra al cálculo de la ronda, y la comparación de la contraseña: no hay camino
  hacia el banco de registros ni hacia la memoria.
- ESTADO tiene AUTH (bit 0) e INIT (bit 1). Solo lo cambian `vcr` y `setpwd`; ninguna instrucción lo
  lee. Se escribe en WB y se usa en ID para validar cada instrucción cripto.
- Reset: AUTH = 0, INIT = 1 y la bóveda se borra. Después de un reset hay que repetir `setpwd`, `vcr`
  y `ell`; las llaves anteriores no se recuperan.
- Antes de `setpwd` no hay contraseña y `vcr` no autentica, ni con una candidata en 0.

**Excepción de privilegio.** `decoder_crypto` valida en ID cada instrucción con el ESTADO de ese
ciclo. Si no tiene permiso, la marca viaja por ID/EX y en EX `top`:
- anula el bundle completo (ALU, LSU, BRU y cripto; un salto no se toma y no se escribe su enlace);
- anula los 2 bundles de IF e ID, igual que un salto tomado;
- carga el PC con `TRAP_VECTOR` (`0x3FF0`), donde va el manejador. El ensamblador no ubica código en
  una dirección fija, así que los testbenches escriben el manejador directamente en esa posición;
- guarda el PC culpable en `trap_pc` y cuenta las excepciones en `trap_count` (solo para
  observación).

**Temporización.**

| Qué | Cuándo se ve |
|:---|:---|
| Par `(rd, rd+1)` de `fsl`/`fsli` | Desde el bundle N+3, como cualquier registro |
| Bóveda (`ell`, `setpwd`, `camcon`) | Desde el bundle N+1: se escribe al final de EX (por ejemplo, un `vcr` en el bundle siguiente a `setpwd` ya usa la contraseña nueva) |
| ESTADO (`vcr`, `setpwd`) | Desde el bundle N+3: después de `vcr`, el `ell` o `fsl` va 3 bundles después |
| Memoria escrita por `camcon` | Al final de EX, igual que un `guardap` |

**Decisiones de diseño.** `camcon` rota la contraseña de la bóveda y también la copia en `M[dir]`,
para que la siguiente `vcr` con esa copia siga autenticando. La memoria de datos tiene dos puertos
para que `vcr` y `camcon` puedan ir en el mismo bundle que una instrucción de la LSU. Por la
definición de Feistel4, F(0, K) = K: `fsl` sobre un bloque (0, 0) entrega K, lo que solo es posible con
AUTH = 1.

## 10. LSU y memoria de datos (`lsu`, `memory`)

**LSU** (`rtl/lsu.sv`, slot 1). La dirección es `base + offset`, con el offset de 11 bits extendido con
signo.

| Instrucción | Qué hace |
|:---|:---|
| `guardap base, dato, off` | Escribe la palabra completa |
| `guardab base, dato, off` | Escribe el byte bajo de `dato` en el byte que indica la dirección |
| `cargai rg, base, off` | Lee la palabra completa |
| `cargabai rg, base, off` | Lee un byte y lo extiende con signo a 32 bits |

- La memoria se organiza en palabras de 4 bytes: `guardap` y `cargai` ignoran los 2 bits bajos de la
  dirección (`0x25` se trata como `0x24`); `guardab` y `cargabai` usan la dirección exacta.
- Un NOP en el slot 1 tiene el mismo código interno que `guardap`, así que la LSU solo se habilita
  cuando `decoder_lsu` indica que el slot trae una instrucción LSU (`valid`).
- El dato de una carga se guarda en un registro interno de la LSU, que cumple el papel de EX/WB:
  llega a WB en el mismo ciclo que la ALU y sigue la regla N+3.
- Un guardado se escribe al final de EX, así que una carga del bundle siguiente ya lo ve.

**Memoria de datos** (`rtl/memory.sv`): 64 KB (16 384 palabras de 32 bits), direccionable por byte y
*little-endian* (el byte de la dirección más baja es el menos significativo). Lectura combinacional,
escritura en el flanco de subida con byte enables y todo en 0 al iniciar. Tiene dos puertos: A para la
LSU y B para la cripto (`vcr` lee, `camcon` lee y escribe); si los dos escriben la misma palabra en el
mismo ciclo, gana el B.

**Mapa de memoria.** Las memorias de instrucciones y de datos son espacios separados: el PC solo
direcciona la de instrucciones y la LSU solo la de datos.

| Memoria | Rango | Uso |
|:---|:---|:---|
| Instrucciones | `0x0000`–`0x3FE0` | Programa; después del reset el PC vale `0x0000` |
| Instrucciones | `0x3FF0` | Manejador de excepciones (`TRAP_VECTOR`) |
| Datos | `0x0000`–`0x3FFF` | Libre. `make archivo` usa `0x100`–`0x11F` para contraseña, llave y fin, y el archivo desde `0x200` |
| Datos | `0x4000`–`0x7FFF` | Datos globales, a partir de `gp = 0x4000` |
| Datos | `0x8000`–`0xFFFF` | Pila (crece hacia abajo desde `0x10000`) |

Los rangos siguen la convención de RISC-V del puntero global: con `gp = 0x4000`, cada variable global
se alcanza en una sola instrucción con un offset de −1024 a 1023 bytes. Es un acuerdo del software
que también usa el compilador de CE1108; la memoria no lo impone.

**Archivos `.mem` de datos.** `tools/load_file.py` convierte cualquier archivo en un `.mem` para
`$readmemh`, con una palabra de 32 bits por línea (el formato de `memory.sv`). En un `.hex`, un valor de
hasta `0xFF` se toma como un byte y uno mayor como una palabra; cualquier otro archivo (`.txt`, `.bin`,
imágenes) se carga byte por byte. `tools/extract_data.py` hace lo inverso: saca un rango de un volcado
de memoria (`$writememh`) a `.bin` o `.hex`.

## 11. BRU (`bru`)

`rtl/bru.sv` (slot 2). `PC` es la dirección del bundle que contiene el salto; los offsets están en
bytes y son múltiplos de 16.

| Instrucción | Condición | Destino | Escribe |
|:---|:---|:---|:---|
| `igualsi`, `igualno` | `rf1 == rf2`, `rf1 != rf2` | `PC + off` (11 bits con signo) | — |
| `menora`, `mayoroigual` | `rf1 < rf2`, `rf1 >= rf2`, con signo | `PC + off` | — |
| `sye rg, off` | Siempre | `PC + off` (16 bits con signo) | `rg = PC + 16` |
| `syer rg, rf1, off` | Siempre | `rf1 + off`, con los 4 bits bajos en 0 | `rg = PC + 16` |

Si el salto se toma, la BRU activa `branch_flush` en el mismo ciclo: `top` anula los bundles de IF e
ID y carga el PC con el destino. Un salto tomado cuesta 2 ciclos; uno no tomado, ninguno. El enlace se
registra en la BRU y llega a WB con los demás resultados. Los IDs reservados del tipo salto se
decodifican como NOP.

## 12. Ensamblador y ejecución de programas

`tools/assembler.py` traduce un `.asm` a las imágenes que carga la simulación. Cada línea es un bundle
en el orden `ALU | LSU | BRU | CRIPTO`; `nop` solo en una línea ocupa los 4 slots.

```asm
inicio: sumai x4, x0, 7 | nop | nop | nop
nop
nop
nop | guardap x0, x4, 256 | igualno x4, x0, inicio | nop
```

| Tipo | Sintaxis |
|:---|:---|
| ALU registro | `suma`, `resta`, `cader`, `cizq`, `and`, `or`, `xor`, `cder`, `mrq`, `myq` `rg, rf1, rf2` |
| ALU inmediato | `sumai`, `restai`, `cizqi`, `cderi`, `caderi`, `xori`, `andi`, `ori` `rg, rf1, inm` (−1024 a 1023; desplazamientos de 0 a 2047) |
| Memoria | `cargai`/`cargabai rg, base, off` y `guardap`/`guardab base, dato, off` (off de −1024 a 1023 bytes) |
| Saltos | `igualsi`/`igualno`/`menora`/`mayoroigual rf1, rf2, destino`; `sye rg, destino`; `syer rg, base, off` |
| Cripto | `fsl`/`fsli rd, r1, LK, RK`; `ell LK, off, rs1, rs2`; `vcr dir`; `camcon dir, rotación`; `setpwd rs` |
| Pseudo | `nop`, `mov rg, rf`, `not rg, rf`, `ret` (= `syer x0, ra, 0`) |

- Registros `x0`–`x31` o sus alias del ABI (`ra`, `sp`, `gp`, `t0`–`t11`, `s0`–`s15`); números en
  decimal, `0x` o `0b`; comentarios con `#`, `;` o `//`.
- El destino de un salto es una etiqueta o un desplazamiento en bytes desde el PC del bundle, múltiplo
  de 16 (11 bits en los condicionales, 16 en `sye`).
- Cripto: los pares de Feistel empiezan en un registro par de x2 a x30; LK y RK van de 0 a 3; `ell` usa
  registros pares y `off` 0 o 2; las direcciones van de 0 a 65535 y la rotación de 0 a 31. También se
  aceptan campos nombrados (`fsl rd=6, r1=2, LK=0, RK=1`) y `camcom` como alias de `camcon`.

Antes de generar las salidas, el ensamblador revisa que cada instrucción esté en su slot, los rangos,
que dos slots del mismo bundle no escriban el mismo registro ni lean uno que otro slot escribe, y la
regla N+3 por todos los caminos del programa, incluidos los saltos. Si algo falla, rechaza el programa
e indica la línea. No inserta ni reordena código. La revisión cubre registros; los tiempos de ESTADO
(sección 9) los debe respetar el programa.

| Salida | Contenido |
|:---|:---|
| `.mem` | Una línea de 32 dígitos hexadecimales por bundle, para `$readmemh` de la memoria de instrucciones |
| `.bin` | Los mismos bundles en binario, 16 bytes *little-endian* por bundle |
| `.lst` | Número de bundle, PC, línea del fuente, hexadecimal e instrucción |

`tools/run_program.py` lleva un `.asm` hasta el procesador:

1. Lo ensambla y escribe `program.mem` y `program.lst`.
2. Compila `rtl/` con `tests/rtl/tb_assembled_program.sv`, que carga `program.mem`.
3. Simula los ciclos indicados (`--cycles`); un conflicto de escritura detiene la simulación con error.
4. Vuelca los registros (`registers.txt`) y la memoria (`memory.txt`) y los compara con `--expect`
   (JSON de registros) y `--expect-memory` (JSON de direcciones).
5. Con `--trace`, escribe la traza dinámica en `trace.txt`.

Todo queda en `build/program_<nombre>/`, con el `.vcd`. Admite hasta 1020 bundles. Como el ISA no
tiene una instrucción para detenerse, los programas terminan en un bucle estable
(`fin: nop | nop | sye x0,fin | nop`). `make test-programs` usa este flujo con los programas de
`examples/`; la integración con el compilador de CE1108 está en
[compiler-integration.md](compiler-integration.md).

**Traza dinámica** (`--trace`). `trace.txt` muestra cómo cambia el estado conforme avanza la
ejecución: una línea por cambio, con el ciclo, el PC y el bundle que lo produjo. Registra los
registros (valor anterior y nuevo), las escrituras en memoria, los cambios de ESTADO, los saltos
tomados y las excepciones. Los registros se anotan en WB y lo demás en EX (el bundle 0 llega a WB en
el ciclo 4), y el bucle final se resume en una línea. Ejemplo con `subrutina.asm`:

```text
python3 tools/run_program.py --input examples/subrutina.asm --cycles 60 --trace

#  ciclo  PC      cambio                                          bundle (ALU | LSU | BRU | CRIPTO)
       3  0x0000  salto tomado a 0x0060 (contar)                  nop | nop | sye ra,contar | nop
       4  0x0000  x1/ra: 0x00000000 -> 0x00000010 (16)            nop | nop | sye ra,contar | nop
       7  0x0060  x5: 0x00000000 -> 0x00000001 (1)                contar: sumai x5,x5,1 | nop | nop | nop
       8  0x0080  salto tomado a 0x0010                           nop | nop | syer x0,ra,0 | nop
```

## 13. Testbenches y cobertura

Todos son autoverificables:

| Testbench | Qué verifica |
|:---|:---|
| `tb_alu` | Cada operación con los ejemplos del ISA y casos de borde (acarreo, desborde, desplazamientos de 0, 31 y 32 o más, comparaciones con INT_MIN, INT_MAX y −1), 1000 vectores aleatorios por operación contra un modelo, y las 18 instrucciones ALU codificadas pasando por `decoder_alu` |
| `tb_regfile` | Los 31 registros por todos los puertos, x0, sin bypass, 5 escrituras y 8 lecturas simultáneas, conflictos, reset y 2000 ciclos aleatorios contra un modelo |
| `tb_wb` | Cada unidad sola, destino x0, el par de la cripto, 5 escrituras a la vez, conflictos y 2000 combinaciones aleatorias |
| `tb_regfile_pipeline` | Regla N+3 sobre `top`: lecturas a distancia 1, 2, 3 y 4 del productor |
| `tb_lsu`, `tb_decoder_lsu` | Las 4 instrucciones, byte enables en cada offset, extensión de signo (`0xFF` → `0xFFFFFFFF`), slot inactivo y los 16 IDs |
| `tb_memory` | Palabras y bytes en cada posición, escrituras parciales (*little-endian*), direcciones límite y un modelo de referencia |
| `tb_bru`, `tb_decoder_bru` | Saltos tomados y no tomados con signo, `sye` y `syer` (destino alineado y enlace PC + 16) y los 16 IDs de cada tipo |
| `tb_pipeline_integracion` | Programas sobre `top`: accesos a memoria seguidos, un NOP del slot 1 no escribe memoria, un salto tomado anula exactamente 2 bundles (sin delay slots), ALU, LSU y BRU en el mismo bundle con 3 escrituras a la vez, bucles y llamadas con `sye`/`syer` |
| `tb_key_vault` | Las 4 llaves por sus 16 subllaves, `setpwd`, autenticación, rotación de la contraseña, 1000 escrituras aleatorias y reset |
| `tb_decoder_crypto` | Las 6 instrucciones con codificaciones del ensamblador y los permisos con las 4 combinaciones de AUTH e INIT |
| `tb_crypto_unit` | Excepciones sin efectos, `vcr` correcta e incorrecta, el vector conocido HOLA2026 → `03D44466 D685AFAF` ronda por ronda, 500 rondas aleatorias contra la referencia, `camcon` y ESTADO escrito en WB |
| `tb_pipeline_cripto` | Cifrado y descifrado de 4 bloques contra la referencia, las 4 unidades en el mismo bundle, excepciones (bundle y 2 siguientes anulados, salto a `TRAP_VECTOR`) y que ningún registro ni palabra de memoria contenga la llave |
| `tb_top` | Programa cargado desde un `.mem` y 4 bundles distintos en IF, ID, EX y WB en el mismo ciclo |
| `tb_pipeline_stall` | Proyecto 2: el mismo programa en `top` sin stalls y con 1 y 4 ciclos de stall por acceso (`MEM_MODE = 1`). Mismo estado final (registros, memoria, bóveda y ESTADO), las mismas escrituras en el mismo orden (`camcon` rota una sola vez), N ciclos más por acceso y el PC y los registros de segmentación quietos en cada stall. Interfaces en [`memory-interfaces.md`](memory-interfaces.md) |
| `tb_fetch`, `tb_dispatch`, `tb_decoder_alu` | El bundle sin esperar un flanco, la separación de los 4 slots y las 18 instrucciones ALU con sus campos |
| `tb_pipeline_if_id`, `tb_pipeline_id_ex`, `tb_pipeline_ex_wb` | Captura en el flanco, `flush`, prioridad del reset y 300 ciclos aleatorios |

Fuera de `make sim`: `make archivo` cifra y descifra un archivo real y `make test-programs` ejecuta los
programas de `examples/` sobre el RTL.
