# Issue #28: vaciado de caché en herramientas

Adaptación de tres bancos RTL y del ejecutor Python para observar DMEM después
de confirmar la persistencia. Este documento recibe como referencia el código
`490ed2a`, los fixtures existentes y las ejecuciones registradas. Describe las
salidas, las dependencias y las limitaciones; no cambia instrucciones de uso del
compilador ni el protocolo de producción. Es parte de la documentación técnica
del proyecto, con la auditoría de comentarios R2–R2.2 y evidencia de pruebas.

**Estado funcional: IMPLEMENTADO y VALIDADO CON MODELO** (`l2_model`). La L2
definitiva está PENDIENTE y los dos flujos completos BAL están BLOQUEADOS por
rutas preexistentes. La conservación literal de todos los archivos, incluidos
ignorados y el repositorio concurrente de Compiladores, es PARCIAL: se detallan
las diferencias en AD. No se declara que esos manifiestos sean idénticos.

## A. Estado inicial de Git

Repositorio `/home/javier/Documentos/GitHub/Proyecto2_Arquitectura1`, árbol e
índice inicialmente limpios, sin conflictos ni archivos nuevos pendientes.
Se registraron `pwd`, estado, rama, HEAD, ocho commits, diff normal/cached,
archivos nuevos, referencias y SHA-256 del índice antes de editar. El PR #56
está presente; sus componentes no se confunden con su conexión a la jerarquía.
No se ejecutaron fetch, pull, staging ni operaciones que modifican historial.

## B. Rama y HEAD

Rama `feat/28-vaciado-herramientas`, HEAD
`490ed2a00daab133ff4ba5670143ae6ceba8d5fe`. Se conserva el mismo HEAD.
`develop` y las referencias locales/remotas de ramas permanecen iguales al
registro inicial. K1-B (`b99db7f`, `feat/26b-latencia-amat-l1d`) no se incorpora.

## C. Alcance autorizado

| Archivo | Intervención |
|---|---|
| `tests/rtl/tb_archivo.sv` | Flush antes de cada volcado y del reset entre programas |
| `tests/rtl/tb_assembled_program.sv` | Corte de registros/traza, flush y dump persistente |
| `tests/rtl/tb_ce1108_program.sv` | Detectar store final, completar avances y vaciar |
| `tools/run_program.py` | Exigir confirmación y descartar dumps parciales ante fallo |
| `tests/test_flush_tools.py` | Nuevo: pruebas positivas y adversariales externas |
| `docs/flush-herramientas-p28.md` | Nuevo: análisis, resultados y límites |

No se implementan los issues #9/#29, la L2 definitiva ni una interfaz CLI nueva.

## D. Archivos protegidos

Sin cambios de fuente en `rtl/`, `rtl-p2/`, `tb/`, `tb-p2/`, Makefile, README,
ensamblador, cargador/extractor, herramientas CE1108, pruebas anteriores y
los documentos protegidos. La ISA, Feistel4, llaves y valores esperados se
conservan. Los adaptadores y mutaciones se crean fuera del repositorio.
No se cambian ramas ajenas ni se agregan archivos de instrucciones para IA.

## E. Jerarquía actual

`top` modo 2 → `mem_hierarchy` → árbitro LSU/CRIPTO → L1-D → `l2_model` → DMEM.
La configuración efectiva comprobada es WB/WA/EXCLUSIVA/LRU, write buffer de
cuatro entradas, dos MSHR y bus versión 2. PR #56 aporta `mem_controller`,
`eviction_buffer` y `perf_memory`, pero estos no sustituyen a `l2_model` dentro
de esta instancia. Las pruebas se refieren a la jerarquía realmente conectada.

## F. Política exclusiva

Una víctima sucia debe transferirse al nivel inferior. El scan del flush
expulsa/invalida las líneas sucias transferidas según el productor actual;
las limpias pueden permanecer. El consumidor no recorre etiquetas ni cambia
políticas: solicita mantenimiento y espera su confirmación pública.
No se interpreta el flush como invalidación universal de todas las líneas.

## G. Write-back y persistencia

Un store aceptado puede cambiar L1-D y dejar DMEM vieja. El fin del trabajo útil,
el vaciado del pipeline, la aceptación de una escritura por L2 y la persistencia
son condiciones diferentes. Solo se compara o vuelca DMEM tras `flush_done=1`.
Reset antes de ese punto puede descartar líneas dirty; no reemplaza el flush.

