# D4-A: recuperación de saltos sobre el procesador real

## Objetivo y alcance

Validar una atribución temporal de ciclos perdidos por BRU en `MEM_MODE=0`.
El testbench externo `tb-p2/tb_perf_branch_d4a.sv` instancia el procesador real,
D1, D2 y los contadores A–C. Una segunda instancia del procesador, REF, permite
contrastar la pasividad de la instrumentación. No hay conexión de producción
ni cambios de ISA, pipeline, política de recuperación, memorias o cachés.
D4-B y D5 quedan pendientes.

## Estado y contratos inspeccionados

Rama `feat/7-d4a-recuperacion-saltos`, creada desde `origin/develop` después de
`git fetch origin develop`. Base y HEAD conservado:
`85acb5e3dcd9d3c7e790248d3299fe439a9b6eb1`, incorporación de D3.
Origin apunta a `fabrimena/Proyecto2_Arquitectura1`; árbol e índice estaban
limpios. No se incorporaron ramas antiguas ni cambios adicionales del equipo.

Se contrastaron `rtl-p2/top.sv`, `perf_counters.sv`, `perf_slot_mask.sv`,
`perf_pipeline_monitor.sv`; `rtl/pc_branch.sv`, `pipeline_if_id.sv`,
`pipeline_id_ex.sv`, `pipeline_ex_wb.sv`, `bru.sv`, `isa_defs.sv`, `fetch.sv`,
`instruction_memory.sv`; los testbenches de D3, monitor, contadores y stalls;
y `performance-analysis.md`, `perf-d3-validacion-top.md`,
`memory-interfaces.md`, `simulation.md`. Los comentarios se contrastaron con
asignaciones, prioridades y flancos efectivos del RTL.

## Hechos observados: señales y control reales

| Señal | Contrato utilizado |
|---|---|
| `clk`, `reset` | Reloj general y reset síncrono común de ambas instancias y métricas. |
| `core_en`, `core_clk`, `cache_stall` | En modo 0 se verifica avance permanente, reloj del núcleo igual al general y stall cero. |
| `id_valid`, `id_pc`, `id_bundle` | Bundle de ID antes del flanco; clasificación D1 separada de la validez. |
| `id_ex_valid`, `ex_pc` | Bundle de EX donde se resuelve BRU; no inferir validez de su palabra. |
| `bru_branch_flush`, `branch_flush`, `bru_target_pc` | Decisión combinacional de BRU y destino, no duración de recuperación. |
| `crypto_fault` | Excepción de privilegio en EX; suprime BRU y anula todo el bundle culpable. |
| `redirect`, `redirect_pc` | Salto o excepción; el destino de excepción gana y es `TRAP_VECTOR`. |
| `ex_wb_valid` | Validez real de WB; puede ser NOP y no habilitar ningún puerto GPR. |
| `bundle_complete`, `wb_mask` | Salidas de D2 consumidas antes del flanco por los contadores. |

El salto se acepta en R si `!reset && core_en && id_ex_valid && branch_flush
&& redirect && !crypto_fault`. No basta una transición del PC ni detectar el
flanco de subida de `branch_flush`. El mismo PC puede ejecutar varios saltos
dinámicos; sus identidades y visitas se conservan por separado.

`top` conecta `redirect` al vaciado de IF/ID y de ID/EX, y al PC. EX/WB conserva
el salto y el WB previo puede finalizar en R. Ante excepción se anula también
EX al ingresar en WB; no se anula el WB viejo. La BRU ya recibe sus indicadores
suprimidos por `crypto_fault`, incluso con un jump dentro del bundle culpable.

## Regla verificada: definición del ciclo perdido

La unidad de atribución elegida es **una oportunidad de EX vacía por descarte
BRU**, consumida en el flanco que termina ese intervalo. No significa que todo
el procesador esté inactivo, ni que ese flanco no pueda completar un bundle.

Si R acepta un salto, los huecos EX atribuibles aparecen antes de R+1 y R+2.
La señal diagnóstica se estabiliza antes de esos dos flancos y el contador la
consume allí. R no suma penalización por el salto que todavía está ejecutando.
No se cuenta la burbuja más tarde cuando llegue a WB ni se retrasa la entrada
para hacer coincidir un acumulado. Esta convención identifica la ocupación EX;
una convención basada en huecos WB desplazaría las fechas y no es la usada aquí.

