# D5-A: métricas durante congelamientos del pipeline

## Objetivo y base

Validación externa de los contadores, metadatos y recuperación BRU con memoria
directa y esperas artificiales por LSU. Se crean únicamente este documento y
`tb-p2/tb_perf_stall_d5a.sv`. No se integra instrumentación en `top`, no se
modifica el hardware y no se implementa D4-B ni una jerarquía de cachés.

Rama `feat/7-d5a-metricas-stalls`, creada desde `origin/develop` actualizado
mediante fetch, en `7bd02ebabb95dc9dfbcd336050f0f94251f7029b`, commit de D4-A.
El árbol y el índice estaban limpios. Origin apunta a
`https://github.com/fabrimena/Proyecto2_Arquitectura1.git`. HEAD se conserva.

## Contratos inspeccionados

Se revisaron `rtl-p2/top.sv`, `mem_stall_model.sv`, los tres módulos de métricas,
`rtl/lsu.sv`, `memory.sv`, `bru.sv`, `crypto_unit.sv`, `regfile.sv`, los tres
registros de pipeline, `isa_defs.sv`; los testbenches de stalls, D3 y D4-A;
`performance-analysis.md`, los documentos D3/D4-A, `memory-interfaces.md`,
`simulation.md` y Makefile. Los contratos se contrastaron con asignaciones,
prioridades y flancos reales, no solo con sus comentarios históricos.

## Reloj general, congelamiento y publicación de memoria

`mem_stall_model` calcula `req = re || we` y
`stall = !reset && req && count < STALL_CYCLES`. Su contador usa `clk`.
`top` actualiza `core_en = !cache_stall` mientras `clk=0`, mediante latch, y
forma `core_clk = clk & core_en`. PC, IF/ID, ID/EX, EX/WB, GPR y unidades usan
core_clk; DMEM y contadores de rendimiento usan el reloj general.

El monitor recibe `advance=core_en`. Para el flanco que se va a medir,
`memory_stall = !reset && !core_en`: representa el congelamiento aplicado.
Antes del flanco se comprueba también cache_stall contra la espera predicha.
Después de NBA cache_stall puede cambiar porque avanzó `count`, mientras
core_en conserva el valor aplicado con clk alto. No se usa ese cache_stall
posterior como entrada retrospectiva del mismo flanco.

Las escrituras de puertos A/B se habilitan con `!stall`. Un store y camcon
esperan hasta el flanco que libera el acceso LSU. Las lecturas son combinacionales;
la LSU registra el dato al avanzar, manteniendo N+3. El puerto B no genera
esperas por sí mismo en este modelo. No se exige retener todo el controlador
combinacional, que debe progresar para resolver la petición.

## Instancias y arquitectura de la prueba

| Instancia de prueba | Procesador real | Esperas adicionales por LSU |
|---|---|---:|
| REF | `top MEM_MODE=0` | 0 |
| DUT1 | `top MEM_MODE=1, STALL_CYCLES=1` | 1 |
| DUT4 | `top MEM_MODE=1, STALL_CYCLES=4` | 4 |

Cada módulo auxiliar `perf_stall_case_d5a` del propio testbench tiene un top
CPU, D1, D2, contadores, referencia, registro de efectos y CSV independientes.
Las tres instancias comparten reloj/reset y programa, no acumulados esperados.
No hay force, carga de controles privados ni escrituras a registros internos;
solo se precargan IMEM/DMEM bajo reset y con clk bajo.

El reloj se conduce desde una tarea común. Tras 4 ns con clk bajo, se calculan
las expectativas de cada instancia; cada observador activo espera 1 ns para
propagar su ventana y puertos diagnósticos. Se espera otro ns antes del flanco
común y 1 ns después para NBA. Todos observan un único flanco físico común.
El período de la prueba puede variar al terminar observadores; las métricas
cuentan flancos, no ns. Los contadores no utilizan core_clk.

## Modelo independiente: dos dominios de tiempo

La referencia mantiene `real_cycle` por flanco general y `advances` por avance
predicho. Tablas explícitas describen palabra, máscara, control y destino por
PC. Un IF admitido en avance n tiene finalización prevista en n+3; cada admisión
recibe serie propia, aunque se repita un PC. El PC de IF se predice desde cero,
sin tomar el PC observado del DUT como siguiente valor esperado.

