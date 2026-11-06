# D3: validación externa de métricas contra top

D3 conecta A–D2 únicamente desde un testbench externo al procesador real.
No integra contadores dentro de top ni modifica ISA, latencias, decoders,
memorias, módulos de métricas o lógica de compañeros.

## Base y alcance

Rama `feat/7-d3-validacion-top`, creada desde `origin/develop` en
`5be2ca84eff6a830dc3cc4f30b6937d7f9a592e3`. Se comprobó que origin apunta a
`https://github.com/fabrimena/Proyecto2_Arquitectura1.git` y se consultó develop
con fetch antes de crearla. No se utilizó la antigua rama de integración.

DUT y REF instancian `top #(.MEM_MODE(0))`. REF no tiene conexiones a los nuevos
observadores. Memoria directa implica cache_stall=0, core_en=1 y core_clk=clk.
Los módulos de caché que compila el Makefile no se elaboran en este modo.
D3 no valida su integración ni la jerarquía completa.

## Contratos y conexiones reales

| Señal | Uso externo |
|---|---|
| clk/reset | Reloj general y reset síncrono común del procesador y métricas. |
| DUT.id_bundle | Entrada de perf_slot_mask; tabla de máscaras independiente en el testbench. |
| DUT.id_valid/id_pc | Validez y PC de ID, separados de su máscara. |
| DUT.core_en | advance de perf_pipeline_monitor, estable antes del flanco. |
| DUT.id_ex_valid/ex_pc | Ocupación real de EX y PC del bundle, para contrastar fechas. |
| DUT.id_ex_valid && DUT.branch_flush | ex_branch_taken del monitor; no se usa redirect como salto. |
| DUT.id_ex_valid && DUT.crypto_fault | ex_exception, separada de BRU. |
| MONITOR.bundle_complete/wb_non_nop_mask | Evento y máscara entregados a perf_counters. |
| DUT.ex_wb_valid | Validez real de WB, independiente de si se escribe un GPR. |
| DUT.wb_we/wb_waddr/wb_wdata | Comparación de los cinco puertos con REF, no fuente del conteo de instrucciones. |

Se verificaron también IF/fetch, redirect/redirect_pc, puertos A/B de DMEM,
crypto_estado, trap_count, trap_pc y banco público de registros.
La excepción suprime el BRU del mismo bundle en top; gana sobre una solicitud
de salto, anula el culpable en EX y descarta las dos posiciones jóvenes.
El WB anterior conserva su efecto.

Los contadores utilizan clk. memory_stall y branch_recovery están fijados a 0:
no hay espera de memoria y aún no existe atribución verificada de la duración
de recuperación. **branch_penalty_count=0 no significa que no haya penalización
real de saltos**. branch_flush no se conecta a branch_recovery.

## Temporización y referencia independiente

El reloj se controla desde la tarea flanco. Se dejan 4 ns de estabilización antes
de conducir el flanco positivo y 1 ns para NBA antes de observar el estado posterior.
No se registra un pulso adicional ni se atrasa artificialmente la finalización.

| Instante | Bundle admitido desde IF en el flanco n |
|---|---|
| Después de n | ID |
| Después de n+1 | EX |
| Después de n+2 | WB |
| Antes/durante n+3 | Evento de finalización consumido por los contadores |
| Después de n+3 | WB siguiente; su elegibilidad no es otra finalización en n+3. |

El modelo de referencia usa tablas de fechas, PC, número de secuencia, máscara
conocida y causa de anulación. Cada IF realmente admitido recibe fecha c+3.
Las máscaras se declaran al construir el programa; no proceden del clasificador
ni del monitor. Un NOP admitido tiene validez 1, máscara 0 y una fecha de finalización.
Una burbuja no puede completar.

Las decisiones y destinos BRU se contrastan con otra tabla dirigida: saltos
siempre tomados, no tomados, excepción y las tres primeras vueltas tomadas del
bucle acotado. No se ejecutan instrucciones ALU/LSU/CRIPTO dentro del modelo.
Después se aplican anulaciones por edad: redirect descarta ID e impide admitir
IF; la excepción además cancela la fecha de EX. El WB anterior se consume primero.

Se comprueban ID/EX/WB reales, máscara de ID, evento PRE, máscaras/causas EX/WB
POST, evento elegible siguiente y todos los acumulados de 64 bits. Cada secuencia
de finalización debe avanzar sin duplicados, aunque se repita el PC de un bucle.
Una desaparición/desfase/duplicación del evento o máscara rompe las comparaciones
por ciclo y los totales conocidos. El monitor no aporta valores esperados.
Las tablas modelan únicamente transporte y observación, no un segundo procesador.

