# Integración transversal de métricas VLIW, etapas y L1-D

Este documento técnico explica las conexiones de los observadores existentes
#7, #8 y #26 al procesador real. Sus entradas son programas ISA, eventos públicos
PRE y ventanas síncronas; sus salidas son acumulados observables, pruebas,
comparaciones y evidencias reproducibles. Depende del pipeline IF/ID/EX/WB,
del avance global y de L1-D con l2_model. Mantiene ISA, N+3, permisos y flush.
No implementa instrucciones D18 ni una interfaz de lectura por software.

**IMPLEMENTADO y VALIDADO CON MODELO:** los cuatro grupos están conectados y
sus pruebas nominales/regresiones pasan. **Resultado formal PARCIAL:** el control
negativo obligatorio que sustituye WB por ex_wb_valid resulta equivalente en
este RTL y no se puede declarar detectado. Se documenta, sin modificar el
procesador para fabricar una divergencia. **BLOQUEADO, preexistente:** flujos
CE1108 completos por rutas antiguas. Fabricio debe revisar top/mem_hierarchy
antes de integrar esta rama; no se solicita ni se realiza un merge aquí.

## A. Estado inicial de Git

Se verificaron pwd, estado, rama, HEAD, diez commits, diff normal/cached,
no rastreados, conflictos y módulos presentes. Árbol e índice estaban limpios.
No existía instrumentación equivalente dentro de top/mem_hierarchy. Se leyeron
las instrucciones locales externas y los archivos completos del contrato.
El manifiesto inicial contiene 427 archivos de Arquitectura, también ignorados,
excluyendo .git; se tomó otro de Compiladores. Los artefactos son externos.

## B. Rama y HEAD

Rama autorizada `feat/7-26-integracion-metricas-top`, HEAD obligatorio
`7a8c03f3da2b54437445933a9439a3da4bf39465`, conservado. Incluye el #9 sobre
PR #58/#57 y los monitores previos. No hubo cambio de rama, fetch, pull,
staging, commits ni operaciones de publicación o modificación del historial.

## C. Alcance

Se conectan permanentemente perf_vliw_monitor y perf_stage_counters en top,
y perf_cache_l1d/perf_cache_l1d_latency en la jerarquía del modo 2. Reutilizan
perf_slot_mask, perf_pipeline_monitor y perf_counters, sin reemplazarlos.
Los únicos registros de producción añadidos son los de esas instancias existentes.

Modificados: rtl-p2/top.sv, rtl-p2/mem_hierarchy.sv y rtl-p2/perf_vliw_monitor.sv.
Nuevos: tb-p2/tb_perf_integracion_top.sv y este documento. Cinco archivos total.
El wrapper solo añade una salida de validez WB; sus algoritmos se conservan.

## D. Archivos protegidos

Sin cambios: rtl/, tb/, caché/arreglos/WBUF/árbitro/L2 provisional/definiciones,
controlador/eviction_buffer/perf_memory, seis monitores protegidos restantes,
tools/, tests/, examples/, Makefile, README y documentación anterior.
No se escribe en Compiladores. Los manifiestos incluyen tamaño, permisos y SHA256.
Las pruebas usan copias de HEAD y cambios autorizados; no se corrigen fallos
preexistentes en fuentes protegidas.

## E. Arquitectura actual

MEM_MODE=0 conecta DMEM directamente, como el Proyecto I. Modo 1 conserva el
modelo de cuatro esperas por acceso LSU del banco; puerto B no añade sus propias
esperas en ese modelo. Modo 2 es top -> mem_hierarchy -> l1d_port_arbiter ->
l1d_cache -> l2_model -> DMEM. No contiene L2 real, controlador o eviction buffer
integrados. DMEM sigue siendo la instancia de 65536 bytes observable original.

## F. Integración VLIW

`top.g_perf.PERF_VLIW` usa clk/reset comunes, perf_measure_enable, core_en,
id_valid/id_bundle, id_ex_valid, branch_flush y crypto_fault. El wrapper califica
EX y da prioridad a excepción; redirect no se trata como BRU. Los cinco
acumulados llegan a señales internas explícitas perf_cycle_count,
perf_bundle_count, perf_instruction_count, perf_memory_stall_count y
perf_branch_penalty_count. Se conservan diagnósticos de evento/recuperación/máscara.
No se cuenta desde wb_we ni se duplica FSL por sus dos escrituras.
La máscara conserva la clasificación de las 34 operaciones reconocidas por
tipo/ID y slot. Excluir reservados de las métricas no elimina los efectos del
fallback ALU existente; no se modifica ningún decoder para normalizarlos.

## G. Integración por etapa

