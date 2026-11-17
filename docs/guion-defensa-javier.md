# Guion técnico del aporte de Javier — Proyecto II

## Alcance que corresponde defender

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

1. Mostrar `make tb_perf_d18_cierre`: cuatro configuraciones0/1/REAL/MODEL.
   Explicar medir0, instantánea de lcont9–12, mitad alta, selector reservado,
   medir1 y vaciarc real. El calendario independiente verifica retiro y descarta
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
   872, checksum1056,32 GPR y65536 bytes correctos; separar ejecución y vaciado.
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
   Exclusiva registra0 lecturas RAM frente a256 en NINE. Sus576 misses L2 son
   escrituras de víctimas L1, mientras sus576 lecturas L2 aciertan; sumar ambas
   poblaciones sin explicarlas ocultaría la ventaja observada de reutilización.
7. Mostrar #31 como parcial, sin inventar niveles:

   ```bash
   python3 tools/comparar_optimizaciones.py --compiler-root "$CE1108_ROOT" --output /tmp/demo-p31-nueva
   ```

   La variante tradicional de factorial/whale/puntajes se contrasta contra M2
   independiente y RTL0/2, con resultados120/21/37. Las pasadas IR de balc no
   generan todavía versiones ASM optimizadas. El informe lo declara PARCIAL.

## Preguntas probables

**¿Por qué clk general?** core_clk se detiene durante espera; usarlo perdería
precisamente los ciclos de stall que queremos medir. Los eventos MC/L2 ya se
publican en el dominio CPU; no se incorpora otro cruce asíncrono al monitor.

**¿Qué significa completar un bundle?** WB válido y avance efectivo antes del
flanco. NOP conserva validez con máscara0; burbuja no. La máscara se transporta
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
por transacción L2/RAM en las capturas guardadas; sus medias quedan N/D y #26
PARCIAL. No se suman ocupaciones solapadas ni se usan las víctimas L2 como si
fueran exclusivamente demandas que fallaron en L1.

**¿Qué hace la pausa con una petición pendiente?** Los productores continúan.
K1-A/L2/RAM suman solo sucesos/flancos habilitados. K1-B conserva seguimiento y
excluye de su cohorte una demanda cortada. No se recupera historia al reanudar.

**¿Cómo sabemos que las métricas no cambian el procesador?** Hay comparaciones
activas/inactivas al mismo tiempo exacto, con PC, orden, datos, GPR, cripto,
traps, memoria y protocolos; los observadores no retroalimentan control.

**¿Cuatro etapas L2 siempre mejoran los programas?** No. En estos benchmarks la
referencia bloqueante reproduce872/2606/10236 frente a872/2606/10260 actuales.
La L1 limita las peticiones simultáneas aprovechables. No se usa el modelo
siempre-hit como referencia bloqueante ni se promete speedup general.

**¿La captura certifica que terminó main?** No. El pipeline sigue activo y los
cortes B5 solo acreditan observación local tras un retorno retirado. No hay HALT
artificial. Otros niveles necesitarán sus propios cortes equivalentes.

**¿Quedó todo lo asignado completo?** La instrumentación de eventos, regresiones,
benchmarks/configuraciones y documentación están verificados. #26 permanece
PARCIAL por AMAT L2; #31, por la falta de dos niveles productivos distintos de
balc. #38 tiene la preparación técnica lista y espera la publicación/integración
autorizada y el SHA final. La evidencia funcional no certifica síntesis/CDC física.

## Cierre formal después de publicar e integrar

Repositorio de entrega: <https://github.com/fabrimena/Proyecto2_Arquitectura1>.
SHA del último commit de entrega: **PENDIENTE**. Se verificará después de la
publicación e integración autorizadas; e461b70 identifica la base auditada y
no sustituye ese SHA. El archivo para TEC Digital contendrá únicamente el enlace
y el hash final, según la sección10 del enunciado. El material técnico preparado
no permite declarar completado ese paso de #38 antes de realizarlo.
