# Issue #29 — Benchmarks independientes de memoria

Este documento describe tres programas VLIW y su infraestructura de reproducción.
Recibe ASM/expectativas versionados y las salidas del runner real; entrega
oráculos, comparaciones completas, estadísticas y evidencias externas. Depende
de Python, unittest, Icarus y los contratos #9/#28. No cambia ISA, pipeline,
compilador, cachés, políticas ni componentes D18. No implementa el issue #30.

## Alcance y estado inicial

Rama autorizada: `feat/29-benchmarks-memoria`.
HEAD conservado: `8b00af39b6580d05c07b24bb174d6ec17bc501b1`.
Se comprobaron cwd, rama, HEAD, diff normal/cached y archivos no rastreados;
árbol e índice limpios antes de crear archivos. No se ejecutó ninguna operación
de actualización, cambio de rama, integración, staging o publicación.

La arquitectura vigente es IF/ID/EX/WB con N+3, ROM síncrona y DMEM de 65536 bytes.
MEM_MODE=0 conecta memoria directa. MEM_MODE=2 conecta top → árbitro A/B → L1-D
→ **l2_model** → DMEM. La configuración efectiva que acredita el banco es
WB, WA, EXCLUSIVA, LRU, cuatro entradas WBUF, dos MSHR y bus versión2.
Los controladores/CDC/buffers existentes por separado no componen aquí una L2 real.
D18-A existe de forma independiente, pero sus instrucciones no se usan ni se conectan.

## Inventario exacto

Nuevos, trece archivos:

- `examples/bench_secuencial.asm`, `.expected.json`, `.memory.json`.
- `examples/bench_aleatorio.asm`, `.expected.json`, `.memory.json`.
- `examples/bench_stride.asm`, `.expected.json`, `.memory.json`.
- `examples/archivos/archivo18k.bin`.
- `tools/run_memory_benchmarks.py`.
- `tests/test_memory_benchmarks.py`.
- `docs/benchmarks-memoria-p29.md`.

Modificado: Makefile, solo para agregar `test-memory-benchmarks` y `bench-memory`.
No se necesita cambiar `docs/simulation.md`: no se agrega un banco SystemVerilog.
Los targets previos conservan recetas y dependencias; los benchmarks no se ejecutan
con `make sim`. No se modifican top, jerarquía, contadores, ensamblador, runner
original, testbenches anteriores, ejemplos previos ni archivos CE1108.

## Diseño comparable y temporización

Los tres tienen **868 bundles, 872 avances de horizonte, 32 stores y 64 loads**:

1. Escribir valores1..32 en 32 palabras distintas.
2. Leer las32 palabras en el mismo orden y acumularlas.
3. Repetir la lectura completa y su acumulación.
4. Escribir x7=1, dejar separación y permanecer en `sye x0,fin` a sí mismo.

Cada dirección se construye en x20 como `(direccion//1024)<<10`; el offset de
LSU es `direccion%1024` (0..1023). Así se respetan los inmediatos signed de 11 bits
incluso al llegar a 63488. sumai→shift y shift→LSU tienen dos bundles intermedios;
load→suma de checksum también. Cada fuente expresa cuatro slots y NOP explícitos.
El ensamblador original verifica slots, N+3, RAW/WAW, saltos y capacidad IMEM.

La fase de escritura usa siete bundles por palabra; cada lectura usa diez.
868 =32×7+64×10+4. El runner reserva cuatro avances adicionales para drenar
IF/ID/EX/WB. El corte872 se deriva de la longitud; no se amplió buscando PASS.
El salto final no escribe enlace y proporciona reposo útil ilimitado durante
mantenimiento, evitando que IMEM envuelva y reanude stores. El pipeline sigue
**ACTIVO**: no existe HALT ni se certifica retorno semántico de main.

## Patrones y direcciones

Cada programa realiza384 bytes de accesos lógicos (96×4) sobre 128 bytes útiles
(32 palabras únicas). No son 384 bytes de tráfico físico L1/L2/RAM.
`span_bytes` es max(dirección)−min(dirección)+4 e incluye huecos, no datos útiles.