`top.g_perf.PERF_STAGES`: IF=fetch_valid, ID=id_valid, EX=id_ex_valid,
WB=perf_wb_valid. Salidas explícitas: perf_stage_measured_cycles,
perf_stage_occupied, perf_stage_bubbles, perf_stage_stalls y
perf_stage_stalled_occupied. Índices 0/1/2/3 corresponden a IF/ID/EX/WB.
Ocupados+burbujas=medidos módulo 2^64; ocupados_congelados<=congelados sin wrap.
Los cuatro stalls son el mismo congelamiento; no se suman como stall global.

## H. Validez completa de WB

perf_vliw_monitor expone al final de su lista de puertos `wb_valid`, conectado
al puerto ya existente de PIPELINE. No crea otro transportador, registro o
referencia jerárquica en producción. Es nivel de residencia PRE, incluso con
stall y máscara cero; bundle_complete exige además avance y ausencia de reset.
NOP suma bundle/cero instrucciones; una burbuja no completa. Store/BRU/CRIPTO
no necesitan una escritura ALU. Un salto conserva su bundle y anula IF/ID;
la excepción anula también EX culpable y conserva el WB anterior.

La revisión encontró 33 instanciaciones por nombre en las fuentes actuales
(top: 28, jerarquía: 2, wrapper: 3, incluidos los dos top nuevos del módulo de prueba).
Los tres parámetros anteriores de top y sus puertos mantienen orden; PERF_ENABLE
y perf_measure_enable se agregan al final de sus respectivos grupos. Todos los
consumidores anteriores usan conexiones nombradas y pasan las regresiones.
No se promete compatibilidad posicional para consumidores externos no presentes.

En el RTL vigente EX_WB.valid_in=id_ex_valid&&!crypto_fault y el transporte de
metadatos sigue el mismo flujo global. Por inducción sobre reset/avance/redirect,
sus bits de WB coinciden en este contrato coherente. La mutación05 pasó las
mismas 60 capturas: no demuestra sensibilidad ni justifica adoptar el carril ALU
como contrato futuro universal. La variante05b limita WB a ALU útil y sí falla.

## I. Integración K1-A

`top.g_mem_cache.HIER.g_perf.PERF_K1A` recibe diecinueve salidas públicas de L1D
mediante perf_events[18:0]. Sus resultados son perf_event_counts[18:0][63:0]
y perf_access_totals[4:0][63:0]. La auditoría cableado-k1a.json verifica cada
conexión productor/bit/contador, además de las comparaciones PRE/POST reales.

Orden 0..18: rd_hit, rd_miss, wr_hit, wr_miss, stall, wb_full_stall, raw_stall,
raw_forward, wb_push, l2_read, l2_write, fill, victim_dirty, victim_clean,
mshr_alloc, mshr_merge, mshr_load, hit_under_miss, mshr_full_stall.
Los cinco totales son lecturas, stores, accesos, hits y misses, respectivamente.
Un fill, push, reserva o fusión no es otra demanda. l2_read/write son inicios,
no aceptaciones ni resultados de una caché L2. No se inspeccionan privados.

## J. Integración K1-B

`top.g_mem_cache.HIER.g_perf.PERF_K1B` recibe c_re/c_we/c_stall DESPUÉS del árbitro
y los mismos cuatro eventos de clasificación. Cada fase B-read/A/B-write es una
demanda del puerto único; no se suman los dos puertos previos ni se atribuye toda
la espera global del bundle al servicio interno de una operación de L1-D.

Salidas por puertos internos explícitos: perf_completed_by_class,
perf_service_by_class, perf_wait_by_class (0RH/1RM/2WH/3WM), perf_completed_accesses,
perf_completed_reads/writes/hits/misses, perf_service_cycles, perf_wait_cycles,
perf_no_wait_accesses, perf_excluded_accesses, perf_protocol_errors,
perf_pending, perf_pending_eligible y perf_pending_wait_cycles. Todos los
acumulados/edades son unsigned64; seguimiento y diagnóstico conservan sus reglas.
Service=wait+completed módulo 2^64, siempre dentro de la misma cohorte.

## K. Señales y productores

| Señal | Productor real | Uso |
|---|---|---|
| core_en | Latch con clk bajo de !cache_stall | Avance efectivo, no valor POST. |
| fetch_valid | FETCH combinacional | Presencia IF, NOP incluido. |
| id_bundle/id_valid | IF_ID con core_clk | Bundle completo de ID PRE. |
| id_ex_valid | ID_EX con core_clk | Presencia EX PRE. |
| branch_flush | BRU combinacional efectiva | Evento de salto, no duración. |
| crypto_fault | CRYPTO combinacional válida | Excepción, separada de BRU. |
| perf_wb_valid | PIPELINE del wrapper | Ocupación WB completa, no retiro por GPR. |
| c_re/c_we/c_stall | Árbitro y L1D | Demanda arbitrada y espera interna. |
| ev_* | Puertos combinacionales L1D | Clasificación, tráfico y mantenimiento PRE. |

