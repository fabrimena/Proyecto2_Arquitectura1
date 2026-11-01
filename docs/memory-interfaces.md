# Interfaces de la jerarquía de memoria (Proyecto Grupal 2)

> Curso: CE4301 – Arquitectura de Computadores I, II Semestre 2026  
> Profesor: Dr.-Ing. Jeferson González Gómez  
> Estado: propuesta de la iteración 1, para revisar en grupo  
> Equipo: Dylan Guerrero González, José García Izaguirre, Javier Hernández Castillo, Alejandro Vásquez Oviedo, Fabricio Mena Mejia

Cómo se conectan el núcleo del proyecto 1, la L1-D, la L2 y la memoria principal. La idea es que cada
uno pueda hacer y probar su módulo por separado contra un modelo simple y que después todo encaje. Las
secciones 2 a 4 ya están implementadas en `rtl/top.sv` y `rtl/mem_stall_model.sv`; las secciones 5 a 8
son propuestas y lo marcado como pendiente se decide en grupo.

## 1. Regla de partida

- El procesador del proyecto 1 no se modifica: ni la ISA ni los tiempos que ve el software (regla N+3
  del banco, latencia de las cargas, 2 ciclos por salto tomado, bóveda visible en N+1 y ESTADO en N+3).
  Así el compilador de CE1108 sigue funcionando sin cambios.
- La jerarquía se agrega entre el núcleo y la memoria de datos, dentro de EX (no hay etapa MEM). Un hit
  de L1-D responde en el mismo ciclo, igual que la memoria actual. Un miss congela el bundle completo.
- Lo nuevo va en módulos nuevos. En `top.sv` solo se agregó el enganche de la memoria (sección 3) y el
  reloj del núcleo (sección 4).

## 2. Núcleo y jerarquía

Son las señales que ya existen en `top.sv`. La jerarquía recibe los dos puertos del núcleo y entrega los
datos leídos y `cache_stall`.

| Señal | Hacia | Bits | Significado |
|:---|:---|:---:|:---|
| `mem_re` | jerarquía | 1 | Carga válida en EX (`cargai`, `cargabai`). La calcula `top` con las mismas condiciones que `valid_in` de la LSU |
| `mem_we` | jerarquía | 1 | Store válido en EX (`guardap`, `guardab`) |
| `mem_be` | jerarquía | 4 | Bytes que se escriben: `1111` palabra, `0001 << addr[1:0]` byte |
| `mem_addr` | jerarquía | 32 | Dirección de byte (`rf1 + off`) |
| `mem_wdata` | jerarquía | 32 | Dato ya colocado en la posición del byte |
| `mem_rdata` | núcleo | 32 | Palabra completa de `mem_addr`; la LSU elige el byte y extiende el signo |
| `crypto_mem_we` | jerarquía | 1 | Escritura de `camcon` |
| `crypto_mem_addr` | jerarquía | 32 | Dirección de `vcr` o `camcon` (16 bits útiles) |
| `crypto_mem_wdata` | jerarquía | 32 | `ROL(M[dir], imm)`, calculado con `crypto_mem_rdata` |
| `crypto_mem_rdata` | núcleo | 32 | `M[dir]`: la candidata de `vcr` o la palabra que rota `camcon` |
| `cache_stall` | núcleo | 1 | 1: el acceso no termina en este ciclo y el núcleo no avanza |

Reglas que tiene que cumplir cualquier implementación:

1. El acceso aparece en EX y, mientras `cache_stall = 1`, el núcleo lo mantiene igual porque está
   congelado.
2. `cache_stall` es combinacional, pero solo puede depender del acceso y de registros que cambian en
   el flanco positivo de `clk`. Tiene que estar estable antes del flanco de bajada, que es cuando `top`
   lo toma.
3. En el ciclo en que `cache_stall = 0`, `mem_rdata` (y `crypto_mem_rdata`) tienen el dato correcto y en
   ese flanco el núcleo avanza. En un hit de L1-D eso pasa en el mismo ciclo del acceso.
4. Cada escritura tiene efecto una sola vez aunque el acceso dure varios ciclos. Es obligatorio para
   `camcon`, que escribe `ROL(M[dir], imm)`: si se repitiera, rotaría la palabra varias veces.
5. Dentro de un bundle se lee antes de escribir: una carga o `vcr` ven el valor anterior a un store o a
   un `camcon` del mismo bundle, y el bundle siguiente ya ve el nuevo, como en el proyecto 1.
6. Si los dos puertos escriben la misma palabra en el mismo ciclo, gana el puerto B (como en
   `memory.sv`).
7. Las direcciones válidas son `0x0000` a `0xFFFF` (64 KB). `guardap` y `cargai` ignoran los 2 bits
   bajos.

