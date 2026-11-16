# Issue #26 — K1-B: servicio observado de L1-D

## A. Estado inicial de Git

Repositorio `Proyecto2_Arquitectura1`, árbol e índice limpios, sin conflictos ni
archivos K1-B anteriores. Se ejecutaron `pwd`, `git status --short --branch`,
`git branch --show-current`, `git rev-parse HEAD`, `git log -7 --oneline`,
`git diff --stat`, `git diff --cached --stat` y
`git ls-files --others --exclude-standard` antes de crear archivos.

El manifiesto inicial contiene **401 archivos**, incluidos los ignorados que
existían, excluyendo `.git`. Las compilaciones y evidencias se generan en copias
externas. Las referencias remotas son las locales existentes: no se ejecutó fetch.

## B. Rama y HEAD verificados

Rama autorizada: `feat/26b-latencia-amat-l1d`.
HEAD y `develop`: `8765a678566c01e869da976d4b6741aa04cd45d7`, merge del PR #55.
K1-A, K1-A2 y el issue #8 están presentes en esa base.
No se cambia de rama ni se modifica el historial o el índice.

## C. Alcance autorizado

**IMPLEMENTADO:** `rtl-p2/perf_cache_l1d_latency.sv`, monitor independiente;
`tb-p2/tb_perf_cache_l1d_k1b.sv`, pruebas independientes y con L1-D real;
y este documento. La finalidad es medir cohortes completas de demandas para
calcular medias de servicio fuera del hardware. No cierra el issue #26.

## D. Archivos protegidos

Todos los archivos anteriores se conservan: procesador, pipeline, ISA, caché,
políticas, L2 provisional, memorias, monitores K1-A/VLIW/etapas, pruebas anteriores,
Makefile, README y documentación histórica. No se escribe en Compiladores.
No se integra el monitor en `top`, ni se implementan `vaciarc`, `medir`, `lcont`,
L2 real, controlador de memoria o K1-C.

## E. Análisis de K1-A y K1-A2

K1-A conserva diecinueve acumuladores de eventos y cinco totales derivados.
Su ventana selecciona eventos por flanco: puede contar una finalización cuyo
inicio quedó fuera de ventana, o stalls de un acceso que termina fuera de ella.
Esa población no sirve directamente para una media de servicio completo.

K1-B aporta cantidades, espera y servicio **por cohorte de operaciones completas**.
No reemplaza los eventos de tráfico, víctimas, MSHR, RAW o buffer lleno de K1-A.
Sus totales solo coinciden con los de K1-A cuando las poblaciones coinciden.

Se revisaron los archivos completos indicados por la solicitud: productor,
definiciones, modelo L2, cuatro bancos relacionados, monitores previos, Makefile
y documentación de caché, interfaces, decisiones, guía y rendimiento. Los
registros históricos de esos documentos no sustituyen las pruebas actuales.

## F. Contrato real de L1-D

| Señal pública | Interpretación PRE, antes de `posedge clk` |
|---|---|
| `re`, `we` | Demanda del puerto único; mutuamente excluyentes. |
| `stall` | La demanda no puede terminar en este flanco. |
| `ev_rd_hit`, `ev_rd_miss`, `ev_wr_hit`, `ev_wr_miss` | Clasificación única de la demanda que termina. |
| `ev_mshr_alloc`, `ev_mshr_merge`, `ev_mshr_load` | Reserva, mezcla o carga desde MSHR; no otra demanda. |
| `ev_fill`, `ev_wb_push`, víctimas | Actividad interna o mantenimiento; no finalización adicional. |
| `l2_req && l2_gnt` | Aceptación de transacción de línea, distinta del servicio de CPU. |
| `l2_rvalid` | Respuesta de lectura; puede corresponder a un MSHR de fondo. |

El RTL define `acc = !reset && (re || we)`, `acc_eval = acc && !flush_active`,
`stall = acc && !complete`. Los cuatro eventos son combinacionales y están
calificados por `complete`. `acc_busy/acc_was_miss` preservan la clasificación
inicial evaluada por el productor. K1-B utiliza exclusivamente sus puertos;
no consulta estos registros privados.