La producción no contiene accesos jerárquicos nuevos a registros de compañeros.
Los resultados solo se leen por testbench; no son todavía accesibles por software.
Una futura lcont podrá seleccionar estas señales mediante un contrato acordado,
sin modificar ahora el banco de registros ni inventar selectores ISA.

## L. Relojes y temporización

Todos los monitores consumen clk general. core_clk continúa gobernando únicamente
el núcleo, como antes. El productor presenta estado PRE estable; CPU y métricas
actualizan mediante NBA y el banco lee POST tras #1. La fase baja permite al
latch decidir avance. Un observador independiente de posedge core_clk comprueba
que hubo exactamente un pulso si el PRE core_en lo permitía.

El reloj manual del banco deja estabilizar cuatro parejas y no modela frecuencia
máxima ni síntesis física. Son ciclos observados, no tiempos de pared de Python.
Las marcas BRU se desplazan en avances; solo los huecos EX causales consumidos
suman penalización. Una ventana puede cortar uno de los dos huecos de un salto.

## M. Ventanas de medición

perf_measure_enable es input con default1 en top y mem_hierarchy. Propaga una
única ventana a los cuatro grupos. No controla avance, datos, solicitudes, flush
o relojes. Default mide desde salida de reset. La pausa conserva acumulados;
metadatos WB/marcas BRU y seguimiento K1-B siguen trabajando.

K1-A cuenta eventos por flanco habilitado. K1-B excluye el acceso que atraviesa
una pausa y termina habilitado. Ejemplo escenario2, modo 2, política1: K1-A cuenta
18 finales (4H/14M), K1-B: 17 completos y un excluido; servicio 123 y espera 106.
No se divide stall K1-A/global por completos K1-B mezclando cohortes.

## N. Reset y pausas

Reset común síncrono prioritario borra acumulados y metadatos, aun en pausa.
K1-B desconoce un inicio anterior al reset; reposo o terminación recuperan
frontera. La CPU tiene suficiente reposo de arranque para los casos completos.
No se promete cancelación atómica de stores en DMEM durante reset: el contrato
anterior permite efectos y aquí solo se conserva su pasividad.

Se prueban ventana completa, inicio tardío en ciclo 5, pausas 7..9 / 16..17,
reanudación y ventana vacía. La segunda pausa corta deliberadamente el primer
load frío de escenario2. Se verifican 123 stalls apagados, 36 finales apagados
y un final parcial habilitado en modo 2 a lo largo del banco; no son programas.
Se aplica reset con pipeline ocupado y con miss pendiente y medición cerrada.

## O. Modos de memoria

Modo 0: VLIW/etapas activos, sin instancias K1-A/B. Modo 1: iguales monitores con
stalls de su modelo real, sin caché. Modo 2: los cuatro grupos activos y conexión
LSU/CRIPTO por árbitro. Se ensayan modo 0, modo 1/WAIT4 y modo 2 con ROM_SYNC=1/0.
Los ceros de probes sin caché significan ausencia de esos monitores; el reporte
usa N/A para sus métricas, sin publicar hits/misses ficticios.

## P. Configuración EXCLUSIVA

No se modifican parámetros de L1D: WB, WA, EXCLUSIVA, LRU, WBUF4, MSHR2 y busv2.
El banco acredita los parámetros públicos reales de CPU; la sombra usa el mismo
productor. El control20 cambia solo la instancia consumidora en una copia externa
a NINE y falla por configuración, con compilación válida. EXCLUSIVA no acredita
exclusión global entre dos cachés reales: L2 continúa siendo un modelo sin tags.

## Q. MSHR y operaciones pendientes

Stores a0 y4 se aceptan como reserva/fusión antes del fill. H=64 residente
permite hit-under-miss; 0/2048/4096 compiten por dos vías y ejercitan espera de
capacidad, víctimas limpias/sucias y lectura desde MSHR. Los llenados posteriores
no prolongan el servicio de un store ya aceptado ni incrementan su demanda.
Las clases iniciales conocidas se contrastan independientemente (RM/WM/RH);
los loads de reemplazo restantes admiten hit/miss según productor y verifican datos.
No se reproduce LRU leyendo etiquetas o MSHR privados.

## R. Vaciado y mantenimiento

Se conserva literalmente el control original de flush y su ruta a DMEM. El banco
solicita después de capturar igual progreso, con NOP/saltos sin enlace y sin nuevos
efectos útiles. Espera flush_done de ambas instancias antes de comparar todos los
bytes. La CPU sigue activa. La ventana completa se abre durante mantenimiento
para probar pushes/tráfico sin nuevas demandas; las métricas tabuladas se
capturan antes de ese intervalo. Pausada/vacía no se reabren automáticamente.

