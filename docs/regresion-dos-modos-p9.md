# Issue #9 — Regresión arquitectónica en dos modos

`regresion-dos-modos-p9.md` describe la selección real de memoria, las capturas
del simulador y su comparación. Sus entradas son programas, referencias de ISA
y resultados RTL; sus salidas son el informe A–AL, estadísticas y evidencia
reproducible. Depende del runner, unittest, Icarus y la jerarquía vigente con
`l2_model`. Reutiliza el mantenimiento del #28. No cambia ISA, procesador,
políticas, ejemplos ni Compiladores. Es documentación técnica del proyecto.

**IMPLEMENTADO:** API/CLI de selección, configuración verificable, estadísticas,
target y suite nueva. **VALIDADO CON MODELO:** equivalencia en 0/2 con L1-D
exclusiva y L2 provisional. **BLOQUEADO, preexistente:** integración BAL completa
por rutas antiguas. **PENDIENTE:** L2 definitiva y comparaciones de rendimiento
posteriores. Las mediciones aquí son de regresión, no benchmarks del #29.

## A. Estado inicial de Git

Árbol e índice limpios en el repositorio autorizado. Se registraron `pwd`,
estado, rama, HEAD, ocho commits, diff normal/cached, no rastreados, referencias
y hash del índice antes de editar. Se comprobó que los dos archivos nuevos no
existían. El manifiesto inicial incluye 425 archivos, también los ignorados,
excluyendo `.git`.

La línea base se ejecutó antes de implementar y se respaldó externamente.
Al continuar, `/tmp` había sido vaciado; se recuperó el paquete de evidencia
persistente verificando su SHA-256. HEAD y fuentes versionadas se volvieron a
contrastar con esa referencia. No se presentan cifras de K1-B/#28 como medidas
nuevas del #9; las tablas proceden de sus ejecuciones de referencia actuales.

## B. Rama y HEAD

Rama `feat/9-regresion-dos-modos`. HEAD
`f992fdd59d35ccf4c6d6151a270d93dd2bd7ee7b`, conservado.
El historial local incluye PR #55/#56, PR #57 (`aabfb30`) y PR #58 (`f992fdd`).
No hubo cambios de rama, fetch, pull, staging, commit, push ni integración.

## C. Alcance autorizado

Se modifican `tools/run_program.py`, `tests/rtl/tb_assembled_program.sv` y
Makefile. Se crean `tests/test_memory_modes.py` y este documento.
La continuación posterior a la propuesta mínima de compatibilidad incorpora
`tests/test_flush_tools.py` como sexto archivo: su helper selecciona el parámetro
público y dos llamadas declaran el modo a la API. Los comentarios del helper
se actualizaron. Se mantienen todos sus escenarios, datos y aserciones.

## D. Archivos protegidos

Conservados por hash: `rtl/`, `rtl-p2/`, `tb/`, `tb-p2/`, ejemplos/expectativas,
pruebas originales del procesador y CE1108, bancos de archivo/fixture CE1108,
ensamblador, cargador/extractor, scripts CE1108, README y documentación previa,
incluidos K1-B y #28. Makefile cambia solo por el nuevo target independiente.
No se agrega ninguna señal a top ni se escribe en Compiladores.

## E. Arquitectura actual

Modo 0: conexión directa a DMEM, 65536 bytes. Modo 1: modelo de stalls.
Modo 2: top → mem_hierarchy → árbitro A/B → L1-D → l2_model → DMEM.
Controlador, CDC y eviction buffer existen y están probados por separado, pero
no están conectados aquí como jerarquía definitiva. Sus pruebas siguen pasando.

## F. Configuración exclusiva

En modo 2 el banco comprueba los parámetros públicos reales:
WB, WA, EXCLUSIVA, LRU, WB_DEPTH=4, N_MSHR=2 y L2_BUS_V2=1.
Solo después emite `[CACHE_CONFIG] ... l2=MODEL`. El código de inclusión es 2,
no NINE. Geometría vigente: 4096 bytes, dos vías, línea de 32 bytes.
Los arrays/etiquetas/colas privados no se utilizan para construir referencias.
La prueba no certifica exclusión global entre dos cachés reales inexistentes.

