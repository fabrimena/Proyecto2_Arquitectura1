# Análisis de rendimiento — Proyecto II

Las secciones A–D2 siguientes conservan su evidencia histórica. El estado integrado
y las medidas de la L2 real se encuentran en «Cierre integrado, 16 de noviembre
de 2026», al final; las limitaciones de integración de aquellos bloques no son
una descripción del sistema vigente.

## Issue #7, bloque A: contador de ciclos

`rtl-p2/perf_counters.sv` es un módulo independiente, todavía sin conexión al
procesador. Este bloque solo mide ciclos; los demás eventos del issue #7 quedan
para bloques posteriores. No cambia la ISA, el pipeline ni las memorias.

### Interfaz y semántica

| Señal | Sentido | Semántica |
|:---|:---|:---|
| `clk` | Entrada | Reloj de muestreo; actualización en el flanco positivo |
| `reset` | Entrada | Reset síncrono activo en 1, prioritario sobre la habilitación |
| `measure_enable` | Entrada | En 1 permite contar el flanco; en 0 conserva el valor |
| `cycle_count[63:0]` | Salida | Número acumulado de flancos habilitados desde el último reset |

En cada flanco positivo:

1. Si `reset = 1`, el resultado es cero, incluso con `measure_enable = 1`.
2. Si `reset = 0` y `measure_enable = 1`, se suma uno.
3. Si ambas entradas están en cero, se conserva el valor.

Deshabilitar pausa la medición sin borrarla. Volver a habilitar continúa el
acumulado; una medición independiente requiere aplicar reset durante al menos un
flanco positivo. No se garantiza un valor inicial antes del primer reset.
El contador es unsigned de 64 bits y desborda módulo 2^64, sin saturación.

### Límites de medición

El primer flanco con reset inactivo y habilitación activa está incluido. El primer
flanco con habilitación inactiva está excluido. Cambiar las entradas entre flancos
no actualiza el contador; tampoco lo hace un flanco negativo. Las entradas deben
estar estables alrededor del flanco positivo. En simulación se observa la salida
después de las asignaciones no bloqueantes (NBA), para evitar carreras.

Ejemplo después del reset: habilitaciones `1, 1, 1, 0, 0, 1` producen los valores
`1, 2, 3, 3, 3, 4`. Los intervalos separados se acumulan.

Cuando se integre al procesador deberá usarse el reloj `clk` sin detener. Este
módulo no infiere inicio ni fin de programa; quien lo instancie define la ventana
mediante `measure_enable` y reset. La integración se realizará en otro bloque.

### Pruebas y reproducción

```bash
make tb_perf_counters
make sim
make test-assembler
make test-programs
make archivo
```

El Makefile descubre automáticamente los archivos nuevos; no necesita cambios.
`tb_perf_counters` usa las utilidades de autoverificación del proyecto y compara
los 64 bits completos. Comprueba reset inicial y durante ejecución, prioridad,
pausa/reanudación, ventanas de uno y varios flancos, cambios entre flancos y
ausencia de actualización en flancos negativos. Para comprobar acarreo hacia el
bit 32 y desbordamiento de 64 bits, precarga el registro por jerarquía únicamente
en el testbench; no agrega mecanismos de carga al módulo.

### Evidencia de validación

Base: `main`, commit `787e380f13177a3420b726c6826941edee8fade9`.
Entorno: Ubuntu, Icarus Verilog/VVP 12.0, Python 3.12.3 y GNU Make 4.3.

Antes de modificar código se ejecutaron los cuatro comandos siguientes desde
`main`. Todos terminaron con código de salida 0.

| Comando | Resultado previo |
|:---|:---|
| `make sim` | 21 PASS, 0 FAIL, 0 NO-COMPILA, 0 SIN-CHEQUEO |
| `make test-assembler` | 44 pruebas OK: 21 + 13 + 4 + 6 |
| `make test-programs` | 14 pruebas OK |
| `make archivo` | 7 verificaciones RTL; comparación binaria correcta de 386 bytes |

En `make archivo`, el archivo predeterminado es
`examples/archivos/mensaje.txt`: cifrado en 989 ciclos y descifrado en 989 ciclos.
Los logs RTL y los archivos de memoria/binarios previos se preservaron en
`build/perf_block_a/before/`, con hashes en `sha256.json`. Las salidas de unittest
y los códigos de salida previos quedaron registrados en la sesión de ejecución.
`build/` contiene evidencia local ignorada por Git.

Después de implementar el bloque A en `feat/7-contadores-base`:

| Comando | Resultado posterior | Código de salida |
|:---|:---|:---:|
| `make tb_perf_counters` | PASS, 21 verificaciones | 0 |
| `make sim` | 22 PASS, 0 FAIL, 0 NO-COMPILA, 0 SIN-CHEQUEO | 0 |
| `make test-assembler` | 44 pruebas OK | 0 |
| `make test-programs` | 14 pruebas OK | 0 |
| `make archivo` | 7 verificaciones RTL; 386 bytes idénticos al original | 0 |

Los 51 archivos preservados (logs, imágenes de memoria y binarios) son idénticos
byte a byte a los generados después del cambio. El cifrado y el descifrado siguen
tardando 989 ciclos cada uno. El único testbench añadido a `make sim` es
`tb_perf_counters`. No se observaron fallos preexistentes ni regresiones.

Evidencia posterior: `build/tb_perf_counters/sim.log`,
`build/perf_block_a/after/{sim,test-assembler,test-programs,archivo}.log`,
`build/perf_block_a/after/results.json` y
`build/perf_block_a/after/comparison.json`. Estas pruebas no validan integración
con el pipeline ni cachés: esas implementaciones todavía no forman parte del bloque A.

## Issue #7, bloque B: bundles, instrucciones e IPC

El mismo módulo incorpora dos contadores unsigned de 64 bits. La semántica de
`cycle_count`, reset y habilitación del bloque A se conserva.

| Señal nueva | Sentido | Semántica |
|:---|:---|:---|
| `bundle_complete` | Entrada | Un evento de finalización por cada flanco positivo en que vale 1 |
| `non_nop_mask[3:0]` | Entrada | Operaciones válidas no NOP del bundle que finaliza; bits 0/1/2/3 = ALU/LSU/BRU/CRIPTO |
| `bundle_count[63:0]` | Salida | Bundles completados dentro de la ventana |
| `instruction_count[63:0]` | Salida | Operaciones completadas dentro de la ventana |

Reset pone los tres contadores en cero, incluso con habilitación y evento activos.
Con `measure_enable = 0` todos conservan su valor y los eventos se ignoran: no se
encolan para contarlos al reanudar. Con habilitación activa se cuenta cada ciclo;
solo si también está activo `bundle_complete` se suma un bundle y la cantidad de
bits activos de `non_nop_mask` a instrucciones. Sin evento, la máscara no afecta
los contadores. Un evento con máscara `0000` suma un bundle y cero instrucciones.
Los tres contadores desbordan módulo 2^64.

No se detectan flancos de `bundle_complete`: mantenerlo activo durante tres
flancos habilitados representa tres bundles consecutivos. El productor debe
presentar el evento y la máscara del mismo bundle, estables antes del flanco.
Un pulso que no coincide con el flanco positivo no cuenta. Se aplica la misma
inclusión/exclusión de límites de ventana descrita para el bloque A.

### IPC fuera del RTL

Después de muestrear los contadores, el reporte calcula:

`IPC = instruction_count / cycle_count`

La división usa números reales y no división entera. Una ventana con cero ciclos
produce **N/D** (no disponible); no se divide por cero ni se reporta como IPC cero.
Con ciclos positivos y cero instrucciones, IPC es cero. No hay divisor ni señal
IPC en el módulo sintetizable: el cálculo y las comprobaciones están en el
testbench. Ejemplos comprobados: 4/1 = 4, 4/4 = 1, 4/5 = 0.8 y 10/6 ≈ 1.666667.
El reporte debe delimitar las ventanas para evitar desbordamientos; después de un
desbordamiento los acumulados ya no representan los totales de esa ventana.

### Contrato para la integración futura

Los eventos no se deducen de escrituras al banco de registros. Una operación
válida que escribe `x0`, un store o un salto cuentan mediante su bit; una operación
cripto que escribe dos registros sigue representando una instrucción. El productor
debe clasificar las operaciones no NOP y alinear los metadatos con la finalización.

Durante un congelamiento deberá desactivar `bundle_complete`; no alcanza con
mantener la máscara estable. Los bundles descartados, las burbujas y los bundles
anulados por excepción no deben producir eventos. Los NOPs válidos sí pueden
producir eventos con máscara cero. El módulo no identifica ninguno de estos casos
por sí mismo, ni determina cuándo termina el programa. La integración, el drenado
del pipeline y la generación de eventos corresponden al bloque D; la contabilidad
de stalls corresponde al bloque C. No se modificó `top.sv`.

### Pruebas del bloque B

Las 21 comprobaciones originales del bloque A se conservan y ejecutan primero.
Se agregan casos con 0, 1, 2, 3 y 4 operaciones, cada slot individual, ausencia de
evento, eventos consecutivos, pausa y reanudación, reset simultáneo con eventos,
acumulación, pulsos entre flancos, acarreo y desbordamiento de los contadores nuevos.
El IPC se verifica con valores conocidos y con ventanas de cero ciclos. Los
valores esperados de acumulación se indican explícitamente en el testbench.