## H. MSHR y operaciones pendientes

Un store miss puede asignar MSHR y permitir que el núcleo avance antes del
llenado. `FL_IDLE` no inicia el scan mientras haya MSHR, lectura pendiente,
árbitro ocupado o acceso incompleto. Luego se recorren líneas y se drena el
write buffer. `mem_hierarchy` añade la condición `l2_idle`: la última palabra
de una escritura de línea debe alcanzar DMEM, aunque L1 ya haya terminado.
`l2_model` escribe ocho palabras por línea, en flancos sucesivos.

## I. Contrato de vaciado

Cada banco tiene tareas locales equivalentes `flush_cache(phase)` y
`check_flush_quiescence(phase)`. El llamador aporta un corte sin trabajo útil
pendiente del núcleo. La primera modifica solo `flush_req`, espera `clk`
general y produce un marcador o `$fatal`; no altera core, reset ni datos.
La segunda solo observa demandas, escrituras GPR y actividad criptográfica.
Se repite la tarea en tres archivos porque el alcance no autoriza un include
nuevo compartido ni cambios del Makefile.

Se exige req inicialmente inactivo. Se mantiene alto hasta un done exactamente
igual a uno. Cero es espera normal; X/Z es error. Después se retira req y se
espera done exactamente cero. No se genera un volcado válido tras un fallo.

Estados del productor: `FL_IDLE` espera operaciones previas; `FL_SCAN` recorre
128 entradas WB; `FL_DRAIN` drena WBUF/bus; `FL_DONE` conserva done hasta retirar
req. El retorno de `FL_DONE` a `FL_IDLE` requiere otro posedge en modo 2.

## J. Temporización

Los llamadores alcanzan sus cortes fuera de la región activa del posedge.
`#1` desplaza la solicitud respecto del último flanco; otro `#1` permite
propagar la respuesta combinacional de modos 0/1. No se añaden flancos en esos
modos. Si hay espera, se consume `@(posedge clk)` y después `#1` para observar
las NBA y los caminos combinacionales antes de leer done.

La comprobación del núcleo es PRE-flanco, cuando las demandas y `core_en` que
serán muestreados están estables. El mantenimiento usa `clk`, porque `core_clk`
puede detenerse por caché. Se baja req POST-NBA y se deja propagar done; si
permanece uno, se consume el posedge que vuelve a IDLE. Los retardos sincronizan
la observación; no sustituyen la condición de persistencia por ciclos fijos.

Un programa nuevo puede iniciarse después de esta confirmación y retorno,
como ocurre entre cifrar y descifrar. El reset del siguiente programa se aplica
en negedge mediante el procedimiento anterior, conservado.

## K. Timeout y errores

Límite predeterminado de 10000 flancos para espera y otros 10000 para salida.
`+FLUSH_MAXCYCLES=N` permite diagnóstico acotado; N debe ser positivo. Es un
plusarg del banco, sin nueva opción pública Python. El scan normal de 128
entradas y los casos MSHR/WBUF medidos quedan ampliamente dentro del límite.
`waited` y `released` pertenecen al mantenimiento y no aumentan el presupuesto
útil reportado. Ante timeout se informa fase, espera, límite, req, done y etapa:
`[FAIL] vaciado de caché no completado`. También se rechazan done X/Z, retorno
inválido y actividad nueva del programa. No hay espera infinita.

La ventana del ejecutor/fixture tiene límite general `avances*256+1024`.
Ese margen es una protección del modelo actual, no una especificación de una
L2 futura. Los watchdogs globales de los bancos son respaldos finitos y Python
limita la simulación a 30 s de pared. Ninguno sustituye el protocolo físico.

## L. Adaptación de tb_archivo

La secuencia es ejecutar cifrado → observar salto final EX → flush →
`cifrado.mem` → reset de descifrado → ejecutar → flush → `descifrado.mem` →
comparación. También se vacía en `SOLO_DESCIFRAR`. El primer flush ocurre
obligatoriamente antes del reset. Se conserva el final por self-jump del fixture,
sin certificar retorno semántico de main. Si no llega antes del límite, ahora
se aborta antes del volcado o siguiente ejecución.

No cambian datos iniciales, claves, programas, oráculos ni formatos de
`$writememh`. Los ciclos mostrados para cifrado/descifrado corresponden a su
procedimiento de ejecución; las esperas adicionales aparecen en `[FLUSH]`.