La petición se conserva durante stall. No hay identificadores ni cancelación
pública de demanda: un cambio de dirección/datos durante una espera no puede
detectarse con esta interfaz mínima y viola el contrato del productor.
El monitor detecta cambio de tipo o desaparición de una petición retenida,
pero no inventa una correlación de transacciones.

## G. Política exclusiva

Todas las cachés nuevas del banco, incluidas las sombras, fijan explícitamente:

```systemverilog
.WRITE_POLICY(WP_WRITE_BACK), .INCL_POLICY(INCL_EXCLUSIVE),
.ALLOC_POLICY(AP_WRITE_ALLOC), .REPL_POLICY(RP_LRU),
.RAW_POLICY(RAW_FORWARD), .WB_DEPTH(4), .N_MSHR(NM), .L2_BUS_V2(1)
```

La configuración principal usa `NM=2`; se contrastan también 1 y 4.
Los tipos se corresponden con los parámetros reales: políticas de escritura y
asignación de un bit, inclusión/reemplazo de dos bits, capacidades enteras y bus bit.
EXCLUSIVA obliga a esperar RAW aunque se declare `RAW_FORWARD`.
No se cambia EXCLUSIVA por NINE ni se modifica el soporte NINE existente.

**VALIDADO CON MODELO:** víctimas limpias/sucias, propagación de `rdirty`, espera
RAW, MSHR y persistencia tras vaciado en la infraestructura utilizada.
**PENDIENTE:** demostrar `L1-D ∩ L2 = ∅` entre dos cachés reales y medir la L2 real.
El respondedor dirigido y `l2_model` no tienen etiquetas/reemplazo de una L2 real.

## H. Definición de acceso

Una demanda es una operación que L1-D recibe por su puerto único, no un bundle,
una escritura GPR o una transacción de línea. Tras completar, un nivel `re/we`
que sigue activo puede representar otra operación en el flanco siguiente.
No se requiere un flanco ocioso entre accesos consecutivos.

Cuando el árbitro serializa los puertos A/B, cada fase que entrega a L1-D es
una demanda distinta. El servicio aquí medido no incluye automáticamente toda
la espera global del bundle por arbitraje. Esa integración sigue **PROPUESTA**.

## I. Inicio y finalización

Inicio: primer PRE de demanda después de una frontera conocida, o primer PRE
observado de una demanda cuyo inicio no conocemos (seguimiento no elegible).
Mientras espera, `pending` conserva identidad, tipo y edad sin emitir finalizaciones.

Final: exactamente un evento de demanda, coherente con `re/we`, con `stall=0`.
No se infiere una terminación a partir de una simple caída de stall ni del grant.
Un evento sostenido en dos flancos completos cuenta dos operaciones.

`protocol_errors` registra una incoherencia por flanco: tipos simultáneos,
clasificación múltiple/ausente, evento durante stall/sin demanda/de otro tipo,
o pérdida/cambio de tipo del acceso pendiente. Se descarta la observación hasta
recuperar frontera; el productor no se corrige ni se controla desde el monitor.

## J. Convención temporal

Todo se mide en flancos de `clk` general, también mientras `core_clk` está detenido.
Las entradas son conocidas y estables antes del flanco. La caché y el monitor
consumen el mismo PRE; sus registros se actualizan mediante NBA.

Si S es el primer flanco y F el de terminación:

```text
espera = F - S
servicio = F - S + 1 = espera + 1
```

El banco dirige el reloj manualmente, deja estabilizar PRE y observa registros
POST con `#1`, sin `#0`. Después de NBA un fill puede convertirse en hit visible;
ese nuevo evento combinacional no es el que se consumió en el flanco anterior.

## K. Definición de latencia

Servicio visible en el puerto de demanda, en ciclos por acceso completo.
Hit inmediato: servicio 1, espera 0. Miss bloqueante dirigido: ocho flancos de
espera y uno de terminación, servicio 9. No incluye reposo entre demandas ni
trabajo posterior del MSHR o buffer. Si una demanda espera mantenimiento,
sus flancos de stall sí forman parte de su servicio; mantenimiento sin demanda
no crea accesos ficticios.

## L. Definición de stalls

`wait_by_class` acumula las esperas de las mismas operaciones incluidas en
`completed_by_class`. No registra por separado las esperas parciales o sin fin;
estas permanecen observables en `pending_wait_cycles` mientras siga pendiente.

