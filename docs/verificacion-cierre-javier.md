# Verificación del cierre de métricas y rendimiento — Javier

## Estado y alcance

Estado actualizado al 20 de noviembre de 2026: los dos commits del aporte de
Javier están integrados en `develop` mediante el
[PR #70](https://github.com/fabrimena/Proyecto2_Arquitectura1/pull/70)
(merge `5e6e45f7baacff4a70ad44ec2e3a2c61c0defe26`). Los PR #68, #71 y #72
también están integrados. La revisión documental individual se prepara en
`docs/javier-cierre-final-simulaciones`, desde
`192050e802cbe45296d8d23cb0f8216f3e6313e2`; este SHA identifica su base y
**no la entrega final**. Los observadores temporales completan
#26 para L1, lecturas L2 y RAM; la API productiva DCE acredita dos contrastes
reales de #31. #38 continúa parcial por revisión/presentación/entrega colectiva.
Los resultados anteriores se conservan como antecedentes y el cierre temporal
al final de este documento distingue las ejecuciones nuevas de las históricas.

### Antecedente del cierre integrado en 4a16239

Rama `feat/javier-cierre-metricas-rendimiento-p2`, base/HEAD conservado
`e461b70b1195ea402b5352e43ab1f357309a8ffe` de origin/develop. Se creó con árbol e
índice limpios tras fetch autorizado e inspección de los cinco commits posteriores
a128ce789: solo cinco filas nuevas de docs/simulation.md. main y develop no se
modificaron directamente. En aquella revisión no hubo staging, commits,
publicación, PR ni integración de historial; la integración posterior fue por PR #70.

Herramientas verificadas: Icarus/VVP12.0, Python3.12.3, GNU Make4.3 y GCC13.3.0.
Las ejecuciones se elaboran en copias externas. La primera carpeta /tmp se perdió
por apagado; se reconstruyeron la base desde Git y la entrega desde los cambios,
y se repitieron las pruebas conservando evidencia persistente fuera del proyecto.
No se atribuye integridad de archivos ignorados a un manifiesto inicial perdido.

## Cobertura de responsabilidades

| Trabajo | Estado del alcance de Javier | Evidencia |
|---|---|---|
| #7 VLIW | COMPLETO | 292 verificaciones base; transporte, anulación, BRU/stalls y pasividad sobre top |
| #8 etapas | COMPLETO | Contadores existentes, regresión y60 capturas de top |
| #9 regresión de modos | COMPLETO | 16 métodos, memoria real, 32 GPR y65536 bytes |
| #26 caché/memoria | COMPLETO en métricas observables definidas | AMAT L1, lecturas L2 y media RAM por cohortes; posted sin respuesta y tasas RAM N/A explícitos |
| D18 | COMPLETO | Clasificación37 operaciones, RSV estrictos, lcont0–12, medir/vaciarc y N+3 |
| #28 flush | COMPLETO | Diez métodos y persistencia real, sin relajar quiescencia |
| #29 benchmarks | COMPLETO | Tres fuentes/oráculos intactos,872 avances, L2 real,18KiB y capacidad |
| #30 configuraciones | COMPLETO en la matriz probada | Nueve configuraciones×tres fuentes×dos rondas; referencia bloqueante real |
| #31 optimizaciones BAL | COMPLETO en dos contrastes reales | Tradicional/IDE-DCE para puntajes y funciones; cada variante contra M2/RTL0/RTL2; no niveles -O ficticios |
| #36 análisis | COMPLETO | Capítulo de cierre con poblaciones, resultados, interpretación y límites |
| #37 README | COMPLETO | Arquitectura P2, comandos, reproducción y mapa documental |
| #38 aporte/defensa | PARCIAL: preparación técnica lista | Aporte integrado por PR #70; pendientes revisión colectiva, presentación, integración develop→main, TEC Digital y SHA final |

La tabla acredita alcance técnico; el estado remoto de los issues se verifica
por separado durante el cierre autorizado. El equipo conserva la responsabilidad
sobre cachés, CDC/síntesis y entregables colectivos. La implementación está
integrada por PR #70; el cierre documental requiere su propio PR hacia `develop`.
#38 permanece abierto hasta completar la entrega colectiva.

## Implementación e interfaces

perf_cache_l2 acumula diez indicadores públicos con clk general, reset prioritario,
measure_enable y wrap64 natural. No tiene control hacia el productor. El vector
publicado por mem_hierarchy distingue RH/RM/WH/WM/fill/víctima/flushWB/inval/read_req/
write_offer. Write_offer mide ciclos de oferta, no escrituras físicas aceptadas.
Se reutiliza perf_memory sin modificarlo, con cinco señales públicas MC; sus seis
acumulados exponen lecturas, escrituras, busy, medidos, timeouts y errores.
PERF_ENABLE0 elimina observadores; MODEL1 o modos0/1 publican cero L2/RAM.

Top solo propaga políticas/parámetros y conecta observaciones. lcont9/10 suma
clasificaciones L2,11 aceptaciones RAM y12 busy;0–8/reservados/mitades se conservan.
El clasificador reutiliza decoder_cache_isa para reconocer D18 con RSV válidos;
la comparación exacta de validez evita X de un decoder todavía no evaluado.
No se modifican decoders, ISA original, relojes, pipeline ni algoritmos protegidos.

run_program conserva el orden de sus argumentos anteriores, añade configuración,
precarga, timeout de pared y armado diferido de medición; acredita parámetros por
-P y su propagación real. execution.json conserva schema1 y añade observación2,
procedencia y vectores. La ventana se captura antes de flush. El armado diferido
solo evita medir arranque antes del primer medir0; no cambia avance o datos.

El comparador #30 valida estado y traza con los oráculos independientes #29,
repite determinísticamente y verifica una dimensión por par. #31 compila mediante
balc real y compara cada variante con M2 completo y ambos modos RTL; no adopta el
modo0 como oráculo automáticamente correcto. BALB con datos iniciales no vacíos
se rechaza explícitamente hasta ampliar ese contrato de entrada.

## Resultados comprobados

Configuración de referencia: REAL, ROM síncrona, exclusiva, WB/WA, LRU/PLRU,
MSHR2, WBUF4, EB4, MEM_DIV4. Cada benchmark tiene868 bundles estáticos,872 avances,
32 stores/64 loads y checksum1056. Dos rondas conservan todos los GPR/DMEM/traza.

| Programa | Ciclos | Stall | Instr. completadas | L1 H/M | L2 H/M | RAM R/W | Busy | Flush |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Secuencial | 872 | 0 | 386 | 64/32 | 0/4 | 4/0 | 212 | 653 |
| Aleatorio | 2606 | 1734 | 386 | 64/32 | 0/32 | 32/0 | 1696 | 1936 |
| Stride | 10260 | 9388 | 386 | 0/96 | 0/190 | 96/83 | 9443 | 732 |

IPC=386/ciclos. Ocupación de etapas, clases K1-B, MSHR y denominadores se conservan
en CSV/JSON, sin multiplicar el mismo stall global por cuatro etapas. El campo
ciclos incluye preparación/checksum/NOP/recuperación, no solo accesos de memoria.
Al corte puede quedar una transferencia RAM aceptada todavía en curso: sus
ciclos busy medidos no tienen por qué igualar Tmem×aceptaciones de la ventana.

| Configuración | Secuencial | Aleatorio | Stride |
|---|---:|---:|---:|
| Referencia exclusiva | 872 | 2606 | 10260 |
| NINE, WB/WA | 872 | 2606 | 8452 |
| NINE, WT/NWA | 971 | 2778 | 8240 |
| L1 FIFO | 872 | 2606 | 10260 |
| L1 Random | 872 | 2606 | 10260 |
| L2 Random | 872 | 2606 | 9980 |
| MSHR1 | 1128 | 2920 | 10907 |
| MSHR4 | 872 | 2476 | 10260 |
| MEM_DIV2 | 872 | 2186 | 7768 |

La tabla completa contiene54 filas y48 contrastes dirigidos, dos rondas. La
referencia bloqueante real proviene de5c6990683204cc2bd6747c47931808f3085ed462;
solo l2_cache.sv difiere en los hashes RTL. Sus ciclos872/2606/10236 se contrastan
con872/2606/10260 actuales en seis comparaciones, sin usar MODEL como sustituto.
No hay una ventaja universal: el stride de esta población favorece NINE y el
pipeline actual cuesta24 ciclos más que la referencia bloqueante en ese caso.

Capacidad18KiB:576 líneas por pasada, primera pasada caliente no medida; ventana
D18 de la segunda, sin arranque inicial. Horizonte común8085 avances del programa
completo. Dos rondas: exclusiva8639 ciclos medidos/4608 stalls,576 lecturas L2 con
hit y576 escrituras L2 con miss,0 lecturas RAM; NINE22975 ciclos/18944 stalls,
320 hits/256 misses de lectura L2 y256 lecturas RAM (busy13568). Toda DMEM permanece
idéntica a la precarga y se verifica checksum/GPR independientes. Los dos tienen
576 demandas L1 con miss. El miss L2 de una víctima completa no implica leer RAM.

Archivo18k.bin:18432 bytes, SHA256
c98e65ae5a58f7925bdc75bd3325ff60603df3c7113f5852bcccc2784fd920c3, intacto.
Roundtrip real:83018 ciclos cifrar y83018 descifrar, espera de vaciado32264 por
fase,7 comprobaciones y recuperación byte a byte. Es correctitud/persistencia;
la diferencia de capacidad se demuestra con el experimento separado anterior.
Además, los2304 bloques cifrados coinciden byte a byte con Feistel4 de software,
sin usar el descifrado RTL como única referencia del cifrado.

CE1108 tradicional: factorial120 a3403 avances, whale21 a247 y puntajes37 a2748.
M2/RTL0/RTL2 coinciden en32 GPR, estado público y65536 bytes. En estos casos los
stores MSHR y las cargas residentes no generan stalls globales. #31 no publica
speedup entre niveles inexistentes. Los cortes son observaciones B5, no HALT ni
certificación de identidad semántica del retorno de main.

## Pruebas y criterios

Dieciocho órdenes antes/después, todas con código0:

| Comando | Base | Entrega |
|---|---|---|
| make sim | 65 PASS | 69 PASS |
| make test-assembler | 58 métodos | 58 métodos |
| make test-programs | 14 métodos | 14 métodos |
| make test-memory-modes | 16 métodos | 16 métodos |
| make test-memory-benchmarks | 35 métodos | 35 métodos |
| make tb_cache_isa | 81 comprobaciones | 81 comprobaciones |
| make tb_perf_integracion_top | 8029914 /60 capturas | Igual |
| make tb_perf_cache_l1d_k1a | 247770 | Igual |
| make tb_perf_cache_l1d_k1b | 979004 | Igual |
| make tb_mem_hierarchy | 47 | Igual |
| make tb_l2_cache | 65 | Igual |
| make tb_l2_cache_nine | 73 | Igual |
| make tb_l2_cache_integracion | 29 | Igual |
| make tb_l2_cache_flush | 72 | Igual |
| make tb_l2_pipeline | 8 | Igual |
| make tb_mem_controller | PASS en DIV2/4/5 | Igual |
| make tb_perf_memory | PASS | Igual |
| unittest test_flush_tools.py | 10 métodos | 10 métodos |

Sin FAIL/NO-COMPILA/SIN-CHEQUEO ni omisiones en las regresiones finales. Las
cantidades de comprobaciones, bancos, métodos y ejecuciones no son intercambiables.
Los133 métodos Python de la tabla no se suman a los69 bancos como si fueran casos
del mismo tipo. Adicionales:20 métodos del comparador #30,12 de #31,8 del adaptador
fuente y3 de funciones; todos sin skips. Los bancos nuevos incluyen32608 aserciones
L2, cuatro jerarquías activas/inactivas, cuatro ejecuciones D18 con calendario
independiente y578 flancos de MC con2 aceptaciones/2 timeouts/1 error.
El clasificador ampliado pasa6368 verificaciones y conserva las34 operaciones.

Los controles negativos mutan copias externas: configuración/política/proveedor,
GPR, DMEM, contadores, ventana, ausencia de flush, binario obsoleto, programa,
reporte duplicado, tiempos y entrada. Cada uno exige su diagnóstico específico;
no se presenta un timeout, compilación fallida o infraestructura ausente como
prueba de sensibilidad. PERF_ENABLE0 y ventana vacía conservan arquitectura con
métricas cero y cocientes no definidos. La mutación histórica WB→ex_wb_valid
sigue siendo equivalente en el RTL actual y no se atribuye detección ficticia.

Incidencias propias resueltas: el primer ensayo de clasificación D18 propagó X
desde un decoder aún no evaluado; la comparación exacta de validez lo corrigió.
Una ampliación de comentarios colocó un docstring entre @classmethod y su def;
la primera ejecución final de comparadores terminó con SyntaxError. Se conservó
ese log, se corrigió la posición y se repitieron los32 métodos: OK, código0.
Los errores de preparación iniciales perdieron sus logs con /tmp; no se cuentan
como regresiones anteriores ni como controles negativos acreditados.

## Integridad y límites

Se cotejan archivos protegidos contra Git HEAD y se inventarían cambios propios.
Se preservan rtl/, cachés/arreglos/reemplazo/WBUF/árbitro/EB/MC/checker, programas,
expectativas y archivo18k. Top/jerarquía cambian parámetros, cables y observadores.
Compiladores solo se lee; se compara un manifiesto nuevo tomado al reanudar.
No se garantiza reconstruir su estado ignorado anterior al apagado. Los dos
bytecodes Python generados al principio se apartan a evidencia; no son fuente.

Diagnóstico histórico, anterior a verificar IDE-DCE: CE1108 necesita al menos dos niveles productivos distintos,
con ABI/cortes/observables comparables, para cerrar #31. Se conserva compatibilidad
tradicional sin implementar otro optimizador. CDC para síntesis y restricciones
físicas requieren trabajo colectivo; las pruebas son simulación funcional.
Ese diagnóstico precede a la publicación e integración autorizadas por PR #70.
El nuevo cierre documental y la entrega colectiva conservan su revisión del equipo.
No hay fallos nuevos conocidos sin resolver en el alcance probado.

Pendiente histórico de #26, resuelto por el cierre temporal posterior: el requisito incluye AMAT de cada nivel, no solo
contadores de tráfico. K1-B permite el AMAT observado L1 de demandas completas;
las capturas L2 no conservan tiempos de aceptación/respuesta por transacción.
Se registra por ello PARCIAL. La revisión y las fórmulas están en
[performance-analysis.md](performance-analysis.md#revisión-histórica-del-requisito-amat-del-issue-26-base-4a16239).
La inclusión exclusiva y los stores non-blocking no impiden medir latencias:
impiden sustituir sus poblaciones por las del modelo serial sin acreditarlas.

## Entrega formal pendiente del issue #38

El enunciado oficial, sección10 (página19), y el issue #38 exigen el enlace del
repositorio y el hash del último commit al entregar. Repositorio:
<https://github.com/fabrimena/Proyecto2_Arquitectura1>.
El SHA final está **PENDIENTE** hasta confirmar la integración definitiva
`develop` → `main` y verificar el commit efectivamente entregado. La publicación
e integración del aporte individual por PR #70 no sustituyen ese paso colectivo.
Los SHA e461b70, 4a16239 y 192050e identifican bases de trabajo y
**no son por ese motivo el SHA final de entrega**.

Después de ese paso se prepara el archivo para TEC Digital con únicamente la URL
y el SHA final verificado. Este informe y el guion no sustituyen ese archivo ni
acreditan la entrega formal. El cierre individual no autoriza fusionar
`develop` → `main` ni entregar en TEC Digital en nombre del equipo.

## Reproducción y evidencias

README ofrece órdenes verificadas. Usar copia externa de las fuentes y destinos
nuevos; los comparadores producen CSV/JSON/Markdown y metadatos por ejecución.
Los manifiestos de origen, logs, hashes, diff completo, auditoría por archivo,
informe y propuestas de commit/PR se entregan fuera del repositorio. La carpeta
persistente de esta revisión se identifica en el informe final de la sesión.

Para defender contratos y evitar interpretaciones incorrectas, consultar
[guion-defensa-javier.md](guion-defensa-javier.md). El detalle de eventos/ratios y
los registros históricos se conservan en [performance-analysis.md](performance-analysis.md).

### Cierre documental del 20 de noviembre de 2026

Se agregan 21 filas a la tabla principal de `simulation.md`: 19 bancos `tb_perf_*`
y dos unitarios D18, con fuentes/oráculos revisados y sin duplicados. Se conservan
las filas previas y los comandos L2/RAM. Se actualizan las referencias a PR #68/#70,
sin reescribir mediciones históricas ni sustituir el SHA final de entrega.

La única corrección de código adelanta las declaraciones de `flush_done` y
`shadow_flush_done` en `tb_perf_stage_counters.sv`, eliminando dos warnings de
red implícita. El log y los seis diarios de etapas coinciden byte a byte antes
y después. Se conserva el aviso de sensibilidad a las 13 palabras de `counters`
en `cache_isa_unit.sv`; no modifica el resultado ni justifica alterar el mux.

Validación nueva: `make sim` termina 0 con 72 PASS, sin FAIL, NO-COMPILA ni
SIN-CHEQUEO. Pasan 199 métodos Python: ensamblador, programas, modos, benchmarks,
flush, configuraciones, AMAT y contratos independientes CE1108. No se repiten las
12 pruebas de integración productiva CE1108; siguen respaldadas por la campaña
histórica de 211 métodos y sus hashes verificados. No se atribuyen esas 12
ejecuciones a este cierre documental ni se regeneran las 54 capturas anteriores.

## Campaña temporal definitiva sobre 4a16239

Registro histórico del 16 de noviembre: rama `feat/javier-cierre-final-amat-ce1108`,
entonces sin staging ni commit nuevo. Posteriormente se publicó e integró por
PR #70, como se indica en el estado vigente. El
cierre anterior está integrado en4a16239; esta campaña no altera esos resultados
ni el historial. Evidencia externa persistente:
`/home/javier/Documentos/evidencias-arquitectura-amat-final-4a16239-20261116`.

La línea base ejecutó21 comandos, todos con código0:69 testbenches PASS y178
métodos Python. La validación final efectiva ejecuta26 comandos, todos con
código0:72 testbenches PASS,0 FAIL,0 NO-COMPILA,0 SIN-CHEQUEO y211 métodos Python,
sin skips. Se mantienen los13 tests anteriores del analizador y los32 de
comparadores; se agregan25 métodos temporales y8 del DCE productivo.
Los tres bancos nuevos comprueban191 casos L2,33 checks RAM dirigidos más los
controladores reales DIV2/4 y10797 flancos del diario de integración en cuatro
configuraciones. Los checks por flanco agrupan varias propiedades; no se suman
como si cada campo o ejecución repetida fuera otro testbench.

Durante la campaña final se agotó `/home`: seis comandos terminaron120/2 por
infraestructura, incluidos fallos al escribir logs con tee. No se contaron
como controles negativos ni como éxitos funcionales. Tras conservar comprimidos
los build terminados y verificar sus hashes, se repitieron los seis en destinos
y binarios nuevos: todos código0. Los resultados originales, recuperaciones y
su correspondencia permanecen en los reportes externos; no se ocultan fallos.

La relectura histórica encontró capturas sin `measurement_control`; el primer
análisis terminó1. Se admitió explícitamente la ausencia como null, sin inventar
armado de ventana, y una prueba nueva cubre ese caso. La relectura de las54
capturas termina0 y conserva sus latencias L2/RAM como null. La campaña actual
contiene54 capturas nuevas y4 de capacidad; dos rondas adicionales0/2 conservan
32 GPR,65536 bytes, imagen,96 accesos lógicos y checksum1056.

La implementación usa dos observadores nuevos y conexiones pasivas en jerarquía.
No se modifica top, MC, caches, buffers, ROM, ISA ni etapas. Reset y `medir`
comparten la ventana actual; `lcont`0–12 y `vaciarc` conservan su contrato.
La instrumentación temporal y los mapas/cortes CE1108 se describen en el
[cierre temporal](performance-analysis.md#cierre-temporal-por-transacción-y-dce-productivo-26-31-y-38).

#26 queda completo para medias observables L1/read-L2/RAM, con stores posted
sin respuesta y tasas de caché RAM no aplicables explícitos. #31 queda completo
en dos contrastes productivos tradicional/IDE-DCE (puntajes y funciones), más
las tres referencias tradicionales verificadas contra M2/RTL0/RTL2. La copia
CE1108 usada se identifica por rama, commit, módulos y ejecutable; no se declara
una familia -O ni una versión oficial final del compilador.
#38 sigue parcial: revisión del equipo, presentación y entrega formal con el
SHA del último commit efectivamente publicado/integrado permanecen pendientes.
La plantilla formal externa conserva **PENDIENTE DE INTEGRACIÓN FINAL**.

El contraste bloqueante también se reelaboró en una copia experimental externa:
solo `l2_cache.sv` se toma del commit5c699068; los demás RTL y observadores son
idénticos al snapshot actual. Doce ejecuciones0/2 dan seis contrastes estrictos
con `blocking_contrasts`, sin relajar su comprobación de inventario/hashes ni
modificar el comparador #30. Sus872/2606/10236 ciclos se conservan frente a
872/2606/10260 actuales. La procedencia distingue la copia mixta del árbol puro
del commit histórico; no se cambia ninguna caché de la rama de trabajo.
