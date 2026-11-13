# Contadores de ocupación y congelamiento por etapa — issue #8

Este monitor pasivo observa IF/ID/EX/WB. Recibe validez y avance del productor;
no controla el procesador, no genera stalls ni deduce finalizaciones. Se desarrolla
en `feat/8-contadores-etapas-pipeline`, desde `origin/develop`
`7d06431353844a743f20aa8c47b8b27d15ee38db`. Solo se agregan el módulo, su banco
de pruebas y este documento. La integración dentro de `top` queda pendiente.

## Contrato de medición

Cada flanco positivo de `clk` con `!reset && measure_enable` observa el estado
**anterior al flanco**. El bit de validez significa presencia de un bundle, incluso
si todos sus slots son NOP. No significa instrucción útil ni retiro.

Los índices son 0=IF, 1=ID, 2=EX, 3=WB; cada salida por etapa es un vector
empaquetado `[3:0][63:0]`. Todos los valores son unsigned, en ciclos del reloj general.

| Salida | Definición por flanco habilitado |
|---|---|
| `measured_cycles` | Aumenta una vez, haya avance o congelamiento. |
| `occupied_cycles[s]` | Aumenta si la etapa s es válida antes del flanco. |
| `bubble_cycles[s]` | Aumenta conceptualmente si s es inválida; se deriva como total menos ocupados. |
| `stall_cycles[s]` | Aumenta si `core_advance=0`, incluso con una burbuja. |
| `stalled_occupied_cycles[s]` | Aumenta si s es válida y `core_advance=0`. |

El congelamiento es global: las cuatro salidas `stall_cycles` son copias del
mismo registro. No representan cuatro causas independientes ni deben sumarse.
Ocupación y congelamiento se superponen; ocupados más stalls no es el total.
Sin desbordamiento: ocupados+burbujas=medidos, stalls<=medidos y
ocupados_congelados<=stalls. Se conserva solo el estado necesario: diez registros
de 64 bits (total, congelamiento global y dos registros por etapa).

`reset` es síncrono y prioritario, incluso con medición deshabilitada o sin avance.
`measure_enable=0` conserva todos los acumulados; al reanudar solo cuentan los
nuevos flancos. El módulo no transporta metadatos: su productor debe seguir
actualizándolos durante las pausas de medición.

Las entradas deben ser binarias conocidas y estar estables antes del flanco.
Los registros se actualizan mediante NBA; las salidas derivadas se estabilizan
después. El banco comprueba después de NBA, sin usar las señales posteriores
como si fueran la entrada consumida. Los cálculos son módulo 2^64: las identidades
algebraicas son modulares, pero las desigualdades dejan de ser garantías tras wrap.
No se agrega divisor, saturación ni registro para una causa que el núcleo no expone.

## Correspondencia con el procesador

`clk` sigue activo durante las esperas; `core_clk=clk & core_en` puede detenerse.
`core_en` retiene `!cache_stall` durante la fase baja de clk. Se muestrea ese
valor anterior al flanco, que decide si habrá un pulso real del núcleo.

IF utiliza `fetch_valid`, ID `id_valid`, EX `id_ex_valid`. WB utiliza `wb_valid`
del `perf_pipeline_monitor` independiente, conectado a clk y core_en. La máscara
proviene de `perf_slot_mask`. Una escritura GPR o la validez del carril ALU no
es el contrato universal de ocupación WB: stores, NOP y operaciones cripto también
ocupan un bundle. Aunque algunas señales coincidan en esta versión, la prueba
no construye ese contrato a partir de escrituras del banco.

La ocupación describe presencia, antes de aplicar la redirección de ese flanco.
Un bundle en EX que causará una excepción puede estar ocupado y luego quedar
anulado, sin llegar válido a WB. Un salto tomado conserva su propio bundle y
descarta las posiciones jóvenes; la excepción además anula al culpable. La
contabilidad no llama salto a una excepción ni reconstruye una penalización fija.

En el top actual, IF entrega siempre una posición válida fuera de reset; no hay
un fin de programa que la vuelva inválida. Su burbuja fuera de reset se verifica
con entradas sintéticas independientes, sin inventar un fin en el procesador.