K1-A puede acumular WBUF y tráfico durante mantenimiento. K1-B con c_re=c_we=0
no agrega accesos/servicio; si una futura demanda esperara un flush, su espera
sí pertenecería a esa demanda según contrato, sin inventar un servicio anterior.
No se divide costo de vaciado por accesos de ejecución ni se modifica #28.

## S. Pasividad de la integración

Cada configuración ejecuta CPU PERF_ENABLE=1 y SHADOW PERF_ENABLE=0 con idénticos
programas, memoria inicial, reloj/reset/ventana/flush y horizonte temporal exacto.
El cero elimina consumidores registrados al elaborar y mantiene salidas explícitas
cero; no selecciona otro núcleo ni cambia su control. En modo 2 también se propaga
a HIER. Nunca hay conexiones de retorno hacia cache_stall/core_en/flush_req,
l2_req/gnt/rvalid ni datos.

PRE y POST se contrastan PC, todos los puertos GPR,32 registros, datos leídos y
escritos A/B/DMEM, stalls, BRU/excepción/redirect/destino, ESTADO público y traps,
flush, demanda arbitrada y bus L2 completo (request/grant/response/dirty/idle).
Tras flush se comparan 16384 palabras con sombra y gold en cada captura.
No se permiten tolerancias temporales. VCD nuevo selecciona solo señales públicas.

La auditoría estática retira únicamente adiciones de observación/puertos y
comprueba igualdad de tokens de funcionamiento con el HEAD en top y jerarquía.
En el wrapper solo cambia la exposición de wb_valid. No es un certificado formal
de síntesis; complementa la ejecución real y los manifiestos de fuentes protegidas.

## T. Pruebas positivas

Cuatro configuraciones por cinco programas por tres ventanas =60 capturas.
No son60testbenches distintos. Cada configuración contiene dos CPU reales.

| Programa | Expectativas declaradas antes de observar salidas |
|---|---|
| NOP | Seis avances; ocupados6/5/4/3 y burbujas0/1/2/3 en ventana completa. |
| LSU/BRU | Palabra77+byte1=333, loads333/1, consumidor N+3=334; salto tomado anula jóvenes, condicional falso conserva flujo. |
| MSHR/víctimas | Stores7/7/7, byte parcial0x707, cargas correctas, líneas de un mismo conjunto y ráfaga de reemplazos. |
| CRIPTO/A+B | setpwd 7 / VCR 7/llaves 0; FSL produce par 0 y una instrucción; cuatro slots, load+camcon ve7 y store+camcon conserva28 por prioridad B. |
| Bucle/excepción | Tres decrementos, dos tomados; FSL no autorizado anula bundle de cuatro slots y jóvenes; centinela intacto, una excepción y manejador x30=99. |

Los programas distintos del NOP se capturan a80 avances, con bucle final activo;
no a iguales ciclos absolutos entre modos. Los snapshots de GPR/PC/estado/traps
se comparan a ese horizonte; cada pareja activa/inactiva usa además tiempo igual.
Se verifican reset inicial/durante actividad, burbujas, tiendas sin GPR, par cripto,
recuperaciones, congelamientos prolongados, consecutivos, puertos B y flush real.

## U. Pruebas negativas

Todas compilan0 sobre copias externas de bancos o consumidores autorizados.
Ninguna cambia cachés de compañeros, oráculos nominales o archivos originales.
Hay21 variantes: los20 controles pedidos y05b adicional. Diecinueve simulaciones
fallan con vvp1 en su aserción precisa;16 ejecuta RTL con vvp0 y su validador
independiente retorna1 por esquema.05 ejecuta con vvp0 y NO acredita detección.

