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


## K1-A2 — Actualización al bus v2 y eventos WB/exclusiva/MSHR

Las secciones anteriores conservan íntegramente el registro histórico K1-A.
Este anexo describe la implementación vigente después del PR #47 de José y las
pruebas nuevas del 8 de noviembre de 2026. Los conteos y advertencias históricos
no deben confundirse con los resultados actuales de este anexo.

### Base, alcance y fases

Base remota comprobada mediante `git fetch origin develop`, código 0:
`3d8fae0645f15fd7e10e748c71e38b43d7599c5a`. Rama nueva:
`feat/26a2-adaptacion-l1d-v2`. HEAD se conserva. El árbol y el índice estaban
limpios y no había cambios locales de K1-B. Los tres archivos autorizados son
los mismos de K1-A; no se crean archivos adicionales ni se modifica Compiladores.

El PR #47 incorpora write-back, exclusiva, write-allocate, MSHR de stores,
vaciado por recorrido, bits sucios y separación de aceptación/respuesta L2.
También elimina las advertencias de sensibilidad del buffer mediante vectores
aplanados. Esos cambios son de José: no forman parte de nuestro diff.
Se revisaron sus fuentes, sus tres pruebas de caché y las decisiones/guía del equipo.

Fase A primero: se adaptó únicamente el banco al bus v2 y las políticas explícitas,
conservando el RTL de once contadores. Se ejecutaron seis targets de caché y los
nueve controles negativos antes de iniciar la ampliación. Todos pasaron: el caso
nominal terminó con 172995 verificaciones y código 0. La Fase B añadió ocho
acumuladores y sus pruebas después de guardar esa versión verificada externamente.

### Bus v2: aceptación no es respuesta

`l2_req/we/addr/wline/be/wdirty` permanecen válidos hasta `req && gnt`.
Una escritura se aplica al aceptar su solicitud y no genera `rvalid`. Una lectura
aceptada queda pendiente por separado y solo entrega su línea con `rvalid` y
`rdirty`. Que req permanezca activo antes del grant no indica nuevos inicios.
Tras el grant de lectura req puede bajar durante la espera de respuesta; no se
exige estabilidad de campos inválidos de una petición ya aceptada.

Nuestro banco ya no conecta ni consulta `l2_ready`. Conecta `l2_gnt`, `l2_rvalid`,
`l2_rdirty` y `l2_wdirty` y fija `L2_BUS_V2(1)` en todas sus instancias.
En los escenarios históricos, el respondedor mínimo acepta la lectura al inicio
y conserva ocho ciclos de espera hasta su respuesta. Para mantener la presión
original sobre la FIFO, demora ocho flancos el grant de una escritura. Ya no
simula una respuesta de lectura para confirmar un drenado. Los controles se
estabilizan antes del flanco muestreado por el reloj manual del banco.

El guion WB entrega grants y respuestas deliberadamente por separado. Retiene
una escritura cuatro flancos sin grant, contrastando dirección, tipo, máscara,
línea y dirty; solo un inicio de tráfico debe contabilizarse. Comprueba cada
aceptación y que rvalid corresponda a una lectura previamente aceptada.
`rdirty=1` se inyecta en un llenado conocido y debe observarse posteriormente
como víctima sucia, incluso sin un store de CPU sobre esa línea.

Esto sigue siendo infraestructura de prueba contenida en el banco: memoria de
respuesta y estímulos deterministas, sin tags L2, inclusión, reemplazo ni controlador
de producción. La memoria inferior se actualiza en el grant de escritura;
la referencia arquitectónica se actualiza por los stores dirigidos.

### Configuración explícita e independencia de defaults