K1-A conserva la medición global por flanco. Sus causas FULL/RAW/WBUF no
particionan necesariamente toda espera: por ejemplo, un fill de MSHR bloquea
un store por el puerto único sin activar MSHR-full. No se suman causas para
reconstruir la espera total ni se atribuye todo stall a un miss de L2.

## M. Tratamiento de hits

La clase de terminación procede del productor, no de etiquetas reconstruidas.
Los hits del guion duran un flanco. Un hit puede coincidir con un fill de otro
acceso; solo suma una demanda y su propio servicio. Una espera estructural podría
hacer mayor que uno el servicio de un hit en otra configuración.

## N. Tratamiento de misses

Un miss que llena la línea conserva la clase inicial al terminar. La carga que
espera un MSHR parcialmente escrito puede completar cuando luego acierta en L1-D;
sigue contabilizándose como miss por el evento original. No se fija una penalidad
universal de ocho: hay casos de 1, 5, 9, 13 y 19 flancos por construcción del banco.

## O. Stores con MSHR

En `NM>=2`, un store miss puede terminar al reservar o fusionar su MSHR, con
servicio 1 y espera 0. No se espera su fill para finalizar servicio ni se promete
persistencia. Con `NM=1` el mismo tipo de store sigue el camino bloqueante.

K1-B no añade acumuladores redundantes de alloc/merge/load; K1-A ya los conserva.
La interfaz mínima de K1-B clasifica lectura/store e hit/miss, sin particionar
sumas de latencia por origen MSHR. Para hacerlo en una población mezclada se
necesitaría consumir y acordar esos eventos adicionales; no se infiere desde
los tiempos ni desde peticiones L2.

## P. Hit-under-miss

Se prueban load/store residentes mientras un store tiene MSHR pendiente, load
servido por palabra completa de MSHR y load que espera una palabra parcial.
También se completa un hit de H en el mismo flanco que el fill independiente de X.
Los fills o reservas no se suman nuevamente al denominador de demandas.

## Q. Write buffer y espera RAW

El guion A/B/C/D de un conjunto de dos vías expulsa A sucia y B limpia;
E entra con `rdirty=1` y luego sale como víctima sucia sin un store de CPU sobre E.
Grants demorados comprueban retención de dirección, tipo, máscara, datos y dirty.

Con exclusiva, volver a pedir una víctima en WBUF espera su drenado y después
su lectura, sin forwarding. Otro guion acumula cuatro víctimas limpias, llena
WBUF4 y demora el grant: la nueva carga espera espacio y respuesta. Ambos accesos
completos aportan servicio 13, espera 12 en sus respectivos guiones.

## R. Ventanas de medición

El seguimiento continúa con `measure_enable=0`. La elegibilidad se determina
al inicio y se pierde irrevocablemente si algún flanco del acceso está apagado.
Reanudar antes de terminar no recupera el prefijo ni compensa los ciclos omitidos.

| Situación | Resultado |
|---|---|
| Acceso completo siempre habilitado y con frontera conocida | Se incorpora a su clase. |
| Inicio apagado, final habilitado | Se excluye; suma `excluded_accesses`. |
| Pausa en medio, luego final habilitado | Se excluye aunque se haya reanudado. |
| Final apagado, incluyendo acceso enteramente apagado | No cambia estadísticas; se cierra seguimiento. |
| Pausa en reposo | Conserva estadísticas y permite reconocer el próximo inicio. |
| Acceso aún esperando al capturar | `pending=1`; no entra todavía en ninguna media. |

`excluded_accesses` cuenta solo finalizaciones habilitadas rechazadas; no todos
los accesos apagados ni todas las ventanas interrumpidas. No es un estimador de
transacciones perdidas. `pending_eligible` y edad son estado de seguimiento, no
acumuladores pausados. `protocol_errors` es diagnóstico de toda la época, también
en pausa: una infracción no debe ocultarse cerrando la ventana.

## S. Reset y épocas

Reset síncrono prioritario borra estadísticas, diagnóstico y seguimiento, incluso
con evento y ventana activa o con ventana apagada. No consume ese final.

