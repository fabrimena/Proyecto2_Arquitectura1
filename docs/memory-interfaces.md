# Interfaces de la jerarquía de memoria (Proyecto Grupal 2)

> Curso: CE4301 – Arquitectura de Computadores I, II Semestre 2026  
> Profesor: Dr.-Ing. Jeferson González Gómez  
> Estado: interfaces de núcleo y L1-D documentadas; controlador de memoria y eviction buffer implementados y probados por separado; integración con L2 real pendiente 
> Equipo: Dylan Guerrero González, José García Izaguirre, Javier Hernández Castillo, Alejandro Vásquez Oviedo, Fabricio Mena Mejia

Cómo se conectan el núcleo del proyecto 1, la L1-D, la L2 y la memoria principal. La idea es que cada
uno pueda hacer y probar su módulo por separado contra un modelo simple y que después todo encaje. Las
secciones 2 a 4 están en `rtl-p2/top.sv` y `rtl-p2/mem_stall_model.sv`; la 5, la 7 y la 8 en
`rtl-p2/mem_hierarchy.sv`, la L1-D de José y la L2 de prueba (`rtl-p2/l2_model.sv`). La sección 6 documenta los puertos implementados de memoria principal y eviction buffer.
La conexión de estos módulos con la L2 real todavía está pendiente en `mem_hierarchy.sv`. Las decisiones de
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

## 6. L2, eviction buffer y memoria principal

La memoria principal tiene una capacidad de 64 KB y utiliza líneas de 256 bits, equivalentes a ocho palabras de 32 bits.

El controlador de memoria trabaja con un reloj generado mediante un divisor del reloj del procesador. La frecuencia es configurable entre 20 MHz y 50 MHz, con 25 MHz como configuración predeterminada.

### 6.1. Interfaz de solicitudes de memoria

La interfaz de línea completa utiliza las siguientes señales:

| Señal | Dirección | Bits | Descripción |
|---|---|---:|---|
| `ram_req` | Hacia controlador | 1 | Solicitud de acceso a memoria |
| `ram_we` | Hacia controlador | 1 | 0: lectura; 1: escritura |
| `ram_addr` | Hacia controlador | 32 | Dirección de byte, alineada a 32 bytes |
| `ram_wline` | Hacia controlador | 256 | Línea completa para escritura |
| `ram_ready` | Desde controlador | 1 | Pulso de finalización de la solicitud |
| `ram_rline` | Desde controlador | 256 | Línea completa obtenida en una lectura |
| `mem_error` | Desde controlador | 1 | Indica que la operación terminó con error |

El controlador conserva internamente los parámetros de cada solicitud mientras realiza la transferencia.

El evento `ram_ready` indica que la línea completa está disponible o que la escritura terminó correctamente. No representa la llegada de cada palabra individual.

### 6.2. Entrega individual de palabras

El controlador también proporciona señales para observar la entrega de cada palabra al dominio del procesador.

| Señal | Dirección | Bits | Descripción |
|---|---|---:|---|
| `ram_word_valid` | Desde controlador | 1 | Indica la entrega de una palabra válida |
| `ram_word_data` | Desde controlador | 32 | Dato correspondiente a la palabra entregada |
| `ram_word_index` | Desde controlador | 3 | Posición de la palabra dentro de la línea, entre 0 y 7 |

Las señales permiten comprobar que la primera palabra se entrega después de 25 ciclos del procesador y que las siguientes respetan la frecuencia de memoria.

Estas salidas complementan la interfaz de línea completa. No sustituyen `ram_ready` ni `ram_rline`.

### 6.3. Reloj y temporización

El procesador funciona a 100 MHz. El reloj de memoria se obtiene mediante un divisor configurable:

| Parámetro `MEM_DIV` | Frecuencia RAM | Latencia de línea `TMEM` |
|---|---|---|
| 2 | 50 MHz | 39 ciclos CPU |
| 4 | 25 MHz | 53 ciclos CPU |
| 5 | 20 MHz | 60 ciclos CPU |

La latencia nominal se calcula mediante:

`TMEM = 25 + 7 × MEM_DIV`

La primera palabra se entrega después de 25 ciclos de CPU. Las siete palabras restantes se entregan con una separación de `MEM_DIV` ciclos.

Para la configuración predeterminada de 25 MHz, las entregas corresponden a los ciclos 25, 29, 33, 37, 41, 45, 49 y 53.