| ID | Mutación | Propiedad / defecto evitado | Resultado real |
|---|---|---|---|
| 01 | Reloj core_clk en VLIW | Pierde flancos de espera; ciclos deben seguir clk. | compile0, vvp1; vliw_cycles |
| 02 | Avance constante en transporte | Un WB retenido no puede volver a finalizar durante stall. | compile0, vvp1; retirement_oracle |
| 03 | WB NOP convertido en burbuja | Presencia no depende de máscara útil. | compile0, vvp1; stage_occupied |
| 04 | Retiro inferido de wb_we | NOP/store sin GPR siguen completando. | compile0, vvp1; retirement_oracle |
| 05 | WB tomado de ex_wb_valid | Equivalente en este RTL; no demuestra sensibilidad. | compile0, vvp0; EQUIVALENTE EN RTL ACTUAL; no acredita detección |
| 05b | WB limitado al carril ALU útil | Adicional: omite NOP y bundles sin ALU. | compile0, vvp1; stage_occupied |
| 06 | Redirect como BRU y excepción desconectada | Culpable no debe completar ni generar BRU. | compile0, vvp1; validity_oracle |
| 07 | Par GPR cripto contado como otra instrucción | Dos salidas de FSL siguen siendo una operación. | compile0, vvp1; vliw_instructions |
| 08 | K1-B observa re/we A+B antes del árbitro | Las fases y el servicio deben corresponder al puerto único. | compile0, vvp1; k1b_classes |
| 09 | Fill sumado a lecturas K1-A | El mantenimiento no es otra demanda. | compile0, vvp1; k1a_events |
| 10 | Fill sumado a stores K1-A | Store MSHR ya terminó al aceptarse. | compile0, vvp1; k1a_events |
| 11 | Mantenimiento añadido a servicio de acceso previo | Servicio cerrado no crece durante flush sin demanda. | compile0, vvp1; k1b_totals |
| 12 | Ventana VLIW ignorada | Pausa debe conservar acumulados. | compile0, vvp1; vliw_cycles |
| 13 | Reset de etapas durante pausa | Pausar no borra la época. | compile0, vvp1; stage_cycles |
| 14 | Eventos K1-A retrasados a otro PRE | No consumir eventos POST como si fueran del flanco anterior. | compile0, vvp1; k1a_events |
| 15 | Ventana realimenta core_clk | Pasividad exige mismo avance exacto con PERF_ENABLE=0/1. | compile0, vvp1; clock_applied |
| 16 | Reporte renombra hits L1-D como hits L2 | Rechazo de esquema: solicitudes de línea no acreditan hits L2. | compile0, vvp0, consumidor1; REPORT_SCHEMA_ERROR |
| 17 | Validez IF omitida | La ocupación debe seguir IF real. | compile0, vvp1; stage_occupied |
| 18 | Stalls globales sumados por cuatro etapas | Un congelamiento global no se multiplica por cuatro. | compile0, vvp1; vliw_memory |
| 19 | Hits de lectura/escritura intercambiados | Clase exacta del productor debe llegar al contador correcto. | compile0, vvp1; k1a_events |
| 20 | Consumidor instancia L1-D con NINE | La configuración acreditada debe seguir EXCLUSIVA. | compile0, vvp1; exclusive_configuration |

Las04/07/11/18 alteran lecturas diagnósticas, no declaran fallos observados del
RTL correcto.16 altera el reporte del consumidor y prueba rechazo de una
atribución inválida, no hits L2 físicos.20 verifica configuración al arrancar:
no es una divergencia arquitectónica de datos ni un error de compilación.
El resto modifica conexiones de consumidores en copias externas. El fallo inicial
del ejecutor08 esperaba k1b_aux; el primer desacuerdo real es k1b_classes, porque
se corta primero el servicio de la fase B. Se corrigió la expectativa del
harness, conservando los logs y sin cambiar la mutación o el oráculo nominal.

## V. Oráculos independientes

Máscaras/kind/destinos proceden de tablas preparadas con el programa. El modelo
lleva PC y posiciones ID/EX/WB, aplica anulaciones por edad y programa los dos
huecos de recuperación por avance aceptado; no copia estado del monitor.
Los datos esperados son los 32 GPR y toda DMEM preparados desde ISA y stores conocidos.
La sombra sirve para pasividad, sin reemplazar esos oráculos.

K1-A contrasta conexión y acumulación de eventos públicos PRE; las clases
iniciales dirigidas se comprueban contra la operación/geometría. Es una referencia
del contrato público, no un predictor independiente de cada decisión privada.
K1-B usa fechas S/F, último flanco apagado y frontera conocida: servicio F-S+1,
espera F-S, exclusión si la ventana corta. Nunca lee acumuladores para decidir gold.

## W. Resultados de métricas

Ventana completa, antes del mantenimiento. La cuarta configuración, modo 2 con
ROM combinacional, reproduce exactamente la fila del modo 2 de cada programa.
Las otras ventanas se conservan completas en metricas-programas.csv/JSON.