Un reset aislado del monitor puede ocurrir mientras L1-D sigue esperando. No
hay ID ni `busy` público que permita reconstruir el inicio anterior. Por ello,
`boundary_known=0` tras reset. Un PRE ocioso o el consumo de una terminación
recupera frontera para el acceso siguiente. Hasta entonces se excluye
conservadoramente el acceso observado, incluso si parece un hit inmediato.

Para medir desde el primer acceso de una época, proporcionar un flanco ocioso
posterior al reset. El reposo que coincide con reset todavía pertenece a reset.
Una edad posterior a reset aislado cuenta solo el sufijo observado; no convierte
el acceso en completo. No se cancela el productor desde este módulo.

Se prueban reset con hit/evento, durante stall/miss con lectura L2 pendiente,
con medición apagada, después de completar y con MSHR ocupado. Reset común de
productor/monitor descarta las reservas del productor; no se exige persistencia
de stores descartados por ese reset. Reset solo del monitor permite continuar
llenado y vaciado sin inventar demanda nueva.

## T. Diseño del módulo

Estado mínimo para la demanda retenida: presencia, tipo, elegibilidad, frontera
y edad unsigned de 64 bits. Un decodificador combinacional reconoce las cuatro
clases exactas; un proceso secuencial prioriza reset, error, reposo, final y espera.

Los acumuladores son tres vectores de cuatro clases, más accesos inmediatos,
excluidos y diagnóstico. Los totales se derivan para no duplicar poblaciones.
No se añaden mínimo/máximo: el alcance prioriza sumas verificables para medias.
No hay división, punto flotante, instancia de caché, archivos, retardos ni acceso
jerárquico en el módulo de producción. No hay ninguna salida conectada al productor.

## U. Interfaz y señales

| Grupo | Puertos |
|---|---|
| Tiempo/control | `clk`, `reset`, `measure_enable` |
| Demanda | `re`, `we`, `stall` |
| Clase pública | Los cuatro `ev_rd/wr_hit/miss` |
| Estadísticas por clase | `completed_by_class`, `service_by_class`, `wait_by_class` |
| Totales derivados | `completed_accesses/reads/writes/hits/misses`, `service_cycles`, `wait_cycles` |
| Auxiliares | `no_wait_accesses`, `excluded_accesses`, `protocol_errors` |
| Seguimiento | `pending`, `pending_eligible`, `pending_wait_cycles` |

Índices empaquetados: 0=RH, 1=RM, 2=WH, 3=WM. Las estadísticas son unsigned de
64 bits. No hacen falta entradas de L2 para delimitar servicio al núcleo: añadir
grant/response induciría correlaciones inválidas con tráfico de fondo.

## V. Contadores e invariantes

Para cada clase y para el total:

```text
completos = lecturas + stores = hits + misses
servicio = espera + completos
```

Las identidades son módulo 2^64. Sin overflow, servicio es al menos la cantidad
de completos. Las sumas por clase concuerdan con totales. Un acceso pertenece a
una única clase y los parciales no entran a ninguna de esas sumas.

Se prueban acarreo a 33 bits y wrap en las doce estadísticas por clase, inmediatos,
excluidos, diagnóstico y edad. Solo el consumidor sintético recibe precargas de
prueba, nunca privados de caché, sin `force`. La presencia pendiente distingue
un acceso con espera incluso si su edad da la vuelta; no se lo reclasifica como
inmediato. El RTL no satura ni publica bandera de overflow: el usuario debe evitar
épocas que desborden para interpretar medias como números ordinarios.

## W. Fórmulas de promedios y AMAT

Para la cohorte completa, sin desbordamiento:

```text
media_servicio = real(service_cycles) / real(completed_accesses)
media_espera = real(wait_cycles) / real(completed_accesses)
media_clase[k] = real(service_by_class[k]) / real(completed_by_class[k])
media_lecturas = (servicio_RH + servicio_RM) / (cantidad_RH + cantidad_RM)
media_stores = (servicio_WH + servicio_WM) / (cantidad_WH + cantidad_WM)
```

Lo mismo aplica a hits y misses. Denominador cero produce **N/D**, nunca cero ni
división inválida. Todas las medias son ciclos/acceso de la población indicada,
sin pausas, accesos incompletos ni actividad de fondo añadida. Las divisiones se
hacen fuera del RTL, con aritmética real y tolerancia del banco `1e-12`.