La referencia identifica si EX contiene una LSU válida que no está anulada por
excepción y consume WAIT esperas antes de permitir el avance. No consulta
core_en para decidir el avance esperado. Luego comprueba core_en/cache_stall
reales, validez/PC de etapas, máscara ID y evento/máscara WB. Las decisiones y
destinos BRU proceden del programa dirigido y del número de visitas.
No se implementa otra ALU, LSU o función Feistel dentro de la referencia.

En flancos medidos se actualizan cinco expectativas de 64 bits: ciclos reales,
bundles, instrucciones por popcount, memoria y BRU. Un stall solo suma ciclos y
memoria; sin stall se pueden consumir WB o huecos BRU. El modelo no usa las
salidas acumuladas, bundle_complete o diagnósticos como fuente de expectativas.
Se comprueba la suma de penalizaciones extendida a 65 bits contra ciclos.

## Metadatos, retención y reanudación

D2 clasifica y transporta la máscara del bundle; no se infieren instrucciones
de escrituras GPR. `bundle_complete = !reset && core_en && wb_valid` debe ser
cero durante cada espera. WB, máscaras, causas e identidad pendiente se conservan.
Los cinco contadores se contrastan después de NBA en todos los flancos activos.

Durante un stall se verifica igualdad PRE/POST de PC, IF/ID completo, todos los
campos de ID/EX, EX/WB, puertos WB registrados, 32 GPR, estado público, registros
de excepción, metadatos D2 y marcas diagnósticas BRU. También se exige ausencia
de escrituras DMEM A/B. Las series de finalización deben aumentar sin duplicados;
la primera finalización posterior a la espera debe coincidir con su fecha de avance.
Un nivel wb_we retenido no se interpreta como escritura nueva: el banco solo
consume su reloj efectivo. Las escrituras DMEM sí se comprueban en clk general.

## Programa dirigido y operaciones LSU/CRIPTO

Se reutilizan los formatos y patrones legales de `tb_pipeline_stall`, con tablas
propias y dos extensiones: cadena de saltos y BRU dentro del bundle culpable.

| Bundles | Operaciones y propósito |
|---|---|
| 0–4 | Cinco cargas consecutivas de contraseña/llave; ALU, setpwd y vcr comparten bundles LSU. |
| 7–8 | ell autorizado, respetando N+3 de ESTADO y N+1 de bóveda. |
| 9–26 | Dos vueltas: cargas consecutivas, ALU, cuatro rondas FSL, stores consecutivos y branch atrás con LSU. |
| 27–33 | Palabra/byte, signo y cargas tras stores; se respetan dependencias N+3. |
| 34 | camcon y carga en el mismo bundle: la carga ve la palabra anterior y camcon rota una sola vez. |
| 35,37 | sye con LSU y destino sye sin LSU; mínimo intervalo legal entre redirecciones. |
| 40,43 | vcr incorrecto y FSL tres bundles después, con ALU/load/BRU que deben anularse. |
| 1023 | Manejador: x30=99 y salto a sí mismo. Se observa solo su primera recuperación completa. |

Son 19 accesos LSU aceptados; el load del culpable no se acepta. Se contrastan
vector público HOLA2026 → `03D44466 D685AFAF`, palabra cargada -5, byte -5,
DMEM[0x304]=0x0000FB00, carga anterior a camcon=-5 y posterior=0xFFFFFFBF.
No se replica Feistel ni se inspecciona la bóveda. La rotación pública no idempotente
y la secuencia de escrituras detectan ejecuciones repetidas de camcon.

## Saltos, excepciones y recuperación pendiente

Solo se acepta BRU con EX válido, avance real, salto tomado y sin excepción.
Un salto retenido junto a LSU puede mantener branch_flush durante varias
esperas, pero no genera aceptaciones ni nuevas marcas hasta core_en=1.
Las marcas diagnósticas avanzan únicamente con el núcleo, sin depender de medición.
La referencia reserva dos oportunidades EX posteriores en **avances**, no
multiplicando el acumulado de saltos ni sumando dos ciclos absolutos a ciegas.