| Patrón | Direcciones por pasada | Líneas de 32 B | Conjuntos | Extensión en bytes |
|:---|:---|---:|---:|---:|
| Secuencial | 4×i, i=0..31 | 4 | 4 | 128 |
| Aleatorio | Primera palabra de 32 líneas de una permutación | 32 | 28 | 3876 |
| Stride | 2048×i, i=0..31 | 32 | 1 | 63492 |

### Secuencial

Direcciones 0,4,…,124: ocho palabras por línea, cuatro líneas consecutivas.
Las dos pasadas de lectura reutilizan ese pequeño conjunto. Esta geometría
favorece localidad espacial y temporal; los hits no se deducen automáticamente
del patrón. La ejecución observó cero stalls globales con los stores MSHR vigentes.

### Aleatorio determinista

Semilla `0x29c0de`. Fisher-Yates recorre i=127..1 en una lista inicial 0..127.
Antes de cada intercambio actualiza `s=(1664525*s+1013904223) mod 2^32` y usa
j=s mod(i+1). Se toman las primeras32 líneas y se multiplican por 32. No depende
de random de Python ni de una semilla implícita. Hay una palabra por línea,
menor reutilización espacial que secuencial y a lo sumo dos líneas por conjunto.

Direcciones exactas, en orden de escritura y de cada pasada de lectura:

```text
0x0d00 0x00c0 0x0240 0x0c80 0x0980 0x04c0 0x0b00 0x0640
0x0580 0x01c0 0x0940 0x0ea0 0x0320 0x0e00 0x05c0 0x0f60
0x01e0 0x0f20 0x0100 0x0460 0x0380 0x0ec0 0x0300 0x0840
0x0b80 0x0880 0x0c00 0x0bc0 0x06c0 0x06e0 0x0040 0x0c40
```

También quedan en el encabezado ASM, oracle.json y summary.json externos.

### Stride y conflictos

Con líneas de 32 B y 64 conjuntos: índice=(dirección>>5)&63.
2048=32×64, por lo que todas las direcciones 0,2048,…,63488 tienen índice0 y
etiquetas 0..31 distintas.32 líneas compiten por dos vías. El experimento observó
814 stalls globales con esa secuencia; el diseño provoca competencia geométrica,
pero el reporte no inventa un número de misses sin una interfaz que los exporte.
Todas las palabras se mantienen dentro de DMEM y alineadas a cuatro bytes.

## Oráculos independientes

Antes de ejecutar se construyen32 GPR desde reset: x4=32, x5=32,
x6=2×sum(1..32)=1056, x7=1 y x20=base alineada a 1024 de la última dirección.
Los otros27 registros, incluido x0, deben seguir cero. x20 vale0/3072/63488
para secuencial/aleatorio/stride, respectivamente.

DMEM esperada empieza con 16384 palabras cero. En la dirección a[i] se escribe
i+1; ninguna otra palabra cambia. Las expectativas JSON contienen los32 GPR y
las32 palabras escritas. El comparador revisa además **todas las16384 palabras**,
no solo los campos del JSON ni hashes. Igualdad entre modos nunca reemplaza gold.

prepare_oracle interpreta estáticamente el subconjunto acotado de instrucciones
para contrastar fuente, direcciones, orden, valores y checksum con esas fórmulas.
No simula el pipeline ni lee estados del DUT. Una fuente alterada, aun si ensambla,
no puede redefinir silenciosamente el patrón o las expectativas de referencia.

La traza cruda acredita el orden PC/dirección/dato/máscara de los32 stores y los
valores1..32 dos veces en x5, además de observar el salto final. No se usan bytes
parciales: cada store debe llevar1111. Un control cambia la máscara y debe fallar;
las regresiones anteriores mantienen la cobertura funcional de guardab/cargabai.