### Evidencia de validación del bloque B

Base: `feat/7-contadores-base`, commit del bloque A
`65bcaecef46cf1623d3e9a252e55aad41afd12f7`, sin cambios locales iniciales.
Se ejecutaron las cuatro regresiones antes y después de modificar el código.

| Comando | Antes del bloque B | Después del bloque B | Salida antes/después |
|:---|:---|:---|:---:|
| `make sim` | 22 PASS | 22 PASS | 0 / 0 |
| `make test-assembler` | 44 pruebas OK | 44 pruebas OK | 0 / 0 |
| `make test-programs` | 14 pruebas OK | 14 pruebas OK | 0 / 0 |
| `make archivo` | PASS, 7 verificaciones RTL | PASS, 7 verificaciones RTL | 0 / 0 |

Ambas ejecuciones de `make sim` reportaron cero FAIL, NO-COMPILA y SIN-CHEQUEO.
El testbench ampliado, ejecutado también con `make tb_perf_counters`, terminó
con código 0 y **111 verificaciones correctas**, incluidas las 21 originales.

Los 51 archivos de evidencia del Proyecto I comparados (logs, imágenes de memoria
y binarios, excluyendo el testbench de métricas ampliado) son idénticos byte a
byte antes y después. `make archivo` conservó 989 ciclos para cifrar y 989 para
descifrar, y recuperó los 386 bytes originales. No se observaron fallos nuevos.

Evidencia local ignorada por Git:

- `build/perf_block_b/before/{sim,test-assembler,test-programs,archivo}.log`.
- `build/perf_block_b/after/{sim,test-assembler,test-programs,archivo}.log`.
- `build/perf_block_b/{before,after}/results.json` (comandos y códigos de salida).
- `build/perf_block_b/before/sha256.json` y `build/perf_block_b/after/comparison.json`.
- `build/tb_perf_counters/sim.log` y `build/tb_perf_counters/tb_perf_counters.vcd`.

## Issue #7, bloque C: ciclos perdidos por memoria y saltos

El módulo independiente agrega indicadores explícitos de ciclos perdidos y dos
contadores unsigned de 64 bits. No se conecta al procesador en este bloque.

| Señal nueva | Sentido | Semántica en el flanco positivo de `clk` |
|:---|:---|:---|
| `memory_stall` | Entrada | El núcleo está globalmente detenido por memoria en este ciclo |
| `branch_recovery` | Entrada | Este ciclo corresponde a recuperación de un salto tomado |
| `memory_stall_count[63:0]` | Salida | Ciclos atribuidos a espera de memoria dentro de la ventana |
| `branch_penalty_count[63:0]` | Salida | Ciclos atribuidos a recuperación de salto dentro de la ventana |

### Regla de atribución

Con reset inactivo y medición habilitada, cada flanco suma uno a `cycle_count`.
Si `memory_stall = 1`, suma uno únicamente a `memory_stall_count`. En caso
contrario, si `branch_recovery = 1`, suma uno a `branch_penalty_count`. Si ambas
entradas están en cero, no incrementa ninguna categoría de penalización.

**La memoria tiene prioridad cuando coinciden las causas.** El ciclo se cuenta
una sola vez entre las categorías. Esta es una convención de medición aprobada
para el monitor, pendiente de contrastar con el comportamiento real del pipeline
durante el bloque D. No representa un cambio al control del procesador.

`branch_recovery` no es el evento de salto ni se conecta directamente a un pulso
de `branch_flush`: el generador externo debe indicar cada ciclo realmente perdido.
Dos ciclos activos producen dos ciclos de penalización; uno produce uno. El módulo
no multiplica eventos por dos ni mantiene una recuperación pendiente. Cuando
ambas causas coinciden, tampoco difiere ni reencola una penalización de salto:
solo cuenta una recuperación posterior si el generador la indica en ese ciclo.
Un salto no tomado no activa recuperación.

No hay entrada de excepción ni se deducen saltos desde un redirect genérico. Las
excepciones criptográficas deben excluirse de `branch_recovery` en el generador
externo. La comprobación unitaria de este contrato usa recuperación inactiva para
el caso de excepción; no verifica todavía la clasificación de señales reales.

### Reset, ventana y finalizaciones

El reset síncrono prioritario pone los cinco contadores en cero, incluso con
medición deshabilitada y ambas penalizaciones activas. Deshabilitar la medición
conserva los cinco valores; los ciclos y eventos fuera de la ventana se ignoran.
Todos los contadores desbordan módulo 2^64. Las entradas se muestrean en el flanco
positivo y deben estar estables alrededor de él; los pulsos entre flancos no cuentan.

Los ciclos totales continúan aumentando durante memoria y recuperación de salto.
El bloque C agrega una protección a la finalización del bloque B:
`bundle_complete && !memory_stall`. Mientras el núcleo está congelado por memoria
no incrementan bundles ni instrucciones, aunque el evento permanezca activo.
Con `memory_stall = 0`, el comportamiento de los bloques A y B se conserva.

La recuperación de salto no bloquea por sí sola una finalización: un bundle
anterior puede completar mientras IF/ID se recuperan. El generador debe entregar
eventos válidos para ese caso. Sigue siendo responsable de alinear la máscara,
excluir burbujas y bundles anulados, distinguir saltos de excepciones y no volver
a presentar el mismo bundle después de reanudar. El monitor no reconoce PCs ni
identidades de bundles, ni valida que la máscara represente instrucciones reales.
La protección por memoria supone el congelamiento global acordado; si cambiara
esa arquitectura habría que revisar el contrato.

Antes de cualquier desbordamiento, los incrementos mutuamente excluyentes y el
reset común garantizan:

`memory_stall_count + branch_penalty_count <= cycle_count`

El testbench verifica la desigualdad con una suma extendida a 65 bits después de
cada paso funcional del bloque C. Como en los bloques anteriores, las ventanas
deben limitarse para evitar desbordamientos: después de ellos los acumulados ya
no representan los totales históricos ni se garantiza esa desigualdad.

### Pruebas del bloque C

Se conservan y ejecutan primero las 111 comprobaciones anteriores (incluidas las
21 originales del bloque A). Se agregan cero, uno y cuatro ciclos consecutivos
de memoria, recuperación de dos ciclos, salto no tomado, coincidencias, reset
durante stall, pausa/reanudación, ausencia de duplicados con evento sostenido,
excepción sin recuperación de salto, límites de ventana y muestreo. También se
comprueban finalizaciones durante recuperación, acarreo hacia el bit 32 y
desbordamiento de los dos contadores nuevos mediante precargas de simulación.

### Evidencia de validación del bloque C

Rama: `feat/7-contadores-stalls`, creada desde `feat/7-contadores-base` en
`3c85f5e938e3d277c9f168d0c4a38e38a87203f0` (bloque B, precedido por el bloque A).
El árbol de trabajo estaba limpio antes del cambio. Se ejecutaron los cinco
comandos antes y después de implementar el bloque C:

| Comando | Antes | Después | Salida antes/después |
|:---|:---|:---|:---:|
| `make tb_perf_counters` | 111 verificaciones PASS | 292 verificaciones PASS | 0 / 0 |
| `make sim` | 22 PASS | 22 PASS | 0 / 0 |
| `make test-assembler` | 44 pruebas OK | 44 pruebas OK | 0 / 0 |
| `make test-programs` | 14 pruebas OK | 14 pruebas OK | 0 / 0 |
| `make archivo` | PASS, 7 verificaciones RTL | PASS, 7 verificaciones RTL | 0 / 0 |

Ambas ejecuciones de `make sim` reportaron 0 FAIL, 0 NO-COMPILA y 0 SIN-CHEQUEO.
Las 111 verificaciones previas se conservan y pasan. Los 51 archivos de evidencia
del Proyecto I comparados (logs, memorias y binarios, excluyendo el testbench de
métricas ampliado) son idénticos byte a byte. El flujo de archivos conserva los
989 ciclos de cifrado y 989 de descifrado, y recupera los 386 bytes originales.
No se observaron fallos nuevos.

Los logs y códigos de salida están en
`build/perf_block_c/{before,after}/{tb_perf_counters,sim,test-assembler,test-programs,archivo}.log`
y `build/perf_block_c/{before,after}/results.json`. La comparación se registra en
`build/perf_block_c/before/sha256.json` y
`build/perf_block_c/after/comparison.json`. La evidencia local en `build/` está
ignorada por Git; los resultados no demuestran integración con el procesador.

## Issue #7, D1: clasificación de operaciones por bundle

`rtl-p2/perf_slot_mask.sv` recibe `bundle_in[127:0]` y produce
`non_nop_mask[3:0]` mediante lógica combinacional, sin reloj, reset ni registros.
El bit 0 corresponde a ALU, el 1 a LSU, el 2 a BRU y el 3 a CRIPTO.
No se conecta todavía al procesador ni a los contadores.

Se comparan exactamente los campos tipo `[31:25]` e ID `[24:21]` de cada
instrucción con las constantes de `rtl/isa_defs.sv`, respetando su slot fijo:

| Slot | Tipo | IDs definidos | Operaciones |
|:---|:---|:---|:---:|
| ALU | REG | 5, 6, 8–15 | 10 |
| ALU | IMM | 0–7 | 8 |
| LSU | LSU | 0, 1, 8, 9 | 4 |
| BRU | COND | 1, 2, 4, 8 | 4 |
| BRU | JUMP | 0, 1 | 2 |
| CRIPTO | CRYPTO | 0–5 | 6 |

Son las 34 instrucciones de la green card de `docs/isa.md`. Los IDs no listados,
tipos de otra unidad y tipos desconocidos se excluyen. `0x00000000` es el NOP
canónico; cualquier palabra con `TYPE_NOP` tampoco representa una operación
reconocida, aunque tenga bits bajos activos. Los prefijos X/Z no coinciden con
ninguna entrada de los `case` exactos; no se usan `casex` ni `casez`.

El destino `x0` no elimina una instrucción reconocida. Loads, stores, saltos
condicionales/incondicionales y operaciones sin escritura general se reconocen
por su codificación, no por `wb_we`. Una operación cripto aporta un solo bit.
Las pseudoinstrucciones se reconocen por la instrucción real a la que se expanden.

### Diferencia entre reconocimiento ISA y fallback de la ALU

Se revisaron los cuatro decodificadores antes de implementar D1. En
`decoder_alu.sv`, los IDs REG 0–4 y 7, e IMM 8–15, no tienen operación definida,
pero el decoder conserva `ALU_ADD` junto con los campos de operandos y destino.
En particular, una palabra reservada con destino distinto de `x0` puede producir
efectos en el procesador actual. No debe describirse como un NOP de hardware.

El clasificador **excluye esas codificaciones según el contrato de la ISA**.
Esta diferencia se reportó antes de implementar y se documenta explícitamente:
la máscara no demuestra ausencia de efectos arquitecturales para un programa
con codificaciones fuera de la ISA. El testbench observa el decoder original y
comprueba tanto su fallback como la exclusión de las métricas. No se corrige ni
modifica el decoder en D1.

En LSU y CRIPTO, los IDs reservados dejan `valid = 0`; los saltos JUMP reservados
dejan `is_jump = 0`. Para COND, el decoder activa `is_branch` para cualquier ID
del tipo, pero la BRU solo implementa las cuatro condiciones de la ISA; el resto
no toma el salto. D1 reconoce únicamente esas cuatro, no todo `is_branch`.

### Alcance y contrato para etapas posteriores

Esta es una máscara de operaciones reconocidas, no un validador completo de
instrucciones ni una señal de finalización. No comprueba restricciones de
operandos, bits RSV, pares de registros, alineación ni permisos AUTH/INIT; esas
validaciones no se deducen de los bits de salida. El programa debe respetar el
contrato del ensamblador/compilador. Variar los 21 bits de operandos no cambia la
clasificación de un prefijo reconocido.

Una operación cripto reconocida puede provocar una excepción; la etapa posterior
deberá excluir el bundle anulado. Asimismo, una burbuja y un bundle NOP pueden
tener máscara cero y se distinguirán por la validez transportada en D2. D1 no
transporta metadatos, resuelve flush, detecta stalls ni modifica la ISA o latencias.

### Pruebas de D1

`tb-p2/tb_perf_slot_mask.sv` usa las utilidades autoverificables existentes. Las
34 palabras fijas proceden de las referencias de `tests/test_assembler.py` y
`tests/test_isa.py`; cada una se prueba en los cuatro slots. Se ejercitan las
16 combinaciones de slots activos, transiciones a NOP y destinos ALU `x0`.

Un barrido de los 128 tipos por los 16 IDs comprueba los cuatro slots, con los
21 bits bajos en cero y en uno, usando bitmaps numéricos independientes de las
constantes del DUT. Esto incluye todos los IDs reservados y tipos incorrectos.
Se agregan mezclas de válidas/reservadas, instrucciones en unidades equivocadas,
NOP no canónico, tipo desconocido y prefijos X/Z. No se necesita flanco de reloj
para obtener la salida; el testbench solo espera propagación combinacional.

### Evidencia de validación de D1

Rama: `feat/7-integracion-metricas`, creada exactamente desde
`feat/7-contadores-stalls` en `f0f0171ef5182bc9613dc428c25399905f138169`,
con los bloques A–C y sin incorporar la rama de Fabricio. El árbol y el índice
estaban limpios antes de comenzar. Se ejecutó la línea base antes de modificar
código, y después se ejecutaron los siguientes comandos:

| Comando | Antes de D1 | Después de D1 | Salida antes/después |
|:---|:---|:---|:---:|
| `make tb_perf_slot_mask` | No existía | PASS, 4299 verificaciones | — / 0 |
| `make tb_perf_counters` | PASS, 292 verificaciones | PASS, 292 verificaciones | 0 / 0 |
| `make sim` | 22 PASS | 23 PASS | 0 / 0 |
| `make test-assembler` | 44 pruebas OK | 44 pruebas OK | 0 / 0 |
| `make test-programs` | 14 pruebas OK | 14 pruebas OK | 0 / 0 |
| `make archivo` | PASS, 7 verificaciones RTL | PASS, 7 verificaciones RTL | 0 / 0 |

Ambas ejecuciones de `make sim` reportaron cero FAIL, NO-COMPILA y SIN-CHEQUEO.
No se observaron fallos. Los 53 archivos de evidencia previa comparados (logs,
imágenes de memoria y binarios, incluyendo los logs del monitor A–C) son
idénticos byte a byte. El flujo de archivos conserva 989 ciclos de cifrado y
989 de descifrado y recupera los 386 bytes originales.

Logs y comandos con códigos de salida: `build/perf_d1/{before,after}/*.log`
y `build/perf_d1/{before,after}/results.json`. Los hashes previos se registran en
`build/perf_d1/before/sha256.json` y el resultado de comparación en
`build/perf_d1/after/comparison.json`. El testbench nuevo también deja ondas en
`build/tb_perf_slot_mask/tb_perf_slot_mask.vcd`. Esta evidencia local está ignorada
por Git. D1 no valida la integración al pipeline, que sigue pendiente.

## Issue #7, D2: metadatos ID → EX → WB

`rtl-p2/perf_pipeline_monitor.sv` observa un pipeline abstracto en orden. Recibe la
validez y máscara de ID, y mantiene registros auxiliares para EX y WB. No se
instancia en `top.sv`, no altera datos ni control del núcleo y no agrega una etapa
MEM o latencia al procesador. No utiliza PC para identificar finalizaciones.

### Fuentes y adaptación al proyecto

Se consultaron las **Notas de Clase de Arquitectura de Computadores I**, del
Dr.-Ing. Jeferson González Gómez, versión del **27 de octubre de 2026**, archivo
externo `notas_de_clase_arqui1_v0.4.pdf`. La numeración siguiente es la impresa
(el PDF tiene ocho páginas preliminares):

| Fuente | Principio respaldado | Aplicación y límites en D2 |
|:---|:---|:---|
| Notas §3.1.2, pp. 50–53 | Registros síncronos transportan datos y control; capturan en el mismo flanco y conservan valores entre flancos | Se transporta máscara y validez en paralelo, usando las cuatro etapas reales IF/ID/EX/WB; no se copia el ejemplo de cinco etapas |
| Notas §3.2.3, pp. 61–62 | Un salto resuelto más tarde obliga a descartar más trabajo joven; el ejemplo distingue ID de EX | Se transporta la causa del vaciado de las dos posiciones jóvenes con resolución en EX; no se calcula una penalización automática |
| Notas §3.2.4, pp. 62–66 | El compilador puede insertar NOPs para calendarización estática | NOP válido no equivale a bundle inválido ni aporta instrucciones útiles |
| Notas §5.1, pp. 89–93 | Slots ligados a unidades funcionales, paquetes en orden y calendarización estática | Una máscara representa los cuatro slots del mismo bundle y avanza conjuntamente |
| Notas §6.3.4, pp. 122–123 | El modelo bloqueante congela el pipeline; se contrasta con cachés no bloqueantes | `advance = 0` congela todos los metadatos; no se implementa hit-under-miss ni ejecución fuera de orden |
| Enunciado Proyecto II §3.1.1 y §5.1, pp. 3 y 9 | Avance conjunto del bundle, stall global por miss y distinción entre bundles completados y operaciones no NOP | Interfaz abstracta de avance y evento único de finalización con su máscara |

Son decisiones particulares de este proyecto: usar EX para memoria y resolución
de saltos, cuatro slots ALU/LSU/BRU/CRIPTO, N+3, efectos de store/bóveda en EX y
resultados de registros/ESTADO en WB. Se revisaron `top.sv`, IF/ID, ID/EX, EX/WB,
BRU y CRIPTO para definir la alineación. La finalización común al consumir WB es
una convención de observación; no retrasa efectos ni añade un retiro al datapath.
La prioridad de excepción sobre salto proviene del RTL actual, no de una regla
nueva del monitor. La prueba de D2 todavía no demuestra el enganche al núcleo.

### Interfaz abstracta