| Control | Avance de aceptación | Ciclo REF/DUT1/DUT4 | Recuperación absoluta REF / DUT1 / DUT4 |
|---|---:|---|---|
| Branch atrás PC416 | 29 | 29 / 38 / 65 | 30,31 / 39,40 / 66,67 |
| sye con LSU PC560 | 58 | 58 / 77 / 134 | 59,60 / 78,79 / 135,136 |
| sye destino PC592 | 61 | 61 / 80 / 137 | 62,63 / 81,82 / 138,139 |
| Primer salto manejador | 70 | 70 / 89 / 146 | 71,72 / 90,91 / 147,148 |

La segunda vuelta del branch es no tomada y no crea recuperación. La excepción
en PC688 impone TRAP_VECTOR y suprime BRU/ALU/load/CRIPTO del culpable y jóvenes.
El trabajo anterior puede completar. Se conserva trap_count=1, trap_pc=688,
x27/x28/x29/x3=0 y x30=99 del manejador. No se atribuyen sus huecos a BRU.

## Coincidencia de memoria y BRU: alcance real

El contador da prioridad a memoria si ambas entradas están activas. Esa prioridad
se verifica en las 292 pruebas unitarias existentes, que también se ejecutan aquí.

En este procesador, el stall requiere LSU válida en EX. La recuperación atribuida
por D4-A requiere EX inválido. Por tanto, no se observó ni se fabricó coincidencia
real de stall con hueco BRU o marca EX de recuperación en MEM_MODE=1. Se comprueba
cero coincidencias y que durante memoria no crezca BRU. Las esperas del bundle
salto ocurren **antes** de aceptar la redirección; sus dos huecos posteriores
avanzan sin LSU y sin nuevos stalls en este modelo.

La lógica diagnóstica retiene marcas al no avanzar, pero D5-A no demuestra una
marca BRU no cero congelada por memoria: ese caso es inalcanzable con el productor
actual. Retención de marcas abstractas queda cubierta por D2. Nuevos stalls de
buffers, memoria asíncrona u otras etapas exigirán pruebas futuras específicas.

## Punto de comparación y secuencia arquitectónica

El punto común es el flanco que consume el **segundo hueco EX del primer salto
del manejador**, después de haber completado su WB. Se elige desde la referencia,
no por el acumulado obtenido. Son 72 avances efectivos en las tres instancias.
Cada una captura allí sus 32 GPR, DMEM completa, PC, ESTADO y excepción, aunque
las otras instancias aún estén ejecutando o ya hayan pasado ese punto.

Se comparan dos veces por política los 65536 bytes mediante igualdad real de
16384 palabras: 14 comparaciones completas en siete políticas. No se usa hash
como sustituto de igualdad. También se comparan 74 efectos ordenados por avance:
puertos GPR, stores A, camcon B, accesos LSU, redirecciones y cambios de ESTADO.
Por ejecución completa son 40 escrituras GPR, 6 stores A, 1 escritura B de
camcon, 19 accesos LSU, 4 saltos, 1 excepción y 3 cambios de ESTADO.
No se comparan estados de distinto progreso en el mismo ciclo absoluto.
Las capturas y secuencias prueban estos programas, no equivalencia universal.
El núcleo continúa con el reloj común después de su captura; el observador deja
de medir en ese punto y conserva la captura sin detener el procesador.

## Métricas con ventana completa

| Configuración | Ciclos reales | Avances | Bundles | Instrucciones | Memoria | BRU | Saltos | Excepciones | IPC externo |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| REF | 72 | 72 | 59 | 48 | 0 | 8 | 4 | 1 | 0.666666667 |
| DUT1 | 91 | 72 | 59 | 48 | 19 | 8 | 4 | 1 | 0.527472527 |
| DUT4 | 148 | 72 | 59 | 48 | 76 | 8 | 4 | 1 | 0.324324324 |

Cada congelamiento se comprueba por separado; después se contrasta globalmente
DUT1−REF=19 y DUT4−REF=76=4×19. No es AMAT, miss rate ni rendimiento de L1/L2:
se trata de un modelo artificial de espera constante por acceso LSU.
El IPC se calcula con reales fuera del RTL. Con cero ciclos es NO DEFINIDO.
NOPs, arranque, control y ventanas también afectan IPC.

## Ventanas de medición