**Límite de la traza heredada:** registra niveles durante freeze y wb_pc no es un
identificador fiable de retiro durante stall, pues se actualiza con clk general.
Solo para estas fuentes sin bucles útiles se colapsan stores adyacentes idénticos
y valores de x5 adyacentes repetidos. PCs de stores y valores de loads consecutivos
son distintos por construcción. No se usa ese procedimiento como contador físico
de escrituras aceptadas ni para programas arbitrarios. El avance hasta fin, checksum
y estado completo complementan la traza; duplicaciones físicas indistinguibles de
un nivel retenido requieren observación de aceptación, fuera de esta API protegida.

## Runner, frescura y reportes

La herramienta usa la API real run_program con MEM_MODE=0 y 2, trace=True,
vcd=False y ciclos872. Copia la misma fuente a un destino externo y la congela
para ambos modos. Cada programa/modo/ronda tiene directorio nuevo y elaboración
independiente; no se cachean binarios ni se aceptan destinos previos.

Se conservan execution.json, imagen/listado, binario, logs, GPR/DMEM y trazas.
El lector vuelve a verificar MEM_MODE, CACHE_CONFIG, FLUSH, finalización,
identidades de estadísticas, hashes/argv de elaboración y bytes de la imagen.
El control de mtime detecta archivos anteriores a la invocación; esa fecha solo
se usa para frescura, nunca para calcular rendimiento. Se exige estructura
completa y conocida de dumps. Solo después se publica summary.csv/summary.json.

`--repeat 2` crea doce ejecuciones independientes y exige igual estado y medidas
RTL por programa/modo entre rondas. run_id distingue reportes, sin sustituir la
reserva exclusiva de directorios. Los errores devuelven código1 y conservan
salidas parciales para diagnóstico; argparse usa2 para sintaxis inválida.

## Resultados reales con l2_model

Mismo horizonte872 y población96; la segunda ronda repite las medidas.
E son flancos de ejecución, S stalls globales y F mantenimiento, incluyendo
retorno del handshake. En todas las filas E=A+S. F no se suma a S.

| Benchmark | Accesos | Bytes lógicos / útiles | Modo | A | E | S | F | Arquitectura |
|:---|---:|---:|---:|---:|---:|---:|---:|:---|
| Secuencial | 96 | 384 /128 | 0 | 872 | 872 | 0 | 0 | Correcta y equivalente |
| Secuencial | 96 | 384 /128 | 2 | 872 | 872 | 0 | 131 | Correcta y equivalente |
| Aleatorio | 96 | 384 /128 | 0 | 872 | 872 | 0 | 0 | Correcta y equivalente |
| Aleatorio | 96 | 384 /128 | 2 | 872 | 926 | 54 | 263 | Correcta y equivalente |
| Stride | 96 | 384 /128 | 0 | 872 | 872 | 0 | 0 | Correcta y equivalente |
| Stride | 96 | 384 /128 | 2 | 872 | 1686 | 814 | 131 | Correcta y equivalente |

La preparación de direcciones, inicialización, NOP, checksum y salto final están
incluidos. No son tiempos puros del bucle de memoria. El aleatorio puede trasladar
trabajo al mantenimiento por stores non-blocking; observar solo E ocultaría eso.
No se usa reloj de pared ni se presenta una repetición determinista como evidencia
de significancia estadística. No se comparan políticas/configuraciones del #30.

Los contadores VLIW/etapas/K1-A/B existen en top, pero run_program no exporta
capturas de sus ventanas. Se reportan únicamente EXEC_STATS, sin introducir otro
mecanismo de lectura ni sumar mantenimiento a servicio de demandas cerradas.
No se publican hits/misses L2, IPC de una cohorte incompatible ni AMAT definitivo.

## Archivo de 18 KiB

`archivo18k.bin`: **18432 bytes**, todos los valores de byte aparecen.
LCG32 anterior, esta vez con semilla `0x18b00b5`; cada byte es s>>24 después de
actualizar el estado. No es una fuente criptográfica ni un archivo solo de ceros.
SHA-256:

```text
c98e65ae5a58f7925bdc75bd3325ff60603df3c7113f5852bcccc2784fd920c3
```