| Parámetro | Guiones originales y sus sombras | Guiones WB y sus sombras |
|---|---|---|
| WRITE_POLICY | WP_WRITE_THROUGH | WP_WRITE_BACK |
| INCL_POLICY | INCL_NINE | INCL_EXCLUSIVE |
| ALLOC_POLICY | AP_NO_WRITE_ALLOC | AP_WRITE_ALLOC |
| REPL_POLICY | RP_LRU | RP_LRU |
| RAW_POLICY | RAW_FORWARD o RAW_STALL | RAW_FORWARD (exclusiva obliga a esperar) |
| WB_DEPTH | 2 | 2 |
| N_MSHR | 1 | 1, 2 y 4 explícitos |
| L2_BUS_V2 | 1 | 1 |

Las dos macros de instanciación declaran los ocho parámetros; sus expansiones
cubren las diez cachés reales/sombra. El banco no menciona los alias temporales
`L1D_WRITE_POLICY` ni `L1L2_INCLUSION_POLICY`. Una auditoría estática verifica estos
hechos y la ausencia del puerto antiguo. José puede cambiar los defaults y retirar
los alias al actualizar su propio módulo, sin cambiar este banco, mientras conserve
los nombres, códigos y contratos públicos de parámetros y puertos. No se alteraron
sus defaults ni se ensayaron mutaciones de sus fuentes, tampoco en la copia externa.

### Diecinueve contadores; cinco totales conservados

Se mantienen los nombres, incrementos y cinco sumas originales. Se añaden entradas
y acumuladores unsigned de 64 bits para:

| Entrada | Acumulador nuevo | Semántica verificada |
|---|---|---|
| `ev_fill` | `fill_events` | Llegada de línea: incluye llenado asíncrono de un MSHR. |
| `ev_victim_dirty` | `victim_dirty_events` | Víctima de reemplazo sucia que entra al write buffer. |
| `ev_victim_clean` | `victim_clean_events` | Víctima de reemplazo limpia enviada por exclusiva. |
| `ev_mshr_alloc` | `mshr_alloc_events` | Store miss que reserva un MSHR libre. |
| `ev_mshr_merge` | `mshr_merge_events` | Store miss fusionado con una reserva existente. |
| `ev_mshr_load` | `mshr_load_events` | Load servido por los cuatro bytes disponibles de una palabra en MSHR. |
| `ev_hit_under_miss` | `hit_under_miss_events` | Hit de L1-D completado mientras hay MSHR ocupados. |
| `ev_mshr_full_stall` | `mshr_full_stall_cycles` | Flanco de espera de store por reservas agotadas; excluye el flanco de fill. |

Todos usan `posedge clk`, reset síncrono prioritario y la misma habilitación.
Pausar conserva acumulados, sin encolar eventos perdidos. No hay detección de
flancos ni exclusión entre categorías. Se conservan aritmética módulo 2^64 y
cálculo externo de tasas; no hay divisores ni promedios adicionales en el RTL.

La interpretación de los eventos originales sigue el productor vigente:

- Las cuatro clasificaciones cuentan finalizaciones, no reservas o llenados.
  Store reservado/fusionado en MSHR y load servido desde MSHR son misses de L1-D
  aunque no tengan stalls. Los hits bajo miss pertenecen a L1-D, no a L2.
- `ev_wb_push` ahora incluye stores WT, víctimas y líneas sucias del vaciado.
  Su registro original se conserva; ya no debe interpretarse universalmente
  como cantidad de stores completados.
- `ev_stall` sigue siendo el total por flanco. WB lleno, RAW y MSHR lleno son
  causas observadas y no se suman automáticamente al total.
- `ev_l2_read/write` siguen siendo inicios de solicitudes, no aceptaciones ni
  hits/misses de una L2 real. `ev_fill` corresponde a la respuesta efectiva.
- `ev_victim_dirty/clean` clasifica reemplazos al ingresar a WBUF; un push del
  recorrido de vaciado no activa por sí solo esos eventos de víctima.