## M. Adaptación de tb_assembled_program

`CYCLES` delimita avances efectivos de `core_en` muestreado PRE-flanco; un stall
no cuenta como avance de pipeline. En modo 0 coincide con los ciclos previos.
Después del último avance y sus NBA se guardan los 32 registros y se cierra
la traza; luego se vacía y se generan las 16384 palabras de `memory.txt`.
Así los flancos de mantenimiento no desplazan silenciosamente el corte GPR ni
se presentan como ejecución en la traza. Los cuatro avances de reserva final
siguen drenando pipeline; ahora se distinguen del flush de caché.

El núcleo continúa ejecutándose. Durante los flancos adicionales se rechazan
nuevas demandas LSU/CRIPTO, operaciones cripto, fallos cripto y escrituras GPR
útiles. NOP y saltos sin enlace a x0 pueden continuar. Esta condición es
conservadora y no incorpora un halt. Un bucle con stores posteriores se rechaza.

## N. Adaptación de tb_ce1108_program

Conserva a=8, b=3, gp=0x4000 y resultado esperado 10. Recuerda el store aceptado
por el puerto del núcleo a 0x4008 con máscara completa y `core_en=1`; no lee
DMEM como criterio de fin. Completa `bundles+4` avances efectivos y exige haber
observado ese store. Después vacía, comprueba resultado y que a/b siguen iguales,
y conserva el mensaje PASS original. Una imagen NOP que no ejecuta el store
es rechazada. Es un criterio específico de este fixture lineal.

## O. Adaptación de run_program.py

API, argumentos, nombres y formatos públicos se conservan. Tras un proceso
exitoso se exige tanto el marcador `[FLUSH] fase=assembled ...` como el mensaje
`[OK] programa ejecutado: ...`. Deben existir dumps nuevos; los analizadores
previos siguen exigiendo 32 registros y 16384 palabras conocidas de memoria.
Un retorno cero vacío o un archivo viejo no bastan para aprobar la ejecución.

Ante fallo de proceso, mantenimiento o ausencia de confirmación, se eliminan
solo los dos dumps propios, que podrían incluir un snapshot GPR parcial.
Se conservan logs, ondas y trazas para diagnóstico. Las comparaciones de valores
esperados y sus excepciones previas no se reemplazan ni se relajan.

## P. Reutilización por CE1108

`run_ce1108_source.py` reutiliza esta API y recibirá el contrato actualizado
cuando se repare su integración de rutas. No se editó ese script ni Compiladores.
Se validó directamente el fixture existente `examples/ce1108.linear` mediante
el emisor/bundler original y `tb_ce1108_program`; no equivale a ejecutar BAL
con la estructura reorganizada del compilador.

## Q. Verificación de MEM_MODE=0

Los tres bancos ejecutaron modo 0 con respuesta combinacional inmediata:
`espera=0 salida=0`. No se consume ningún posedge adicional en flush.
Cuatro programas (`alu_isa`, `lsu_isa`, `bru_isa`, `subrutina`) ejecutados antes
y después produjeron registros, 65536 bytes de memoria, listados, imágenes y
trazas legibles idénticos byte a byte. También coinciden los volcados completos
y binarios del ejemplo de archivo. Se conservan 989 ciclos por programa.
En `make archivo` el fin pasa de 19.840.000 a 19.843.000 ps por sincronización
subciclo, sin nuevos ciclos de ejecución ni cambio de resultados.

## R. Verificación de MEM_MODE=1

Elaboración explícita y comprobada del modo 1 en los tres bancos. Mismos
resultados conocidos, cifrado y descifrado que en 0/2. El productor actual también
responde combinacionalmente: flush muestra `espera=0 salida=0`. Los stalls del
programa se consumen mediante reloj general y no agotan avances de pipeline.

## S. Verificación de MEM_MODE=2

Elaboración explícita, assert de modo y comprobación de las políticas efectivas
de la L1-D en el módulo raíz auxiliar. Para el runner, copia temporal con
`top #(.MEM_MODE(2))` y assert interno. Las sustituciones exigen una coincidencia
exacta; un cambio de estructura no puede ejecutar silenciosamente modo 0.