| Señal | Sentido | Contrato |
|:---|:---|:---|
| `clk`, `reset` | Entradas | Reloj general y reset síncrono prioritario, también con `advance = 0` |
| `advance` | Entrada | El núcleo completo avanza en este flanco; debe estar estable antes de él |
| `id_valid`, `id_non_nop_mask[3:0]` | Entradas | Bundle que ocupa ID antes del flanco; la máscara procede de D1 |
| `ex_branch_taken` | Entrada | Salto tomado del bundle actualmente en EX, no la mera presencia de BRU |
| `ex_exception` | Entrada | Excepción del bundle actualmente en EX, ya determinada por el control |
| `ex_valid`, `ex_non_nop_mask`, `ex_cancel_cause` | Salidas | Metadatos registrados de EX |
| `wb_valid`, `wb_non_nop_mask`, `wb_cancel_cause` | Salidas | Metadatos registrados de WB |
| `bundle_complete` | Salida | Nivel consumible en el flanco: `!reset && advance && wb_valid` |

Las causas de anulación son códigos internos de observación de dos bits:
0 = ninguna, 1 = salto tomado, 2 = excepción. No son opcodes de la ISA.
Toda posición anulada tiene validez cero y máscara cero. Una burbuja inicial o
entrada inválida sin redirect tiene causa cero; una posición descartada conserva
la causa de su descarte. Un NOP válido tiene validez uno, máscara cero y puede
finalizar. Una entrada inválida, incluso con máscara distinta de cero, no cuenta.

### Flancos y temporización

Los metadatos se actualizan solo en `posedge clk`: primero reset y, en su ausencia,
solo si `advance = 1`. Sin cancelaciones, para un bundle A que ya está en ID:

| Instante | ID antes del flanco | EX después de NBA | WB después de NBA | Bundle consumido en el flanco |
|:---|:---|:---|:---|:---|
| E0 | A | A | vacío | ninguno |
| E1 | B | B | A | ninguno |
| E2 | C | C | B | A |
| E3 | inválido | inválido | C | B |
| E4 | inválido | inválido | inválido | C |

```text
ID(A) ──E0──> EX(A) ──E1──> WB(A) ──E2──> finalización de A
```

En E2 los contadores muestrean el WB anterior al flanco (A); las asignaciones no
bloqueantes del monitor ponen B en WB después. Registrar un pulso adicional de
finalización después de E2 introduciría otro ciclo de desfase, por lo que no se
hace. Después de NBA, `bundle_complete` describe la elegibilidad del nuevo WB
para el siguiente flanco; no significa que ese bundle se contó en el flanco recién
ocurrido. El testbench verifica ambas fases y los contadores efectivamente consumidos.

El cableado abstracto al contador usa `bundle_complete` y `wb_non_nop_mask`.
El testbench conecta `memory_stall = !advance` para representar exclusivamente
sus congelamientos sintéticos, y fija `branch_recovery = 0`. No incorpora nombres
de Fabricio ni una conexión real a memoria. La ventana de medición solo habilita
los contadores: los metadatos deben seguir avanzando aunque la medición esté
deshabilitada, para no reproducir eventos viejos al reanudarla.

### Congelamiento y reanudación

Con `advance = 0` se mantienen EX, WB y la causa pendiente de IF/ID, y
`bundle_complete = 0`. No se desplaza ni crea una marca y no se reemplaza una
retención por una burbuja. Al reanudarse se consume el WB pendiente una vez.
Finalizaciones consecutivas pueden mantener el nivel activo: cada flanco
consume un bundle diferente. No se comparan PCs ni máscaras para deduplicar.

Los controles de EX solo se aceptan en un flanco de avance y para un EX válido.
El productor debe conservar la condición pendiente durante un congelamiento si
el núcleo la aceptará al reanudar. Un pulso que desaparece antes de un flanco
habilitado no se encola: este es un contrato síncrono, no una interfaz asíncrona.

### Saltos, excepciones y marcas de anulación

Un salto tomado aceptado conserva el bundle de EX al pasar a WB y anula el que
estaba en ID. Se guarda una causa auxiliar que identifica el hueco de IF/ID que
el mismo redirect produjo; en el próximo avance esa segunda posición se anula
al pasar por ID. Esta causa es metadato de IF/ID, no una nueva etapa de ejecución.
El productor debe respetar la secuencia real de ID: tras el flush aparece el
hueco de IF/ID antes de que el destino alcance ID. El monitor no almacena la
instrucción original descartada en IF. Las marcas describen posiciones vaciadas,
que incluso podrían estar ya inválidas, no identidades de bundles útiles perdidos.

Un salto no tomado no activa `ex_branch_taken` y no crea esas marcas. Si hay
excepción y salto simultáneos, gana la excepción: se anula el bundle actual de
EX y también las dos posiciones jóvenes, todas con causa 2. El WB anterior puede
finalizar en ese mismo flanco; no se lo anula con la excepción del EX siguiente.
Los controles sobre un EX inválido se ignoran. Reset limpia todas las causas.

**Transportar marcas de salto hasta WB no equivale a medir ciclos perdidos.** D2
no produce `branch_recovery`, no suma dos por salto ni conecta la causa 1 a ese
contador. Atribuir los ciclos reales, resolver coincidencias con memoria y
delimitar la ventana requiere el control real y queda pendiente de D4. Las causas
2 nunca se convierten en marcas de salto. El testbench comprueba transporte y
prioridad de causas, no penalidades reales del procesador.

### Modelo de referencia y pruebas

El testbench independiente instancia D1, D2 y los contadores existentes, sin
instanciar `top`. La referencia usa fechas de salida en número de avances
efectivos: un bundle presentado en ID en el avance n vence en n+2. Una tabla
registra cancelaciones por edad y sus causas; no replica los dos registros RTL
del monitor. Cada paso compara metadatos y contadores antes del flanco y después
de NBA, usando además totales dirigidos independientes para casos clave.

Se verifican reset con/sin avance, llenado/drenado, NOP válido, máscaras de uno a
cuatro slots, inválidos, finalizaciones consecutivas, congelamientos de 1 a 4
ciclos, reanudación, salto tomado/no tomado, dos posiciones jóvenes anuladas,
excepción cripto, prioridad de excepción, conservación de WB anterior, controles
retenidos/transitorios, congelamiento de marcas, ventana de medición y 300 pasos
pseudoaleatorios reproducibles con semilla `0xCE430102`. El contador de saltos
permanece en cero porque no se ha validado su atribución temporal.

D3 deberá contrastar estos metadatos con el procesador actual. D4 deberá confirmar
avance/reset y controles con Fabricio e implementar la atribución real de saltos.
D5 verificará la combinación con congelamientos del núcleo. No se realizaron
esos enganches ni se modificaron los módulos existentes en D2.

### Evidencia de validación de D2

Se comenzó en `feat/7-integracion-metricas`, HEAD `cb62d86` (D1), con árbol e
índice limpios, conservando A–C y sin incorporar Fabricio. Antes de modificar
código se ejecutaron las seis regresiones existentes; todas terminaron con 0.

| Comando | Antes de D2 | Después de D2 | Salida antes/después |
|:---|:---|:---|:---:|
| `make tb_perf_pipeline_monitor` | No existía | PASS, 9981 verificaciones | — / 0 |
| `make tb_perf_slot_mask` | PASS, 4299 verificaciones | PASS, 4299 verificaciones | 0 / 0 |
| `make tb_perf_counters` | PASS, 292 verificaciones | PASS, 292 verificaciones | 0 / 0 |
| `make sim` | 23 PASS | 24 PASS | 0 / 0 |
| `make test-assembler` | 44 pruebas OK | 44 pruebas OK | 0 / 0 |
| `make test-programs` | 14 pruebas OK | 14 pruebas OK | 0 / 0 |
| `make archivo` | PASS, 7 verificaciones RTL | PASS, 7 verificaciones RTL | 0 / 0 |

Ambas ejecuciones de `make sim` reportaron 0 FAIL, 0 NO-COMPILA y 0 SIN-CHEQUEO.
No se observaron fallos. Los 55 archivos previos comparados (logs, memorias y
binarios, incluyendo D1 y A–C) son idénticos byte a byte. El flujo de archivos
conserva 989 ciclos de cifrado, 989 de descifrado y los 386 bytes originales.

La evidencia local está en `build/perf_d2/{before,after}/*.log`, los comandos y
códigos de salida en `build/perf_d2/{before,after}/results.json`, los hashes en
`build/perf_d2/before/sha256.json` y la comparación en
`build/perf_d2/after/comparison.json`. Las ondas del nuevo testbench están en
`build/tb_perf_pipeline_monitor/tb_perf_pipeline_monitor.vcd`. Estos artefactos
están ignorados por Git. Los resultados de D2 no validan los ciclos reales de
penalización por saltos ni la temporización del enganche con Fabricio.


## Cierre integrado, 16 de noviembre de 2026 (#26, #29–#31, #36)

### Arquitectura y procedencia

Base `origin/develop` en `e461b70b1195ea402b5352e43ab1f357309a8ffe`, posterior
al HEAD auditado `128ce789`: los cinco commits adicionales solo agregan cinco
filas de documentación de simulación. Las contribuciones colectivas #60–#64
ya proporcionan L2 real, jerarquía completa, D18 y cuatro etapas L2. Este cierre
agrega observación y herramientas; no implementa de nuevo las cachés del equipo.
Los resultados corresponden al diff de esta rama sobre esa base, no a un commit
nuevo. Cada ejecución conserva hashes de todos los RTL elaborados.

