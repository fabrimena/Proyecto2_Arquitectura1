# Issue #26 — K1-A: contadores de eventos de L1-D

## Alcance y base

El issue #26 requiere accesos, hits, misses, tasas y AMAT de caché. K1-A implementa
exclusivamente el consumidor de los once eventos públicos de L1-D y valida sus
acumulados. AMAT definitivo queda para K1-B; este bloque no cierra el issue #26.
No se integra al procesador ni a una L2 real.

Base verificada mediante `git fetch origin develop`:
`711a1c37596957a19b3131405ffb9ba088f2e13a`. Rama local:
`feat/26a-contadores-l1d`, creada desde `origin/develop` actualizado.
El árbol y el índice estaban limpios. Se conservó HEAD y no se hizo staging,
commit, publicación ni integración con otras ramas.

Únicos archivos nuevos: `rtl-p2/perf_cache_l1d.sv`,
`tb-p2/tb_perf_cache_l1d_k1a.sv` y este documento. Todos los archivos anteriores
están protegidos, incluidos `top.sv`, las cachés y sus políticas, los módulos de
métricas existentes, los registros del pipeline, los testbenches, `Makefile`,
`README.md` y los archivos de Compiladores.

## Contrato observado en el productor de José

La geometría actual es 4 KiB, 64 conjuntos, dos vías y líneas de 32 bytes:
8 palabras. Se usan los 16 bits físicos bajos: etiqueta `[15:11]`, conjunto
`[10:5]`, palabra `[4:2]`. Los estímulos usan write-through, no-write-allocate,
LRU y dos entradas de write buffer, una configuración admitida para provocar
llenado. Se prueban RAW_FORWARD y RAW_STALL en instancias distintas.

La inspección comprende `l1d_cache.sv`, `cache_defs.sv`, `l1d_arrays.sv`,
`l1d_replacement.sv`, `l1d_write_buffer.sv`, sus pruebas existentes, los monitores
anteriores, `docs/l1d-cache.md`, `docs/memory-interfaces.md`,
`docs/performance-analysis.md` y el Makefile. Se contrastaron comentarios con las
asignaciones reales, en particular el momento de clasificación y el bloqueo RAW.

| Evento de entrada | Acumulador unsigned de 64 bits | Qué representa cada incremento |
|---|---|---|
| `ev_rd_hit` | `read_hits` | Una lectura completada que inicialmente acertó. |
| `ev_rd_miss` | `read_misses` | Una lectura completada que inicialmente falló. |
| `ev_wr_hit` | `write_hits` | Un store completado que inicialmente acertó. |
| `ev_wr_miss` | `write_misses` | Un store completado que inicialmente falló. |
| `ev_stall` | `stall_cycles` | Un flanco con el acceso demandado en espera, por cualquier causa. |
| `ev_wb_full_stall` | `wb_full_stall_cycles` | Un flanco de bloqueo atribuido por el productor a buffer lleno. |
| `ev_raw_stall` | `raw_stall_cycles` | Un flanco de bloqueo RAW con necesidad de llenado y bus aún libre. |
| `ev_raw_forward` | `raw_forward_events` | Un llenado con coincidencia de línea en el buffer, corregido por forwarding. |
| `ev_wb_push` | `wb_push_events` | Un store aceptado en el write buffer. |
| `ev_l2_read` | `l2_read_requests` | Inicio de solicitud de lectura de línea hacia L2. |
| `ev_l2_write` | `l2_write_requests` | Inicio de drenado de un store hacia L2. |

Los cuatro resultados de demanda se emiten al completar el acceso, no al empezar
ni durante cada ciclo de espera. `acc_was_miss` conserva la clasificación inicial.
El llenado no convierte el miss pendiente en un hit para las métricas. Un store
NWA puede fallar y completarse sin lectura de línea si hay espacio en el buffer.
Los hit/miss no se infieren de datos, escrituras de registros ni tráfico L2.

Para accesos legales con `re` y `we` excluyentes, solo una de las cuatro
clasificaciones puede estar activa. La prueba contrasta su vector exacto por
flanco. El consumidor confía en ese contrato y no corrige productores inválidos.
No usa detección de flancos del evento: dos completados consecutivos de la misma
clase pueden mantener el nivel activo y ambos deben contarse.