| Flanco | Estado antes del flanco | Efecto después de NBA | Penalización consumida |
|---|---|---|---:|
| R | EX=salto, ID=joven 1, IF=joven 2, WB=anterior si existe | PC=destino; ID y EX inválidos; WB=salto | 0 |
| R+1 | EX=hueco 1, ID inválido, IF=destino; WB=salto válido | ID=destino; EX=hueco 2; WB inválido | 1 |
| R+2 | EX=hueco 2, ID=destino, WB inválido | EX=destino; ID=siguiente; WB inválido | 1 |
| R+3 | EX=destino, WB inválido | WB=destino, salvo excepción | 0 |
| R+4 | WB=destino válido | Destino consumido como finalización | 0 |

Los dos ciclos son un resultado contrastado contra validez, PC y fechas reales,
no una sustitución del experimento por `2 * saltos`. Los saltos consecutivos
legales pueden aceptarse en R y R+3: el segundo destino es otro salto en EX,
y ambas parejas de huecos quedan separadas.

## Método diagnóstico y referencia independiente

El diagnóstico tiene dos marcas locales de posiciones descartadas:
`discarded_id` para el hueco producido en IF/ID y `discarded_ex` para el que
ocupa EX. En un salto aceptado se marcan ambas; en el siguiente avance se
transporta la primera hacia EX. `branch_recovery` exige marca EX, invalidez EX
real, avance y ausencia de reset. No lee las causas del monitor D2 para generar
la señal y no mira el contenido cero del bundle. La medición no controla las marcas.

La referencia usa otro procedimiento: PC de IF predicho desde cero, tablas de
palabras/máscaras/decisiones/destinos declaradas por programa, visitas dinámicas
y fechas de finalización n+3. No toma el PC del DUT como próximo PC esperado.
El programa predice el salto en EX a partir de su identidad y visitas; reserva
las fechas R+1/R+2, anula las dos posiciones jóvenes y comprueba su invalidez
real. La excepción cancela además la fecha de EX sin reservar recuperación BRU.
Se verifican máscaras, causas D2 y los cinco acumulados completos de 64 bits.
Los valores esperados no proceden del diagnóstico ni de los acumulados observados.

Antes del flanco se esperan 4 ns de estabilización; después se espera 1 ns para
NBA. PRE describe entradas consumidas y acumulados anteriores; POST presenta
salidas registradas. `penalizaciones_esperadas` en ambas filas es el total
esperado **después** del flanco indicado. Los campos `*_ref` conservan la
identidad WB y causa EX muestreadas antes del flanco. Una divergencia conserva
ambas filas, imprime el primer caso/época/ciclo y termina con `$fatal(1)`.
No se utiliza `force` ni se escriben GPR, controles o registros del pipeline.
Solo se preparan IMEM/DMEM durante reset con el reloj bajo.

## Programas dirigidos y métricas observadas

| Caso | Horizonte | Ciclos medidos | Bundles | Instrucciones | Penalización BRU |
|---|---:|---:|---:|---:|---:|
| 1: sye adelante, WB previo y jóvenes ALU/store | 14 | 14 | 9 | 3 | 2 |
| 2: igualno x0,x0 falso | 12 | 12 | 9 | 2 | 0 |
| 3: destino es otro sye | 14 | 14 | 7 | 3 | 4 |
| 4: cuatro decrementos, tres saltos atrás | 36 | 36 | 27 | 9 | 6 |
| 5: NOP antes, jóvenes NOP y destino NOP | 12 | 12 | 7 | 1 | 2 |
| 6: excepción cripto con BRU en el culpable | 8 | 8 | 2 | 1 | 0 |
| 7: medir solo 1–4, recuperación fuera | 12 | 4 | 1 | 1 | 0 |
| 8: medir solo 5–6, salto fuera | 12 | 2 | 1 | 1 | 2 |
| 9: pausa en 6 y reanudación | 12 | 11 | 7 | 3 | 1 |
| 10: pausa en 5 y reanudación | 12 | 11 | 6 | 2 | 1 |
| 11: ventana vacía, seguimiento activo | 12 | 0 | 0 | 0 | 0 |
| 12: antes de reset, horizonte termina en R | 4 | 4 | 1 | 1 | 0 |
| 12: reset con dos marcas pendientes | 0 | 0 | 0 | 0 | 0 |
| 12: nueva época después de reset | 8 | 8 | 3 | 2 | 2 |
| 13: secuencial, ALU N+3 y NOPs | 14 | 14 | 11 | 2 | 0 |
| 14: horizonte termina en R+1 | 5 | 5 | 2 | 2 | 1 |

En todos los casos `memory_stall_count=0`. El IPC se calcula solo en simulación,
con conversión real: instrucciones/ciclos medidos. Ventanas de cero ciclos
producen **NO DEFINIDO**, sin dividir por cero. NOPs, arranque y límites de ventana
afectan IPC: no se atribuye toda su disminución exclusivamente a BRU.