## Programas y adversariales

| Caso | Programa y propiedades verificadas |
|---|---|
| 1 | 32 ALU inmediatas consecutivas, incluidas escrituras a x0, reutilización de registros y dependencia N+3 final. |
| 2 | Store palabra/byte, load palabra/byte, ALU+LSU, salto condicional no tomado y consumidor de load N+3. |
| 3 | Cuatro decrementos, tres saltos hacia atrás tomados, salida no tomada, enlaces de sye/syer y jóvenes anulados. |
| 4 | setpwd, vcr, ell, fsl/fsli y camcon autorizados; bundle de cuatro unidades, otro de tres, y dos puertos GPR de cripto para una sola instrucción. |
| 5 | Cuatro operaciones en un bundle con excepción cripto y solicitud BRU: se anula entero, se conservan WB anterior y DMEM previa, se alcanza el vector. |
| 6 | NOP válidos con inicio de medición tardío, pausa y reanudación; no se confunden con burbujas. |
| 7 | Útiles que completan fuera de ventana, pausa con pendientes, reanudación sin repetición y reset durante actividad, con nueva época de llenado. |

Los programas se construyen con constantes de isa_defs y formatos contrastados
con los testbenches existentes. Solo se precargan IMEM y DMEM mientras reset está
activo y el reloj bajo; no se escribe ningún GPR o registro de pipeline desde
el testbench ni se utiliza force.

Oráculos arquitectónicos adicionales: caso 1 x27=31 y x0=0; caso 2 DMEM[4]=333,
x5=333, x6=1, x7=334; caso 3 x2=0, enlaces 128/224, destino55 y jóvenes sin efecto;
caso 4 AUTH=1/INIT=0, ALU 11 y par Feistel con datos/llave cero; caso 5 x2=77,
culpable/jóvenes sin efecto, DMEM[4]=0xf00d, trap_count=1 y trap_pc=16.
No se implementa una función Feistel de referencia adicional en D3.

Se ejercitan los 20 requisitos adversariales mediante estos escenarios y las
aserciones por fecha: evento doble/adelantado/tardío/perdido, máscara errónea,
burbuja/NOP, store/BRU sin GPR, dos salidas cripto, cancelaciones, WB anterior,
reset, pausas/reanudaciones, flujo consecutivo, bucle, reloj y pasividad.
No son20 testbenches diferentes ni 20 fallos inyectados: son condiciones que la
referencia detecta si divergen. No se modifican módulos protegidos para fabricar fallos.

## Resultados de contadores y ventanas

| Caso / ventana | Ciclos | Bundles | Instrucciones | IPC externo |
|---|---:|---:|---:|---:|
| ALU | 44 | 41 | 33 | 0.750000000 |
| LSU | 20 | 17 | 10 | 0.500000000 |
| Saltos/bucle/enlaces | 70 | 57 | 13 | 0.185714286 |
| Cripto/varios slots | 24 | 21 | 12 | 0.500000000 |
| Excepción | 9 | 2 | 2 | 0.222222222 |
| NOP, ventana discontinua | 10 | 10 | 0 | 0.000000000 |
| Útiles, ventana discontinua | 10 | 10 | 10 | 1.000000000 |
| Reset activo | 0 | 0 | 0 | NO DEFINIDO |
| Útiles tras nuevo reset | 5 | 2 | 2 | 0.400000000 |

En cada ventana los contadores de stalls y penalización son 0 por contrato D3.
El IPC se calcula con conversión real fuera del RTL; ciclos 0 produce NO DEFINIDO.

En los casos 6/7 se ejecutan 20 flancos normales, pero solo se miden 5–8 y 15–20.
measure_enable solo afecta acumulación: procesador y metadatos siguen avanzando.
Se observan 14 finalizaciones con medición deshabilitada entre ambos casos.
No se vuelven a contar al reanudar. Un reset con medición habilitada borra los
acumulados y los metadatos de forma prioritaria, sin contar ese flanco.

Cobertura medida: 92 NOP completados,3 stores,10 operaciones BRU completadas,
un bundle de cuatro slots, dos rondas con par GPR real,6 cancelaciones ID por
salto y2 por excepción (culpable EX e ID joven),14 completados fuera de ventana.
Las marcas de IF descartado se contrastan aparte; esas cantidades no son ciclos
perdidos ni un conteo total de operaciones anuladas de toda la jerarquía.