| Programa | Modo | Ciclos | Bundles | Instr. | IPC | Stall global | BRU | IF/ID/EX/WB ocupados | H/M L1-D | Completos/servicio/espera K1-B |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| NOP | 0 | 6 | 3 | 0 | 0.000000000 | 0 | 0 | 6/5/4/3 | N/A | N/A |
| LSU/BRU | 0 | 80 | 51 | 23 | 0.287500000 | 0 | 27 | 80/65/51/51 | N/A | N/A |
| MSHR/víctimas | 0 | 80 | 53 | 38 | 0.475000000 | 0 | 25 | 80/66/53/53 | N/A | N/A |
| CRIPTO/A+B | 0 | 80 | 53 | 27 | 0.337500000 | 0 | 25 | 80/66/53/53 | N/A | N/A |
| Bucle/excepción | 0 | 80 | 39 | 24 | 0.300000000 | 0 | 36 | 80/60/40/39 | N/A | N/A |
| NOP | 1 | 6 | 3 | 0 | 0.000000000 | 0 | 0 | 6/5/4/3 | N/A | N/A |
| LSU/BRU | 1 | 96 | 51 | 23 | 0.239583333 | 16 | 27 | 96/81/67/67 | N/A | N/A |
| MSHR/víctimas | 1 | 152 | 53 | 38 | 0.250000000 | 72 | 25 | 152/138/125/125 | N/A | N/A |
| CRIPTO/A+B | 1 | 96 | 53 | 27 | 0.281250000 | 16 | 25 | 96/82/69/69 | N/A | N/A |
| Bucle/excepción | 1 | 80 | 39 | 24 | 0.300000000 | 0 | 36 | 80/60/40/39 | N/A | N/A |
| NOP | 2 | 6 | 3 | 0 | 0.000000000 | 0 | 0 | 6/5/4/3 | 0/0 | 0/0/0 |
| LSU/BRU | 2 | 80 | 51 | 23 | 0.287500000 | 0 | 27 | 80/65/51/51 | 0/4 | 4/4/0 |
| MSHR/víctimas | 2 | 194 | 53 | 38 | 0.195876289 | 114 | 25 | 194/180/167/167 | 4/14 | 18/132/114 |
| CRIPTO/A+B | 2 | 86 | 53 | 27 | 0.313953488 | 6 | 25 | 86/72/59/59 | 6/3 | 9/11/2 |
| Bucle/excepción | 2 | 80 | 39 | 24 | 0.300000000 | 0 | 36 | 80/60/40/39 | 0/0 | 0/0/0 |

Las muestras incluyen los NOP/saltos finales hasta el horizonte declarado: no
son conteos de operaciones estáticas ni benchmarks del #29. Los contadores de
ocupación son residencia, no retiros; no se suma ocupación con stalls para obtener
ciclos. BRU puede quedar impar al capturar en medio de una recuperación.

## X. Resultados arquitectónicos

En cada una de las60 capturas se verifican los 32 GPR contra gold y contra sombra;
se contrastan también snapshots entre0/1/2 y las ROM. Cada vaciado recorre todas
las16384 palabras por pareja frente a sombra y gold. No se usan hashes como
sustituto de los 65536 bytes. No hubo divergencias arquitectónicas nominales.
N+3, cuatro etapas, penalización de salto, Feistel4, excepción y prioridad B
conservan su funcionamiento observado; las regresiones mantienen su cobertura.

## Y. Comparación con instrumentación deshabilitada

PERF_ENABLE es bit de elaboración default1, al final de parámetros top; HIER lo
hereda en modo 2 y también tiene default1 para bancos anteriores. PERF_ENABLE=0
no genera consumidores ni registros de métricas. Las observaciones explícitas
son cero y todos los productores son exactamente los mismos. La prueba verifica
la duración exacta y las secuencias públicas por fase, no únicamente datos finales.
El control15 introduce realimentación desde la ventana al reloj y falla al
primer pulso esperado no aplicado: demuestra sensibilidad a pérdida de pasividad.

## Z. Regresión inicial

Las trece órdenes se ejecutaron antes de implementar, en copia externa del HEAD.
Se verificó make list real; no se inventaron targets. Tabla antes/después:

| Comando | rc antes/después | s antes/después | Resultado |
|---|---:|---:|---|
| `make sim` | 0/0 | 60.947/73.08 | 55 → 56 PASS; cero FAIL/NO-COMPILA/SIN-CHEQUEO |
| `make test-assembler` | 0/0 | 0.616/0.516 | 44 métodos (21+13+4+6) |
| `make test-programs` | 0/0 | 4.474/4.475 | 14 métodos |
| `make test-memory-modes` | 0/0 | 23.818/23.917 | 16 métodos; 19 parejas nominales |
| `make archivo` | 0/0 | 0.665/0.715 | 7 verificaciones; 386 bytes idénticos |
| `make tb_mem_hierarchy` | 0/0 | 2.119/2.82 | 43 verificaciones |
| `make tb_perf_counters` | 0/0 | 0.032/0.032 | 292 verificaciones |
| `make tb_perf_pipeline_monitor` | 0/0 | 0.114/0.114 | 9981 verificaciones |
| `make tb_perf_vliw_monitor_d4b1` | 0/0 | 1.718/1.818 | 42836 verificaciones |
| `make tb_perf_stage_counters` | 0/0 | 4.374/5.076 | 430652 verificaciones |
| `make tb_perf_cache_l1d_k1a` | 0/0 | 0.766/0.817 | 247770 verificaciones |
| `make tb_perf_cache_l1d_k1b` | 0/0 | 2.621/3.021 | 979004 verificaciones |
| `python3 -m unittest discover -s tests -p test_flush_tools.py -v` | 0/0 | 11.289/15.05 | 10 métodos; cero skips |

## AA. Regresión posterior