Los bancos reales midieron 130 flancos de espera y uno de retorno en los casos
nominales. El arnés de persistencia midió 139+1 con MSHR pendiente. Son medidas
de estos estímulos, no límites universales. VALIDADO CON MODELO `l2_model`.

## T. Pruebas positivas

Suite nueva: 10 métodos unittest, todos OK, 0 skips, salida 0, 12.144 s.
Incluye subcasos por modo/tamaño; no se cuentan como diez suites distintas.

| Método | Escenario/oráculo |
|---|---|
| 01 | Runner en 0/1/2, GPR conocidos y comparación de toda DMEM |
| 02 | Fixture CE1108 original en 0/1/2, resultado 10 y a/b preservados |
| 03 | Cifrado/round-trip de 1, 8 y 24 bytes en 0/1/2; SOLO con ciphertext externo |
| 04 | Jerarquía real: vacío, dirty hit, store MSHR, repetición, reset, víctima WBUF y puerto B |
| 05 | Respuesta controlada tardía, 300 flancos, más errores de protocolo |
| 06–10 | Controles negativos descritos en U |

El arnés 04 confirma primero DMEM vieja y aceptación de MSHR; después compara
cada palabra contra gold. A/B/C comparten conjunto para expulsar una víctima
sucia. Observa la escritura pendiente al bus inferior antes de otro flush.
No se usan señales privadas para calcular los valores esperados.

## U. Pruebas negativas

| Defecto introducido en copia/estímulo externo | Detección exigida |
|---|---|
| Omitir flush dirty/MSHR | Divergencia de palabra persistente contra gold |
| Comparar antes de flush | Misma aserción de persistencia |
| Reset antes de flush | Datos dirty perdidos frente a gold |
| Solo cuatro avances de pipeline | DMEM todavía vieja |
| Retirar req entre flancos | Timeout específico del handshake |
| done nunca activo | Timeout con espera/límite/req/done/fase |
| done X y done Z | Diagnóstico de señal desconocida |
| done retenido al retirar req | Error acotado de retorno a reposo |
| done X después de confirmación | Error de retorno inválido |
| Salida cero vacía / OK sin flush | Python rechaza y retira dumps obsoletos |
| Proceso fallido con marcadores | Código de error prevalece, con dumps nuevos válidos |
| Marcadores sin dumps nuevos | Python no reutiliza archivos anteriores |
| Bucle que continúa guardando | Corte no quiescente, sin memory.txt válido |
| Reset entre cifrado y su flush | Reinicio del PC detectado como actividad útil; no llega a éxito |
| Fixture NOP sin store final | Error de finalización observable |

Cada negativo RTL exige compilación correcta, código distinto de cero y la
aserción específica. Nunca se acredita falta de ejecutable, sintaxis inválida,
watchdog ajeno ni modificación del oráculo. Los negativos de marcadores/código generan dumps nuevos válidos para aislar
la causa del rechazo; la ausencia de archivos no puede ocultar ese defecto.
Los simuladores diagnósticos Python son ejecutables explícitos con salida/código controlados, usados para probar
rechazo de resultados y no para afirmar resultados de la caché.

Las primeras ejecuciones de desarrollo fallaron por rutas de include, slots
incompletos en estímulos y un comentario de mutación que ocultaba la comparación;
se conservan sus logs. Se corrigió solo la prueba nueva. El negativo de reset
real usa el diagnóstico que efectivamente aparece (núcleo no quiescente), no una
comparación de ciphertext que el banco no llega a ejecutar. La suite final
incluye todos estos arreglos, sin fallos nuevos pendientes.

## V. Oráculos independientes

Gold de 16384 palabras se inicializa con `0x12340000 XOR índice` y se actualiza
solo por los stores aceptados del driver. Se confirma la situación pre-flush
antes de usarlo como referencia post-flush. El runner prepara cero más stores
de 77 en direcciones 256/260. CE1108 espera 10 desde a=8,b=3. Cifrado usa una
implementación Feistel4 de software con las claves originales, módulo 2^32 y
rotaciones explícitas; descifrado se compara con el plaintext preparado.
No basta una comparación entre dos memorias derivadas del mismo RTL.

## W. Integridad de memoria

La persistencia se contrasta sobre las 16384 palabras (65536 bytes), también
tras reset y repetición. Los escenarios cripto conservan centinelas conocidos
en 0x4000/0xfffc y las comprobaciones históricas fuera del archivo. Se guardan
dumps completos; `run_program` rechaza longitudes incorrectas y valores X/Z.
Los hashes de equivalencia antes/después constan en `equivalencia-hashes.json`.