VLIW IF/ID/EX/WB, cuatro slots, ROM síncrona, regla N+3 y Feistel4 se conservan.
Modo 0 mantiene DMEM directa; modo 1 añade esperas sintéticas; modo 2 usa L1-D
4 KiB/2 vías/32 B, WB+WA/LRU, WBUF4/MSHR2, exclusiva, L2 real 16 KiB/4 vías/PLRU
con cuatro etapas, EB4 y controlador de RAM con MEM_DIV4 (Tmem53). MODEL1
reemplaza L2/EB/MC por el proveedor provisional: sus ceros L2/RAM son ausencia
de instrumentación real, no evidencia de cero tráfico físico.

### Contrato común de observación

Todos los monitores usan `clk` general y consumen señales PRE; las capturas son
POST-NBA. Reset síncrono prioritario borra acumulados, incluso en pausa. La
aritmética es unsigned módulo 2^64; las tasas exigen ventanas sin desbordamiento.
`perf_measure_eff = perf_measure_enable && cisa_measure_enable`. Pausar conserva
valores sin detener CPU, caché o mantenimiento; no se recuperan eventos omitidos.
PERF_ENABLE0 elimina monitores al elaborar y deja sus salidas en cero.

El transporte de metadatos sigue ID→EX→WB con el avance global real. Un NOP
válido completa un bundle y cero instrucciones; una burbuja no completa. Stores,
saltos no tomados y destinos x0 cuentan por su operación; dos salidas cripto no
son dos instrucciones. Un congelamiento desactiva finalización y conserva WB.
Un salto descarta jóvenes, una excepción descarta además al culpable, sin contar
como recuperación BRU. El contador histórico llamado stall de memoria observa
**todo `!core_en`**, incluido arbitraje y `cisa_hold` de vaciarc: no es una medida
exclusiva de misses. Las causas memoria/recuperación no se duplican.

El clasificador conserva las 34 operaciones originales y agrega D18 solo en LSU,
reutilizando decoder_cache_isa y su validación de RSV/operandos conocidos. IDs
reservados no cuentan. El fallback ALU de codificaciones reservadas sigue siendo
una discrepancia hardware/ISA documentada; no se modifica ni se oculta.
La validación exacta de `cache_valid===1` evita que un decoder no evaluado con
LSU constante cero propague X al monitor abstracto durante inicialización.

Etapas: índice 0/1/2/3 = IF/ID/EX/WB. Ocupación mide residencia de bundles,
no operaciones ni retiros; ocupado+burbuja=medido. Los cuatro stalls describen
el mismo congelamiento global y no se suman para obtener stall del procesador.

### L1-D K1-A y K1-B

K1-A conserva diecinueve eventos: RH, RM, WH, WM, stall, WBUF lleno, RAW stall,
RAW forwarding, WBUF push, inicio lectura L2, inicio escritura L2, fill, víctima
sucia, víctima limpia, reserva MSHR, fusión MSHR, carga desde MSHR, hit bajo miss
y MSHR lleno. Los primeros cuatro clasifican demandas completadas; el resto
no son demandas adicionales. Sus solicitudes L2 no prueban hits/misses de L2.

K1-B observa el puerto único **después** del árbitro: cada fase B-read/A/B-write
es una demanda distinta. Para una cohorte íntegramente observada: servicio=F−S+1,
espera=F−S y servicio=completados+espera. Un store termina para el núcleo al
reservar/fusionar su MSHR; su fill posterior no prolonga ese servicio. Un acceso
cortado por pausa se excluye de la cohorte. No se divide el stall global entre
completados K1-B, ni se incorporan períodos de mantenimiento sin demanda.

### L2 y RAM: poblaciones y puertos

`perf_cache_l2` observa diez salidas públicas registradas de L2. El vector
`perf_l2_counts[9:0][63:0]` expuesto al final de mem_hierarchy tiene este orden:

| Índice | Evento / unidad |
|---:|---|
| 0 / 1 | Lectura L2 clasificada hit / miss |
| 2 / 3 | Escritura L2 clasificada hit / miss |
| 4 | Relleno de una línea de L2 |
| 5 | Víctima sucia entregada por reemplazo |
| 6 | Writeback entregado durante vaciado |
| 7 | Invalidación por movimiento exclusivo L2→L1; no coherencia multicore |
| 8 | Inicio de solicitud de lectura al nivel inferior |
| 9 | **Ciclos de oferta** de escritura al nivel inferior; puede repetirse |

Lecturas=0+1; escrituras=2+3; hits=0+2; misses=1+3; accesos=0+1+2+3.
Las decisiones pertenecen a S2, mientras fills/invalidados consumen las etapas
posteriores. Una ventana que corte peticiones pendientes no garantiza igualdad
entre aceptaciones y decisiones dentro de ese intervalo. No se interpreta el
índice9 como escrituras físicas aceptadas, ni se mezcla reemplazo con vaciado.

Se reutiliza `perf_memory` de Dylan sin modificarlo. Recibe directamente
req_accept, req_we_accepted, transfer_busy, timeout_event y error_event de MC.
`perf_ram_counts` contiene 0 lecturas aceptadas, 1 escrituras aceptadas,
2 ciclos busy, 3 ciclos medidos, 4 timeouts y 5 errores definitivos. Un req
retenido no genera una aceptación por ciclo; el reintento mantiene la misma
solicitud y sí agrega ocupación. El controlador sigue usando clk_mem para RAM;
solo sus eventos públicos se contabilizan en clk, sin otro CDC introducido.

### D18 y ventanas

lcont0–8 conservan sus fuentes; 9=hits L2, 10=misses L2, 11=lecturas+escrituras
aceptadas RAM, 12=busy RAM. 13–31 retornan cero. sel[5] selecciona la mitad alta;
se captura PRE en EX, se retiene durante freeze y se escribe por LSU en WB,
con N+3. Dos lecturas de mitades no son atómicas: medir0 permite obtener una
instantánea estable. Modos sin jerarquía y MODEL1 no inventan contadores reales.

medir0 incluye su flanco de aceptación EX usando el enable anterior; medir1
abre a partir del siguiente flanco. vaciarc espera el vaciado encadenado real,
retira req/ack y permite continuar. Con medición abierta su espera pertenece
al stall global; con medir0 no se agrega actividad de mantenimiento.

El runner captura GPR y todos los contadores al mismo horizonte efectivo,
cierra la entrada externa y luego solicita el vaciado antes de volcar DMEM.
La memoria se acepta solo con flush confirmado, retorno a reposo y ausencia de
nuevos efectos útiles. El núcleo continúa activo: no hay HALT artificial.
Para estudios con calentamiento, `defer_measurement=True` excluye el arranque
hasta observar el primer medir0 y deja luego a D18 gobernar la ventana. Sin
ese medir0, la ventana permanece vacía; no se frena la ejecución.

### Métricas calculadas por software

IPC=instrucciones completadas/ciclos medidos; CPI es el cociente inverso con
las mismas instrucciones. Denominador cero produce null/N/D, nunca una tasa
cero inventada. Hit/miss rate L1 usa sus cuatro clasificaciones; el de L2 usa
las suyas, que incluyen víctimas de L1 y no solo demandas de CPU. Utilización
RAM=busy/medidos; sus aceptaciones son transacciones de línea, no bytes útiles.

Servicio L1 observado=servicio K1-B/completados K1-B de la misma cohorte. Es una
media de servicio al puerto, no latencia de persistencia de un store ni AMAT
teórico jerárquico. Un modelo teórico tipo 1+MR1×(8+MR2×Tmem) exigiría misses
condicionales de la misma población y ausencia de superposición/forwarding;
no se aplica automáticamente a stores non-blocking y caché víctima exclusiva.
No se suman latencias de niveles que se superponen ni se atribuye flush a
las demandas ya cerradas. Las tablas conservan los denominadores originales.

### Revisión histórica del requisito AMAT del issue #26 (base 4a16239)

Este diagnóstico describe las capturas sin extensión temporal. El cierre
posterior de este documento agrega observadores y sustituye el estado PARCIAL
para las capturas nuevas; no modifica ni completa artificialmente las antiguas.