El controlador utiliza precarga interna para obtener los datos antes de su fecha de entrega. Esta implementación sigue la aclaración del profesor, que permite anticipar los accesos internos siempre que los datos se entreguen con la latencia y tasa de transferencia especificadas.

### 6.4. Interfaz física de RAM

El controlador accede a la memoria mediante palabras de 32 bits.

| Señal | Dirección | Bits | Descripción |
|---|---|---:|---|
| `clk_mem` | Desde controlador | 1 | Reloj de RAM generado mediante divisor |
| `mem_word_addr` | Hacia RAM | 14 | Dirección de palabra dentro de los 64 KB |
| `mem_word_wdata` | Hacia RAM | 32 | Dato de escritura |
| `mem_word_we` | Hacia RAM | 1 | Habilitación de escritura |
| `mem_word_rdata` | Desde RAM | 32 | Dato leído |

Cada línea se divide en ocho palabras consecutivas. La palabra de índice cero ocupa los bits menos significativos de la línea.

La transferencia física procesa una palabra por ciclo de memoria.

### 6.5. Cruce de dominios de reloj

El controlador utiliza sincronizadores de dos registros para transferir eventos de control entre los dominios CPU y RAM.

El protocolo identifica solicitudes y confirmaciones mediante cambios de estado o *toggles*.

El controlador conserva la solicitud mientras está activa y utiliza confirmaciones para distinguir cuándo termina una transferencia.

La implementación incluye mecanismos para detectar respuestas atrasadas y evitar que una confirmación de un intento anterior complete una solicitud nueva.

La validación funcional incluye pruebas de solicitudes consecutivas, cambios de fase, transferencias interrumpidas y recuperación.

### 6.6. Timeout y recuperación

El parámetro `MEM_TIMEOUT` establece un límite predeterminado de 256 ciclos de CPU por intento.

Las señales de control y observación son:

| Señal | Dirección | Bits | Descripción |
|---|---|---:|---|
| `req_accept` | Desde controlador | 1 | Indica aceptación de una solicitud |
| `req_we_accepted` | Desde controlador | 1 | Indica aceptación de una escritura |
| `transfer_busy` | Desde controlador | 1 | Indica transferencia activa |
| `timeout_event` | Desde controlador | 1 | Pulso que registra un timeout |
| `error_event` | Desde controlador | 1 | Pulso que registra un error definitivo |
| `mem_hold` | Hacia controlador | 1 | Detiene el avance de la transferencia física |

Cuando un intento supera el tiempo permitido, el controlador realiza un único reintento.

Si el segundo intento también falla, la operación termina con error.

Durante la recuperación, el controlador evita reutilizar datos o confirmaciones correspondientes al intento anterior.

### 6.7. Eviction buffer

`rtl-p2/eviction_buffer.sv` implementa una FIFO de líneas sucias de 256 bits con profundidad configurable mediante `EB_DEPTH` (mínimo 4, máximo 16; valor predeterminado 4). Las direcciones se alinean a 32 bytes y las entradas permanecen almacenadas hasta recibir confirmación de escritura exitosa desde RAM.

**Interfaz de desalojo desde L2 hacia el buffer:**

| Señal | Dirección relativa al eviction buffer | Bits | Contrato |
|---|---|---:|---|
| `evict_valid` | Entrada | 1 | L2 presenta una línea sucia para insertar |
| `evict_addr` | Entrada | 32 | Dirección de byte; el buffer la alinea a 32 bytes |
| `evict_line` | Entrada | 256 | Contenido completo de la línea desalojada |
| `evict_ready` | Salida | 1 | Hay espacio para insertar la línea; inserción cuando `evict_valid && evict_ready` |

**Interfaz de lectura desde L2 hacia el buffer:**

| Señal | Dirección relativa al eviction buffer | Bits | Contrato |
|---|---|---:|---|
| `read_req` | Entrada | 1 | L2 solicita leer una línea; se requiere retirar la solicitud para habilitar una nueva |
| `read_addr` | Entrada | 32 | Dirección de la línea solicitada, alineada internamente |
| `read_ready` | Salida | 1 | Pulso de respuesta de lectura correcta |
| `read_line` | Salida | 256 | Contenido de la línea solicitada |
| `read_forwarded` | Salida | 1 | La lectura se resolvió directamente con una línea aún en FIFO |