En particular, al llenarse un MSHR el puerto único bloquea stores un ciclo.
Ese ciclo suma stall, pero queda excluido de `ev_mshr_full_stall`. El guion con
reservas llenas comprueba tres ciclos de capacidad más uno de fill: cuatro
stalls totales, no siete ni cuatro ciclos de MSHR lleno.

### Referencia, guiones reales y pasividad

Se conservan todos los escenarios históricos y sus expectativas de clasificación,
datos, tasas, ventanas y espera. Cada tick contrasta ahora los diecinueve registros
contra una referencia por operaciones y protocolo público. Los fills esperados
proceden del respondedor independiente, no de leer `ev_fill`.

El arnés adicional usa guiones de eventos explícitos por flanco, no una copia de
la máquina de estados de José. Antes de cada operación se conocen dirección,
datos, conjunto, reservas y resultados esperados. No lee registros privados de
caché para construir expectativas. Un registro de aceptación pendiente valida
el bus y memoria inferior; no calcula etiquetas ni reemplazo.

Cada arnés WB (capacidades 1, 2 y 4) tiene caché sombra con idéntica configuración,
pero sin consumidor. Datos, stall, flush, bus y eventos públicos se contrastan por
flanco. El consumidor no controla ninguna entrada del productor. Tras el vaciado
se comparan las 16384 palabras de memoria contra la referencia de CPU.

| Escenario | Expectativa independiente comprobada |
|---|---|
| A/B/C/D, mismo conjunto 5, A modificada | C expulsa A sucia; D expulsa B limpia en exclusiva. |
| E entra con rdirty=1, F y G posteriores | La víctima E conserva dirty sin store de CPU sobre E. |
| Guion completo de reemplazo | 7 fills, 2 víctimas sucias y 3 limpias por capacidad. |
| Store miss con capacidad 1 | 8 stalls, fill y un miss; no reserva MSHR. |
| Store miss con capacidad 2/4 | Se completa con reserva antes del fill, sin stall. |
| Segundo store a línea pendiente | Un merge, sin nueva reserva; ambos datos sobreviven al fill. |
| Load de palabra completa del MSHR | Un miss secundario y evento mshr_load, sin fill ni stall. |
| Load y store hits con otro MSHR ocupado | Dos hit_under_miss y sus clasificaciones de demanda. |
| NM reservas agotadas | Tres FULL+STALL y luego FILL+STALL sin FULL; el nuevo store reserva después. |
| Ráfaga drenada en orden | NM+1 reservas/fills únicos, datos de todas las líneas correctos. |
| Flush exclusivo | Push de líneas sucias, grant de escrituras, memoria correcta y cero demanda inventada. |
| Carga posterior de línea sucia vaciada | Miss público: esa línea fue invalidada al moverse. |
| Ventana apagada y reset de métricas | Productor continúa, registros conservados y posterior borrado de los diecinueve. |

Los guiones de capacidad usan longitudes adaptadas a NM para llenar todas sus
reservas. No se presentan como un benchmark comparativo de velocidad entre
capacidades ni se exige igualdad de ciclos; cada una se contrasta con su memoria
esperada. La exclusividad global frente a una L2 real requiere su integración
posterior; la sombra no sustituye ese checker.

### Sintéticos, controles negativos y resultados

Se extienden eventos individuales, consecutivos, combinaciones, pausas y resets
a los diecinueve contadores. El testbench conserva las precargas de acarreo y
overflow y las amplía a los ocho registros nuevos, sin `force` ni alteraciones de
estado privado del productor. Solo el consumidor sintético recibe precargas.

Se conservan las nueve mutaciones originales y se agregan siete: reserva duplicada,
merge/fill omitidos, víctima sucia reclasificada, repetición de FULL, ventana WB
ignorada y omisión de reset con solo el contador de fills no nulo. Todas modifican
exclusivamente entradas diagnósticas del consumidor. Para el reset negativo se
omite su reset, sin cambiar el reset del productor. Los dieciséis controles
terminan con código 1 en el índice de contador previsto; son fallos esperados,
no regresiones nominales. La tabla completa y las primeras divergencias están en
el informe externo y `final-negativos.json`.