`rom_sync` precarga con `next_pc` en el mismo flanco en que cambia PC. Con
ROM_SYNC=1 el bundle durante el ciclo sigue correspondiendo al PC actual, sin
añadir una etapa. Se contrasta con ROM_SYNC=0. Durante un congelamiento ambos
permanecen retenidos.

## Verificación

El banco instancia seis parejas de `top`. CPU recibe las conexiones de observación
y SHADOW ejecuta los mismos estímulos sin ellas. La instrumentación de prueba es
externa; este trabajo **no instancia el monitor dentro de top**. Las compilaciones,
trazas, ondas y controles negativos se guardan fuera del repositorio. Nunca se
modifica Makefile ni se generan binarios en el árbol original.

## Interfaz y almacenamiento

| Entrada | Ancho | Responsabilidad del productor |
|---|---:|---|
| `clk` | 1 | Reloj general, activo durante las esperas. |
| `reset` | 1 | Reset síncrono común; no es una pausa. |
| `measure_enable` | 1 | Habilitación de la ventana, estable antes del flanco. |
| `core_advance` | 1 | Permiso efectivo de avance global de ese flanco. |
| `if_valid` | 1 | Presencia válida en IF, aun si se descartará al redirigir. |
| `id_valid` | 1 | Presencia en el registro IF/ID antes del flanco. |
| `ex_valid` | 1 | Presencia del bundle completo en ID/EX. |
| `wb_valid` | 1 | Validez transportada del bundle completo que reside en WB. |

Las salidas `occupied_cycles`, `bubble_cycles`, `stall_cycles` y
`stalled_occupied_cycles` tienen cuatro elementos de 64 bits; el índice selecciona
etapa, no slot ISA. `measured_cycles` tiene 64 bits. No hay puertos de control
hacia el procesador ni referencias jerárquicas en el módulo de producción.

Se registran total y congelamiento global, cuatro ocupaciones y cuatro
ocupaciones congeladas. Burbuja y stall por etapa son conexiones derivadas. Esto
evita cuatro registros redundantes de burbujas y tres copias registradas del stall.
Las restas combinacionales tienen ancho fijo; no se agregó un divisor ni una FSM.

## IF, ID, EX y WB

| Etapa / índice | Fuente externa en el testbench | Qué significa su ciclo ocupado |
|---|---|---|
| IF / 0 | `CPU.fetch_valid` | Existe el bundle de fetch antes de aceptar una posible redirección. |
| ID / 1 | `CPU.id_valid` | El registro IF/ID conserva un bundle válido. |
| EX / 2 | `CPU.id_ex_valid` | El bundle ocupa EX, incluso si este ciclo determina una excepción. |
| WB / 3 | `METADATA.wb_valid` | Un bundle completo llegó válido a WB; no exige una escritura GPR. |

En el RTL actual, `EX_WB.valid_in = id_ex_valid && !crypto_fault`, por lo que
`ex_wb_valid` puede coincidir temporalmente con la validez del monitor. Sin embargo,
ese registro transporta los datos de ALU: no se adopta como contrato general para
los otros slots. La mutación 11 prueba el proxy incorrecto de una escritura ALU
efectiva a un registro no cero; no afirma haber distinguido dos señales que en
esta versión coinciden para los programas probados.

La validez de METADATA se verifica contra una referencia que no consulta el
contador ni sus salidas. También se comprueban su máscara y el evento
`!reset && core_advance && wb_valid`, incluida su ausencia durante congelamientos.
Una identidad dinámica de WB solo puede retirarse una vez. A diferencia de ese
evento, un bundle retenido suma ocupación en cada ciclo que sigue presente.

## Fechas y referencia independiente

El modelo mantiene PC predicho, identidades dinámicas y posiciones ID/EX/WB.
La admisión nace del programa conocido, no de los bits de validez del DUT. Las
tablas independientes de máscaras, decisiones de control y destinos permiten
predecir saltos y excepción. Se comprueban los PC, palabras de IF/ID, validez
real, metadatos de WB y destino antes de actualizar el modelo.