## X. Cifrado y descifrado

18 ejecuciones nominales del banco de archivo: nueve round-trips (tres tamaños
por tres modos) y nueve SOLO_DESCIFRAR con ciphertext del oráculo externo.
Todos recuperan los datos esperados, mantienen centinelas y pasan las aserciones
originales. `make archivo` conserva 386 bytes originales, ciphertext de 392 bytes
por padding y las siete verificaciones. Hashes de binarios y volcados modo 0
coinciden antes/después. No se modifican Feistel4, llaves ni programas.

## Y. Resultados de CE1108

Fixture directo: PASS en 0/1/2. Flujo completo:
`make test-ce1108-source CE1108_ROOT=<copia HEAD>` retorna 2 antes/después
(error de preparación, cero métodos ejecutados). `make test-compiladores-funciones`
retorna 2 antes/después (tres métodos, dos FAIL y cinco errores de subcasos).
Ambos siguen buscando `src/generacion_basica.c`, `Analisis_Sintactico/...` y
`Analisis_Semantico/...`, ausentes en las rutas antiguas. BLOQUEADO, preexistente.
Se usó archivo del HEAD `9dbea8d786d9def80f86934451747e04549df4dc` de Compiladores,
sin incorporar sus cambios de trabajo concurrentes ni reparar sus rutas.

## Z. Regresión inicial

Referencia medida sobre copia externa del HEAD autorizado antes de los cambios.
La tabla incluye códigos de salida y segundos de pared antes/después. Los
resultados corresponden a unidades distintas: bancos, métodos o aserciones;
no se suman como si fueran comprobaciones equivalentes.

| Comando | rc antes / después | s antes / después | Resultado en ambas referencias |
|---|---|---|---|
| `make sim` | 0 / 0 | 67.223 / 144.618 | 54 PASS; 0 FAIL/NO-COMPILA/SIN-CHEQUEO |
| `make test-assembler` | 0 / 0 | 0.565 / 1.017 | 44 métodos (21+13+4+6) |
| `make test-programs` | 0 / 0 | 5.679 / 8.536 | 14 métodos |
| `make archivo` | 0 / 0 | 1.016 / 1.267 | 7 verificaciones + round-trip de 386 bytes |
| `make tb_mem_hierarchy` | 0 / 0 | 2.57 / 4.074 | 43 verificaciones |
| `make tb_port_b` | 0 / 0 | 0.866 / 1.368 | 44 verificaciones |
| `make tb_l1d_writeback` | 0 / 0 | 16.653 / 25.833 | 68 verificaciones |
| `make tb_l1d_mshr` | 0 / 0 | 14.012 / 20.627 | 109 verificaciones |
| `make test-ce1108-source` | 2 / 2 | 0.116 / 0.166 | 0 métodos; error de preparación |
| `make test-compiladores-funciones` | 2 / 2 | 0.566 / 0.165 | 3 métodos; 2 FAIL y 5 errores de subcasos |

Las dos órdenes CE1108 incluyen `CE1108_ROOT=/tmp/ce4301-p28-v3n76lh5/ce1108`.
Los JSON conservan argv exactos, tiempo y ruta del log. `make sim` ejecutó 54
bancos en esta referencia posterior a PR #56; no se reutilizó la cifra de K1-B.
Las advertencias de Icarus se conservan en logs de compilación individuales:
no son un PASS por sí mismas y ningún error de compilación se omite del resumen.

## AA. Regresión posterior

Las ocho órdenes de Arquitectura repitieron el resultado exitoso y código 0.
Los dos fallos de integración CE1108 mantienen su causa previa. La suite nueva
final retornó 0 y todos sus métodos pasaron; los códigos 1 de los negativos RTL
son detecciones esperadas y están conservados, no fallos ocultos de regresión.
`tests-entrega-2/commands.json` registra 54 subprocesos de los auxiliares (42 rc=0,
12 rc=1 esperados); las llamadas al API runner conservan además sus logs propios.
No se afirma que 54 subprocesos equivalgan a 54 métodos nuevos.

Reproducción sin generar artefactos en el repositorio original:

```bash
p28_dir="$(mktemp -d /tmp/p28-repetir.XXXXXX)"
mkdir "$p28_dir/codigo"
git archive HEAD | tar -x -C "$p28_dir/codigo"
for p28_file in tests/rtl/tb_archivo.sv tests/rtl/tb_assembled_program.sv tests/rtl/tb_ce1108_program.sv tools/run_program.py tests/test_flush_tools.py docs/flush-herramientas-p28.md; do
    cp --parents "$p28_file" "$p28_dir/codigo"
done
(
    cd "$p28_dir/codigo" || exit 1
    PYTHONDONTWRITEBYTECODE=1 P28_EVIDENCE_DIR="$p28_dir/resultados" python3 -m unittest discover -s tests -p test_flush_tools.py -v
)
```

El directorio de evidencia debe ser nuevo y exterior a la raíz del código.
Sin esa variable, TemporaryDirectory posee y libera todos los recursos.
El Makefile permanece sin cambios.

## AB. Compatibilidad con Icarus

Ubuntu, Icarus Verilog 12.0, Python 3.12.3, GNU Make 4.3. La configuración
auxiliar usa `defparam` desde un segundo módulo raíz con ambos `-s` explícitos;
el banco temporal del runner usa instanciación parametrizada verificada.
Las rutas `-I` incluyen la raíz porque decoders históricos incluyen
`rtl/isa_defs.sv`, además de los directorios RTL. Se elaboran los parámetros
reales: un plusarg de ejecución no sustituye la selección de `MEM_MODE`.
No se edita RTL protegido ni el modo predeterminado de los bancos.

## AC. Auditoría de comentarios R2–R2.2

Se revisaron individualmente las dos tareas nuevas en los tres bancos:
precondición, entrada phase, señales observadas, req modificado, uso de clk,
NBA, límites y diagnósticos. `flush_limit`, `flush_req`, `flush_done`, `waited`
y `released` explican su papel y estado. Las ventanas de ejecución documentan
`advanced`, `elapsed`, `final_store` y el corte; los snapshots, cierre de traza,
watchdogs y secuencia de reset se comentan donde ocurren.

El bloque Python modificado explica marcadores, margen de pared, excepciones,
archivos propios retirados y conservación de diagnóstico. El archivo nuevo
explica entradas/salidas/dependencias/límites y ownership externo. Se revisaron
cada helper (`replace_once`, `flush_task`, `feistel_block`, `rol`, `setUpClass`,
`tearDownClass`, `command`, `folder`, `compile_tb`, `simulate`, `runner_root`,
`archivo`, `read_dump`, `compile_custom`, `protocol_bench`, `persistence_bench`),
los diez métodos de prueba y las tareas/procesos de los textos SV temporales.
Sus comentarios explican datos, oráculo, temporización y defecto buscado.
La auditoría detallada se guarda externamente en `auditoria-comentarios.md`.
No se sustituyen comentarios históricos ajenos al flush ni se usan separadores
decorativos. El documento es guía técnica; no agrega reglas para asistentes.

## AD. Integridad de archivos

Git muestra únicamente cuatro fuentes modificadas y dos archivos nuevos del
alcance. El índice, HEAD y referencias de ramas se conservan. Los hashes de
fuentes protegidas, cachés RTL, testbenches de compañeros, Makefile y README
son iguales al manifiesto inicial.

El manifiesto exhaustivo inicial incluye 420 archivos, también ignorados.
Una importación de prueba regeneró `tools/__pycache__/run_program.cpython-312.pyc`,
ignorado por Git: no se incluye en el diff ni se publica, pero su hash cambió.
Una caché nueva de la prueba se trasladó a evidencia externa; no se borraron
archivos previos para ocultar diferencias. Por ello no se afirma igualdad
literal de todos los archivos ignorados, aunque las fuentes protegidas sí
permanecen intactas. Las demás ejecuciones usaron copias externas y la suite
final se ejecutó con `PYTHONDONTWRITEBYTECODE=1`.

Compiladores tiene cambios concurrentes respecto de sus 474 archivos iniciales;
el manifiesto registra cada diferencia. El usuario ya confirmó otra sesión de
trabajo allí. Esta tarea solo leyó su repositorio y utilizó su archivo HEAD
externo para la referencia CE1108; no se restauraron ni alteraron sus cambios.
La igualdad de todo Compiladores no puede declararse: ver manifiesto final.

## AE. Evidencias externas