Si la dirección coincide con entradas de la FIFO, el buffer devuelve la versión más reciente (*forwarding*), incluso si esa línea aún espera confirmación de escritura. Para lecturas sin coincidencia, el buffer emite una solicitud de lectura hacia RAM. Las lecturas pendientes tienen prioridad sobre **nuevos** drenados; una escritura de RAM que ya está en curso no se interrumpe.

**Interfaz con el controlador de memoria principal:**

| Señal | Dirección relativa al eviction buffer | Bits | Contrato |
|---|---|---:|---|
| `ram_req` | Salida | 1 | Solicitud de transferencia de línea |
| `ram_we` | Salida | 1 | 0 = lectura; 1 = drenado de escritura |
| `ram_addr` | Salida | 32 | Dirección de byte de la línea |
| `ram_wline` | Salida | 256 | Línea que se escribe en RAM |
| `ram_ready` | Entrada | 1 | Confirmación satisfactoria de la transferencia |
| `ram_rline` | Entrada | 256 | Línea recibida desde RAM |
| `ram_error` | Entrada | 1 | Error definitivo reportado por el controlador (`mem_error`) |

El controlador utiliza `mem_error` para su salida de error; **al conectarlo al buffer debe enlazarse con el puerto `ram_error`**. Una escritura pendiente solo se retira de la FIFO si `ram_ready && !ram_error`. Ante un error de escritura, la FIFO conserva la línea y bloquea los nuevos drenados, sin impedir las lecturas.

**Estado, recuperación y eventos:**

| Señal | Dirección relativa al eviction buffer | Bits | Contrato |
|---|---|---:|---|
| `clear_write_error` | Entrada | 1 | Pulso de recuperación que elimina el bloqueo si RAM está libre y sin respuesta activa |
| `empty` | Salida | 1 | FIFO sin líneas |
| `full` | Salida | 1 | FIFO sin espacio disponible |
| `busy` | Salida | 1 | Existen líneas, lectura pendiente o transferencia activa |
| `occupancy` | Salida | 32 | Número de líneas pendientes en FIFO |
| `write_error_blocked` | Salida | 1 | Drenados suspendidos por fallo de escritura |
| `ev_push` | Salida | 1 | Pulso de inserción de una línea |
| `ev_pop` | Salida | 1 | Pulso de retiro de una línea escrita correctamente |
| `ev_forward` | Salida | 1 | Pulso de lectura resuelta mediante forwarding |
| `ev_error` | Salida | 1 | Pulso de error en operación con RAM |

El buffer utiliza `clk` del dominio CPU y `reset`. La integración de buffer, controlador y RAM simulada está probada mediante `tb_eviction_buffer_integracion.sv`.

### 6.7.1. Estado real de integración con la jerarquía

En la versión revisada de `rtl-p2/mem_hierarchy.sv`, las solicitudes de la L1-D llegan a `l2_model`, que sigue conectado directamente a DMEM mediante `m_we`, `m_be`, `m_addr`, `m_wdata` y `m_rdata`. La L2 real, el eviction buffer y el controlador no están instanciados allí. Por tanto, **las interfaces del buffer y del controlador están definidas y verificadas por separado, pero su conexión con la L2 real está pendiente**. El bus L1-D ↔ L2 de la sección 5 permanece como contrato de integración; no debe confundirse con los puertos `evict_*` y `read_*` del buffer.

### 6.8. Verificación

Las interfaces del controlador se han probado mediante testbenches de temporización, lectura, escritura, CDC, estrés, timeout, reintentos y confirmaciones atrasadas.

Se verificaron las configuraciones de memoria de 20 MHz, 25 MHz y 50 MHz.

Las pruebas de integración comprobaron el intercambio de líneas completas entre el eviction buffer y memoria principal.

Estas pruebas proporcionan evidencia de comportamiento funcional y temporal en simulación. No sustituyen una revisión de las restricciones de reloj y CDC para síntesis.

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
2. Riesgo RAW: write buffer de la L1-D implementado; eviction buffer con forwarding implementado y
   probado por separado (Dylan). Falta conectarlo a la L2 real en la jerarquía.
3. Inclusión: exclusiva por defecto y NINE como parámetro (D3), mientras el profesor la confirma; falta
   la parte de la L2 (Alejandro).
4. Cruce de dominios de reloj, timeout y reintento: implementados y probados en `mem_controller.sv`
   (Dylan). Pendiente la integración con la L2 real y la revisión CDC para síntesis.
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