Sin redirección, cada avance desplaza ID a EX y EX a WB. Con un salto se vacían
las dos posiciones jóvenes, conservando el salto; con excepción se invalida
también el EX culpable. Se consume primero el WB anterior. Un congelamiento
retiene posiciones, PC e identidades del modelo.

Para memoria directa se predice avance permanente. Para MEM_MODE=1 se predice
la petición LSU desde el programa y se exigen exactamente WAIT flancos detenidos
consecutivos por acceso. Para MEM_MODE=2 se observa el handshake público de la
jerarquía y se contrasta que core_en corresponda al stall estable en la fase baja.
Un contador independiente de eventos `posedge CPU.core_clk` confirma si realmente
existió el pulso. No se usan acumuladores de rendimiento para decidir expectativas.
No se reimplementa ni se declara independiente un predictor de latencia de L1-D.

Durante PRE se calculan expectativas y se conservan las entradas diagnósticas.
Durante POST, después de NBA, se comparan todos los acumuladores y el nuevo estado.
La traza de primera divergencia imprime esas entradas PRE conservadas, nunca la
validez nueva como si hubiera sido la consumida. El reloj manual permite esta
separación; las pruebas miden flancos, no frecuencia máxima ni tiempo físico en ns.

Los seis primeros flancos de NOP sin saltos tienen expectativas precalculadas:

| Flanco | IF válido | ID válido | EX válido | WB válido |
|---:|---:|---:|---:|---:|
| 1 | 1 | 0 | 0 | 0 |
| 2 | 1 | 1 | 0 | 0 |
| 3 | 1 | 1 | 1 | 0 |
| 4–6 | 1 | 1 | 1 | 1 |

Al terminar: ocupados `[6,5,4,3]`, burbujas `[0,1,2,3]`, medidos 6 y stalls cero.
La máscara de todos esos bundles es cero; conservar su validez detecta confundir
NOP con burbuja. Las posiciones IF inválidas fuera de reset se ejercitan con una
instancia unitaria, porque el fetch real no ofrece esa condición.

## Programa dirigido y resultados arquitectónicos

Las memorias se preparan únicamente durante reset. No se usa `force` ni se escribe
en registros del pipeline, acumuladores del monitor o estado privado criptográfico.

| Índices de bundle | Función del programa |
|---|---|
| 0 | ALU x1=77 y load x2; el primer stall retiene WB inválido. |
| 1–7 | NOP, store de palabra, load, store/load de byte y dependencia N+3. El bundle 3 usa los cuatro slots, incluye un salto no tomado y setpwd. |
| 8 | Load y salto tomado en el mismo bundle: BRU se mantiene activa durante la espera. |
| 9–10 | ALU/stores jóvenes que deben quedar anulados. |
| 12–14 | Condicional tomado, descarte de jóvenes y readmisión del destino NOP. |
| 15 | FSL sin AUTH con ALU, store y solicitud BRU: la excepción gana y anula el bundle. |
| 16–17 | Jóvenes de la excepción, sin efectos. |
| 1023 | Entrada del vector; salto al manejador de índice 32. |
| 32 / 40 | x30=9 y bucle final, sin terminación artificial. |

Se verifican x1=77, x2=0x1234, x5=x6=77, x7=78, x8=0x400 y x30=9.
Los destinos jóvenes y culpables permanecen en cero; hay una excepción con
trap_pc=240. DMEM[32]=77, la palabra en 36 contiene 0x00004D00 y los tres
centinelas de stores anulados conservan su patrón inicial.

Cada captura corresponde a **64 avances efectivos**, no a un mismo ciclo absoluto.
Los procesadores siguen ejecutándose después y la ventana se cierra; las
comparaciones usan snapshots tomados en ese progreso, no el PC corriente de una
instancia que ya ejecutó más. Después se solicita el vaciado real mediante
flush_req y se espera flush_done antes de comparar DMEM.

## Resultados del monitor

Vectores en orden `[IF,ID,EX,WB]`, ventana completa del programa mixto:

| Configuración | Medidos | Ocupados | Burbujas | Stall por etapa | Ocupados congelados | Retiros |
|---|---:|---|---|---:|---|---:|
| Modo 0, ROM_SYNC=1 | 64 | [64,48,33,32] | [0,16,31,32] | 0 | [0,0,0,0] | 32 |
| Modo 0, ROM_SYNC=0 | 64 | [64,48,33,32] | [0,16,31,32] | 0 | [0,0,0,0] | 32 |
| Modo 1, WAIT=1 | 70 | [70,54,39,37] | [0,16,31,33] | 6 | [6,6,6,5] | 32 |
| Modo 1, WAIT=4 | 88 | [88,72,57,52] | [0,16,31,36] | 24 | [24,24,24,20] | 32 |
| Modo 2, ROM_SYNC=1 | 87 | [87,71,56,47] | [0,16,31,40] | 23 | [23,23,23,15] | 32 |
| Modo 2, ROM_SYNC=0 | 87 | [87,71,56,47] | [0,16,31,40] | 23 | [23,23,23,15] | 32 |

Por ejemplo, WB ocupa 52 ciclos con WAIT=4 y solo se retiran 32 bundles:
los otros 20 son residencia congelada. Esto es correcto y no duplica instrucciones.
En esa configuración el stall global es 24, **no 96** por sumar sus cuatro salidas.
Una mayor ocupación durante esperas no implica mejor IPC ni mayor rendimiento.

El modo 2 usa la L1-D integrada y **l2_model**, no la L2 definitiva. Sus 23 flancos
sin avance representan congelamiento del núcleo en este programa y configuración;
no se atribuyen exclusivamente a L1-D, ni se calculan hits, misses, AMAT o métricas
del issue #26. El vaciado posterior está fuera de la ventana capturada.

## Ventanas, resets y estímulo unitario

Se ejecutan el programa NOP y tres políticas del programa mixto: completa,
habilitada en ciclos 5–10 y desde 17, y vacía. El caso pausado verifica expresamente
que hubo congelamientos con medición deshabilitada. Las ventanas por ciclo absoluto
abarcan diferente progreso en cada modo; no se exige una igualdad incorrecta de
sus acumulados. La arquitectura sí debe coincidir en los snapshots comunes.

Se aplica reset durante ejecución y cuando el modelo de cuatro esperas ya está
detenido en el primer load. El reset prioritario borra todos los acumulados y la
nueva época vuelve a observar el llenado. No se afirma que reset cancele stores
atómicamente: ese comportamiento pertenece al procesador y no se modifica aquí.

Una instancia unitaria separada recorre los 16 patrones de validez con avance,
sin avance y con medición pausada. Verifica reset con ventana cerrada, reset sin
avance, reanudación y ancho de salidas. La referencia mantiene explícitamente
ocupados y burbujas, contrastando la derivación usada en el RTL.

## Pasividad y comparación de memoria

Se contrastan PRE las cinco escrituras GPR y ambos puertos DMEM; después de NBA,
las nuevas escrituras, los 32 registros, PC, redirecciones, ESTADO público,
trap_pc/trap_count, core_en y core_clk frente a SHADOW. Las trazas conservan la
secuencia de candidatos de escritura y si el núcleo avanzó. No se leen ni se
publican llaves, subllaves o contraseña de la bóveda en el testbench nuevo.

Tras flush_done se comparan 16384 palabras exactas, que cubren los 65536 bytes,
con la sombra de cada configuración y entre los seis modos. No se sustituyen por
hashes. Los programas no escriben memoria después de la captura; el vaciado puede
continuar mientras las instancias más rápidas ejecutan el bucle final.

## Controles negativos

Solo CFG=3 recibe conexiones diagnósticas corruptas. CPU, SHADOW, las entradas de
la referencia y los módulos anteriores no cambian. La variante 6 genera un pulso
adicional exclusivamente en el reloj diagnóstico del contador; no en el núcleo.
Todas las ejecuciones terminaron con **VVP=1 por la primera aserción prevista**:

| +mutacion | Defecto | Aserción / etapa | Escenario / ciclo |
|---:|---|---|---|
| 1 | ID adelantada a IF | occupied / ID | NOP / 1 |
| 2 | Validez retrasada | occupied / IF | NOP / 1 |
| 3 | Burbuja EX válida | occupied / EX | NOP / 1 |
| 4 | NOP WB como burbuja | occupied / WB | NOP / 4 |
| 5 | Stall omitido | stall / IF | Mixto / 3 |
| 6 | Stall muestreado dos veces | measured / global | Mixto / 3 |
| 7 | Uso de core_clk | measured / global | Mixto / 3 |
| 8 | Validez borrada durante congelamiento | occupied / IF | Mixto / 3 |
| 9 | Reset ignorado tras ejecución | measured / global | Reset / 0 |
| 10 | Ventana ignorada | measured / global | NOP fuera de ventana / 7 |
| 11 | WB por escritura ALU | occupied / WB | NOP / 4 |
| 12 | Anulación ignorada | occupied / ID | Mixto / 36 |
| 13 | EX y WB intercambiadas | occupied / EX | NOP / 3 |
| 14 | Acumulados borrados al reanudar | measured / global | Mixto / 7 |

La comparación informa configuración, ciclo, etapa, validez esperada y consumida,
avance efectivo, reset, ventana y acumulados esperado/obtenido. El ejecutor externo
exige código no cero y el par aserción/etapa exacto. Un error de compilación o un
fallo diferente no acredita sensibilidad.

## Herramientas, regresiones y reproducción

Icarus/VVP 12.0; flags del Makefile, sin alterarlos. El módulo de producción también
compiló solo con `iverilog -g2012 -Wall -tnull -s perf_stage_counters`, salida 0 y sin
advertencias. Verilator y Yosys no están disponibles; no se instalaron dependencias.
No se realizó síntesis física ni se deduce sintetizabilidad únicamente de Icarus.
El RTL usa registros síncronos, conexiones combinacionales completas y bucles de
cuatro etapas; no contiene retardos, archivos, relojes derivados ni mecanismos de TB.

Ejecutar **en una copia externa** que contenga los tres archivos:

```bash
make tb_perf_stage_counters
make tb_perf_stage_counters PLUSARGS=+vcd
# Debe fallar por occupied/ID, no es una ejecución normal:
make tb_perf_stage_counters PLUSARGS=+mutacion=1
```

Normal y con VCD: **430652 verificaciones, salida 0**. Las catorce ejecuciones
negativas usan el mismo binario y producen código 1. El Makefile descubre el nuevo
tb_*.sv sin ningún cambio en sus reglas ni en la lista compartida.

| Target make | Verificaciones antes / después | Código antes / después |
|---|---|---|
| tb_perf_counters | 292 / 292 | 0 / 0 |
| tb_perf_slot_mask | 4299 / 4299 | 0 / 0 |
| tb_perf_pipeline_monitor | 9981 / 9981 | 0 / 0 |
| tb_perf_top_d3 | 14032 / 14032 | 0 / 0 |
| tb_perf_branch_d4a | 13248 / 13248 | 0 / 0 |
| tb_perf_stall_d5a | 72658 / 72658 | 0 / 0 |
| tb_perf_vliw_monitor_d4b1 | 42836 / 42836 | 0 / 0 |
| tb_perf_cache_l1d_k1a | 247770 / 247770 | 0 / 0 |
| tb_pipeline_stall | 50 / 50 | 0 / 0 |
| tb_mem_hierarchy | 43 / 43 | 0 / 0 |
| tb_port_b | 44 / 44 | 0 / 0 |
| tb_rom_sync | 34 / 34 | 0 / 0 |
| tb_l1d_cache | 81 / 81 | 0 / 0 |
| tb_l1d_mshr | 109 / 109 | 0 / 0 |
| tb_l1d_writeback | 68 / 68 | 0 / 0 |
| tb_l1d_replacement | 17 / 17 | 0 / 0 |
| tb_l1d_write_buffer | 15613 / 15613 | 0 / 0 |
| sim | 38 / 39 PASS | 0 / 0 |
| test-assembler | 44 / 44 métodos (21+13+4+6) | 0 / 0 |
| test-programs | 14 / 14 métodos | 0 / 0 |