Resultado nominal nuevo: **247770 verificaciones, código 0**. Incluye 22861,
23611 y 23871 del arnés WB con NM=1/2/4; los demás chequeos pertenecen a los
sintéticos y escenarios históricos ampliados. La cifra es de aserciones, no de
programas distintos. La Fase A tuvo 172995 frente a 172950 de la línea base:
se agregó dirty y se ajustó la comprobación de validez de petición al bus separado;
los campos de una lectura ya aceptada no necesitan permanecer válidos mientras
req=0. Se conservan las comprobaciones funcionales, de retención hasta grant y
los nueve controles de sensibilidad anteriores.

| Comando | Antes: código | Después: código | Antes: resultado | Después: resultado |
|---|---:|---:|---|---|
| `make tb_perf_cache_l1d_k1a` | 0 | 0 | 172950 verificaciones | 247770 verificaciones |
| `make tb_l1d_cache` | 0 | 0 | tb_l1d_cache: 81 verificaciones correctas | tb_l1d_cache: 81 verificaciones correctas |
| `make tb_l1d_writeback` | 0 | 0 | tb_l1d_writeback: 68 verificaciones correctas | tb_l1d_writeback: 68 verificaciones correctas |
| `make tb_l1d_mshr` | 0 | 0 | tb_l1d_mshr: 109 verificaciones correctas | tb_l1d_mshr: 109 verificaciones correctas |
| `make tb_l1d_replacement` | 0 | 0 | tb_l1d_replacement: 17 verificaciones correctas | tb_l1d_replacement: 17 verificaciones correctas |
| `make tb_l1d_write_buffer` | 0 | 0 | tb_l1d_write_buffer: 15613 verificaciones correctas | tb_l1d_write_buffer: 15613 verificaciones correctas |
| `make tb_perf_counters` | 0 | 0 | tb_perf_counters: 292 verificaciones correctas | tb_perf_counters: 292 verificaciones correctas |
| `make tb_perf_slot_mask` | 0 | 0 | tb_perf_slot_mask: 4299 verificaciones correctas | tb_perf_slot_mask: 4299 verificaciones correctas |
| `make tb_perf_pipeline_monitor` | 0 | 0 | tb_perf_pipeline_monitor: 9981 verificaciones correctas | tb_perf_pipeline_monitor: 9981 verificaciones correctas |
| `make tb_perf_vliw_monitor_d4b1` | 0 | 0 | tb_perf_vliw_monitor_d4b1: 42188 verificaciones correctas | tb_perf_vliw_monitor_d4b1: 42188 verificaciones correctas |
| `make tb_perf_top_d3` | 0 | 0 | tb_perf_top_d3: 13717 verificaciones correctas | tb_perf_top_d3: 13717 verificaciones correctas |
| `make tb_perf_branch_d4a` | 0 | 0 | tb_perf_branch_d4a: 12573 verificaciones correctas | tb_perf_branch_d4a: 12573 verificaciones correctas |
| `make tb_perf_stall_d5a` | 0 | 0 | tb_perf_stall_d5a: 72538 verificaciones correctas | tb_perf_stall_d5a: 72538 verificaciones correctas |
| `make tb_pipeline_stall` | 0 | 0 | tb_pipeline_stall: 50 verificaciones correctas | tb_pipeline_stall: 50 verificaciones correctas |
| `make sim` | 0 | 0 | Resumen: 35 PASS, 0 FAIL, 0 NO-COMPILA, 0 SIN-CHEQUEO | Resumen: 35 PASS, 0 FAIL, 0 NO-COMPILA, 0 SIN-CHEQUEO |
| `make test-assembler` | 0 | 0 | 44 métodos (21+13+4+6) | 44 métodos (21+13+4+6) |
| `make test-programs` | 0 | 0 | 14 métodos | 14 métodos |