Los stalls son ciclos, no accesos. El total no se reconstruye sumando causas.
Con NWA y este puerto único, los casos dirigidos de buffer lleno corresponden a
stores y RAW a lecturas; se prueban también causas sintéticas coincidentes para
confirmar que el consumidor conserva cada indicador sin aplicar prioridades.
`ev_raw_stall` no cubre automáticamente todo el tiempo del acceso RAW: durante un
drenado en curso `port_busy=1` excluye ese evento aunque `ev_stall` siga activo.

El buffer no fusiona stores. Sus entradas se drenan por el bus único cuando una
lectura nueva no tiene prioridad. La coincidencia de forwarding es por línea;
no implica una nueva operación del núcleo. Los eventos de tráfico son pulsos de
inicio, mientras `l2_req` se retiene hasta el `l2_ready` registrado. No describen
hits, misses, inclusión ni reemplazo de una L2 real.

## Diseño, reset y reloj

`perf_cache_l1d` tiene entradas explícitas `clk`, `reset`, `measure_enable` y los
once eventos anteriores. Sus salidas son once acumuladores y cinco totales
combinacionales:

```text
read_accesses  = read_hits + read_misses
write_accesses = write_hits + write_misses
total_accesses = read_accesses + write_accesses
total_hits     = read_hits + write_hits
total_misses   = read_misses + write_misses
```

No hay registros duplicados para los totales, división, accesos jerárquicos,
retardos, archivos, VCD ni instancias de caché en el RTL de producción. Las sumas
y los incrementos son módulo 2^64, sin saturación ni indicador de overflow.
Una tasa válida requiere que tampoco hayan desbordado los totales derivados.

En cada `posedge clk`, reset síncrono borra los once registros con prioridad sobre
la habilitación y todos los eventos. Si no hay reset y la medición está habilitada,
cada evento activo incrementa su propio acumulador. Se usan condiciones separadas
para conservar eventos simultáneos de demanda, tráfico y actividad auxiliar.
En ausencia de habilitación o eventos, los acumuladores conservan su valor.

El reloj es el general, nunca `core_clk`: el buffer y el handshake siguen
funcionando cuando el núcleo espera. Entradas síncronas y estables antes del
flanco son parte del contrato. No se introduce cruce de dominio ni filtrado.
El reset del consumidor no se conecta al productor; la prueba lo aplica por
separado durante una lectura pendiente y verifica que la caché la completa.

## Ventanas de medición

`measure_enable=0` no detiene L1-D ni guarda eventos para después. La reanudación
solo incluye eventos de nuevos flancos habilitados. Se prueba ventana completa,
inicio tardío, pausa y reanudación durante miss, hit deshabilitado, miss entero
deshabilitado y drenado del buffer durante una pausa con acumulados no nulos.

Un miss con espera inicial fuera de ventana y finalización dentro de ella suma
un acceso completo, pero solo la parte observada del stall. Un miss completado
fuera de ventana no suma acceso aunque parte de su espera sí haya sido medida.
Las solicitudes L2 iniciadas fuera de ventana tampoco se recuperan al completarse.
El reset durante un acceso permite observar su finalización sin conservar el
inicio anterior. Estas son medidas por evento observado, no cohortes de accesos.

## Tasas fuera del hardware

Se calculan con aritmética real:

```text
hit_rate        = total_hits / total_accesses
miss_rate       = total_misses / total_accesses
read_hit_rate   = read_hits / read_accesses
read_miss_rate  = read_misses / read_accesses
write_hit_rate  = write_hits / write_accesses
write_miss_rate = write_misses / write_accesses
```

Si el denominador es cero, el resultado es `NO DEFINIDO`, no cero. El banco
comprueba los seis denominadores vacíos y un dataset conocido de 3H/1M de lectura
y 1H/3M de escritura. Usa tolerancia absoluta `1e-12` para los cocientes y verifica
la partición `total_hits + total_misses = total_accesses`. La suma de tasas del
dataset 4H/4M es exactamente 1 por su representación binaria; su comparación
exacta en ese caso no se generaliza a cocientes arbitrarios.

## Referencia independiente y pasividad