La identidad `media_servicio = 1 + media_espera` vale para esta misma cohorte y
sin overflow. No autoriza dividir stalls globales de K1-A por cualquier número
de accesos. La diferencia entre medias de miss y hit es descriptiva de esas
poblaciones; no identifica por sí sola una penalización causal de L2.

**PENDIENTE/BLOQUEADO por niveles no integrados:** AMAT jerárquico definitivo,
hits/misses L2, latencia de memoria principal, persistencia y ancho de banda.
Una fórmula teórica `T_hit + tasa_miss * penalidad` requiere datos y supuestos
adicionales. No se equipara un miss de L1-D con un miss L2 ni se multiplica todo
store miss por ocho ciclos.

## X. Pruebas positivas

Dos niveles y una integración adicional:

1. Unidad con guiones analíticos, operaciones consecutivas, ventanas, reset,
   espera de 257 flancos, protocolo inválido, acarreo y overflow.
2. L1-D real y sombra, guiones dirigidos con capacidades MSHR 2 principal, 1 y 4.
3. Dos cadenas completas L1-D + `l2_model` + `memory`, cada DMEM de 65536 bytes.

Los valores esperados de las clases proceden del guion y geometría A/B/C, no de
los eventos observados. Los tiempos se declaran explícitamente o se obtienen de
fechas del guion. La referencia no reproduce la máquina de estados incremental
del monitor ni lee etiquetas/reemplazo/colas privadas. Cada PRE contrasta eventos
del productor antes de usarlos como evidencia; los acumulados se comparan POST.

Resultados finales y comandos se registran en AD y en el informe externo.

## Y. Pruebas negativas

Dieciséis controles, en copias externas del consumidor/banco o conexiones
diagnósticas. El productor y las expectativas permanecen nominales.

| ID | Defecto introducido | Comprobación que debe detectarlo |
|---|---|---|
| 1 / 2 | Espera omitida / duplicada | Edad declarada por el guion. |
| 3 / 4 | Hit como miss / miss como hit | Cantidad de clase exacta. |
| 5 / 6 | Final duplicado / omitido | Cantidad por operación. |
| 7 | Acceso retenido contado nuevamente | Cantidad sin terminación. |
| 8 | Fill de fondo como demanda | Diagnóstico y cohorte sin acceso. |
| 9 | Ocho esperas ficticias para store MSHR | Servicio WM de un flanco. |
| 10 | Parcial presentado como completo | Exclusión y cantidad de clase. |
| 11 | Terminación apagada incluida | Cohorte en pausa. |
| 12 | Grant confundido con terminación durante stall | Diagnóstico de final prematuro. |
| 13 | Reset perdido con medición apagada | Época borrada. |
| 14 | Ventana ignorada | Cohorte y exclusiones. |
| 15 | Evento retrasado un flanco | Primera finalización esperada. |
| 16 | Una demanda hit y miss simultáneamente | Clase única y diagnóstico. |

Cada control debe compilar con código 0 y terminar `vvp` con código 1 por
`K1B_FIRST_DIVERGENCE`. Timeout, error de compilación o fallo ajeno no acreditan
sensibilidad. Las primeras divergencias reales y códigos están en `negativos.json`.

## Z. Casos límite

Los guiones cubren accesos de cero/uno/múltiples stalls, nivel de evento sostenido,
petición sostenida antes de grant, respuesta tardía, retención prolongada,
fill simultáneo con hit, pausas completas/parciales, reset aislado/común,
clasificación múltiple, final ausente y cambio/desaparición de petición pendiente.
No se acepta X/Z en resultados válidos; se ensaya además un evento desconocido
con demanda presente. No se promete recuperación general de entradas asíncronas
o desconocidas: entradas conocidas y síncronas son parte del contrato.

Aleatoriedad reproducible: unidad semilla `0x026b1107`, 128 demandas, 847 flancos,
clases físicas RH/RM/WH/WM = 29/38/36/25. Completos elegibles 34, excluidos al
terminar habilitados 36; los otros 58 terminan apagados. Cohorte: servicio 196,
espera 162; clases completas 5/14/11/4. No son 128 programas distintos.

Modelo semilla `0x026b1207`: 128 demandas aleatorias residentes, después de ocho
loads fríos, más store MSHR y hit bajo miss. La clasificación conocida evita
usar un segundo controlador de caché como oráculo. Todos los bucles de espera
son acotados; watchdog global de 5000000 ns termina con fallo explícito.

