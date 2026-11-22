# Guion técnico del aporte de Javier — Proyecto II

## Alcance que corresponde defender

Estado al 20 de noviembre de 2026: el aporte de Javier está integrado en
`develop` mediante el [PR #70](https://github.com/fabrimena/Proyecto2_Arquitectura1/pull/70).
El cierre documental individual sigue su propio PR de revisión. La integración
definitiva `develop` → `main`, presentación y entrega formal siguen siendo colectivas.

Javier desarrolló los observadores VLIW, etapas y eventos/servicio L1-D, el
monitor L2 y la integración de métricas RAM existentes, clasificación y unidad
D18, ensamblado/validación de D18, runners, oráculos, benchmarks y comparadores.
La conexión inicial D18 y la jerarquía/ROM/pipeline corresponden a Fabricio;
L1-D/MSHR/WBUF a José; L2/arreglos/PLRU a Alejandro; RAM/CDC/EB/perf_memory a
Dylan. Este cierre reutiliza sus módulos sin modificar sus algoritmos.

## Demostración breve

Preparar una copia externa que incluya los cambios de la rama; las órdenes
Make producen build y los comparadores exigen destinos externos nuevos.
Las mismas órdenes se ejecutaron durante la verificación; elegir otros nombres
de salida al repetir y conservar logs en almacenamiento persistente.

1. Mostrar `make tb_perf_d18_cierre`: cuatro configuraciones 0/1/REAL/MODEL.
   Explicar medir 0, instantánea de lcont 9–12, mitad alta, selector reservado,
   medir 1 y vaciarc real. El calendario independiente verifica retiro y descarta
   un medir situado detrás de un salto tomado. El resultado llega a WB y N+3
   se conserva además en tb_cache_isa; no se mide desde escrituras de registros.
2. Mostrar `make tb_perf_integracion_hierarquia`: productor idéntico con
   PERF_ENABLE0/1, comparación por flanco de datos/stall/flush/reloj y toda DMEM.
   El oráculo suma eventos públicos PRE, no lee los acumulados del monitor.
3. Ejecutar un benchmark reproducible:

   ```bash
   python3 tools/run_memory_benchmarks.py --output /tmp/demo-p29-nueva --repeat 2
   ```

   Mostrar program.mem, execution.json y summary.json. Confirmar REAL, horizonte
   872, checksum 1056,32 GPR y 65536 bytes correctos; separar ejecución y vaciado.
4. Mostrar contadores L1/L2/RAM en execution.json: distinguir demanda arbitrada,
   decisión L2 y aceptación RAM. El campo l2[9] es oferta retenida, no número de
   escrituras físicas; ram[0]+ram[1] sí cuenta aceptaciones de línea.
5. Mostrar la tabla de configuraciones:

   ```bash
   python3 tools/comparar_configuraciones.py --output /tmp/demo-p30-nueva --repeat 2
   ```

   Solo cambiar una dimensión por contraste. WT/NWA usa referencia NINE/WB/WA;
   comparar contra exclusiva introduciría dos cambios. Random tiene reset fijo
   y las repeticiones son deterministas, sin inferencia estadística.
6. Mostrar el estudio de capacidad:

   ```bash
   python3 tools/comparar_configuraciones.py --capacity --output /tmp/demo18k-nueva
   ```

   Misma precarga18KiB,576 líneas, calentamiento no medido y segunda pasada D18.
   Exclusiva registra 0 lecturas RAM frente a 256 en NINE. Sus 576 misses L2 son
   escrituras de víctimas L1, mientras sus 576 lecturas L2 aciertan; sumar ambas
   poblaciones sin explicarlas ocultaría la ventaja observada de reutilización.
7. Mostrar primero la referencia tradicional, sin inventar niveles:

   ```bash
   python3 tools/comparar_optimizaciones.py --compiler-root "$CE1108_ROOT" --output /tmp/demo-p31-nueva
   ```

   La variante tradicional de factorial/whale/puntajes se contrasta contra M2
   independiente y RTL0/2, con resultados 120/21/37. Las pasadas IR de balc no
   generan versiones ASM optimizadas. Este informe de una sola variante se
   mantiene PARCIAL; la comparación productiva IDE-DCE se demuestra abajo.

## Preguntas probables

**¿Por qué clk general?** core_clk se detiene durante espera; usarlo perdería
precisamente los ciclos de stall que queremos medir. Los eventos MC/L2 ya se
publican en el dominio CPU; no se incorpora otro cruce asíncrono al monitor.

**¿Qué significa completar un bundle?** WB válido y avance efectivo antes del
flanco. NOP conserva validez con máscara 0; burbuja no. La máscara se transporta
desde ID y se descarta por edad ante redirect. Store y salto cuentan sin GPR.

**¿Se suma dos por salto tomado?** No: se siguen las posiciones descartadas y
solo se acumulan oportunidades EX realmente perdidas. Las excepciones no son
saltos y memoria tiene prioridad cuando coinciden causas.

**¿Es stall de memoria igual a miss L1?** No. La métrica histórica observa todo
congelamiento global, incluido arbitraje y cisa_hold de vaciarc. K1-B observa
otra población: servicio del puerto único, con fronteras explícitas por acceso.

**¿Por qué RAM acepta cuatro lecturas en secuencial aunque no hay stalls?**
Los stores reservan MSHR y sus llenados progresan mientras se ejecutan NOP y
preparación. No equivalen a cuatro operaciones adicionales de CPU ni obligan
a detener el bundle mientras existan recursos libres.

**¿Qué AMAT podemos demostrar?** El observado en el puerto L1-D es
Σservicio K1-B/completados K1-B, para la misma cohorte íntegramente habilitada.
También equivale a HR×media hit+MR×media miss de esa cohorte. Un store puede
terminar al reservar un MSHR; eso no es persistencia. El análisis externo
`tools/analizar_amat.py` conserva lecturas y stores separados. No hay tiempos
por transacción L2/RAM en las capturas históricas; sus medias siguen N/D.
Las capturas nuevas sí tienen cohortes aceptación→respuesta: los observadores
temporales completan ese pendiente de #26. No se suman ocupaciones solapadas ni se usan las víctimas L2 como si
fueran exclusivamente demandas que fallaron en L1.

**¿Qué hace la pausa con una petición pendiente?** Los productores continúan.
K1-A/L2/RAM suman solo sucesos/flancos habilitados. K1-B conserva seguimiento y
excluye de su cohorte una demanda cortada. No se recupera historia al reanudar.

**¿Cómo sabemos que las métricas no cambian el procesador?** Hay comparaciones
activas/inactivas al mismo tiempo exacto, con PC, orden, datos, GPR, cripto,
traps, memoria y protocolos; los observadores no retroalimentan control.

**¿Cuatro etapas L2 siempre mejoran los programas?** No. En estos benchmarks la
referencia bloqueante reproduce 872/2606/10236 frente a 872/2606/10260 actuales.
La L1 limita las peticiones simultáneas aprovechables. No se usa el modelo
siempre-hit como referencia bloqueante ni se promete speedup general.

**¿La captura certifica que terminó main?** No. El pipeline sigue activo y los
cortes B5 solo acreditan observación local tras un retorno retirado. No hay HALT
artificial. Otros niveles necesitarán sus propios cortes equivalentes.

**¿Quedó todo lo asignado completo?** La instrumentación de eventos, regresiones,
benchmarks/configuraciones y documentación están verificados. #26 acredita las
medias observables L1/L2/RAM; #31 acredita tradicional/IDE-DCE en dos programas,
sin inventar -O. #38 tiene la preparación técnica lista; faltan la revisión del
equipo, presentación, integración definitiva `develop` → `main` y entrega en
TEC Digital con el SHA final. La evidencia funcional no certifica síntesis/CDC física.

## Cierre formal después de publicar e integrar

Repositorio de entrega: <https://github.com/fabrimena/Proyecto2_Arquitectura1>.
SHA del último commit de entrega: **PENDIENTE DE INTEGRACIÓN FINAL**. Se verificará después de la
integración definitiva y la confirmación del commit realmente entregado;
e461b70 identifica la base auditada y
no sustituye ese SHA. El archivo para TEC Digital contendrá únicamente el enlace
y el hash final, según la sección 10 del enunciado. El material técnico preparado
no permite declarar completado ese paso de #38 antes de realizarlo.

## Demostración temporal y comparación productiva actual

Esta sección sustituye el diagnóstico histórico de un único nivel CLI. Javier
aporta observación/validación; cachés, CDC, buffers y segmentación siguen siendo
trabajo de sus responsables. Los comandos escriben capturas externas nuevas.

1. Mostrar VLIW/etapas: `make tb_perf_integracion_top` y
   `make tb_perf_stage_counters`. Los mismos programas con PERF0 conservan PC,
   GPR, cripto y memoria; no sumar cuatro veces el stall global.
2. Mostrar L1 y servicio: `make tb_perf_cache_l1d_k1a tb_perf_cache_l1d_k1b`.
   Distinguir finalización de store en MSHR y persistencia posterior.
3. Mostrar D18: `make tb_perf_d18_cierre`. `medir` habilita observación en clk,
   `lcont` conserva selectores 0–12/N+3 y `vaciarc` confirma persistencia antes
   del programa siguiente. Los módulos nuevos no controlan esas instrucciones.
4. Mostrar L2/RAM: `make tb_perf_cache_l2_latency tb_perf_memory_latency`.
   Señalar aceptación, clasificación tardía, respuesta, pausa y pendiente.
   RAM normal 40/54 flancos con DIV2/4, distinto de busy 39/53; el retry exitoso
   incluye la espera previa y el fracaso final tiene otra población.
5. Mostrar pasividad/políticas: `make tb_perf_amat_integracion` reutiliza
   stores/load, línea sucia, exclusiva/NINE, DIV2/4 y MODEL, compara las 16384
   palabras con gold y el gemelo PERF0. El diario independiente fecha señales,
   en lugar de comparar solo acumuladores del mismo monitor.
6. Mostrar los tres benchmarks con dos rondas y comparar con las 54 capturas
   de configuraciones. Secuencial/aleatorio/stride mantienen 872/2606/10260
   ciclos y checksum 1056. Mostrar AMAT L1=1/19.0625/98.7916666667,
   L2 reads=64/64/99.4895833333 y RAM=54 en la referencia. Stride deja una
   transferencia pendiente:178 completas entre 179 aceptadas al corte.
7. Mostrar `comparar_optimizaciones.py --compiler-root "$CE1108_ROOT" --ide-dce
   --output /tmp/defensa-dce-nueva`: puntajes 801→795 bundles y funciones 528→435.
   Explicar código BAL original/transformado, llamada preservada con copia
   muerta eliminada, marcos diferentes y valores 24/13/37 y 16/15. Cada variante
   coincide completa con M2 y RTL0/2. No denominar las variantes -O0/-O1.
8. Mostrar capacidad18KiB y comparación de políticas con el runner existente;
   separar el calentamiento no medido de la segunda pasada y el flush externo.
   Un hit de L2 puede pertenecer a una línea victimaria exclusiva, no a otra
   demanda del núcleo de la misma población.

Para defender las medias, indicar SIEMPRE puerto, flancos, cohorte, exclusiones
al corte y unidad. El servicio de reads L2 puede superar 64 por congestión; un
presupuesto nominal no reemplaza esa evidencia. Las escrituras posted no tienen
un AMAT de respuesta inventado. RAM no tiene hits/misses de caché.
#26 y #31 están completos en esos alcances observables/probados; no acreditan
síntesis física ni equivalencia universal del optimizador. #38 permanece parcial
hasta presentación, revisión colectiva y entrega real. El archivo formal externo
contendrá solo la URL y el SHA posterior a la integración autorizada.