El banco tiene una unidad con eventos sintéticos y dos escenarios con L1-D real,
uno por política RAW. Cada escenario instancia también una caché sombra sin
consumidor. Ambas reciben las mismas peticiones y respuestas, y se comparan sus
salidas públicas de datos, stall, flush y protocolo en cada flanco relevante.
Los contadores no retroalimentan ninguna entrada de caché.

La expectativa hit/miss viene de un guion dirigido y de la geometría, no de los
eventos ni del estado privado. A/B/A/C en el mismo conjunto determina qué línea
sobrevive con LRU de dos vías. El resto usa líneas vacías conocidas o residentes.
Una cola externa de stores aceptados, con dirección, máscara y datos, permite
predecir espacio disponible, coincidencias RAW y drenados. Es un registro de
operaciones públicas, no un segundo controlador de caché o reemplazo.

El respondedor mínimo del testbench conserva una sola solicitud y devuelve un
ready registrado después de ocho flancos de espera. Guarda 64 KiB de datos para
validar lecturas, bytes de stores y persistencia tras flush. No implementa tags,
políticas ni caché L2 de producción. La memoria esperada de CPU se actualiza al
aceptar stores; la memoria del respondedor se actualiza al atender drenados.
Su igualdad completa se verifica después de cada vaciado.

Antes de cada flanco se predice el vector de once eventos por operación, cola y
protocolo. Se contrasta con el productor original; después de las NBA se verifican
los once prefijos acumulados y cinco totales. Una divergencia registra política,
ciclo, mutación y causa. Los CSV guardan dirección, tipo, clasificación inicial,
ventana, eventos esperados/reales, cola, bus, finalización y reset de métricas.
Las expectativas no se construyen a partir de las salidas del contador.

Los casos sintéticos prueban cada evento individual, repeticiones consecutivas,
combinaciones, pausa/reanudación, ausencia de eventos, reset con eventos y reset
con ventana apagada. Para no simular 2^64 flancos, exclusivamente el testbench
precarga cada registro del consumidor con `0xffffffff` y `0xffffffffffffffff`;
comprueba acarreo a 33 bits y vuelta a cero. También provoca un desbordamiento
aritmético de los totales mediante precarga, sin usar la instrucción `force`.
No se precarga ni consulta estado privado de ninguna caché.

## Escenarios y tiempos comprobados

| Secuencia dirigida | Espera esperada y comprobada |
|---|---|
| Primer load A `0x08ac` | Miss, 8 stalls, servicio 9 flancos. |
| Repetir A y palabra 7 `0x08bc` | Hit, 0 stalls, servicio 1. |
| B `0x10ac`, A, C `0x18ac`, A, B | Miss/hit/miss/hit/miss: C desaloja B. |
| Store hit y store selectivo de byte en A | Dos hits de escritura, 0 stalls, dos pushes. |
| Store NWA `0x3024` | Un miss de escritura, 0 stalls, ningún fill por ese store. |
| Load inmediato `0x3024`, RAW_FORWARD | Un miss, 8 stalls y un forwarding. |
| Mismo caso RAW_STALL | Un miss, 17 stalls, un ciclo específico RAW; luego drenado y lectura. |
| Tres stores consecutivos con profundidad 2 | 0, 0 y 8 stalls; el tercero no hace push con FIFO aún llena. |
| Inicio tardío durante miss | 4 de sus 8 stalls y una finalización medidos. |
| Pausa intermedia durante miss | 5 de sus 8 stalls y una finalización medidos. |
| Hit/miss con ventana apagada | 0 eventos acumulados; la caché sí completa los accesos. |
| Pausa de cuatro flancos con WB activo | Se conserva el acumulado; continúa el drenado. |
| Flush | Drena stores, conserva la memoria y no inventa demanda. |
| Reset exclusivo de métricas durante miss | Borra el acumulado; la solicitud de caché sobrevive. |

Cada política ejecuta 22 accesos físicos: 15 lecturas y 7 stores, con 12 hits y
10 misses; produce 9 solicitudes de lectura y 7 de escritura hacia el respondedor.
El último miss se usa para probar reset independiente y no entra en la media
de los 21 `access()` anteriores.