## AA. Integración controlada con L1-D

Los guiones reales usan el respondedor manual por puertos: memoria de 64 KiB,
aceptación y respuesta separadas y dirty entrante explícito. Nunca leen privados
de L1-D. Un grant de escritura actualiza memoria inferior; gold se actualiza
por el store de CPU independientemente del productor.

La integración adicional usa el `l2_model.sv` real vigente, que lee/escribe una
palabra por flanco y entrega una línea a los ocho ciclos. No se sustituye por una
L2 de producción ficticia. Su `idle` se espera junto con `flush_done`, porque una
escritura aceptada puede seguir llegando a DMEM.

| Guion | Completos | Servicio | Espera |
|---|---:|---:|---:|
| Siete loads miss y un store hit, por capacidad | 8 | 64 | 56 |
| Ráfaga MSHR2 llena y tercer store | 3 | 7 | 4 |
| Ráfaga MSHR4 llena y quinto store | 5 | 9 | 4 |
| Store bloqueante MSHR1 | 1 | 9 | 8 |
| H, stores/merge de X, load MSHR, hits, load parcial | 7 | 19 | 12 |
| Grant demorado y respuesta tardía | 1 | 19 | 18 |
| Hit simultáneo con fill independiente | 3 | 11 | 8 |
| Cadena `l2_model`, ventana completa | 138 | 202 | 64 |

La última cohorte tiene RH/RM/WH/WM = 54/8/75/1 y media
`202/138 = 1.463768115942` ciclos/acceso. El dataset sintético conocido tiene
RH1 + WH1 + RM4 + WM1 + RM2, servicio9/5 = 1.8; medias de lecturas y misses
7/3, de stores y hits 1. Esas medias se comprueban antes de escenarios adicionales.

## AB. Equivalencia con instancia sombra

Por flanco PRE y POST se comparan datos, stall, flush, solicitud L2, tipo,
dirección, máscara, línea, dirty y diecinueve eventos públicos. La cadena con
`l2_model` compara además grant, respuesta, línea/dirty de respuesta, idle y
cada escritura DMEM (dirección, datos y bytes).

Después de flush se comparan **todas las 16384 palabras** de cada memoria
instrumentada y sombra contra gold. Igualdad sombra no reemplaza la expectativa
independiente de datos, clasificación y tiempos; ambas comprobaciones se usan.
No hay caminos desde las salidas de los contadores hacia las cachés o el núcleo.

## AC. Regresión anterior

Antes de crear código se ejecutaron las referencias en la copia externa `antes`
del HEAD autorizado. Los diez comandos de Arquitectura terminaron con código 0.
`make sim` obtuvo 39 PASS, 0 FAIL, 0 NO-COMPILA, 0 SIN-CHEQUEO.

Se ejecutaron también `test-ce1108-source` y `test-compiladores-funciones` con una
copia externa del HEAD de Compiladores `7683bf80e91fdd66bb573d4334f986b6feebe7b5`,
sin incorporar sus modificaciones locales. Ambos `make` terminaron con **código2**:
las herramientas de Arquitectura buscan rutas antiguas `src/` y
`Analisis_Sintactico/` que ese HEAD ya reorganizó. El primero falla en `setUpClass`
(0 métodos ejecutados); el segundo informa 3 métodos, 2 fallos y 5 errores,
varios correspondientes a subcasos. Se registran como limitación preexistente,
sin adaptar fuentes, rutas o herramientas protegidas.

## AD. Regresión posterior

