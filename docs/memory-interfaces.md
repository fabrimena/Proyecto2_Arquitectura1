# Interfaces de la jerarquía de memoria (Proyecto Grupal 2)

> Curso: CE4301 – Arquitectura de Computadores I, II Semestre 2026  
> Profesor: Dr.-Ing. Jeferson González Gómez  
> Estado: secciones 2 a 5, 7 y 8 implementadas; la 6 (L2 real y memoria principal) pendiente  
> Equipo: Dylan Guerrero González, José García Izaguirre, Javier Hernández Castillo, Alejandro Vásquez Oviedo, Fabricio Mena Mejia

Cómo se conectan el núcleo del proyecto 1, la L1-D, la L2 y la memoria principal. La idea es que cada
uno pueda hacer y probar su módulo por separado contra un modelo simple y que después todo encaje. Las
secciones 2 a 4 están en `rtl-p2/top.sv` y `rtl-p2/mem_stall_model.sv`; la 5, la 7 y la 8 en
`rtl-p2/mem_hierarchy.sv`, la L1-D de José y la L2 de prueba (`rtl-p2/l2_model.sv`). La sección 6 sigue
como propuesta hasta que estén la L2, el eviction buffer y el controlador de memoria. Las decisiones de
diseño están en [`decisiones-importantes.md`](decisiones-importantes.md).

## 1. Regla de partida

- El procesador del proyecto 1 no se modifica: ni la ISA ni los tiempos que ve el software (regla N+3
  del banco, latencia de las cargas, 2 ciclos por salto tomado, bóveda visible en N+1 y ESTADO en N+3).
  Así el compilador de CE1108 sigue funcionando sin cambios.
- La jerarquía se agrega entre el núcleo y la memoria de datos, dentro de EX (no hay etapa MEM). Un hit
  de L1-D responde en el mismo ciclo, igual que la memoria actual. Un miss congela el bundle completo.
- Lo nuevo va en módulos nuevos. En `top.sv` solo se agregó el enganche de la memoria (sección 3), el
  reloj del núcleo (sección 4), `mem_re_b` (sección 8) y las señales del vaciado (sección 7).

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
| `mem_re_b` | jerarquía | 1 | `vcr` o `camcon` válidos y con permiso en EX (las condiciones de `exec` en `crypto_unit`) |
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
| 2 | `mem_hierarchy`: los dos puertos pasan por la L1-D (sección 8). Por ahora la L2 es `l2_model`; después se agregan la L2 real, el eviction buffer y el controlador de memoria | L1-D y puerto B listos; L2 real y memoria en las iteraciones 2 y 4 |

