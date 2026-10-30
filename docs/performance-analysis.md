# Análisis de rendimiento — Proyecto II

## Issue #7, bloque A: contador de ciclos

`rtl/perf_counters.sv` es un módulo independiente, todavía sin conexión al
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

`rtl/perf_slot_mask.sv` recibe `bundle_in[127:0]` y produce
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

`tb/tb_perf_slot_mask.sv` usa las utilidades autoverificables existentes. Las
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