| Comando | Antes: código / segundos | Después: código / segundos | Resultado |
|---|---:|---:|---|
| `make -B tb_perf_cache_l1d_k1b` | No existía | 0 / 3.276 | 979004 verificaciones |
| `make tb_perf_cache_l1d_k1a` | 0 / 1.219 | 0 / 1.117 | 247770 verificaciones |
| `make tb_l1d_cache` | 0 / 13.847 | 0 / 12.093 | 81 verificaciones |
| `make tb_l1d_writeback` | 0 / 20.363 | 0 / 17.554 | 68 verificaciones |
| `make tb_l1d_mshr` | 0 / 15.049 | 0 / 12.591 | 109 verificaciones |
| `make tb_mem_hierarchy` | 0 / 3.121 | 0 / 3.123 | 43 verificaciones |
| `make tb_perf_stage_counters` | 0 / 8.634 | 0 / 7.732 | 430652 verificaciones |
| `make sim` | 0 / 84.279 | 0 / 72.087 | 39 → 40 PASS; 0 FAIL/NO-COMPILA/SIN-CHEQUEO |
| `make test-assembler` | 0 / 0.666 | 0 / 0.516 | 44 métodos (21+13+4+6) |
| `make test-programs` | 0 / 6.182 | 0 / 4.524 | 14 métodos |
| `make archivo` | 0 / 1.016 | 0 / 0.716 | 7 verificaciones RTL, 386 bytes idénticos; cifrado/descifrado 989 ciclos |

Las dos pruebas CE1108 se repitieron con el mismo snapshot externo: código2 en
ambas antes y después, por las mismas rutas antiguas ausentes. No hay fallos nuevos
observados de Arquitectura. No se presentan esas pruebas CE1108 como PASS.

La ejecución nueva con `PLUSARGS=+VCD` termina con código0, **979004 verificaciones**
y VCD de **333931 bytes**. Las dieciséis mutaciones compilan con código0 y producen
código1 por la primera aserción prevista. Los logs de compilación de los bancos
no contienen warnings ni errores; no se suprimen diagnósticos nuevos.

El número de verificaciones cuenta aserciones por flanco/estado y por palabra
de memoria; no equivale a escenarios o programas independientes. Para evitar
reutilizar binarios por mtimes conservados en copias, el banco final se recompiló
explícitamente con `make -B`; `make sim` recompila todos sus bancos.


## AE. Compatibilidad con Icarus

Se usa `iverilog -g2012` y `vvp -n`, vectores empaquetados y construcciones
compatibles con Icarus12. Compilación aislada del monitor con `-Wall -tnull`:
código0, sin diagnósticos. El banco se descubre mediante los comodines del
Makefile vigente: no se modifica ese archivo.

No se ejecuta síntesis física ni se promete una frecuencia máxima. La inspección
RTL confirma un solo proceso secuencial y combinacional sin realimentación al
productor. Las precargas de prueba quedan exclusivamente en el banco sintético.

## AF. Advertencias y limitaciones

La regresión CE1108 está **BLOQUEADA** por la incompatibilidad preexistente de
rutas con su HEAD reorganizado. K1-B no cambia esas dependencias. Las pruebas de
ISA/ensamblador y programas de Arquitectura sí se ejecutan normalmente.

El primer ensayo del banco nuevo detectó una expectativa incorrecta: después de
reset aislado se comparaba la edad contra el inicio anterior al reset. Se corrigió
la referencia para comprobar solo el sufijo observado; la operación sigue excluida.
El log inicial se conserva. No se alteró el productor para acomodar expectativas.

No hay validación de L2 real, memoria definitiva, CDC, exclusividad global,
mediciones por origen MSHR ni integración dentro de `top`. Tampoco se reconstruye
el inicio perdido tras reset, se detectan cambios de dirección con esta interfaz
mínima o se interpretan medias después de overflow. Estos límites son parte del
contrato; no se ocultan con señales privadas o terminaciones inventadas.

## AG. Auditoría de comentarios R2–R2.2

Se revisan individualmente señales, procesos, tareas, escenarios, oráculos,
controles negativos y decisiones de temporización. Los encabezados explican
contexto, interfaces, WB/exclusiva/MSHR, dependencias y límites. Las tareas indican
qué preparan, qué referencia modifican, si generan reloj, dónde muestrean,
qué esperan y qué fallo detectan. Se conservan comentarios en español próximos
al código, sin separadores decorativos ni frases mecánicas.

El inventario y las observaciones por elemento quedan en
`auditoria-comentarios.md` de la evidencia. No se editan comentarios anteriores.

## AH. Integridad y hashes

Se conserva manifiesto SHA-256 inicial y final, índice y referencias de Git.
Solo se permiten los tres archivos nuevos de C. Se comprueban también UTF-8,
fin de línea, blancos finales, diff de no rastreados y ausencia de binarios nuevos.
Los archivos nuevos permanecen sin staging; `git diff` vacío por sí solo no
prueba ausencia de cambios no rastreados.