El [issue #26](https://github.com/fabrimena/Proyecto2_Arquitectura1/issues/26)
requiere accesos, hits, misses, tasas y AMAT de cada nivel. El enunciado oficial,
sección5.2 (página10), exige contadores que permitan calcularlo; sección7.1.5
requiere analizarlo con los benchmarks. Las Notas de Clase v0.4, §6.2, página108,
ecuación6.1 y ejemplo6.2, distinguen dos expresiones:

```text
AMAT = HR × T_hit + MR × T_miss
AMAT_serial = T_L1 + MR_L1 × (T_L2 + MR_L2_condicional × T_mem)
```

La primera admite tiempos medios condicionados medidos sobre una misma cohorte.
La segunda exige que las tasas condicionales y las penalizaciones describan la
misma cadena de demandas. Exclusividad o concurrencia no hacen imposible medir
AMAT, pero los agregados disponibles no acreditan esa sustitución serial.

**Definición observada L1-D.** Una demanda empieza en su primer PRE estable del
puerto arbitrado y termina en el flanco con la clasificación pública sin stall.
Para las demandas completas K1-B que no cruzaron reset ni pausa:

```text
T_i = ciclos de espera_i + 1 flanco de finalización
AMAT_L1_observado = Σ T_i / N_completados_K1B
                 = HR_cohorte × media_hit + MR_cohorte × media_miss
```

Se calcula además por lecturas y por stores, con numerador/denominador de esas
clases. No se usan las finalizaciones K1-A como denominador: pueden incluir
operaciones excluidas de la cohorte temporal. Un store miss aceptado en un MSHR
puede tener T_i=1; no se agregan su fill o persistencia posteriores. La espera
anterior a presentar la demanda al puerto arbitrado tampoco pertenece a esta
definición. No es AMAT de persistencia, throughput ni penalización media del CPU.
Sin accesos completos se informa null/N/D, incluso con eventos parciales.
Se exige una época sin overflow y sin errores de protocolo K1-B.

`tools/analizar_amat.py` deriva JSON/CSV nuevos desde las capturas existentes,
verifica log, ventana, imagen/binario y conserva los reportes originales. Su
suite usa duraciones independientes, stores aceptados sin espera, cohortes
incompletas, población vacía y corrupciones de procedencia. No cambia el RTL,
los runners ni la producción de las54 ejecuciones ya verificadas.

| Referencia exclusiva REAL | Completados K1-B | Servicio | AMAT observado L1 (ciclos) |
|---|---:|---:|---:|
| Secuencial | 96 | 96 | 1 |
| Aleatorio | 96 | 1830 | 19.0625 |
| Stride | 96 | 9484 | 98.7916666667 |

**L2 pendiente.** RH/RM/WH/WM son decisiones de S2, sin acumulados de tiempos
aceptación→respuesta. Las lecturas responden en orden; las escrituras se aceptan
sin respuesta y no equivalen a persistencia. Las víctimas de línea completa
pueden fallar sin lectura RAM. Con estos conteos no se reconstruye la media de
lectura ni la espera de oferta→aceptación de stores. Hace falta seguimiento
pasivo por transacción/cohorte, separado por operación, con exclusión de accesos
que crucen ventana y una frontera explícita de finalización de stores. No se
deduce un tiempo individual a partir de ev_l2_fill o de las ofertas retenidas.

**RAM pendiente como media observada.** busy/aceptaciones usa flancos ocupados
y operaciones iniciadas, no necesariamente la misma cohorte: el corte puede
dejar una transferencia pendiente, excluir su inicio o abarcar un reintento.
Tmem=53 es un parámetro nominal con DIV4; no reemplaza tiempos medidos de
aceptación→éxito/error. Se necesitan inicios/finales emparejados y política de
inclusión de fallos. RAM no es una caché con hit/miss rate. Su utilización sí
sigue siendo busy/ciclos medidos, con el significado documentado.

El analizador publica AMAT L2/RAM y jerárquico como null, sin estimaciones
nominales disfrazadas de medición. **#26 queda PARCIAL**: el tráfico y las tasas
L1/L2 están verificados y el AMAT observado L1 está calculado, pero falta el
AMAT L2 exigido. Agregar esa instrumentación y acreditarla es un pendiente
interno; no se presenta como dependencia de un optimizador ni como imposibilidad
teórica del diseño. Esta revisión conserva las medidas validadas y no incorpora
observadores RTL sin una nueva campaña temporal por nivel.

Reproducción sobre evidencia existente (destino externo nuevo):

```bash
python3 tools/analizar_amat.py --report /ruta/comparaciones.json --output /ruta/nueva/amat
python3 -m unittest discover -s tests -p test_analizar_amat.py -v
```

### #29 revalidado con L2 real

Mismos ASM y expectativas: 868 bundles estáticos, horizonte872 avances,
32 stores, 64 loads, checksum1056, 32 GPR y 16384 palabras cotejados con gold.
Dos rondas independientes repitieron exactamente estados y métricas. La traza
heredada sigue deduplicando niveles adyacentes solo para estas fuentes: no es
un contador universal de aceptaciones ni identifica de forma fiable el PC WB
durante stalls. Las tablas anteriores con MODEL permanecen como historia.

| Programa | Ciclos | Bundles retirados | Instr. | IPC | Stall | BRU | L1 H/M | L2 H/M | RAM R/W | RAM busy | Flush |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| secuencial | 872 | 868 | 386 | 0.442661 | 0 | 2 | 64/32 | 0/4 | 4/0 | 212 | 653 |
| aleatorio | 2606 | 868 | 386 | 0.148120 | 1734 | 2 | 64/32 | 0/32 | 32/0 | 1696 | 1936 |
| stride | 10260 | 868 | 386 | 0.037622 | 9388 | 2 | 0/96 | 0/190 | 96/83 | 9443 | 732 |

Los 386 retiros de operaciones incluyen preparación, checksum y el salto final;
no son las 96 operaciones de memoria ni el tamaño estático del programa.
El rendimiento es determinista para estos estímulos, no un estudio estadístico.

### #30: comparación de una dimensión

Nueve configuraciones, tres programas y dos rondas: 54 elaboraciones nuevas.
Cada ejecución verifica su configuración real, imagen, reset/entrada, horizonte,
GPR, DMEM y traza. Se conservan métricas por etapa, MSHR, servicio y espera,
L2 y RAM además de esta tabla reducida de ciclos:

| Configuración | Secuencial | Aleatorio | Stride |
|---|---:|---:|---:|
| exclusiva | 872 | 2606 | 10260 |
| nine | 872 | 2606 | 8452 |
| wt_nwa | 971 | 2778 | 8240 |
| fifo | 872 | 2606 | 10260 |
| random_l1 | 872 | 2606 | 10260 |
| random_l2 | 872 | 2606 | 9980 |
| mshr1 | 1128 | 2920 | 10907 |
| mshr4 | 872 | 2476 | 10260 |
| div2 | 872 | 2186 | 7768 |

Referencia: exclusiva/WB+WA/LRU/PLRU/MSHR2/MEM_DIV4. NINE cambia inclusión;
WT+NWA se compara contra NINE/WB+WA, nunca contra exclusiva. FIFO/Random L1,
Random L2, MSHR1/4 y MEM_DIV2 cambian una sola dimensión respecto de referencia.
WT+exclusiva se rechaza antes de elaborar. MSHR1 desactiva la ruta non-blocking
de stores en la implementación actual; no representa una L2 bloqueante.

L2 bloqueante: versión real `5c6990683204cc2bd6747c47931808f3085ed462`,
anterior a `55e28e5`. El inventario funcional protegido difiere de la versión
actual solo en l2_cache.sv. Se reutilizan los mismos observadores/conexiones y
se verifican hashes de todos los RTL: solo puede diferir ese archivo. Dos rondas
reproducen 872/2606/10236 ciclos frente a 872/2606/10260 con cuatro etapas.
No se usa MODEL como sustituto. En stride la versión actual cuesta 24 ciclos
más (~0.2345%); estos programas no acreditan una mejora de throughput general.
La L1 mantiene una lectura L2 en vuelo y limita la superposición aprovechable.

### 18 KiB: corrección y capacidad

El archivo versionado conserva tamaño18432 y SHA256
`c98e65ae5a58f7925bdc75bd3325ff60603df3c7113f5852bcccc2784fd920c3`.
El roundtrip con MEM_MODE2/L2_MODEL0 recupera todos los bytes: cifrar y descifrar
83018 ciclos cada uno; espera de flush32264 por fase, fuera de esos ciclos.
Ese resultado prueba Feistel4/persistencia, no por sí solo capacidad útil.

El experimento de capacidad usa 576 líneas distintas del archivo precargado
desde0x200, una palabra por línea. La primera pasada calienta con medición
cerrada; la segunda se abre con medir1 y se cierra con medir0. Se excluye el
arranque anterior al primer medir0 mediante armado diferido. No cambia ningún
byte y se verifica toda DMEM, checksum y todos los GPR; los directorios son
independientes por ronda/política. Los resultados exactos de esta ventana se
presentan en el informe de verificación, junto con los vectores originales.
En ambas políticas la segunda pasada demanda576 lecturas L1. Exclusiva evita
lecturas RAM en esa pasada y NINE necesita256; no se infiere esta diferencia
solo de 20KiB frente a16KiB: hay evidencia de eventos reales y colisiones.

### #31: resultado parcial histórico (solo CLI tradicional)

El comparador ejecuta balc real con fuente BAL congelada, registra commit,
argv, hashes de fuente/ASM/BALB/MEM y módulos M2, verifica las imágenes contra
el ensamblador y obtiene un estado completo de M2 independiente. RTL0 y RTL2
se contrastan con los 32 GPR, estado criptográfico público y 65536 bytes M2,
además de los observables semánticos120/21/37. No modifica Compiladores.
Se usan factorial, whale y ejercicio3_puntajes: aritmética, condicionales,
bucles, llamadas, pila y dependencias N+3. Cortes observados B5:3403/247/2748
avances; son puntos tras un retorno observado, no certificación de main ni
terminaciones artificiales. No se reutilizarán para variantes con otro layout.

El CLI actual ofrece -h (no --help), --ir/--dce/--unroll/--reorder/--reorder-json.
Las pasadas IR no generan ASM optimizado; los niveles -O0/-O1/-O2/-O3 no existen.
CFLAGS=-O2 optimiza balc como programa C, no su salida VLIW. El comparador valida
la variante tradicional y publica PARCIAL sin porcentajes de optimización.
Rechaza imágenes idénticas presentadas como niveles distintos. Para incorporar
niveles reales se suministra un manifiesto con comandos, cortes justificados
y los mismos observables semánticos. Por ahora BALB con datos iniciales no
vacíos o entrada distinta de0 se rechaza explícitamente; no se pierde su DMEM.

### Verificación, límites y conclusión

La línea base y la entrega ejecutan las dieciocho órdenes obligatorias: todos
los códigos0. make sim pasa de65 a69 PASS sin FAIL/NO-COMPILA/SIN-CHEQUEO.
La pasividad real de top conserva60 capturas y8029914 comprobaciones, y el nuevo
banco de jerarquía contrasta activa/inactiva con exclusiva/NINE, MEM_DIV2/4
y control MODEL. La memoria final siempre se verifica contra gold previo.
Los tests D18 conservan N+3, anulación, cripto, resultado retenido y persistencia.
Los negativos verifican errores concretos de política, configuración, proveedor,
GPR, DMEM, contadores, ventanas, flush, binario/imagen viejos, duplicados,
tiempos y entradas distintas. Los logs no se silencian ni se cambian los
algoritmos protegidos para conseguir los resultados.

No se acredita síntesis física, frecuencia máxima, CDC para silicio ni una
superioridad universal de una política. #31 requiere al menos dos niveles reales
para cerrarse. La mutación histórica WB→ex_wb_valid continúa siendo equivalente
en este pipeline: no se inventa sensibilidad a una diferencia inexistente.
El apagado eliminó la primera evidencia temporal; se reconstruyeron base y
entrega y se repitieron las pruebas en almacenamiento persistente externo.

Reproducción y detalle por issue: [verificación del cierre](verificacion-cierre-javier.md).
Guion de defensa: [aporte de Javier](guion-defensa-javier.md).

## Cierre temporal por transacción y DCE productivo (#26, #31 y #38)

La rama `feat/javier-cierre-final-amat-ce1108` parte de `origin/develop` en
`4a16239ecf3ce36a34be7c53f99ab05e6edfcc76`. Este SHA identifica la base,
**no el último commit de entrega**. Los cambios siguen pendientes de revisión,
commit y publicación autorizados. No se modifican los algoritmos de cachés,
controlador, buffers, pipeline, ROM, ISA ni el repositorio de CE1108.

### Definiciones temporales y contrato de observación

El enunciado §5.2 y las Notas de Clase v0.4 §6.2 permiten calcular la media
ponderada sobre la MISMA población. Cada nivel conserva su denominador:

| Medida | Inicio y final | Población | Unidad |
|---|---|---|---|
| AMAT observado L1-D | Primer PRE estable del puerto arbitrado hasta clasificación sin stall, incluyendo el flanco final | Demandas K1-B completas y habilitadas íntegramente | Ciclos `clk` de servicio |
| AMAT observado de lecturas L2 | Flanco PRE con `l2_req && l2_gnt` hasta consumo PRE de `l2_rvalid` | Lecturas aceptadas, clasificadas y respondidas, sin pausa | Distancia de flancos `clk` |
| Latencia media RAM | PRE con `req_accept` hasta PRE con `ram_ready` | Transferencias exitosas completas sin pausa, separadas read/write | Distancia de flancos `clk` |
| Tiempo fallido RAM | Aceptación hasta `error_event` | Transferencias fallidas completas sin pausa | Distancia de flancos `clk`, fuera de la media exitosa |

Las medias L1/L2 satisfacen `ΣT/N = HR × media_hit + MR × media_miss` para
sus propias cohortes. Una clase vacía tiene media `null`; su contribución a la
ponderación es cero, sin multiplicar un `null` como si fuera una medición.
Una población vacía tiene tasas y media `null`/N/D. RAM no es caché: no tiene
hit/miss rate aplicable. Se conserva su utilización `busy/ciclos medidos`,
pero **no** se usa como latencia `busy/aceptaciones`.

No se suman medias L1+L2+RAM: los tiempos pueden solaparse y las solicitudes
L2 incluyen víctimas de línea completa. El AMAT observado L1 describe servicio
al puerto arbitrado, no persistencia de stores, espera previa del árbitro,
throughput, penalización media de CPU ni tiempo total de un programa.
La fórmula serial anidada del ejemplo6.2 exige otras hipótesis/poblaciones.

### Observador L2 pasivo

`perf_cache_l2_latency.sv` consume solo puertos públicos. El primer FIFO conserva
las aceptaciones de lecturas y escrituras; los eventos RH/RM/WH/WM clasifican
posteriormente la entrada más antigua. El segundo FIFO conserva exclusivamente
las lecturas clasificadas hasta su respuesta en orden. Clasificar un store no
fabrica un `rvalid`. Se procesa clasificación → respuesta → aceptación del flanco,
impidiendo que una nueva petición justifique una clasificación anterior huérfana.

Los FIFO de16 entradas superan las colas/etapas actualmente vivas del productor.
Un overflow, clasificación múltiple, tipo incorrecto o respuesta huérfana suma
error e invalida seguimiento hasta reset. No se adivina una asociación posterior.
Cada `req && gnt` cuenta una operación distinta, aunque los niveles/valores se
repitan. Una oferta retenida sin grant no inicia una transacción.
El contrato del productor garantiza el orden; sin IDs/datos en esta interfaz,
una permutación que parezca legal no puede identificarse solo con estos puertos.
Las pruebas funcionales L2 verifican por separado datos y orden de respuestas.
Una L2 futura fuera de orden requeriría IDs y otro contrato de observación.

El vector `[PERF_L2_LATENCY]` tiene14 campos en orden creciente:

| Índice | Contenido |
|---|---|
| 0,1 | Lecturas hit/miss completas y elegibles |
| 2,3 | Servicio acumulado de esas lecturas hit/miss |
| 4 | Suma `T_i−1` de lecturas elegibles; no es stall del CPU |
| 5,6 | Respuestas excluidas; errores de protocolo |
| 7,8 | Lecturas pendientes; solicitudes aún sin clasificación |
| 9,10 | Lecturas/escrituras aceptadas desde reset, incluso en pausa |
| 11,12 | Escrituras clasificadas; respuestas observadas, incluso en pausa |
| 13 | Lecturas pendientes que ya no son elegibles |

Las escrituras L2 son posted. No se mide un AMAT de escritura ni un tiempo de
actualización de arrays/persistencia a partir de aceptación o clasificación.
La interfaz observada no acredita inequívocamente el inicio de oferta de cada
store con identidad estable, por lo que esa latencia tampoco se publica.
Se conservan las tasas globales RH/RM/WH/WM y, separadamente, las tasas de la
cohorte de lecturas completas. No se mezclan sus denominadores.

### Observador RAM pasivo y fronteras de reloj

`perf_memory_latency.sv` asocia una única aceptación pendiente al éxito público
`ram_ready` o al fracaso `error_event`. No usa el nivel persistente `mem_error`
como otro error por ciclo ni estados privados de MC. `ram_ready` ya existe:
**no se modifica `mem_controller.sv` ni se añade un puerto al controlador**.
`mem_hierarchy.sv` solo deriva observaciones y publica dos vectores adicionales;
`top.sv`, los selectores `lcont`0–12 y su temporización quedan intactos.

Un `timeout_event` sin `error_event` inicia el único reintento del contrato actual.
El segundo timeout simultáneo con error termina el mismo acceso; no acepta ni
reintenta uno nuevo. El observador conserva tipo, fechas y número de intentos.
Esta inferencia debe revisarse si cambia la política de reintentos del productor.
Fallos y tiempos fallidos se publican aparte. Una pausa tampoco convierte un
fracaso en éxito ni en acceso nuevo.

MC publica su respuesta mediante NBA. La distancia entre aceptación PRE y
**consumo PRE** de esa respuesta es40 con DIV2 y54 con DIV4 en los ensayos
normales. El contrato nominal `TMEM=25+7×DIV` y busy dan39/53: se refieren a
otras fronteras. No se resta un ciclo para forzar el valor nominal. El banco
fecha los dos flancos independientemente, incluye CDC/reintentos reales y
contrasta un gemelo sin observador ciclo a ciclo. La referencia es siempre
`clk` general de100MHz, no `core_clk` ni ciclos de `clk_mem`.

El vector `[PERF_RAM_LATENCY]` tiene22 campos:

| Índice | Contenido |
|---|---|
| 0,1 | Éxitos completos elegibles read/write |
| 2,3 | Servicio de esos read/write |
| 4 | Espera exitosa `Σ(T_i−1)` |
| 5,6 | Fallos completos elegibles; servicio fallido |
| 7,8 | Éxitos/fallos excluidos |
| 9,10 | Timeouts de la cohorte exitosa/fallida |
| 11,12 | Reintentos de la cohorte exitosa/fallida |
| 13 | Errores de asociación/protocolo |
| 14,15 | Pendiente; pendiente elegible (0/1) |
| 16,17 | Aceptaciones/finales observados desde reset |
| 18,19 | Duración y tipo del último final observado (write=1) |
| 20,21 | Fechas de aceptación/finalización de ese último acceso terminado |

Los campos del último final no describen el inicio de la transferencia que aún
puede estar pendiente. No se fabrica una fecha final para completar una media.
El diagnóstico conserva identidad incluso mientras la ventana está apagada.

### Ventanas, reset y compatibilidad de datos

Reset síncrono tiene prioridad sobre todos los eventos y se comparte con el
productor. Reiniciar solo el observador con transacciones vivas pierde historia;
una respuesta huérfana es error, no acceso contado desde un inicio inventado.
Cada flanco deshabilitado invalida las operaciones pendientes. Las que empiezan
apagadas o atraviesan una pausa se siguen hasta su final y quedan excluidas,
aunque se reanude antes de responder. Un pendiente al corte no integra la media.
Los contadores primarios de servicio/completados no avanzan en pausa; los
**diagnósticos de seguimiento** sí. No son lecturas de `lcont` ni controlan al CPU.
Todos los tiempos y acumulados son64 bits; interpretar medias exige época sin wrap.

`PERF_ENABLE=0` elimina los observadores. MODEL1 y modos0/1 exportan vectores
cero y disponibilidad falsa: eso significa medida inexistente, no latencia cero.
El banco captura POST antes de cerrar la ventana y hacer el flush externo.
Las operaciones de mantenimiento posteriores se siguen, pero no se añaden a
las cohortes de ejecución capturadas.

`execution.json` conserva schema1 y observación2; agrega `temporal_schema=1`
solo cuando aparecen ambos marcadores nuevos. Un log histórico sin marcadores
conserva exactamente su objeto anterior. Un par incompleto/duplicado o un error
de protocolo se rechaza. El analizador publica schema2 y admite ambos tipos de
captura; los tiempos ausentes siguen `null`. Se corrigió la interpretación del
puerto K1-B: últimos campos **exclusiones, errores, pendiente**. La API antigua
de fixtures `l1_amat(..., wire_layout=False)` se conserva; las capturas reales
se leen siempre con `wire_layout=True`, comprobado sin cambiar los13 tests previos.

### Resultados nuevos en la referencia REAL exclusiva

Dos rondas nuevas de los tres benchmarks, misma imagen por par0/2, verifican
los32 registros,16384 palabras,96 operaciones lógicas y checksum1056 después
del vaciado. La matriz de nueve configuraciones se repite también en54 capturas
nuevas; las54 históricas se conservan y se releen, sin llamarlas ejecuciones nuevas.

| Programa | Ciclos (sin cambio) | AMAT L1 | Reads L2 completos | Servicio L2 | AMAT lectura L2 | RAM éxitos / aceptados | Servicio RAM exitoso | Media RAM |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Secuencial | 872 | 1 | 4 | 256 | 64 | 4/4 | 216 | 54 |
| Aleatorio | 2606 | 19.0625 | 32 | 2048 | 64 | 32/32 | 1728 | 54 |
| Stride | 10260 | 98.7916666667 | 96 | 9551 | 99.4895833333 | 178/179 | 9612 | 54 |

Las lecturas de estos tres ensayos son misses L2; media hit N/D. Los hits se
acreditan además en integración exclusiva/NINE y en la campaña de capacidad.
Stride registra96 reads y94 escrituras posted clasificadas en L2; sus190 eventos
no son el denominador de las96 respuestas. RAM tiene96 éxitos read y82 write,
con una escritura aún pendiente al corte: no se usan179 aceptaciones para la media.
Su busy histórico9443 incluye9 ciclos de esa pendiente; tampoco es servicio9612.
La diferencia64/99.49 no es un error del parámetro nominal: el stride incluye
colas y tráfico de víctimas/eviction buffer. No se suman latencias superpuestas.

### CE1108: dos variantes productivas verificadas

La copia local auditada está en `feat/i1a-integracion-vliw`, HEAD
`08c8701c7bc6e58461f54b69a90a1a6fe85d0145`; `origin/develop` local es7463123.
No se presenta esa rama como una versión oficial diferente ni se cambia a ella
remotamente. Los fuentes DCE del IDE son idénticos a `origin/develop`; el backend
utilizado se identifica por SHA/binario y sus módulos en cada captura.
`balc --dce/--unroll/--reorder` sigue siendo IR sin ASM productivo.
Pero `ide_dce_analizar` entrega `codigo_nuevo`: el IDE puede aplicar ese fuente
al backend normal. El diagnóstico anterior limitado a CLI era incompleto.

`ce1108_aplicar_dce.c` solo adapta esa API; no implementa DCE. `ce1108_dce.py`
consulta la receta de enlace `make -Bn tests/test_ide_dce`, la enlaza externamente
y registra comandos/hashes. La ruta pasada al IDE es la salida externa porque
la API crea temporales junto a esa ruta. No se escribe en Compiladores.
No se acredita `bring` a módulos locales ni datos BALB iniciales no vacíos.

El comparador admite `transform: "ide-dce"`, observables semánticos nombrados y
mapas de direcciones por variante. Las posiciones se derivan de `balc -m` y el
marco; cada estado completo se compara con M2 independiente y RTL0/RTL2. Entre
variantes se exigen los mismos valores semánticos, no igualdad de temporales.
Puntajes conserva resultado24, combinado13 y total37; la copia muerta de
`acumular(0)` desaparece, pero la llamada se mantiene. El ejemplo de funciones
conserva el arreglo de resultados `[cuadrado(4), suma_hasta(5)] = [16,15]`.

| Programa | Variante | Bundles estáticos | Instrucciones estáticas | Corte B5 (avances) | Ciclos RTL2 |
|---|---|---:|---:|---:|---:|
| Puntajes | tradicional | 801 | 267 | 2748 | 2748 |
| Puntajes | IDE-DCE | 795 | 265 | 2742 | 2742 |
| Funciones | tradicional | 528 | 176 | 6193 | 6193 |
| Funciones | IDE-DCE | 435 | 145 | 2176 | 2176 |

Son ocho ejecuciones RTL y cuatro sesiones M2, además de las tres referencias
tradicionales factorial/whale/puntajes (cortes3403/247/2748). Factorial y whale
no producen cambios con este DCE y se rechazan como supuestos niveles nuevos.
B5 se vuelve a ejecutar para las imágenes transformadas: retiro WB, corredor
NOP y ausencia de efectos previos pendientes. El pipeline permanece ACTIVO;
no se certifica semánticamente `main`, no hay HALT ni porcentajes denominados
speedup de una función. Las diferencias de ciclos son hasta cortes declarados.
No se inventan niveles -O ni se confunde CFLAGS=-O2 con optimización BAL.

### Reproducción y estado de cierre

Los destinos siguientes deben ser NUEVOS y externos. CE1108 se consulta en lectura:

```bash
make tb_perf_cache_l2_latency
make tb_perf_memory_latency
make tb_perf_amat_integracion
python3 -m unittest discover -s tests -p 'test_amat_temporal.py' -v
CE1108_ROOT="$CE1108_ROOT" python3 -m unittest discover -s tests -p 'test_ce1108_dce.py' -v
python3 tools/comparar_optimizaciones.py --compiler-root "$CE1108_ROOT" --ide-dce --output /tmp/p31-dce-nuevo
python3 tools/comparar_configuraciones.py --output /tmp/p30-temporal-nuevo --repeat 2
python3 tools/analizar_amat.py --report /tmp/p30-temporal-nuevo/comparaciones.json --output /tmp/amat-nuevo
```

`--ide-dce` prepara exclusivamente el snapshot y fuentes con B5 acreditado.
Otro commit requiere nuevos cortes/evidencia y `--manifest`; no se reutilizan
los horizontes por suposición. El informe externo conserva los comandos B5,
los símbolos, las capturas y los hashes. El PR68 sigue abierto; sus archivos
`memory-hierarchy.md` y `simulation.md` se conservan sin cambios. Sus presupuestos
nominales61/64 no sustituyen los tiempos por transacción/congestión medidos aquí.

**#26: completo en las métricas observables definidas** (L1, reads L2, RAM;
posted sin respuesta y tasas RAM no aplicables se explican, no se inventan).
**#31: comparación real completa en estos dos contrastes tradicional/IDE-DCE**;
no constituye una familia general -O ni garantiza equivalencia universal.
**#38: parcial**, preparación individual lista; faltan revisión colectiva,
presentación, integración/publicación autorizadas y entrega formal con SHA final.
La URL es https://github.com/fabrimena/Proyecto2_Arquitectura1 y el campo SHA
queda **PENDIENTE DE INTEGRACIÓN FINAL**, nunca4a16239 como sustituto de entrega.

En capacidad18KiB se verificaron además cuatro capturas nuevas (dos rondas):
exclusiva tiene576 lecturas L2 hit completas, servicio4608 y media8; NINE tiene
320 hit/256 miss completos, servicio18944 y media32.8888888889, ponderada como
`(320×8 + 256×64)/576`. RAM en NINE registra256 éxitos, servicio13824 y media54;
en exclusiva no hay transacciones RAM elegibles y la media es N/D. En ambos
hay576 respuestas L2 y576 éxitos RAM excluidos del calentamiento: son diagnóstico
desde reset, no operaciones recuperadas al reabrir `medir`. Los ciclos medidos
8639/22975 y el estado completo coinciden con la campaña histórica.