Antes de ese reset, las ventanas seleccionan 19 finalizaciones: lecturas 5H/7M y
stores 6H/1M. Se comprueban explícitamente 57 stalls con forwarding o 66 con espera
RAW, 8 por buffer lleno, 0/1 por RAW y 1/0 forwardings, respectivamente. Se miden
7 pushes y seis inicios L2 de cada tipo: los demás inicios ocurren fuera de ventana.
Las tasas reales en ambas políticas son 11/19 y 8/19 globales, 5/12 y 7/12 de
lectura, 6/7 y 1/7 de escritura, con tolerancia `1e-12`.

## Límites de la latencia observada y AMAT

Se conservan `re/we`, dirección, stall y finalización por flanco para delimitar
cada acceso. Para los 21 accesos dirigidos completos se observan 93 flancos de
servicio y 72 de espera con forwarding: media `93/21 = 4.428571428571`. Con
RAW_STALL son 102 y 81: media `102/21 = 4.857142857143`. Incluyen accesos apagados
para medir su tiempo completo; no se infieren dividiendo contadores de ventana.
Excluyen inactividad y vaciados entre accesos. El servicio de un store es su
aceptación, no el momento posterior en que toda la jerarquía recibe sus bytes.

Estas medias describen únicamente este guion, sus políticas y un respondedor de
latencia fija. No son AMAT definitivo de L1-D ni de la jerarquía completa.
`ev_stall` mezcla causas, puede quedar cortado por una ventana y no contiene por
sí solo todos los tiempos de servicio o de persistencia. K1-B debe fijar límites
de cada acceso, población medida, tratamiento de stores, solapamiento, causas,
vaciado y latencias reales. Las métricas y AMAT de L2 requieren la interfaz real
del otro integrante. No se atribuyen misses L2 a solicitudes L1-D → L2.

## Sensibilidad: controles negativos

Las mutaciones solo alteran entradas diagnósticas del consumidor en el banco;
no cambian estímulos, productor, respondedor, referencia ni memoria. La mutación 7
altera la habilitación entregada al consumidor. Las de duplicación retienen un
evento un flanco adicional, porque una entrada de un bit no representa dos pulsos
en el mismo flanco. Cada ejecución debe fallar por la aserción de contador prevista:

| Mutación | Error inyectado | Código vvp esperado/real | Primer desacuerdo |
|---:|---|---|---|
| 1 | hit como miss | 1 / 1 | ciclo 12: `contador[0] esperado=1 observado=0` |
| 2 | miss duplicado | 1 / 1 | ciclo 12: `contador[1] esperado=1 observado=2` |
| 3 | acceso omitido | 1 / 1 | ciclo 12: `contador[0] esperado=1 observado=0` |
| 4 | stall omitido | 1 / 1 | ciclo 3: `contador[4] esperado=1 observado=0` |
| 5 | stall repetido fuera de su ciclo | 1 / 1 | ciclo 11: `contador[4] esperado=8 observado=9` |
| 6 | store como lectura | 1 / 1 | ciclo 43: `contador[0] esperado=4 observado=5` |
| 7 | evento acumulado fuera de ventana | 1 / 1 | ciclo 116: `contador[4] esperado=48 observado=49` |
| 8 | tráfico como demanda | 1 / 1 | ciclo 3: `contador[0] esperado=0 observado=1` |
| 9 | forwarding perdido | 1 / 1 | ciclo 74: `contador[7] esperado=1 observado=0` |

Código 1 es el resultado esperado de `vvp` en estos controles, no una regresión
nominal. El caso sin mutación y la ejecución con VCD terminan con código 0.

## Regresiones y evidencia

Las pruebas anteriores se ejecutaron antes y después en dos copias externas,
con el mismo HEAD y los mismos catorce comandos. El target nuevo es descubierto
por el Makefile existente, sin modificarlo.