## AI. Evidencias externas y reproducción

Directorio de esta ejecución: `/tmp/ce4301-k1b-b1phnbx_/`.
Contiene manifiestos, comandos/códigos/tiempos JSON, logs antes/después, CSV PRE,
VCD, las dieciséis mutaciones con sus parches y fallos, auditoría y diff completo.
La ubicación de evidencia no es dependencia del RTL ni del banco.

Para reproducir sin generar artefactos dentro del repositorio original, copiar
las fuentes a un directorio externo nuevo y ejecutar allí:

```bash
make tb_perf_cache_l1d_k1b
make tb_perf_cache_l1d_k1b PLUSARGS=+VCD
make tb_perf_cache_l1d_k1a tb_l1d_cache tb_l1d_writeback tb_l1d_mshr
make tb_mem_hierarchy tb_perf_stage_counters
make sim
make test-assembler
make test-programs
make archivo
```

Los controles8/12 se ejecutan desde directorios externos distintos, con
`vvp -n /ruta/externa/build/tb_perf_cache_l1d_k1b/sim.vvp +MUTATION=8` o `12`.
El resto usa las copias/parches y comandos de compilación del script externo
`k1b_negativos.py`. Código1 y la aserción prevista acreditan detección; no se
presentan esas ejecuciones como PASS nominal de `make sim`.

## AJ. Dependencias de L2 real e issue #30

**PROPUESTO:** integrar el monitor por puertos públicos cuando se acuerden reset,
ventana y acceso de demanda con Fabricio. No se modifican esas interfaces aquí.
**PENDIENTE:** instrumentación L2 y controlador con aceptación/respuesta/memoria
reales; separar AMAT jerárquico, persistencia y tráfico de mantenimiento.

Para futuras comparaciones del issue #30 hay que fijar población, estado inicial,
programa, política, MSHR, protocolo y fronteras de ventanas; conservar corrección
arquitectónica y vaciado antes de comparar DMEM. Las sumas K1-B sirven para
comparar servicio al núcleo bajo esas condiciones, sin atribuir automáticamente
un cambio a L2 o a una penalidad fija por miss.

## AK. Estado final de Git

Se conserva la rama autorizada y HEAD de B. No se hace staging, commit, fetch,
pull, push, PR, merge, rebase, cherry-pick, reset, restore ni clean.
La comprobación final confirma los 401 archivos anteriores idénticos por SHA-256,
el índice, las ramas y referencias remotas sin cambios. Las referencias internas
de captura de la aplicación cambian durante la sesión; no son commits de las
ramas del proyecto. Solo hay tres archivos nuevos sin seguimiento. No aparecen binarios, logs ni evidencias dentro del repositorio.

## AL. Conclusión y propuesta de commit

K1-B implementa servicio/espera por cohorte completa y distingue aceptación de
CPU de la actividad de fondo. Sus pruebas no certifican AMAT definitivo.
La validación CE1108 permanece parcial por la incompatibilidad de rutas descrita.
No se comienza K1-C ni se cierra el issue #26.

Summary propuesto para GitHub Desktop:

`feat: medir latencias de servicio de L1-D por acceso completo`

Description propuesta:

```text
Agregar un monitor pasivo de latencias por lectura/store e hit/miss de L1-D.
Contar servicio y espera de cohortes completas con clk general, reset prioritario
y seguimiento independiente de las ventanas de acumulación.
Excluir accesos parciales o con inicio desconocido sin reconstruir historia.

Validar guiones sintéticos, WB/EXCLUSIVA/WA/LRU con WBUF4 y MSHR1/2/4,
y cadenas independientes con l2_model y DMEM completa tras vaciado.
Conservar productor, políticas, monitores anteriores y archivos de compañeros.

Documentar medias externas, límites de MSHR/AMAT, sensibilidad de los oráculos
y la incompatibilidad preexistente de rutas en las pruebas CE1108.

Relacionado con #26. K1-C, L2 real e integración en top pendientes.
```

Pruebas del cambio: 979004 verificaciones normales y con VCD; 16 controles
negativos detectados; 40 PASS de simulación y regresiones anteriores conservadas.
El commit y la publicación corresponden a Javier, después de su revisión.