## 3. Modos de `top` (`MEM_MODE`)

| `MEM_MODE` | Entre el núcleo y DMEM | Estado |
|:---:|:---|:---|
| 0 (por defecto) | Conexión directa, como en el proyecto 1 | Listo |
| 1 | `mem_stall_model`: cada acceso de la LSU tarda `STALL_CYCLES` ciclos más, como si todos fueran un miss | Listo, para probar el congelamiento |
| 2 | Jerarquía completa: L1-D, write buffer, L2, eviction buffer y controlador de memoria | Iteraciones 2 a 4 |

DMEM (`memory.sv`, 64 KB) se queda en `top` como el almacenamiento de la memoria principal. Así
`DUT.DMEM.mem` sigue siendo la memoria para los testbenches y las herramientas que la cargan o la leen
por jerarquía (`tb_archivo`, `tb_assembled_program` de `run_program.py`, `tb_pipeline_cripto` y otros).
En el modo 2, el único que la usa es el controlador de memoria, con la latencia y el reloj de la memoria
principal.

Un testbench nuevo elige el modo con parámetros:

```systemverilog
top #(.MEM_MODE(1), .STALL_CYCLES(4)) DUT (.clk(clk), .reset(reset), ...);
```

Para correr un testbench existente en otro modo sin cambiarlo, basta un archivo extra con `defparam`
compilado como segundo módulo raíz:

```systemverilog
module cfg; defparam tb_archivo.DUT.MEM_MODE = 1; defparam tb_archivo.DUT.STALL_CYCLES = 4; endmodule
```

```bash
iverilog -g2012 -I rtl -I tb -s tb_archivo -s cfg -o sim.vvp rtl/*.sv tests/rtl/tb_archivo.sv cfg.sv
```

## 4. Congelamiento del núcleo (`core_clk`)

`top` genera `core_clk = clk & core_en`, donde `core_en` es `!cache_stall` tomado mientras `clk` está en
0 (un latch). Si `cache_stall` cambia con `clk` en 1, `core_clk` no tiene flancos falsos. Con
`cache_stall = 0` siempre (modo 0), `core_clk` es igual a `clk` y el procesador hace exactamente lo
mismo que en el proyecto 1.

| Reloj | Qué usa ese reloj |
|:---|:---|
| `core_clk` | `PC_BRANCH`, `IF_ID`, `ID_EX`, `EX_WB`, `REGFILE`, `LSU`, `BRU`, `CRYPTO` (con la bóveda adentro) y `trap_pc`/`trap_count` |
| `clk` | `DMEM`, `mem_stall_model` y todo lo que se agregue: cachés, buffers, controlador y contadores |

Durante un stall todo el núcleo se queda en el mismo estado: el bundle de EX mantiene su acceso, el de
WB todavía no escribe el banco y el PC no avanza. Cuando el acceso termina, el pipeline sigue como si
el stall no hubiera existido. Con N ciclos de stall por acceso, un programa con A accesos tarda
exactamente N × A ciclos más y termina con los mismos registros y la misma memoria.

Los contadores (iteración 1, Javier) deben usar `clk`, no `core_clk`. Señales útiles: `cache_stall`
(ciclo de stall), `core_en` (el núcleo avanza en este flanco), `mem_re` y `mem_we` (acceso de la LSU).

## 5. L1-D y L2 (propuesta para José y Alejandro)

Una línea tiene 32 bytes (8 palabras); la dirección de línea es `addr[15:5]`. La L1-D, o su write
buffer, le pide líneas a la L2 con este bus:

| Señal | Hacia | Bits | Significado |
|:---|:---|:---:|:---|
| `l2_req` | L2 | 1 | Hay una petición; se mantiene hasta `l2_ready` |
| `l2_we` | L2 | 1 | 0 = leer una línea, 1 = escribir |
| `l2_addr` | L2 | 32 | Dirección alineada a 32 bytes |
| `l2_wline` | L2 | 256 | Datos de la línea (palabra 0 en los bits bajos) |
| `l2_be` | L2 | 32 | Bytes válidos de `l2_wline` |
| `l2_ready` | L1 | 1 | Un ciclo en 1 cuando la L2 terminó; en una lectura, `l2_rline` es válido en ese ciclo |
| `l2_rline` | L1 | 256 | Línea leída |

- Una petición a la vez. Un hit de L2 tarda 8 ciclos desde `l2_req` hasta `l2_ready`.
- Con `l2_be` la misma interfaz sirve si la L1-D es write-through (escribe una palabra o un byte) o
  write-back (escribe la línea completa).