Antes/después de `sim`: cero FAIL, NO-COMPILA y SIN-CHEQUEO. Se ejecutaron
exactamente esos veinte targets en ambas copias, además de las ejecuciones
específicas del nuevo banco. No se corrigieron fallos en archivos protegidos.

## Evidencias, trazas y auditoría didáctica

La evidencia primaria queda en `/tmp/ce4301-issue8-cgckc1es/`: manifiestos,
estado inicial, regresiones por comando, normales, catorce negativos, ondas,
capturas de contadores y el informe A–AG. Las trazas por configuración usan tres
tipos de registro identificados en su primera columna:

- PRE: escenario, política, ciclo, reset, medición, avance, validez esperada,
  validez real, PC y total esperado posterior al flanco.
- POST: escenario, política, ciclo, etapa, total, ocupados, burbujas, stalls y
  ocupados congelados, ya después de NBA.
- EFFECT_PRE: escenario, ciclo, avances previos, avance efectivo, enables,
  direcciones y datos de los cinco puertos WB y los dos puertos DMEM, redirect y
  destino. Son candidatos PRE; solo un pulso del núcleo publica sus efectos GPR.

El VCD nuevo selecciona exclusivamente relojes, validez, ventana y contadores;
no vuelca las instancias completas del procesador ni la bóveda. Las ondas de los
bancos anteriores pertenecen a sus propios contratos; no se amplía su acceso.

Auditoría de los tres archivos: encabezados con propósito y alcance; entradas,
salidas e índices explícitos; condiciones de incremento/retención/reset; distinción
NOP/burbuja; solapamiento de ocupación y stall; justificación de reloj y estado
derivado; explicación PRE/NBA/POST; todos los módulos, funciones y tareas propios
con comentarios; bucles y decisiones temporales explicados; programas y
controles negativos con defecto esperado; limitaciones visibles. No se usan
separadores decorativos ni comentarios que atribuyan integración o síntesis no probadas.

## Limitaciones y dependencias de integración

- El avance debe ser global y coherente. Un futuro pipeline con avance parcial
  necesitaría una interfaz distinta; cuatro copias del stall no lo modelan.
- El contador mide presencia y residencia, no instrucciones retiradas ni causas
  de caché individuales. No reemplaza perf_counters o perf_cache_l1d.
- Las entradas deben ser conocidas; no se define recuperación de X/Z ni estado
  inicial antes del primer reset.
- Se comprobaron los anchos y la aritmética del RTL. No se simularon 2^64 flancos
  ni se precargaron registros internos para alcanzar wrap artificialmente.
- El programa nuevo cubre setpwd y una excepción FSL; no certifica nuevas
  secuencias autorizadas Feistel/puerto B. Las regresiones previas conservan esa cobertura.
- El modelo de caché observa avance externo y contrasta efectos con memoria
  directa; no prueba todas las configuraciones de reemplazo o arbitraje.
- El vaciado usado para comparar memoria queda fuera de la ventana capturada;
  no se publica una métrica separada de costo de flush.
- La L2 y memoria principal definitivas siguen siendo dependencias externas.
- Integrar dentro de top, acordar la fuente de measure_enable y exponer salidas
  requiere coordinación con Fabricio. No se modifican esas interfaces aquí.

La compatibilidad demostrada conserva ISA, cuatro etapas, N+3, penalización de
saltos y efectos de excepciones del procesador actual. No se implementan medir,
lcont, vaciarc ni el issue #26. No se tocaron módulos de compañeros, Makefile,
README o Compiladores. Los cambios quedan sin staging ni commit para revisión.

El manifiesto confirma que los **398 archivos anteriores de Arquitectura** se
conservan y solo aparecen los tres nuevos autorizados. En el primer control final
se detectaron cambios en 49 archivos de Compiladores respecto de sus 409 archivos
iniciales. Esta intervención no escribió en ese repositorio. Javier confirmó
que los cambios corresponden a otra sesión de trabajo suya; se conservan sin
revertirlos y su procedencia queda aclarada. Los manifiestos de Compiladores
son distintos por ese trabajo concurrente y no se presentan como idénticos ni
como cambios del issue #8. El informe conserva la lista de diferencias.