Las trece órdenes pasaron otra vez, código0. El único nuevo PASS de sim es este
banco. Normal y VCD aislados:3654774 verificaciones/60 capturas, salida0, tiempos
8.282 s / 8.583 s. Las cantidades son aserciones, métodos y bancos separados; no se
suman como si fueran programas distintos. Icarus12.0, Python y flags oficiales;
no se agregaron supresiones de advertencias. Los logs de compilación se conservan.
La revisión final de comentarios conserva todos los tokens funcionales probados.

El primer ensayo compiló0 y falló por coverage_windows: la ventana elegida no
atravesaba un miss. Se corrigió únicamente el estímulo y se añadió la pausa 16..17.
El segundo ensayo pasó, pero make se invocó accidentalmente desde el repositorio
original. Se verificó que sus seis artefactos bajo build/tb_perf_integracion_top
no existían en el manifiesto inicial y se trasladaron a evidencia externa. No se
tocaron archivos iniciales; las ejecuciones finales/regresiones son externas.
La incidencia y sus rutas están registradas, sin clean/reset/restore de Git.

## AB. Compatibilidad con CE1108

Se conservan ISA/ensamblador y las herramientas #9/#28. La suite #28 verifica su
fixture directamente en0/1/2. Los dos flujos completos se ejecutaron con ambas
versiones de Arquitectura y el mismo snapshot externo de Compiladores
08c8701c7bc6e58461f54b69a90a1a6fe85d0145. Ambos make retornan2 antes y después:
test-ce1108-source falla al preparar y ejecuta0 métodos; test-compiladores-funciones
informa3 métodos, 2 fallos y 5 errores de subcasos. Buscan ubicaciones anteriores de
src/generacion_basica.c, Analisis_Sintactico y Analisis_Semantico. BLOQUEADO
preexistente; no se adapta ese repositorio ni se presenta como PASS.

## AC. L2 y memoria pendientes

La jerarquía continúa con l2_model y DMEM. No se integra L2 real, controlador,
CDC o eviction buffer. Sus pruebas independientes anteriores siguen pasando.
No se publican hits/misses L2 ni AMAT jerárquico definitivo. Para integrar esos
niveles habrá que revisar persistencia de flush_done, latencia y poblaciones.

## AD. Instrucciones D18 pendientes

No se implementan medir, lcont ni vaciarc. perf_measure_enable es entrada de
observación, no una instrucción. Los resultados son señales internas explícitas
para los bancos; una futura selección/lectura software requiere diseño y pruebas
separadas con Fabricio y el responsable de ISA. No se modifica REGFILE ni LSU.

## AE. Limitaciones

El modelo presupone avance global y atribuye toda falta de avance a memoria,
incluido arbitraje. No representa ejecución parcial, otras causas de freeze o
transacciones fuera de este contrato. Las entradas deben ser conocidas PRE.
Los cálculos son módulo 2^64 y medias/desigualdades requieren evitar overflow.
No se ejecutó síntesis física ni validación de frecuencia/CDC de la futura RAM.

El bitmap de eventos observado es 0x7ff5f:17 de 19 categorías tuvieron actividad.
raw_forward es siempre 0 con EXCLUSIVA; wb_full_stall no se activó en estos
programas con este modelo L2. Ambos están cableados y auditados uno a uno;
las regresiones K1-A/K1-B conservan sus escenarios independientes de buffer lleno.
No se inventan eventos para atribuirles cobertura de integración inexistente.

El negativo05 es equivalente y por ello la sensibilidad exigida es PARCIAL.
No se alteran pipeline/decoders para forzar su fallo. Permanece pendiente que
Javier/Fabricio acepten esta limitación o definan un contrato futuro distinguible.
El procesador continúa activo durante flush y tras las capturas; no se certifica
retorno semántico de main ni se exponen secretos de bóveda como parte de las métricas.

## AF. Auditoría de comentarios R2–R2.2

Cada instancia nueva documenta productor, reloj, PRE/NBA, avance, reset, ventana,
resultados y ausencia de realimentación. WB, diecinueve eventos, puerto arbitrado
y cohortes se explican junto a su conexión. Se conserva documentación anterior
válida; no se añaden separadores decorativos nuevos.

El banco comenta encabezado, módulos, señales, funciones codificadoras, tareas,
modelo independiente, programas, expectativas/defectos, bucles y watchdog.
La auditoría externa inventaría cada función/tarea/proceso y controla sus entradas,
salidas, propiedad, errores y límites. Los parches/guía de negativos documentan
mutación, propiedad violada, diagnóstico y por qué la compilación/ejecución es
pertinente; no se sustituye detección con fallos de sintaxis.

## AG. Integridad y hashes