## G. Contrato de MEM_MODE

`run_program(..., trace=False, mem_mode=0)` mantiene las siete posiciones
anteriores y añade el modo al final. Solo acepta tipo int y valores 0/1/2;
rechaza bool, cadenas, floats, None y otros tipos antes de leer el archivo.
El CLI acepta `--mem-mode {0,1,2}`, cero predeterminado.
No se convierte un valor inválido silenciosamente en memoria directa.

## H. Elaboración con Icarus

El banco declara `parameter int MEM_MODE = 0` y lo pasa explícitamente a top.
El runner compila con `-Ptb_assembled_program.MEM_MODE=N`, conservando raíz,
`-g2012`, includes, fuentes, advertencias y logs anteriores. Cada ejecución tiene
binario nuevo; no se introduce una caché que deba invalidarse por modo/fuentes.

La opción se probó en Icarus 12.0 sobre un prototipo externo y luego sobre todos
los programas reales. `+REQUESTED_MEM_MODE=N` solo verifica la intención al
ejecutar; no selecciona el hardware. Se preserva MEM_MODE=0 en top y en el banco.

## I. Verificación del modo efectivo

El banco compara petición, parámetro propio y `DUT.MEM_MODE`, y emite exactamente
un `[MEM_MODE] solicitado=N efectivo=N`. Python exige una sola línea bien
formada y concordante con la API. Rechaza ausencia, duplicación, contradicción,
X/Z, valor diferente o formato inválido. También contrasta el modo de `[FLUSH]`
y la política acreditada en `[CACHE_CONFIG]`.

Un control copia el binario REAL de modo 0 a la salida de una petición modo 2;
el compilador diagnóstico devuelve cero, pero vvp ejecuta ese hardware y el
banco aborta con `solicitado=2 banco=0 efectivo=0`. No es una falla de sintaxis ni
falta de ejecutable. Sin acreditar modo, los datos iguales podrían ocultarla.

## J. Adaptación de run_program.py

El runner conserva ensamblado y análisis previos. Exige retorno exitoso,
marcadores de fin/flush, dumps nuevos, modo y estadísticas válidos. Solo tras
validar los dumps completos y expectativas publica `execution.json` (schema 1):
modos, medidas RTL, hashes de imagen/binario y argv de elaboración/simulación.
Su retorno sigue siendo el diccionario de 32 registros.

Los metadatos anteriores se invalidan antes de ejecutar. Ante error de proceso,
flush o configuración se retiran los dumps propios parciales y se preservan
logs/trazas/ondas. No se ocultan advertencias mediante supresiones adicionales.
Los hashes son evidencia complementaria, no el oráculo de comparación final.

## K. Adaptación del testbench

Se añade el parámetro público, comprobación de configuración y observación de
flancos/tiempos. La carga de IMEM, reset, x0, conflictos WB, trazas, VCD, límites,
formatos y marcadores `[FLUSH]`/`[OK]` se conservan. Las dos tareas del #28,
`flush_cache` y `check_flush_quiescence`, permanecen literalmente iguales.
Ninguna observación nueva controla señales del procesador.

`clock_edges` cuenta todos los posedge de clk mediante NBA. Se captura a inicio
de ejecución, antes de flush y al terminar. Los puntos de observación son
POST-NBA; `core_en` se muestrea PRE para decidir si hubo avance. El reloj sigue
en 10 ns. Los enteros de tipo time se imprimen en ns, no como %t en ps.

## L. Compatibilidad de API y CLI

Se ejecutaron llamadas de siete argumentos posicionales, default0, explícito0,
modo1 y CLI modo2. Pasan las suites anteriores del procesador y del #28.
`read_expected`, `run_logged`, excepciones y los archivos registers/memory/trace
mantienen su contrato; execution.json es una salida adicional.