- Write buffer de 2 a 8 entradas `{l2_addr, l2_wline, l2_be}`. Si una carga falla en L1-D y su
  dirección está en el buffer, hay un riesgo RAW: se espera a que el buffer se vacíe o se reenvía el
  dato (pendiente, José).

## 6. L2 y memoria principal (propuesta para Alejandro y Dylan)

La L2 es write-back, así que hacia la memoria solo mueve líneas completas:

| Señal | Hacia | Bits | Significado |
|:---|:---|:---:|:---|
| `ram_req` | controlador | 1 | Hay una petición; se mantiene hasta `ram_ready` |
| `ram_we` | controlador | 1 | 0 = leer una línea, 1 = escribir una línea sucia |
| `ram_addr` | controlador | 32 | Dirección alineada a 32 bytes |
| `ram_wline` | controlador | 256 | Línea que se escribe |
| `ram_ready` | L2 | 1 | Un ciclo en 1 cuando la transferencia terminó |
| `ram_rline` | L2 | 256 | Línea leída |

- Eviction buffer de 4 a 16 líneas entre la L2 y el controlador: la L2 deja ahí la víctima sucia y
  sigue; el controlador la escribe cuando no hay lecturas pendientes. Un miss de L2 primero busca su
  línea en el buffer (riesgo RAW).
- El controlador trabaja con el reloj de la memoria (20 a 50 MHz, con la CPU a 100 MHz). Una línea tarda
  `Tmem = 25 + 7 × ⌈100 / fmem⌉` ciclos del procesador (53 a 25 MHz). Lee y escribe DMEM palabra por
  palabra, una por ciclo de memoria.
- Cruce de dominios de reloj (sincronizadores de 2 flip-flops para `req`/`ack` o una FIFO asíncrona) y
  timeout: pendiente, Dylan.

## 7. Vaciado de líneas sucias

Con write-back, DMEM puede no tener el último valor de una palabra. Antes de que un testbench lea
`DUT.DMEM.mem` (volcados de `run_program.py`, `tb_archivo`, comparaciones), la jerarquía tiene que
escribir todas las líneas sucias. Propuesta: una entrada `flush_req` y una salida `flush_done` en la
jerarquía, que solo usan los testbenches. No se agrega ninguna instrucción. L2 con L1-D: Alejandro y
José; adaptar los testbenches: Javier.

## 8. Puerto B (cripto)

`vcr` y `camcon` usan el puerto B. Si el puerto B fuera directo a DMEM con cachés write-back, podría leer
un valor viejo mientras el nuevo está sucio en L1-D o L2. Propuesta: el puerto B también entra a la
L1-D, como un acceso más (`vcr` como carga y `camcon` como carga y store de la misma palabra). Si la LSU
y la cripto acceden en el mismo bundle, se atienden uno después del otro con un stall más. Para eso
`top` necesita un `mem_re_b` (vcr o camcon válidos en EX), que se agrega igual que `mem_re`. Lo hace
Fabricio en la iteración 3.

## 9. Pendientes

1. Políticas de la L1-D: write-through o write-back, write-allocate o no, y reemplazo (José).
2. Stall o store-to-load forwarding en los buffers (José y Alejandro).
3. Inclusiva o NINE, a más tardar en la iteración 4 (Alejandro).
4. Cruce de dominios de reloj y timeout (Dylan).
5. Confirmar con el profesor que se acepta la memoria de instrucciones combinacional. El enunciado pide
   una ROM síncrona, pero hacerla síncrona cambia IF y la penalización de los saltos, y eso afecta al
   compilador.
6. Puerto B a través de la L1-D (Fabricio).

## 10. Pruebas

- `make tb_pipeline_stall` ejecuta el mismo programa en tres copias de `top`: REF (modo 0), DUT1 (modo
  1 con 1 ciclo) y DUT4 (modo 1 con 4 ciclos). El programa usa las 4 unidades, `camcon` en un bundle
  con una carga, saltos en bundles con accesos y termina con una excepción. Las tres terminan con los
  mismos registros, memoria, bóveda y ESTADO; hacen las mismas 46 escrituras en el mismo orden; y con 19
  accesos REF llega al manejador en el ciclo 66, DUT1 en el 85 (+19) y DUT4 en el 142 (+76).
- Con el modo 0, `make sim`, `make test-programs`, `make archivo`, `make descifrar` y los programas de
  CE1108 dan lo mismo que en el proyecto 1: mismas trazas, mismos volcados y mismos ciclos.
- `make archivo` con `imagen.bmp` en modo 1 con 4 ciclos (usando el `defparam` de la sección 3) da el
  mismo `cifrado.bin` en 41757 ciclos en vez de 23189: la diferencia, 18568, es 4 × 4642 accesos.