## Pasividad arquitectónica

DUT y REF tienen idénticos programa, memoria de entrada, reloj/reset y horizonte.
Se comparan antes de cada flanco activo los cinco puertos WB, ambos puertos de
memoria y redirecciones. Después de cada NBA se comparan los 32 GPR, PC,
estado criptográfico público y registros de excepción.

En nueve puntos se comparan todas las 16384 palabras de DMEM: los 65536 bytes,
sin hashes como sustituto. No se inspecciona la bóveda privada ni se afirma
igualdad de sus secretos. Son pruebas de pasividad de instrumentación junto
con oráculos concretos, no certificación universal del procesador.

## Herramientas y reproducción

Icarus Verilog 12.0 instalado, con los flags oficiales del Makefile:
`-g2012 -Wall -Wno-timescale -I rtl -I rtl-p2 -I tb -I tb-p2`.
No se modifican flags ni Makefile: descubre automáticamente el testbench.
En una **copia externa** del proyecto:

```bash
make tb_perf_top_d3
make tb_perf_top_d3 PLUSARGS=+vcd
```

La simulación termina con 13717 verificaciones correctas y código 0.
Son siete escenarios dirigidos, con verificaciones normales/adversariales
compartidas; no se suman como si fueran pruebas disjuntas.
El CSV d3-eventos.csv conserva filas PRE/POST, PC/validez ID/EX, evento/máscara
WB, acumulados, branch_flush/crypto_fault/redirect, destino y expectativa WB.
Con +vcd se genera d3.vcd solo de señales públicas seleccionadas, sin volcar
bóveda privada. Logs/CSV/VCD quedan en el build externo, nunca en Git.

## Regresiones antes y después

| Comando | Antes | Después | Verificaciones/casos registrados |
|---|---|---|---|
| make tb_perf_counters | 0 PASS | 0 PASS | 292 |
| make tb_perf_slot_mask | 0 PASS | 0 PASS | 4299 |
| make tb_perf_pipeline_monitor | 0 PASS | 0 PASS | 9981 |
| make tb_pipeline_stall | 0 PASS | 0 PASS | 50 |
| make tb_l1d_replacement | 0 PASS | 0 PASS | 17 |
| make tb_l1d_write_buffer | 0 PASS | 0 PASS | 14248 |
| make tb_l1d_cache | 0 PASS | 0 PASS | 79 |
| make sim | 0, 28 PASS | 0, 29 PASS | 0 FAIL/NO-COMPILA/SIN-CHEQUEO; D3 añade un PASS. |
| make test-assembler | 0 PASS | 0 PASS | 44 métodos: 21+13+4+6. |
| make test-programs | 0 PASS | 0 PASS | 14 métodos. |

Los PASS de caché/stalls corresponden a sus regresiones independientes, no a
integración con métricas. La primera ejecución de desarrollo de D3 detectó un
error en su propio codificador syer: campos rd/rs1 invertidos. Se corrigió solo
el testbench y se añadió una expectativa explícita de destino BRU. No hubo que
cambiar ningún módulo protegido. Se conservan log inicial y evidencia final.

## Aislamiento, límites y dependencias

Se protegieron mediante manifiestos previos todos los archivos de Arquitectura
y Compiladores, incluidos A–D2, cachés y archivos de compañeros. Solo se crean
este documento y tb-p2/tb_perf_top_d3.sv, sin staging ni commit. Se mantiene HEAD
de la rama nueva y se comparan hashes/permisos/tamaños al finalizar.
La evidencia externa de la intervención incluye informes y diff completo.

D3 ejercita una selección dirigida de la ISA real. No afirma ejecutar sus 34
operaciones sobre top: D1 sigue comprobando las 34 y reservados en su propia
regresión. No se inyectan códigos reservados en el programa del DUT para
normalizar el fallback ALU. Tampoco se prueba desbordamiento a 2^64 en top;
los límites del contador permanecen cubiertos por su testbench independiente.

D4 requiere coordinar con Fabricio el enganche definitivo, avance efectivo y
atribución temporal real de penalizaciones, reset y ventanas. Observar un
branch_flush no decide por sí solo cómo contar ciclos perdidos. Top permanece
sin contadores integrados y no se implementa esa fase.

D5 requiere validar eventos retenidos, reloj general frente a core_clk,
finalización única tras congelamientos prolongados y coincidencia de causas,
así como interfaces finales de L1-D/L2/memoria con sus responsables. Ninguna
interfaz de jerarquía se presume definitiva ni se modifica durante D3.