| Comando | Antes: salida | Después: salida | Resultado real |
|---|---:|---:|---|
| `make tb_perf_counters` | 0 | 0 | 292 verificaciones, sin cambios |
| `make tb_perf_slot_mask` | 0 | 0 | 4299 verificaciones, sin cambios |
| `make tb_perf_pipeline_monitor` | 0 | 0 | 9981 verificaciones, sin cambios |
| `make tb_perf_top_d3` | 0 | 0 | 13717 verificaciones, sin cambios |
| `make tb_perf_branch_d4a` | 0 | 0 | 12573 verificaciones, sin cambios |
| `make tb_perf_stall_d5a` | 0 | 0 | 72538 verificaciones, sin cambios |
| `make tb_perf_vliw_monitor_d4b1` | 0 | 0 | 42188 verificaciones, sin cambios |
| `make tb_pipeline_stall` | 0 | 0 | 50 verificaciones, sin cambios |
| `make tb_l1d_replacement` | 0 | 0 | 17 verificaciones, sin cambios |
| `make tb_l1d_write_buffer` | 0 | 0 | 14248 verificaciones, sin cambios |
| `make tb_l1d_cache` | 0 | 0 | 79 verificaciones, sin cambios |
| `make sim` | 0 | 0 | 32 → 33 PASS; 0 FAIL/NO-COMPILA/SIN-CHEQUEO |
| `make test-assembler` | 0 | 0 | 44 métodos (21+13+4+6) |
| `make test-programs` | 0 | 0 | 14 métodos |

`make tb_perf_cache_l1d_k1a`: salida 0, **172950 verificaciones**, incluidas
comparaciones por flanco y de cada una de las 16384 palabras tras cada flush.
La cifra cuenta aserciones ejecutadas, no programas ni escenarios independientes.
`vvp ... +VCD`: salida 0, mismo resultado y archivo VCD de 513684 bytes.

Advertencias: Icarus informa sensibilidad `@*` a todas las entradas de arreglos
en `l1d_write_buffer.sv:258,261,264,265`, ya presente en la línea base. Las
instancias nuevas añaden mensajes del mismo código protegido con profundidad 2.
No se corrigieron ni ocultaron; no hubo fallos en las regresiones finales.
Durante el desarrollo del banco se corrigió una expectativa final de conteo
(eran 9 lecturas L2, no 11) y una apertura de CSV con una expresión de cadenas
que Icarus rechazaba. Fueron defectos de infraestructura nueva, sin cambios al
RTL protegido. Los registros iniciales y los definitivos permanecen en la evidencia.

## Aislamiento y reproducción

Se compararon SHA-256, tamaños y modos de los **384 archivos anteriores de
Arquitectura** y los **359 de Compiladores**, excluyendo `.git` del manifiesto
de contenido. Todos permanecen idénticos. HEAD, diff de archivos rastreados e
índice de Arquitectura se conservan; Compiladores mantiene su estado Git completo.
Solo aparecen los tres archivos nuevos autorizados, sin seguimiento ni staging.
Los logs, CSV, VCD, manifiestos, binarios y diff están fuera de ambos repositorios.

Evidencia de esta ejecución: `/tmp/ce4301-k1a-9e7i9ufz/`. Incluye
`antes.json`, `despues.json`, logs por comando, `negativos.json`, `vcd/`,
`*-inicial.json`, `*-final.json`, `aislamiento.json`, `k1a.diff` e informe A–AB.
La ubicación temporal es evidencia local; no es una dependencia del módulo.

Para reproducir sin generar artefactos en el repositorio original, copiar el
árbol de fuentes a un directorio externo vacío y ejecutar allí:

```bash
make tb_perf_cache_l1d_k1a
make tb_perf_cache_l1d_k1a PLUSARGS=+VCD
```

Para los controles negativos, ejecutar desde un directorio externo distinto para
cada mutación, usando la ruta absoluta al binario compilado y N entre 1 y 9:

```bash
vvp /ruta/externa/build/tb_perf_cache_l1d_k1a/sim.vvp +MUTATION=N
```

Deben terminar con código 1 y mostrar la primera divergencia de la tabla.
Los comandos de la tabla de regresión deben repetirse sobre esa copia externa;
`make sim` recompila y vuelve a ejecutar todos los testbenches. Las trazas se
escriben en el directorio de ejecución; no deben dirigirse al repositorio original.

K1-A deja pendiente la integración del consumidor en una instancia real del
sistema, la metodología definitiva de AMAT de K1-B y la instrumentación de L2
según su interfaz final. No modifica la ISA, el pipeline ni los componentes
asignados a otros integrantes.