| Caso/política | Definición | Propiedad |
|---|---|---|
| 1/0 | Medición completa hasta el punto común | Incluye tiempo real, memoria y ocho recuperaciones. |
| 2/1 | Desde ciclo real 12 | Diferente progreso de inicio entre modos; expectativas independientes. |
| 3/2 | Excluir espera del primer acceso | Pausa durante stall y reanuda al liberarse. |
| 4/3 | Excluir primera oportunidad de cada recuperación | Segunda marca se mide tras reanudar; cuatro penalizaciones. |
| 5/4 | Medición siempre deshabilitada | Todos los acumulados cero, ejecución y efectos continúan. |
| 6/5 | Medir únicamente stalls | 19/76 ciclos, cero bundles/instrucciones/BRU en DUT1/DUT4. |
| 7/6 | Excluir progreso previo 2 y 3 | Pausa cruza espera/finalización; reanudar no recupera lo ignorado. |

En las siete políticas se mantiene el mismo estado arquitectónico final y secuencia.
Los acumulados pueden diferir cuando la ventana comienza en un ciclo real fijo;
no deben compararse como si describieran las mismas instrucciones medidas.
La ventana no congela ni borra metadatos o marcas pendientes.

## Reset normal y con acceso pendiente

Todos los resets se aplican con clk bajo y se mantienen hasta un flanco positivo.
Se verifica núcleo limpio, marcas/metadatos borrados y los cinco contadores a cero,
incluso con habilitación de medición activa durante reset.

Caso 9: reset después del primer ciclo de espera de una carga en DUT4. El modelo
hace stall=0 por `!reset`; el latch abierto con clk bajo actualiza core_en=1 y
el próximo flanco de clk llega como core_clk, permitiendo reset síncrono del núcleo.
La carga no llega a x2 y DMEM conserva 0x12345678. La siguiente época vuelve a
llenar el pipeline sin finalizaciones antiguas.

**Limitación observada, caso 10:** con store pendiente en DUT4, reset también
hace stall=0, pero `m_we = we && !stall` no está inhibida por reset y DMEM no
tiene entrada reset. En el flanco de reset se publica ese store: DMEM[0] pasa de
0x12345678 a 0. Núcleo y métricas sí quedan reseteados. Se conserva una aserción
explícita de ese efecto real; no se presenta reset como cancelación atómica de
memoria ni se modifica el RTL. La política deseada requiere coordinación antes
de una integración definitiva.

Caso 11: reset con las dos marcas reales de BRU pendientes, tras aceptar el branch
con LSU. Se borran ambas y la siguiente época no continúa la recuperación previa.
No se afirma haber verificado reset pulsado exclusivamente con clk alto, ni su
seguridad para cualquier controlador futuro o escritura cripto pendiente.

## Adversariales y sensibilidad

Las aserciones cubren los 20 riesgos solicitados mediante fechas, series,
retención, ventanas, efectos y comparaciones. La congelación de una marca BRU
no cero por LSU se identifica expresamente como inalcanzable, no como cobertura.

Siete controles opcionales `+mutacion=1..7` modifican solo las salidas diagnósticas
hacia contadores. Las siete ejecuciones fallan con VVP=1 por aserciones previstas:

| Mutación | Defecto | Primera divergencia: caso/config/ciclo |
|---|---|---|
| 1 | Presentar WB retenido como nueva finalización | 1/1/5 |
| 2 | Omitir memory_stall | 1/1/3 |
| 3 | Atribuir BRU durante espera | 1/1/3 |
| 4 | Omitir recuperación | 1/0/30 |
| 5 | Perder máscara de instrucciones WB | 1/0/4 |
| 6 | Ignorar ventana activa, dentro del horizonte | 2/0/1 |
| 7 | Omitir WB cuando EX está ocupado | 1/0/4 |

Las mutaciones 1 y 3 son rechazadas por el contrato de sus puertos, incluso si el
contador todavía impide duplicar bundles o BRU gracias a la prioridad de memoria.
No se afirma que esas dos variantes hagan fallar el acumulado: prueban sensibilidad
de la instrumentación. Ninguna modifica señales del procesador o módulos aprobados.

## Pruebas y regresiones

Icarus Verilog/VVP 12.0, flags oficiales sin alterar Makefile. El testbench nuevo
normal y con VCD completa **72538 verificaciones**, código make 0. Son diez
escenarios: siete políticas y tres casos dirigidos de reset; no 72538 programas.

