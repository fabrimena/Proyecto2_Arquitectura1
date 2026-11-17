# Verificación del cierre de métricas y rendimiento — Javier

## Estado y alcance

Rama `feat/javier-cierre-metricas-rendimiento-p2`, base/HEAD conservado
`e461b70b1195ea402b5352e43ab1f357309a8ffe` de origin/develop. Se creó con árbol e
índice limpios tras fetch autorizado e inspección de los cinco commits posteriores
a128ce789: solo cinco filas nuevas de docs/simulation.md. main y develop no se
modifican. No hay staging, commits, publicación, PR ni integración de historial.

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
| #26 caché/memoria | PARCIAL | Accesos/tasas L1/L2 y AMAT observado L1 verificados; falta AMAT L2 por cohorte temporal |
| D18 | COMPLETO | Clasificación37 operaciones, RSV estrictos, lcont0–12, medir/vaciarc y N+3 |
| #28 flush | COMPLETO | Diez métodos y persistencia real, sin relajar quiescencia |
| #29 benchmarks | COMPLETO | Tres fuentes/oráculos intactos,872 avances, L2 real,18KiB y capacidad |
| #30 configuraciones | COMPLETO en la matriz probada | Nueve configuraciones×tres fuentes×dos rondas; referencia bloqueante real |
| #31 optimizaciones BAL | PARCIAL | Comparador probado; tradicional de tres BAL validado frente a M2/RTL; faltan dos niveles productivos |
| #36 análisis | COMPLETO | Capítulo de cierre con poblaciones, resultados, interpretación y límites |
| #37 README | COMPLETO | Arquitectura P2, comandos, reproducción y mapa documental |
| #38 aporte/defensa | PARCIAL: preparación técnica lista | Informe/guion/evidencias listos; falta publicación/integración autorizada y registrar el SHA final de entrega |

No se cierran issues de GitHub ni se confunde este estado con una publicación.
El equipo conserva la responsabilidad sobre cachés, CDC/síntesis y entregables
colectivos. Falta revisión colectiva del diff antes de integrar a develop.

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

Pendiente externo: CE1108 necesita al menos dos niveles productivos distintos,
con ABI/cortes/observables comparables, para cerrar #31. Se conserva compatibilidad
tradicional sin implementar otro optimizador. CDC para síntesis y restricciones
físicas requieren trabajo colectivo; las pruebas son simulación funcional.
Revisión/commit/publicación/PR/merge dependen de la decisión del usuario/equipo.
No hay fallos nuevos conocidos sin resolver en el alcance probado.

Pendiente interno de #26: el requisito incluye AMAT de cada nivel, no solo
contadores de tráfico. K1-B permite el AMAT observado L1 de demandas completas;
las capturas L2 no conservan tiempos de aceptación/respuesta por transacción.
Se registra por ello PARCIAL. La revisión y las fórmulas están en
[performance-analysis.md](performance-analysis.md#revisión-del-requisito-amat-del-issue-26).
La inclusión exclusiva y los stores non-blocking no impiden medir latencias:
impiden sustituir sus poblaciones por las del modelo serial sin acreditarlas.

## Entrega formal pendiente del issue #38

El enunciado oficial, sección10 (página19), y el issue #38 exigen el enlace del
repositorio y el hash del último commit al entregar. Repositorio:
<https://github.com/fabrimena/Proyecto2_Arquitectura1>.
El SHA final está **PENDIENTE** hasta publicar e integrar los cambios con las
autorizaciones correspondientes y verificar el commit efectivamente entregado.
El HEAD e461b70 de esta auditoría es la base y **no es el SHA final de entrega**.

Después de ese paso se prepara el archivo para TEC Digital con únicamente la URL
y el SHA final verificado. Este informe y el guion no sustituyen ese archivo ni
acreditan una publicación que todavía no se realizó. No se hace ninguna operación
remota ni integración para completar este pendiente durante esta revisión.

## Reproducción y evidencias

README ofrece órdenes verificadas. Usar copia externa de las fuentes y destinos
nuevos; los comparadores producen CSV/JSON/Markdown y metadatos por ejecución.
Los manifiestos de origen, logs, hashes, diff completo, auditoría por archivo,
informe y propuestas de commit/PR se entregan fuera del repositorio. La carpeta
persistente de esta revisión se identifica en el informe final de la sesión.

Para defender contratos y evitar interpretaciones incorrectas, consultar
[guion-defensa-javier.md](guion-defensa-javier.md). El detalle de eventos/ratios y
los registros históricos se conservan en [performance-analysis.md](performance-analysis.md).