En el caso 1 el salto de PC16 a PC80 se acepta en 4; recuperación en 5 y 6;
el NOP del destino finaliza en 8. El anterior x2=77 sobrevive, el enlace es 32,
x3=55 se ejecuta y x20/x21 y los stores de los jóvenes no tienen efecto.
El caso 3 acepta saltos en 3 y 6. El bucle toma el PC96 en 9, 15, 21 y sale no
tomado en 27: son cuatro ejecuciones distintas del mismo PC.

## NOPs, excepción y WB anterior

Un NOP válido tiene validez uno y máscara cero: completa un bundle, cero
instrucciones y ninguna penalización. Si un NOP joven es descartado por un salto,
la posición vaciada pasa a ser una burbuja causal de recuperación; no se cuentan
sus bits cero como criterio. Se preserva esa distinción en el caso 5.

En el caso 6 el bundle culpable está en PC16: ALU, store, jump y FSL sin AUTH.
En el flanco4 la excepción impone TRAP_VECTOR, anula EX y jóvenes, conserva
x2=77 del WB previo, no escribe el enlace ni el par cripto y mantiene DMEM[4].
`trap_count=1`, `trap_pc=16`, BRU efectiva inactiva y penalización BRU cero.
El NOP del vector completa antes del final del horizonte 8. IMEM es circular;
no se extiende este caso hasta volver a ejecutar el culpable por alias de dirección.

El WB previo completa en el mismo R; el salto completa en R+1 mientras EX
está recuperándose. Por eso no se exige `!bundle_complete` para atribuir un
ciclo de recuperación. Las comprobaciones por fecha y serie excluyen bundles
anulados y duplicaciones, sin usar escrituras GPR como instrucciones completadas.

## Ventanas, reset y horizonte

Las marcas siguen los eventos aun con `measure_enable=0`. El contador solo
consume los huecos que coinciden con flancos habilitados; los ignorados no se
encolan ni se recuperan al reanudar. Los casos 7–11 verifican ambas fronteras,
pausas en cada hueco y ventana vacía. Reset cancela marcas y acumulados de forma
prioritaria, con medición activa. La nueva época vuelve a llenar el pipeline.
El horizonte truncado en R o R+1 produce cero o una penalización respectivamente,
sin contar el futuro pendiente ni exigir artificialmente dos por evento.

## Comparación arquitectónica y cobertura

DUT y REF reciben iguales programa, DMEM, reloj, reset y horizonte. Se comparan
antes de cada flanco activo los cinco puertos GPR, ambos puertos DMEM y las
redirecciones; después de NBA, los 32 GPR, PC, ESTADO público y trap_pc/trap_count.
En 16 puntos se comparan las 16384 palabras de DMEM por igualdad real (65536 bytes),
sin sustituirla por hashes. El patrón inicial de memoria no es uniforme.
No se consulta la bóveda privada ni se afirma equivalencia semántica universal.

Cobertura normal: 14 escenarios, 15 saltos aceptados, 1 excepción, 27 flancos de
recuperación observados, 72 NOP completados y 6 flancos de recuperación fuera de
ventana. No debe aplicarse `15 * 2` al total27: hay un reset en R y un horizonte
que termina en R+1. Los acumulados se verifican por época y ventana.

## Adversariales y controles negativos

| Riesgo | Comprobación que lo detecta |
|---|---|
| Penalización adelantada/retrasada/duplicada/omitida | Igualdad de recuperación PRE por fecha y acumulado POST en cada flanco. |
| No tomado o excepción atribuidos a BRU | Decisión dirigida y fechas sin recuperación; casos2 y 6. |
| NOP confundido con burbuja | Validez por fecha, máscara cero y NOP completado; casos1,5,13. |
| Anulado contado o WB antiguo perdido | Evento WB, serie y máscara por fecha; efectos jóvenes anulados en casos1/6. |
| Reset pendiente o reanudación duplicada | Caso12 y ventanas7–11; acumulados y marcas posteriores. |
| PC repetido confundido con evento | Visitas y serie dinámica del bucle, caso4. |
| Destino incorrecto | Target dirigido, PC IF predicho y PC posterior a cada flanco. |
| Recuperación futura fuera del horizonte | Casos12/14, acumulados parciales conocidos. |
| Diferencia arquitectónica | Comparaciones PRE/POST y DMEM completa. |
| Control con EX inválido | BRU/fault contra tabla, validez real y recuperación atribuida. |
| Penalizaciones mayores que tiempo medido | Comparación de 64 bits y límite branch_cycles<=cycles en todos los flancos. |