| Comando | Antes / después | Código antes / después |
|---|---|---|
| make tb_perf_counters | 292 / 292 | 0 / 0 |
| make tb_perf_slot_mask | 4299 / 4299 | 0 / 0 |
| make tb_perf_pipeline_monitor | 9981 / 9981 | 0 / 0 |
| make tb_perf_top_d3 | 13717 / 13717 | 0 / 0 |
| make tb_perf_branch_d4a | 12573 / 12573 | 0 / 0 |
| make tb_pipeline_stall | 50 / 50 | 0 / 0 |
| make tb_l1d_replacement | 17 / 17 | 0 / 0 |
| make tb_l1d_write_buffer | 14248 / 14248 | 0 / 0 |
| make tb_l1d_cache | 79 / 79 | 0 / 0 |
| make sim | 30 / 31 PASS, cero FAIL/NO-COMPILA/SIN-CHEQUEO | 0 / 0 |
| make test-assembler | 44 / 44 métodos | 0 / 0 |
| make test-programs | 14 / 14 métodos | 0 / 0 |

La primera ejecución terminó con make 2: esperaba ocho recuperaciones pero capturaba
al completar el WB del manejador, tras solo siete huecos. Se amplió el horizonte
hasta el segundo hueco real; se conservaron las aserciones y el total esperado 8.
La ejecución siguiente y las finales pasan. No hubo que corregir hardware.

## Evidencias y reproducción

CSV independientes `d5a-config0.csv`, `d5a-config1.csv`, `d5a-config4.csv`, con
1224/1490/2288 filas respectivamente y 40 campos. PRE contiene señales consumidas;
POST contiene valores registrados tras NBA. `avances_antes` conserva el progreso
previo; `avances` y las expectativas describen el resultado esperado de ese flanco.
Los acumulados obtenidos en PRE todavía son los anteriores. Durante reset se
reinicia la numeración local a cero; la fila reset marca una nueva época.
Se registran identidad WB, máscara, controles, esperas y escrituras DMEM.
Los CSV `d5a-efectos-config*.csv` conservan además los efectos públicos ordenados:
1=GPR, 2=DMEM A, 3=DMEM B, 4=LSU, 5=BRU, 6=excepción, 7=ESTADO.
Sus datos proceden de puertos públicos y entradas del programa, no de VAULT.

VCD opcional `d5a.vcd` de relojes, control y métricas públicas seleccionadas;
no se vuelca toda la jerarquía ni se incluyen señales privadas de VAULT.
Una divergencia conserva las primeras filas afectadas y termina con `$fatal(1)`.
Las mutaciones guardan sus logs/trazas en directorios externos separados.

Para reproducir, copiar el proyecto completo, incluidos estos dos archivos nuevos,
a un directorio temporal fuera de ambos repositorios. Desde esa copia ejecutar
los doce comandos de la tabla anterior y:

```bash
make tb_perf_stall_d5a
make tb_perf_stall_d5a PLUSARGS=+vcd
# Control negativo separado: debe terminar con error.
make tb_perf_stall_d5a PLUSARGS=+mutacion=1
```

El Makefile descubre automáticamente el archivo. Las salidas quedan en el build
de esa copia, nunca en el repositorio original durante esta intervención.
Se conservan fuera de ambos repositorios manifiestos, códigos, logs y diff completo.

## Límites y dependencias

D5-A valida solo los modos 0/1 actuales y estos programas/ventanas. No demuestra
integración L1-D/L2, memoria principal con reloj independiente, AMAT, stalls
por buffers o retención no cero de recuperación bajo nuevos productores de stall.
No prueba todas las instrucciones ni desbordamientos de contadores sobre top.
Las regresiones de caché pasan como pruebas independientes existentes.

D4-B requiere coordinación con Fabricio para cualquier cambio de top/pipeline:
reloj general, reset aplicado realmente al núcleo, ventana, core_en estable,
validez y máscara ID, evento/máscara WB, salto aceptado, excepción y marcas causales.
Usar la decisión de avance muestreada para atribuir memoria; no reinterpretar
cache_stall tras NBA. Acordar primero si reset debe cancelar escrituras pendientes.

La jerarquía completa exige revisar con Fabricio y responsables de memoria ambos
puertos, buffers pendientes, clock gating, escrituras únicas, prioridad memoria/BRU,
retención de recuperaciones y vaciado de datos sucios antes de comparar DMEM.
No se presume interfaz definitiva ni MEM_MODE=2 funcional: el top actual solo
implementa explícitamente modo 1 y el else de conexión directa.