DMEM (`memory.sv`, 64 KB) se queda en `top` como el almacenamiento de la memoria principal. Así
`DUT.DMEM.mem` sigue siendo la memoria para los testbenches y las herramientas que la cargan o la leen
por jerarquía (`tb_archivo`, `tb_assembled_program` de `run_program.py`, `tb_pipeline_cripto` y otros).
En el modo 2 solo la usa la jerarquía por el puerto A (hoy `l2_model`, después el controlador de
memoria, con la latencia y el reloj de la memoria principal); el puerto B de DMEM queda sin usar. Con
write-back, DMEM no tiene los últimos valores hasta que se vacía la caché (sección 7).

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
iverilog -g2012 -I rtl -I rtl-p2 -I tb -s tb_archivo -s cfg -o sim.vvp rtl/*.sv rtl-p2/*.sv \
    tests/rtl/tb_archivo.sv cfg.sv
```

Con `MEM_MODE = 2` el `defparam` no alcanza: el testbench tiene que contar solo los ciclos en que el
núcleo avanza y vaciar la caché antes de leer `DUT.DMEM.mem` (sección 7). Adaptar `tb_archivo`,
`tb_assembled_program` y `tb_ce1108_program` es el issue #28.

## 4. Congelamiento del núcleo (`core_clk`)

`top` genera `core_clk = clk & core_en`, donde `core_en` es `!cache_stall` tomado mientras `clk` está en
0 (un latch). Si `cache_stall` cambia con `clk` en 1, `core_clk` no tiene flancos falsos. Con
`cache_stall = 0` siempre (modo 0), `core_clk` es igual a `clk` y el procesador hace exactamente lo
mismo que en el proyecto 1.

| Reloj | Qué usa ese reloj |
|:---|:---|
| `core_clk` | `PC_BRANCH`, `IMEM` (ROM síncrona), `IF_ID`, `ID_EX`, `EX_WB`, `REGFILE`, `LSU`, `BRU`, `CRYPTO` (con la bóveda adentro) y `trap_pc`/`trap_count` |
| `clk` | `DMEM`, `mem_stall_model` y todo lo que se agregue: cachés, buffers, controlador y contadores |

Durante un stall todo el núcleo se queda en el mismo estado: el bundle de EX mantiene su acceso, el de
WB todavía no escribe el banco y el PC no avanza. Cuando el acceso termina, el pipeline sigue como si
el stall no hubiera existido. Con N ciclos de stall por acceso, un programa con A accesos tarda
exactamente N × A ciclos más y termina con los mismos registros y la misma memoria.

Los contadores (iteración 1, Javier) deben usar `clk`, no `core_clk`. Señales útiles: `cache_stall`
(ciclo de stall), `core_en` (el núcleo avanza en este flanco), `mem_re` y `mem_we` (acceso de la LSU).

## 5. L1-D y L2: bus versión 2

Una línea tiene 32 bytes (8 palabras); la dirección de línea es `addr[15:5]`. La L1-D, o su write
buffer, le pide líneas a la L2 con este bus (D9; definido en `cache_defs.sv`, sección 4, e implementado
en la L1-D por José, ver [`l1d-cache.md`](l1d-cache.md)):

| Señal | Hacia | Bits | Significado |
|:---|:---|:---:|:---|
| `l2_req` | L2 | 1 | Hay una petición; se mantiene igual hasta `l2_gnt` |
| `l2_we` | L2 | 1 | 0 = leer una línea, 1 = escribir los bytes marcados |
| `l2_addr` | L2 | 32 | Dirección alineada a 32 bytes |
| `l2_wline` | L2 | 256 | Datos de la línea (palabra 0 en los bits bajos) |
| `l2_be` | L2 | 32 | Bytes válidos de `l2_wline` |
| `l2_wdirty` | L2 | 1 | La víctima que se escribe está sucia (exclusiva) |
| `l2_gnt` | L1 | 1 | La L2 aceptó la petición en este ciclo |
| `l2_rvalid` | L1 | 1 | Un ciclo en 1 con la respuesta de una lectura, en orden |
| `l2_rline` | L1 | 256 | Línea leída |
| `l2_rdirty` | L1 | 1 | La línea que se mueve estaba sucia en la L2 (exclusiva) |

- La aceptación (`l2_gnt`) va separada de la respuesta (`l2_rvalid`): una L2 segmentada puede aceptar
  una petición por ciclo. Una escritura termina al ser aceptada.
- Las salidas de la L2 salen de registros, porque el stall de la L1-D solo puede depender de registros.
- Un hit de L2 tarda 8 ciclos: si la petición se acepta en el ciclo t, `l2_rvalid` sale en t + 8.
- Write buffer de 4 entradas (2 a 8) con el mismo formato que una escritura del bus. Riesgo RAW: con
  NINE se reenvían los bytes pendientes; con exclusiva se espera a que la entrada llegue a la L2.

**L2 de prueba** (`rtl-p2/l2_model.sv`). Mientras no está la L2 real, `mem_hierarchy` conecta este
modelo: siempre acierta, no guarda líneas y lee o escribe DMEM una palabra por ciclo, así que una
lectura tarda exactamente 8 ciclos (las 8 palabras de la línea). Una escritura ocupa el modelo 8
ciclos. `l2_rdirty` siempre es 0 porque lo que entrega ya está en la RAM; con la política exclusiva se
comporta como una L2 vacía con la RAM detrás. La L2 real se conecta en su lugar con el mismo bus.

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
escribir todas las líneas sucias. `top` tiene una entrada `flush_req` (0 por defecto, así los
testbenches que no la conectan no cambian) y una salida `flush_done`:

```systemverilog
top #(.MEM_MODE(2)) DUT (.clk(clk), .reset(reset), .flush_req(flush_req), .flush_done(flush_done), ...);

flush_req = 1'b1;
while (!flush_done) @(posedge clk);     // después, DUT.DMEM.mem tiene todo
flush_req = 1'b0;
```

- Modo 2: la L1-D espera a que no quede ningún MSHR, manda sus líneas sucias al write buffer y espera
  a que se vacíe. `flush_done` = 1 cuando la L1-D terminó y la L2 de prueba ya escribió todo en DMEM, y
  se mantiene mientras `flush_req` siga en 1. Con la L2 real se agrega su parte de la cadena (D16).
- Modos 0 y 1: no hay nada que vaciar y `flush_done` sigue a `flush_req`.
- El programa puede seguir después de un vaciado. Con exclusiva, las líneas sucias que se mandaron a la
  L2 quedan inválidas en la L1-D y se vuelven a pedir.

Adaptar los testbenches de las herramientas es el issue #28 (Javier). La instrucción `vaciarc` (crédito
extra, `decisiones-importantes.md` 4.4) va a usar la misma cadena.

## 8. Puerto B (cripto)

`vcr` y `camcon` usan el puerto B. Si el puerto B fuera directo a DMEM con cachés write-back, podría leer
un valor viejo mientras el nuevo está sucio en la L1-D. Por eso, en el modo 2, el puerto B también
entra a la L1-D como un acceso más (D17). `top` calcula `mem_re_b` igual que `mem_re`, y
`rtl-p2/l1d_port_arbiter.sv` junta los dos puertos sobre el puerto único de la L1-D. Si un bundle trae
accesos en los dos, se atienden en fases y el núcleo sigue congelado hasta la última:

| Fase | Acceso | Qué guarda el árbitro |
|:---:|:---|:---|
| 1 | Lectura de B (`vcr` o `camcon`) | La palabra leída (`b_data`) |
| 2 | Acceso de A (carga o store de la LSU) | La palabra de una carga (`a_data`) |
| 3 | Escritura de B (solo `camcon`): `ROL(b_data, imm)`, palabra completa | |

- Este orden da el mismo resultado que el proyecto 1 (reglas 5 y 6 de la sección 2): `vcr` y `camcon`
  leen el valor de antes del store de A, una carga de A lee el valor de antes de `camcon`, y `camcon`
  escribe después de A, así que gana si los dos escriben la misma palabra.
- Cada fase es un acceso normal de la L1-D. Si todo acierta: solo A o solo `vcr`, 0 ciclos más; A con
  `vcr`, o `camcon` solo, 1 ciclo más; A con `camcon`, 2 ciclos más. `camcon` necesita dos accesos
  porque la L1-D hace una operación por acceso, y su lectura se trata como una carga (si falla,
  bloquea), como pide la L1-D para los MSHR.
- Una fase que terminó no se repite aunque el núcleo siga detenido: `camcon` rota `M[dir]` una sola
  vez.
- `cache_stall` sale del árbitro: depende del acceso, de dos marcas registradas y del stall de la
  L1-D, así que cumple la regla 2.

## 9. Pendientes

1. Políticas de la L1-D: listo (José): write-back, write-allocate y LRU por defecto; write-through, FIFO
   y Random como parámetros.
2. Riesgo RAW: listo en el write buffer de la L1-D (forwarding con NINE, espera con exclusiva); falta el
   eviction buffer (Dylan).
3. Inclusión: exclusiva por defecto y NINE como parámetro (D3), mientras el profesor la confirma; falta
   la parte de la L2 (Alejandro).
4. Cruce de dominios de reloj y timeout: decididos (D12 a D14), falta implementarlos (Dylan).
5. Memoria de instrucciones: listo. ROM síncrona leída con el siguiente PC (`rtl-p2/rom_sync.sv`, D1),
   que mantiene los tiempos de IF y no afecta al compilador.
6. Puerto B a través de la L1-D: listo (sección 8).
7. Testbenches de las herramientas con el vaciado (#28, Javier).

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
- `make tb_mem_hierarchy` prueba la jerarquía del modo 2 sin el procesador, contra un modelo de la
  memoria del proyecto 1: un miss tarda 8 ciclos, un hit y un store con un MSHR libre 0, y los casos del
  puerto B de la sección 8 (incluidos `vcr` y `camcon` sobre palabras que solo están sucias en la L1-D).
  Después del vaciado, DMEM es igual al modelo, también tras 3000 bundles aleatorios sobre 32 líneas que
  compiten por 4 conjuntos.
- `make tb_port_b` ejecuta un programa con `setpwd`, `vcr` y `camcon` junto a cargas y stores de la
  misma palabra en tres copias de `top` (modos 0, 1 y 2): mismo estado final, mismas escrituras al banco
  y `camcon` escribe una sola vez.
- Con el modo 2 (copias de `tb_assembled_program`, `tb_archivo` y `tb_ce1108_program` con el vaciado),
  `make test-programs`, `make descifrar` y los programas de CE1108 dan los resultados esperados, y
  `make archivo` da el mismo `cifrado.bin` que el proyecto 1 en más ciclos: `mensaje.txt` 1102 en vez de
  989, `imagen.bmp` 25518 en vez de 23189 y `datos.bin` 2774 en vez de 2509.