Directorio de trabajo: `/tmp/ce4301-p28-v3n76lh5`.
Respaldo persistente sin sobrescribir evidencia anterior:
`/home/javier/Documentos/evidencias-proyecto2-arquitectura-p28-490ed2a-v3n76lh5`.
Incluye informe A–AJ, diff completo de seis archivos, estados Git, manifiestos
iniciales/finales, igualdad de ramas/índice, resultados, comandos, tiempos,
controles positivos/negativos, dumps, ciphertext/plaintext, auditoría de
comentarios y paquete de reproducciones/logs/binarios. Los logs conservan rutas
absolutas del workspace original; el paquete permite inspeccionar su contenido.

## AF. Limitaciones

Flush no para el procesador. Solo se garantiza la captura si el corte no genera
nuevos efectos durante el mantenimiento. El monitor rechaza los efectos
observables citados; no prueba terminación de main ni ausencia universal de
actividad futura. Es conservador con loads/cripto y registros mantenidos. Un
programa largo que vuelva a envolver IMEM durante el scan también puede ser
rechazado. No se agrega halt, se parchean instrucciones ni se fuerza core_en.

El snapshot GPR precede al flush; la coherencia con DMEM depende de ese reposo.
En modos 0/1 no se avanza el reloj durante el handshake, por lo que no aparece
una ventana adicional que vigilar. Los límites se validan con el modelo actual,
no para toda latencia futura. Los productores tardíos/X/Z son diagnósticos del
consumidor y no sustitutos de una L2 real. La CLI general de configuraciones
permanece PENDIENTE del issue #9. La evidencia íntegra de todos los archivos
ignorados/concurrentes es PARCIAL por las diferencias explícitas de AD.

## AG. Dependencias de la jerarquía definitiva

Al conectar la L2 real se debe confirmar que done significa persistencia de
todas las escrituras relevantes, no solo aceptación por buffer/controlador.
Habrá que revisar ownership exclusivo, drenado de víctimas y solicitudes RAM,
reset, latencias máximas y necesidad de un contrato explícito de quiescencia.
Requiere coordinación con sus autores; no se da por estabilizado ese contrato.
La adaptación actual utiliza solo la interfaz existente y no integra K1-B.

## AH. Estado Git final

Misma rama y HEAD de B, sin staging ni commits; cuatro archivos modificados y
dos nuevos autorizados. `git diff --check` sin errores. No se modificó develop,
no hubo publicación, cambio de rama, merge, rebase ni cherry-pick. La caché
ignorada y el trabajo concurrente se informan por separado en AD.

## AI. Conclusión

El vaciado precede a los dumps, comparaciones y reset entre programas; se
conservan los resultados medidos del Proyecto I y se verifica persistencia
write-back/exclusiva con MSHR y WBUF en el modelo actual. No hay fallos nuevos
pendientes en esas pruebas. El flujo CE1108 completo continúa BLOQUEADO por
rutas antiguas y las limitaciones de quiescencia/L2 definitiva siguen explícitas.
La implementación está lista para revisión funcional, sin ocultar las salvedades
del manifiesto exhaustivo. No se cierra el issue ni se avanza al #9/#29.

## AJ. Propuesta de commit

Título: `feat: vaciar caché antes de validar y volcar memoria`

Descripción propuesta:

```text
Adaptar los bancos de archivo, ensamblador y fixture CE1108 al protocolo
flush_req/flush_done antes de observar DMEM y antes del reset entre programas.

Separar el corte GPR/traza del mantenimiento, completar avances efectivos
y rechazar actividad útil o respuestas de flush inválidas con espera acotada.
Exigir confirmación y dumps nuevos en run_program sin cambiar su API/CLI.

Agregar pruebas independientes en MEM_MODE 0/1/2, persistencia WB/exclusiva,
MSHR/WBUF, cifrado/descifrado y controles negativos. Documentar resultados,
precondiciones de quiescencia, L2 de prueba y bloqueos CE1108 anteriores.

Validación: 54 bancos de make sim, 44 métodos de ensamblador, 14 de programas,
make archivo y cuatro bancos de jerarquía; diez métodos nuevos exitosos.
Los dos flujos completos CE1108 conservan fallos preexistentes por rutas.

Relacionado con #28. Sin cambios del RTL de producción ni integración K1-B.
```

Propuesta solamente: no se hizo staging, commit, push ni PR. El `.pyc` ignorado
no forma parte de los seis archivos de la propuesta.