Además se ejecutaron los seis ejemplos originales con el CLI predeterminado,
antes y después: 12 ejecuciones con salida cero. Sus 36 archivos comparados
(imagen, listado, GPR, DMEM, traza cruda y traza legible por programa) son
idénticos byte a byte. `default-comandos.json` y `default-comparaciones.json`
conservan comandos, códigos y hashes de esta comprobación.

Ejemplo validado con sus JSON originales, en un destino externo:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tools/run_program.py \
  --input examples/lsu_isa.asm \
  --expect examples/lsu_isa.expected.json \
  --expect-memory examples/lsu_isa.memory.json \
  --cycles 80 --mem-mode 2 --no-vcd \
  --workdir /tmp/p9-ejemplo-lsu
```

## M. Preservación del issue #28

Se conserva la tarea real de mantenimiento y su orden: snapshot GPR/traza,
flush, dump DMEM. El helper antiguo buscaba `top DUT (` y sus llamadas no
comunicaban el modo al runner. Se reprodujo esa incompatibilidad en un prototipo
externo antes de pedir la excepción. El ajuste se limita al parámetro público,
a dos argumentos y sus comentarios; no se reescribe flush ni se relajan oráculos.
Los diez métodos del #28 pasan, incluidos modos 0/1/2 y sus negativos.

## N. Punto de corte arquitectónico

CYCLES mantiene su significado: cantidad de avances efectivos, con NOP y
recuperación de saltos incluidos. Después del último avance y sus NBA se guardan
GPR y se cierra traza. Se conserva el margen de cuatro avances de pipeline.
Después se confirma persistencia antes de DMEM.

El mismo CYCLES en 0/2 corresponde al mismo horizonte lógico porque el stall
congela el núcleo completo. No se comparan flancos generales iguales mientras
uno de los núcleos siga detenido. Se exige ese horizonte al parser y comparador.
No se certifica retorno semántico de main ni se agrega HALT.

## O. Avances efectivos y stalls

Por ejecución:

```text
flancos_ejecución = avances + stalls
flancos_totales = inicio_flancos + flancos_ejecución + flancos_flush
ns_totales = inicio_ns + ns_ejecución + ns_mantenimiento
```

Los stalls se obtienen de flancos realmente observados con core_en=0. Los saltos
pueden consumir avances con burbujas; no se cuentan como stalls de memoria.
`bundles` es tamaño estático del programa, no bundles retirados ni instrucciones.
No se calcula CPI/IPC ni se mezcla esta población con las latencias K1-B.

## P. Vaciado y persistencia

El contador general se captura a ambos lados de la tarea existente. La diferencia
incluye espera y retorno a IDLE; Python exige que coincida con espera+salida del
marcador de flush. En 0/1 no consume flancos, aunque propagar señales requiere
retardos subciclo. En 2 espera MSHR, scan, WBUF y l2_idle hasta persistir en DMEM.
Un store aceptado en MSHR puede añadir trabajo al flush sin frenar ejecución.

Se conserva el rechazo de actividad útil durante mantenimiento. El bucle que
continúa guardando falla y no produce memory.txt/execution.json aceptados. No se
modifica core_en ni se desactiva quiescencia para obtener un resultado.

## Q. Diseño de la suite nueva

`make test-memory-modes` comprueba iverilog y vvp antes de unittest; se mantiene
independiente de make sim y de los comandos previos. La suite tiene 16 métodos,
0 skips y salida cero. Ejecuta 19 parejas nominales (38 ejecuciones en 0/2,
18 imágenes distintas, incluida una repetición), más compatibilidad y controles.
Esas cantidades no son números de instrucciones ni de programas independientes.

Cada ejecución posee fuente, oráculo preparado, binario, logs, dumps y reporte.
P9_EVIDENCE_DIR permite conservar un destino externo NUEVO. Sin esa variable,
ExitStack/TemporaryDirectory liberan recursos propios. Los casos originales
conservan sus destinos para sus aserciones; sus resultados se copian antes de
que el propietario original elimine el temporal. Se conserva fuente/referencia
antes de ejecutar, para acreditar procedencia independiente.

## R. Programas del Proyecto I

Se ejecutan los diez métodos RTL positivos del archivo protegido
`tests/test_cpu_program.py` mediante un puente que llama al runner real dos veces.
Se mantienen también las aserciones originales, incluido VCD. No se duplica
mecánicamente su fuente ni se usan retornos ficticios para extraer fixtures.

Incluye `alu_isa.asm`, `lsu_isa.asm`, `bru_isa.asm`, `subrutina.asm`,
`dependencias.asm` y `mixto.asm`. Conserva sus JSON cuando existen; dependencias
usa x4=x5=7 y mixto x10=7,x11=0,x12=1, memoria 0x100=14 y 0x104=42 del caso previo.
Los otros positivos cubren inmediatos signed, shifts módulo32, última escritura,
autoactualización y capacidad máxima IMEM. Las pruebas de parser y expectativas
siguen en sus suites originales y no se presentan como ejecución RTL en dos modos.

## S. Estado inicial y oráculos

Ambos modos parten de reset igual, GPR cero, DMEM cero y el mismo estado inicial
criptográfico del RTL protegido. memory.sv inicializa explícitamente todas las
palabras; la selección de caché no cambia esos datos. IMEM se inicializa a NOP y
se carga la misma imagen. Los bytes reales de program.mem deben coincidir.

Las expectativas proceden de los JSON originales o de semántica ISA declarada.
Toda DMEM esperada se construye desde cero más stores conocidos; guardab en
byte1 produce 0x00007f7f. Las referencias se guardan en oracle.json antes de
observar el DUT. No se toma modo0 como referencia automáticamente correcta.

## T. Comparación de 32 registros

El lector exige x0..x31 una vez cada uno y hexadecimal de ocho dígitos. El
comparador recorre los 32 valores completos, incluso registros ausentes en un
JSON esperado parcial. Además conserva el oráculo de corrección disponible.
Las diferencias reportan registro y valores de ambos modos; no basta x0=0.

## U. Comparación de 16 384 palabras

El lector exige 16384 palabras de ocho dígitos, conocidas. Se comparan las
65536 bytes observables palabra a palabra, no solo dos direcciones ni hashes.
Cada divergencia incluye índice, dirección de byte, valores y rutas de evidencia.
El JSON externo conserva todas; consola muestra estado y primera divergencia.
Se rechazan capturas incompletas antes de usar zip, evitando truncamiento mudo.

## V. Pruebas positivas

Además de los diez originales: un bundle NOP/ALU/load, memoria con stores
consecutivos y parciales, lecturas, MSHR, víctimas del mismo conjunto, palabra
inicial/final, bucle finito y puertos LSU/CRIPTO simultáneos. El tercer store a
0/2048/4096 compite por dos vías; 65532 prueba el borde superior válido.

Para puerto B, se prepara contraseña7/AUTH; load+camcon ve7 antes de rotar a14,
y store42+camcon conserva14 por prioridad B. Los NOP de separación corresponden
a N+3 explícito. La repetición exige mismo estado y mismas medidas RTL en destinos
independientes. El límite de IMEM mantiene 1020 bundles y completa la última WB.

## W. Pruebas negativas

25 controles tienen registro explícito en results.json:
siete estructuras de dump inválidas, tres divergencias de datos, igualdad con
oráculo incorrecto, trece alteraciones de protocolo/proceso y binario equivocado.
Se añaden validaciones de API/CLI, tres comparaciones inválidas, programa activo,
fuente inválida y manejo de errores de infraestructura. No se suman estos últimos
como divergencias RTL detectadas.

Se alteran copias externas: omitir/duplicar GPR, hex X/Z, DMEM vacía/truncada;
cambiar x4 o palabra0x100 o palabra0xfffc; cambiar imagen, horizonte o modo;
omitir/duplicar/contradecir/formar mal marcadores; omitir flush/fin/estadísticas;
mezclar mantenimiento en ejecución, reutilizar dumps o devolver error con éxito
impreso. Cada control exige la causa correspondiente, no cualquier excepción.

Los productores diagnósticos de stdout escriben dumps NUEVOS válidos para
que ausencia de archivos no oculte el defecto del marcador/código. El caso de
dumps viejos sí omite producir nuevos y debe ser rechazado. Errores de compilador,
ejecutable ausente y timeout son pruebas del manejo de errores, no PASS RTL.
Los oráculos nominales y el RTL de producción permanecen sin mutaciones.

## X. Control de modo incorrecto

El compilador diagnóstico copia el sim.vvp real de modo0 al destino solicitado
para modo2 y retorna0. La simulación real falla con diagnóstico de petición2,
banco0 y efectivo0. El binario no desaparece ni contiene sintaxis inválida.
Los programas pueden producir iguales datos en ambos modos, por lo que este
control requiere verificar configuración además de equivalencia arquitectónica.
Se guardan script, binario, compile.log y sim.log de ese control externo.

## Y. Integridad de dumps

read_snapshot valida estructura y procedencia antes de comparar. La API valida
además los formatos históricos antes de devolver GPR. Los metadatos se publican
solo después de verificar datos/expectativas. Un error de simulación se propaga como excepción y se conserva en el log;
no se clasifica como DIFERENTE. Los estados del comparador son:
EQUIVALENTE Y CORRECTO; DIFERENTE; MISMA SALIDA, PERO EXPECTATIVA INCORRECTA.
La tercera categoría evita aprobar dos modos que comparten el mismo error.

## Z. Resultados de equivalencia

19 parejas nominales acreditadas, todas EQUIVALENTE Y CORRECTO. Las 18 imágenes
distintas coinciden byte a byte dentro de su pareja. No hubo divergencias
arquitectónicas nominales ni fallos nuevos pendientes. Los negativos localizaron
sus divergencias artificiales sin alterar las expectativas para ocultarlas.
El detalle completo, incluidos valores y rutas, está en pruebas-entrega/results.json.

## AA. Estadísticas de ejecución

A continuación, los valores medidos. E son flancos de ejecución, S stalls y F
flancos de mantenimiento incluyendo retorno. En todas las parejas el presupuesto
A de avances es igual; no se exige E0=E2 ni mayor duración en todos los casos.
Los números no proceden del tiempo de pared. CSV/JSON externos incluyen también
inicio/total de flancos y nanosegundos por intervalo.

| Caso | Bundles estáticos | A | E0 / E2 | S0 / S2 | F0 / F2 |
|---|---:|---:|---:|---:|---:|
| semilla | 4 | 8 | 8 / 8 | 0 / 0 | 0 / 138 |
| all_18_instructions_and_pseudos | 24 | 28 | 28 / 28 | 0 / 0 | 0 / 131 |
| memory_program | 10 | 80 | 80 / 87 | 0 / 7 | 0 / 131 |
| branch_program | 13 | 80 | 80 / 80 | 0 / 0 | 0 / 131 |
| subroutine_call_and_return | 9 | 60 | 60 / 60 | 0 / 0 | 0 / 131 |
| two_nop_bundles_between_producer_and_consumer | 4 | 8 | 8 / 8 | 0 / 0 | 0 / 131 |
| immediate_signed_limits_and_logic | 5 | 9 | 9 / 9 | 0 / 0 | 0 / 131 |
| shift_amount_reduced_modulo_32 | 6 | 10 | 10 / 10 | 0 / 0 | 0 / 131 |
| latest_write_and_self_update | 7 | 11 | 11 / 11 | 0 / 0 | 0 / 131 |
| last_bundle_reaches_writeback_at_capacity_limit | 1020 | 1024 | 1024 / 1024 | 0 / 0 | 0 / 131 |
| mixed_program_with_crypto | 24 | 60 | 60 / 61 | 0 / 1 | 0 / 131 |
| nop | 1 | 5 | 5 / 5 | 0 / 0 | 0 / 131 |
| alu | 1 | 5 | 5 / 5 | 0 / 0 | 0 / 131 |
| load | 1 | 5 | 5 / 13 | 0 / 8 | 0 / 131 |
| memoria-bordes-victima | 27 | 31 | 31 / 43 | 0 / 12 | 0 / 151 |
| bucle-finito | 8 | 80 | 80 / 80 | 0 / 0 | 0 / 131 |
| puerto-b-load | 11 | 15 | 15 / 17 | 0 / 2 | 0 / 131 |
| puerto-b-store | 11 | 15 | 15 / 17 | 0 / 2 | 0 / 131 |
| repeticion | 4 | 8 | 8 / 8 | 0 / 0 | 0 / 138 |

Por ejemplo, LSU utiliza 80 avances en ambos modos, 80/87 flancos de ejecución y
0/7 stalls; el flush suma 0/131 flancos por separado. La semilla de store MSHR
consume 8 avances y 8 flancos en ambos; su vaciado necesita 138 en modo2. Esos
casos muestran por qué no se atribuye toda espera a misses bloqueantes ni se
incluye automáticamente persistencia en tiempo de ejecución. Ningún dato aquí
certifica una mejora de rendimiento o un AMAT jerárquico definitivo.

## AB. Regresión inicial

Se ejecutaron las siete órdenes siguientes en la copia externa del HEAD antes
de editar. La tabla muestra códigos y segundos de pared antes/después; bancos,
métodos y aserciones se reportan separados y no se suman como una sola población.

| Comando | rc antes / después | s antes / después | Resultado |
|---|---:|---:|---|
| `make sim` | 0 / 0 | 146.083 / 64.387 | 55 PASS; 0 FAIL/NO-COMPILA/SIN-CHEQUEO |
| `make test-assembler` | 0 / 0 | 29.296 / 0.516 | 44 métodos (21+13+4+6) |
| `make test-programs` | 0 / 0 | 48.003 / 4.676 | 14 métodos |
| `make archivo` | 0 / 0 | 15.407 / 0.716 | 7 verificaciones y 386 bytes idénticos |
| `make tb_mem_hierarchy` | 0 / 0 | 3.222 / 2.22 | 43 verificaciones |
| `make tb_perf_cache_l1d_k1b` | 0 / 0 | 5.228 / 2.571 | 979004 verificaciones |
| `python3 -m unittest discover -s tests -p test_flush_tools.py -v` | 0 / 0 | 46.033 / 12.244 | 10 métodos, 0 skips |

## AC. Regresión posterior

`make test-memory-modes`: 16 métodos, salida0, cero skips, 22.318 s.
Las siete órdenes anteriores pasan otra vez. La suite #28 ejecuta diez métodos
y conserva sus expectativas, incluidos los controles negativos de persistencia.
No hay fallos nuevos de Arquitectura. La última revisión ajustó solo comentarios
y docstrings; se verificó igualdad del AST Python sin docstrings y no se alteró
ningún token RTL de funcionamiento después de esas pruebas.

Las advertencias de Icarus se preservan en compile.log; no se añadieron opciones
de supresión. El resumen sim mantiene cero NO-COMPILA y SIN-CHEQUEO. La duración
de pared depende del entorno y no se interpreta como ciclos ni speedup RTL.
El primer script de edición detectó un punto de sustitución duplicado y se
corrigió su anclaje antes de editar el runner; no fue una prueba funcional FAIL.
Las tres ejecuciones de desarrollo de la suite nueva terminaron con código0.

## AD. Compatibilidad con CE1108

Se mantienen scripts CE1108 y la API predeterminada/posicional. La suite del #28
valida directamente su fixture en modos0/1/2. También se ejecutaron ambos flujos
completos sobre una copia externa del HEAD actual de Compiladores
`08c8701c7bc6e58461f54b69a90a1a6fe85d0145`, con la versión base y la adaptada del runner:

- test-ce1108-source: make retorna2 antes y después; error de preparación,
  cero métodos, rutas antiguas ausentes.
- test-compiladores-funciones: make retorna2 antes y después; tres métodos,
  dos FAIL y cinco errores de subcasos por las mismas rutas.

Los scripts siguen buscando src/generacion_basica.c, Analisis_Sintactico y
Analisis_Semantico en sus ubicaciones anteriores. BLOQUEADO y preexistente;
no se reparan rutas ni se presenta BAL completo como PASS. Los logs/argv/códigos
y tiempos actuales se guardan en ce1108-resultados.json. No se modifica ese repo.

## AE. Advertencias y limitaciones

El corte necesita reposo útil durante mantenimiento. Flush no detiene por sí
solo el núcleo; un programa con stores/GPR/cripto activos se rechaza mediante el
control del #28. No se declara finalización semántica de main. Programas largos
que envuelvan IMEM y reanuden efectos durante el scan pueden ser rechazados.
La prueba de capacidad usada tiene NOP al inicio y es segura; no garantiza toda
posible imagen al límite. Solo se comparan GPR/DMEM, no una captura completa de
bóveda/ESTADO como una interfaz arquitectónica adicional.

Se acredita la jerarquía vigente, no L2 real, RAM definitiva, CDC o exclusividad
global de dos niveles reales. Los límites de pared/ejecución siguen siendo los
existentes; una futura jerarquía más lenta debe revisarlos con sus autores.
Las pruebas de infraestructura no demuestran sensibilidad a errores de hardware.

## AF. Auditoría de comentarios R2–R2.2

Se revisaron individualmente archivos, funciones nuevas/modificadas y nested
helpers, selección de modo, dump readers, comparaciones, escenarios, mutaciones,
recursos y errores. Los comentarios están en español y junto al código; explican
entradas/salidas, ownership, fase PRE/POST, fuentes de los oráculos, casos límite,
causas del rechazo y diferencias entre ejecución/mantenimiento.

La auditoría externa enumera cada elemento y sus líneas. Se conservan comentarios
históricos ajenos a la adaptación. El helper del #28 y las dos llamadas cambiadas
mantienen sus aserciones; las dos tareas SV heredadas tienen hash idéntico al
original. No se agregan instrucciones para asistentes al repositorio.
El inventario individual comprende 33 funciones nuevas/modificadas, incluidos
helpers anidados y los 16 escenarios; la excepción del #28 se revisa aparte.

## AG. Integridad de archivos y hashes

Solo se modifican cuatro archivos existentes de C y se crean los dos nuevos.
Las fuentes protegidas se contrastan por SHA-256 contra la referencia inicial.
De los 425 archivos iniciales, los otros 421 conservan hash, tamaño y permisos;
el manifiesto final contiene 427 archivos y ninguna eliminación.
El índice y HEAD se conservan. Los manifiestos completos incluyen ignorados;
cualquier diferencia concurrente de Compiladores se registra sin restaurarla.
La tarea solo leyó su repo para el snapshot HEAD y los hashes.
Las ejecuciones propias usan PYTHONDONTWRITEBYTECODE=1 y destinos externos.
No se generan binarios, logs, VCD ni cachés Python nuevos dentro del original.

## AH. Evidencias externas

Workspace `/tmp/ce4301-p9-extaq7_v`, con la referencia inicial recuperada de su
respaldo. La entrega persistente usa un directorio NUEVO, separado del informe
previo de bloqueo:
`/home/javier/Documentos/evidencias-proyecto2-arquitectura-p9-f992fdd-entrega-extaq7_v`.
Contiene informe A–AL, diff completo de seis archivos sin staging, manifiestos,
hashes, referencias, logs, comandos/códigos/tiempos, estadísticas CSV/JSON,
fuentes/oráculos, dumps, binarios, trazas y auditoría. Los metadatos de los casos
originales conservan argv de sus temporales; las copias de fuente/imagen permiten
reproducir después de que esos temporales sean liberados.

Reproducción en una copia externa, sin editar el original:

```bash
p9_dir="$(mktemp -d /tmp/p9-repetir.XXXXXX)"
mkdir "$p9_dir/codigo"
git archive HEAD | tar -x -C "$p9_dir/codigo"
for p9_file in Makefile tools/run_program.py tests/rtl/tb_assembled_program.sv tests/test_flush_tools.py tests/test_memory_modes.py docs/regresion-dos-modos-p9.md; do
    cp --parents "$p9_file" "$p9_dir/codigo"
done
(
    cd "$p9_dir/codigo" || exit 1
    PYTHONDONTWRITEBYTECODE=1 P9_EVIDENCE_DIR="$p9_dir/resultados" make test-memory-modes
)
```

El destino de evidencia debe ser nuevo. El target también funciona sin la
variable, con temporales propios que se liberan al terminar. No necesita un CLI
nuevo de comparación ni una herramienta del issue #30.

## AI. Dependencias de L2 definitiva

Cuando se conecte, se debe confirmar persistencia completa de flush_done,
orden de víctimas/buffers, latencia máxima, reset y reposo del núcleo. Los datos
de rendimiento y la ventana de K1-B requerirán una población compatible antes
de combinarse. Es coordinación pendiente; no se integra una interfaz supuesta.
La regresión podrá reutilizar sus programas y oráculos si esos contratos siguen.

## AJ. Estado Git final

Misma rama/HEAD de B, índice intacto y sin conflictos. Cuatro archivos modificados
y dos nuevos sin staging. git diff --check sin errores. No se hicieron commits,
publicaciones ni modificaciones de develop. La propuesta de commit se entrega
para revisión; el usuario conserva la publicación manual en GitHub Desktop.

## AK. Conclusión

La regresión acredita corrección y equivalencia de los escenarios nominales en
memoria directa y L1-D exclusiva con el modelo vigente. La selección es real,
los cortes conservan avances y el mantenimiento precede a DMEM. Las medidas
separadas explican diferencias temporales sin alterar las expectativas del
Proyecto I. La entrega está lista para revisión de Javier. CE1108 completo
permanece bloqueado por sus rutas previas; no hay fallos nuevos en Arquitectura.
No se cierra el issue ni se comienza el #29.

## AL. Propuesta de commit

Título: `test: agregar regresión arquitectónica en dos modos de memoria`

Descripción propuesta:

```text
Seleccionar MEM_MODE por elaboración en el banco y el runner, manteniendo
la API posicional y modo cero predeterminado. Verificar el modo efectivo,
la configuración exclusiva y los marcadores de finalización y vaciado.

Separar avances, flancos, stalls y mantenimiento en execution.json.
Agregar make test-memory-modes con comparación de los 32 GPR y 65536 bytes
de DMEM, mismas imágenes y expectativas independientes.

Reutilizar los diez positivos del Proyecto I y validar 19 parejas nominales,
casos de puerto B, límites de memoria, MSHR, víctimas y controles negativos.
Alinear el adaptador del #28 con el parámetro público y la petición explícita.
Documentar evidencias, condiciones de reposo y límites de la L2 provisional.

Pruebas: 16 métodos nuevos, 55 bancos RTL, 44 métodos de ensamblador,
14 de programas, archivo, jerarquía, K1-B y 10 métodos del #28 exitosos.
Los dos flujos CE1108 conservan fallos de rutas preexistentes antes/después.

Relacionado con #9. Sin cambios del RTL de producción ni benchmarks del #29.
```

Propuesta solamente: sin staging, commit, push, merge, rebase, cherry-pick o PR.