Los manifiestos inicial/final prueban el alcance de cinco archivos: tres existentes
modificados y dos nuevos. Los otros424 archivos iniciales conservan SHA256,
tamaño y permisos. No se modifican Makefile, herramientas, pruebas anteriores o
cachés de compañeros. No quedan binarios nuevos en el repositorio original.
Índice, HEAD, ramas y referencias remotas permanecen iguales; las referencias
internas automáticas de la aplicación se distinguen de las ramas del proyecto.
Compiladores solo se leyó para snapshot/manifiestos; cualquier cambio concurrente
se registra sin restaurar ni atribuirlo a esta intervención.

## AH. Evidencias externas

Workspace temporal: /tmp/perf-integracion-zcf5v5sa.
Entrega persistente nueva: /home/javier/Documentos/evidencias-arquitectura-integracion-metricas.
Incluye referencias/manifiestos, diff completo, fuentes exactas, comandos/códigos/
tiempos, antes/después, nominal/VCD,60 filas de métricas,21 variantes negativas,
logs de incidencias, auditoría y paquete completo. No sobrescribe entregas previas.
Los CSV nuevos pertenecen a cada directorio externo; el VCD selecciona métricas
y control públicos, nunca vuelca toda la bóveda.

Reproducción desde el repositorio, sin artefactos en su árbol original:

```bash
perf_dir="$(mktemp -d /tmp/perf-repetir.XXXXXX)"
mkdir "$perf_dir/codigo"
git archive HEAD | tar -x -C "$perf_dir/codigo"
for perf_file in rtl-p2/top.sv rtl-p2/mem_hierarchy.sv rtl-p2/perf_vliw_monitor.sv tb-p2/tb_perf_integracion_top.sv docs/perf-integracion-top.md; do
    cp --parents "$perf_file" "$perf_dir/codigo"
done
(cd "$perf_dir/codigo" && PYTHONDONTWRITEBYTECODE=1 make tb_perf_integracion_top)
```

Para VCD usar un directorio de ejecución diferente con vvp -n y el binario
compilado, +VCD. Las regresiones usan los trece comandos de Z. Las mutaciones
usan el script y parches externos;05 debe pasar por equivalencia,16 debe fallar
en el consumidor de reporte, las otras deben fallar con su tag específico.

## AI. Coordinación con Fabricio

top/mem_hierarchy requieren su revisión antes de integrar a develop: nombres de
instancias y señales observables, nueva entrada default1, parámetro default1,
semántica PRE de core_en, reset de stores pendientes, validezWB y flush con
núcleo activo. Debe revisar también la equivalencia actual del control05 y el
contrato de una futura lcont. No se presupone estabilidad de interfaces futuras
ni se altera su rama. No se enviaron mensajes ni se creó PR o merge.

## AJ. Estado Git final

Misma rama y HEAD de B, sin staging, índice intacto, sin conflictos y diff --check
sin errores. Solo los cinco archivos de C. No se modifican develop u otras ramas,
ni se publican cambios. El usuario revisará y realizará el commit/publicación.
No se continúa con D18, #29, #30 u otra integración.

## AK. Conclusión

Los cuatro grupos quedan conectados pasivamente al procesador real y la L1-D,
con WB completo compartido y ventanas compatibles con los módulos existentes.
Las pruebas nominales/arquitectónicas/regresiones pasan; la pasividad se demuestra
con instrumentación elaborada y eliminada, al mismo tiempo exacto.

El cierre formal permanece PARCIAL por la mutación equivalente05; CE1108 completo
sigue BLOQUEADO por rutas anteriores. Estos límites no se ocultan ni se remedian
cambiando componentes protegidos. Fabricio debe revisar las conexiones antes
de una integración autorizada; no se declara integrada la L2 ni implementado D18.

## AL. Propuesta de commit

Título: `feat: integrar métricas VLIW, etapas y L1-D en top`

Descripción propuesta, sin realizar commit:

```text
Conectar los monitores existentes VLIW y de etapas con clk general y avance
real del procesador. Exponer la validez WB transportada sin duplicar estado.

Observar los diecinueve eventos públicos L1-D y el servicio del puerto
arbitrado con K1-A/K1-B. Agregar habilitación común default activa y
PERF_ENABLE para retirar instrumentación al elaborar, sin realimentación.

Validar cuatro configuraciones, cinco programas y tres ventanas con
60 capturas y 3654774 comprobaciones. Contrastar instrumentación activa/
inactiva, 32 GPR y 65536 bytes, pipeline, demandas y bus L2 por fase.

Conservar las regresiones: 56 PASS RTL, ensamblador, programas, #9, #28
y monitores previos. Documentar 19 negativos RTL y un rechazo de reporte,
el control WB equivalente no detectable y los bloqueos CE1108 preexistentes.

Requiere revisión de Fabricio antes de integrar a develop.
Relacionado con #7, #8 y #26. Sin L2 real, instrucciones D18 ni benchmarks.
```