Reproducción sin escribir en el proyecto:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -c 'from pathlib import Path; from tools.run_memory_benchmarks import archive_bytes; Path("/tmp/archivo18k-repro.bin").write_bytes(archive_bytes())'
cmp examples/archivos/archivo18k.bin /tmp/archivo18k-repro.bin
```

Se ejecutó el flujo existente make archivo en copia externa, sin editar
`tb_archivo.sv`, aserciones, MAXCICLOS ni presupuestos: código0, siete verificaciones,
cifrado 46089 ciclos, descifrado 46089, recuperación idéntica de 18432 bytes por cmp.
Ese target usa MEM_MODE=0 por defecto; esta validación prueba archivo/Feistel4,
**no capacidad combinada L1-D/L2**. La suite #28 conserva sus pruebas pequeñas en 0/1/2.

## Pruebas y controles negativos

La suite unittest final contiene35 métodos (17 estáticos y 18 con preparación RTL),
sin skips. Prepara doce ejecuciones reales para dos rondas y seis adicionales
por CLI; no son 35 programas distintos. Acredita ensamblado, direcciones, población,
semilla, geometría, límites, N+3, IMEM, oráculos, ambas configuraciones, orden,
lecturas, archivos nuevos, CSV/JSON, identidades y repetibilidad.

Los negativos conservan las expectativas originales y mutan copias externas:
registro x31, última palabra0xfffc, imagen, dump truncado, modo, ausencia de FLUSH,
estadística incoherente y archivo obsoleto. Se añaden gold alterado, patrón aleatorio,
stride, violación N+3, capacidad, orden/máscara de stores, dato de carga,
configuración NINE en marcador y reportes adulterados/duplicados.
Cada prueba exige la causa exacta; un ejecutable ausente, timeout, error de lectura
o compilación no cuentan como detección. No se altera RTL para fabricar fallos.
Con P29_EVIDENCE_DIR se conservan copias de mutaciones estáticas y dinámicas.

## Regresiones antes/después

Se ejecutan en dos copias externas de HEAD, aplicando solo los cambios autorizados
a la segunda. El detalle de comandos/códigos/tiempos queda en evidencia persistente.

| Comando | Línea base | Entrega | rc antes/después |
|:---|:---|:---|:---:|
| make sim | 58 PASS | 58 PASS | 0/0 |
| make test-assembler | 58 métodos | 58 métodos | 0/0 |
| make test-programs | 14 métodos | 14 métodos | 0/0 |
| make test-memory-modes | 16 métodos | 16 métodos | 0/0 |
| make archivo | 7 verificaciones;386 bytes idénticos | Igual | 0/0 |
| make tb_mem_hierarchy | 43 verificaciones | Igual | 0/0 |
| make tb_perf_integracion_top | 3654774 verificaciones;60 capturas | Igual | 0/0 |
| make tb_perf_cache_l1d_k1a | 247770 verificaciones | Igual | 0/0 |
| make tb_perf_cache_l1d_k1b | 979004 verificaciones | Igual | 0/0 |
| unittest test_flush_tools.py (#28) | 10 métodos | 10 métodos | 0/0 |

make sim no presenta FAIL, NO-COMPILA ni SIN-CHEQUEO. Las advertencias de Icarus
se conservan en los logs sin añadir supresiones. No se modifican expectativas
previas para conseguir PASS ni se presentan resultados históricos como nuevas ejecuciones.

## Reproducción

Ejecutar desde una copia externa del código con los cambios de trabajo, no desde
la carpeta original si el target produce build/. La evidencia debe ser NUEVA:

```bash
# En la copia externa:
PYTHONDONTWRITEBYTECODE=1 make test-memory-benchmarks
PYTHONDONTWRITEBYTECODE=1 P29_EVIDENCE_DIR=/tmp/p29-suite-nueva make test-memory-benchmarks
make bench-memory BENCH_OUTPUT=/tmp/p29-resultados-nuevos BENCH_REPETITIONS=2
make archivo ARCHIVO=examples/archivos/archivo18k.bin
```

Los binarios/dumps/logs siempre pertenecen a destinos únicos externos del runner.
No se aceptan reportes preexistentes. Para repetir, elegir otras rutas; no es
necesario borrar archivos ni usar git clean. El target test es independiente.

## Auditoría R2–R2.2 e integridad

Cada ASM tiene encabezado de propósito/entrada/salida, direcciones, población,
localidad, resultados, temporización, reposo y límites; cada fase comenta la
propiedad que comprueba. Los seis JSON no admiten comentarios: su contrato se
explica aquí y se valida con referencia completa previa al DUT.
El binario documenta algoritmo/semilla/tamaño/hash y reproducción en esta sección.
El runner documenta cada dataclass/función, ownership, errores, oráculo, freeze,
fronteras, frescura y limitaciones. Cada prueba describe preparación, estímulo,
resultado esperado y defecto detectado; los negativos explican mutación y causa.
Makefile solo explica targets y destino externo, sin separadores ornamentales.

El manifiesto inicial registra433 archivos de Arquitectura. Solo Makefile cambia;
los otros432 archivos anteriores se conservan por SHA-256. El manifiesto final incluye también tamaño y permisos.
Se agregan13 archivos autorizados, sin borrar ninguno. Índice, HEAD y referencias
del proyecto se conservan. Se contrasta también Compiladores por hash, sin escribir
allí ni restaurar posibles cambios de otra sesión.

Evidencia persistente: `/home/javier/Documentos/evidencias-arquitectura-p29-8b00af3-r8vzl258`.
Incluye informe final, diff completo (también binario), inventario/hashes,
auditoría individual, comandos/rc/tiempos, logs, oráculos, trazas, CSV/JSON,
execution.json por ejecución, fuentes y resultados del archivo18k. Las rutas
originales de argv bajo `/tmp/p29-r8vzl258` se conservan como procedencia; el
paquete indica su correspondencia con las copias persistentes, sin reescribirlas.

## Limitaciones y trabajo pendiente

- No hay L2 definitiva integrada ni garantía de exclusión global entre dos cachés reales.
- No se valida capacidad20KiB, PLRU L2, RAM a 25MHz, CDC ni AMAT jerárquico.
- Los bytes útiles/extensión/logical_bytes describen poblaciones distintas del tráfico físico.
- No se conecta D18 ni se cambia top para leer contadores. Falta exportar ventanas compatibles.
- La traza deduplicada es específica de estos programas, no prueba universal de retiros o writes físicos.
- El tiempo total incluye preparación y mantenimiento separado; no representa una mejora estadística.
- Las políticas y comparaciones del #30, BAL completo y D18-B quedan fuera de este alcance.

Al integrar L2 real habrá que confirmar persistencia de flush_done, horizonte y
límites legítimos de espera con sus responsables y volver a ejecutar estas mismas
fuentes/oráculos. No se aumenta un presupuesto automáticamente para ocultar fallos.

## Propuesta de commit

Título: `feat: agregar benchmarks reproducibles de memoria VLIW`

Descripción propuesta, sin crear commit:

```text
Agregar benchmarks secuencial, aleatorio determinista y stride conflictivo
con igual población de 32 stores y 64 loads, N+3 y reposo útil antes de flush.

Preparar oráculos independientes de 32 GPR y 65536 bytes, validar trazas,
modo efectivo e imágenes iguales y conservar execution.json por ejecución.
Publicar CSV/JSON con avances, flancos, stalls y mantenimiento separados.

Agregar archivo binario determinista de 18 KiB, suite con 35 métodos y
controles negativos sobre copias externas; incorporar targets independientes.
Documentar reproducción, comentarios R2–R2.2 y límites de l2_model.

Validar dos rondas de benchmarks, archivo recuperado byte a byte y todas
las regresiones anteriores sin cambiar RTL, ISA ni expectativas existentes.

Relacionado con #29. Sin L2 definitiva, comparaciones #30 ni D18-B.
```