Ocho variantes `+mutacion=1..8` corrompen únicamente la salida diagnóstica local:
adelanto, retraso, ciclo adicional, omisión, no tomado, excepción, NOP y ventana
aplicada indebidamente al seguimiento. No alteran el RTL, no hacen force y no
son modalidades válidas de medición. Las ocho deben fallar: VVP termina con 1.
Sus primeras divergencias son respectivamente caso/ciclo:
1/4,1/5,1/4,1/5,2/4,6/4,1/7,7/5. Esto comprueba sensibilidad de la referencia;
no significa que se inyectaron todos los 18 defectos posibles en el hardware.

## Regresiones, trazas y reproducción

Icarus Verilog/VVP 12.0 y flags oficiales del Makefile, sin cambios.
D4-A normal y con `+vcd`: **12573 verificaciones correctas**, código 0.
CSV con 404 filas PRE/POST y 34 campos; VCD de señales públicas seleccionadas.
No se vuelca la jerarquía completa de CRYPTO. Artefactos solo en copia externa.

| Comando | Antes / después | Código antes / después |
|---|---|---|
| make tb_perf_counters | 292 / 292 verificaciones | 0 / 0 |
| make tb_perf_slot_mask | 4299 / 4299 | 0 / 0 |
| make tb_perf_pipeline_monitor | 9981 / 9981 | 0 / 0 |
| make tb_perf_top_d3 | 13717 / 13717 | 0 / 0 |
| make tb_pipeline_stall | 50 / 50 | 0 / 0 |
| make tb_l1d_replacement | 17 / 17 | 0 / 0 |
| make tb_l1d_write_buffer | 14248 / 14248 | 0 / 0 |
| make tb_l1d_cache | 79 / 79 | 0 / 0 |
| make sim | 29 / 30 PASS; cero FAIL, NO-COMPILA, SIN-CHEQUEO | 0 / 0 |
| make test-assembler | 44 / 44 métodos (21+13+4+6) | 0 / 0 |
| make test-programs | 14 / 14 métodos | 0 / 0 |

Para reproducir sin escribir artefactos en el repositorio original, copiar el
proyecto completo a un directorio temporal fuera de ambos repositorios, incluidos
estos dos archivos nuevos. Desde esa copia ejecutar los once comandos de la tabla y:

```bash
make tb_perf_branch_d4a
make tb_perf_branch_d4a PLUSARGS=+vcd
# Control negativo: debe devolver error; conserva sus evidencias en otro directorio.
make tb_perf_branch_d4a PLUSARGS=+mutacion=1
```

El Makefile descubre automáticamente el nuevo testbench. CSV y VCD se generan
en `build/tb_perf_branch_d4a` de esa copia. La intervención conserva fuera de
ambos repositorios los logs/códigos, manifiestos SHA-256 y un informe A–X.

## Divergencias y limitaciones

La primera ejecución de desarrollo falló antes del primer reset por una salida
diagnóstica no inicializada: el bloque `always @(*)` no había sido evaluado.
Se corrigió únicamente el nuevo testbench usando `always_comb`, que se evalúa
al inicio. No se debilitó una aserción ni se modificó un componente protegido.
No quedan divergencias en los casos normales ensayados.

El contrato de dos huecos se ha verificado con memoria directa, fetch
combinacional y avance conjunto. No cubre ROM síncrona, pipeline distinto,
clock gating con stalls, integración L1-D/L2 ni todas las instrucciones/programas.
Las regresiones de caché y stalls son pruebas previas independientes, no evidencia
de que D4-A integre métricas con ellas. Los nombres y acuerdos de interfaces
futuras deberán revisarse de nuevo con el equipo.

## Requisitos pendientes de D4-B

Requiere coordinación con Fabricio cualquier modificación de `top`, registros
del pipeline, congelamiento o interfaz de memoria. Confirmar clk general/reset,
control externo de ventana, advance efectivo estable antes de flanco, validez y
máscara ID, evento/máscara WB únicos, aceptación de redirección y prioridad de
excepción. No conectar `redirect` ni `branch_flush` directamente al contador de
ciclos perdidos. Si se adopta la atribución EX, transportar causas y preservar
las marcas aunque se deshabilite la medición, contrastando contra este contrato.
D4-A ofrece diagnóstico validado en TB; su traslado a producción no está autorizado.

## Requisitos pendientes de D5

Comprobar `MEM_MODE=1` y posteriormente la jerarquía real: recuperación pendiente
retenida durante stalls, clk frente a core_clk, no consumo de una posición si no
hay avance, finalización única al reanudar y memoria prioritaria frente a BRU.
Confirmar con Fabricio y responsables de memoria los eventos, buffers pendientes,
reset con núcleo congelado y ambos puertos. No equiparar ocupación de un buffer
con stall sin validar el contrato; no asumir MEM_MODE=2 operativo: el top actual
solo distingue explícitamente modo1 y un else de memoria directa.
No se implementa ni valida esa lógica aquí.