Los 17 comandos anteriores y posteriores terminaron con código 0. El total de
`make sim` ya era 35 en la base del PR #47 y sigue siendo 35; este bloque no añade
un archivo de testbench. Las pruebas del ensamblador y programas suman 44 y 14
métodos respectivamente. El nuevo target no presenta warnings de Icarus y las
advertencias históricas del write buffer ya habían sido resueltas por José.
El resto de advertencias de compilación de `make sim`, si las hubiera, permanece
en los compile.log externos; no se silenció ni modificó código protegido.
La ejecución opcional con VCD termina con código 0, 247770 verificaciones y
1874788 bytes de ondas. Las trazas incluyen capacidad, ciclo, dirección, vector
esperado/real, ventana, reset y las señales públicas del bus v2.
En la revisión final se corrigió el registro del CSV WB para escribir eventos
antes del flanco, en el mismo instante que usan las aserciones. Las 733 filas
posteriores al reset inicial de los tres arneses concuerdan con su vector esperado.
La primera fila de cada arnés es anterior al primer reset síncrono efectivo:
puede contener X del productor y no se interpreta como divergencia funcional.


### Dependencias de K1-B y L2 real

No se implementa latencia/AMAT nuevo. K1-B debe separar aceptación de CPU,
aceptación de solicitud L2, respuesta/fill, finalización de demanda y persistencia.
Un store puede retirarse con MSHR pendiente, un load puede salir de bytes de MSHR,
y un hit puede solaparse con otro fill. Causas FULL/RAW/WBUF no particionan
necesariamente toda espera. Stores WB no actualizan inmediatamente la memoria
inferior; el vaciado incluye MSHR, recorrido, buffer y luego los niveles restantes.

Por esas razones `AMAT = 1 + stall_cycles/accesos` no es identidad universal de
la caché non-blocking. Las ventanas pueden cortar reserva, solicitud y fill en
flancos diferentes; sus cantidades no son la misma población de accesos. Los
archivos locales y la rama de K1-B se conservan sin modificar.

La L2 real debe garantizar grants/respuestas según su contrato, mantener dirty
con exclusiva y completar su vaciado posterior al de L1-D. Los guiones manuales
no prueban rendimiento de la jerarquía completa, múltiples respuestas fuera de
orden ni memoria principal. No se añaden contadores de L2 ni se conecta el
procesador. El issue #26 sigue pendiente de las etapas restantes.

### Reproducción y aislamiento

Ejecutar en una copia externa con las fuentes vigentes:

```bash
make tb_perf_cache_l1d_k1a
make tb_perf_cache_l1d_k1a PLUSARGS=+VCD
```

Para sensibilidad, desde otro directorio externo, usar la ruta absoluta al
`build/tb_perf_cache_l1d_k1a/sim.vvp` compilado y `+MUTATION=N` (N=1..16).
Cada control debe terminar con código 1 y la aserción especificada; el nominal
termina con código 0. No ejecutar las mutaciones como si fueran PASS de `make sim`.

Evidencia actual: `/tmp/ce4301-k1a2-kx69djnu/`, con manifiestos, diff de José,
regresiones antes/fase-a/después, fuentes de Fase A verificadas, trazas CSV,
controles negativos, VCD, auditoría de parámetros e informe A–AE. Las ubicaciones
temporales anteriores de K1-A son históricas, no dependencias de reproducción.

Se protegen los 391 archivos iniciales de Arquitectura salvo los tres autorizados,
y los 359 archivos de Compiladores. La comparación incluye SHA-256, tamaño y modo;
además se comprueban HEAD, rama e índice. No se crean nuevos archivos dentro de
ningún repositorio ni se modifica implementación de compañeros. Los resultados
finales de aislamiento se registran en `aislamiento.json` y el informe externo.
