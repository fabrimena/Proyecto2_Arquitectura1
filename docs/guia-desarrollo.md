# Guía de desarrollo del proyecto 2

Esta guía dice qué archivo toca cada integrante para seguir la misma línea de diseño. Las decisiones y
sus justificaciones están en [`decisiones-importantes.md`](decisiones-importantes.md): **D1 a D19** son
las filas de su tabla de la sección 2, y las fechas están en su sección 7.

Reglas para todos:

- `rtl/` y `tb/` (proyecto 1) no se modifican. Lo nuevo va en `rtl-p2/` y `tb-p2/`; el Makefile los toma
  solos.
- Los números de la jerarquía (tamaños, políticas, latencias) se definen en `rtl-p2/cache_defs.sv`, cada
  uno en su sección, y los módulos los usan como parámetros.
- Cada cambio va con su testbench y con la regresión en los dos modos: con la caché desactivada
  (`MEM_MODE = 0`) todo idéntico al proyecto 1; con la jerarquía (`MEM_MODE = 2`) los mismos registros y
  la misma memoria, con más ciclos.
- Una rama por bloque, un commit por archivo y un PR a `develop` revisado por otro integrante.

**Estado:** *Modificar* = el archivo ya existe y hay que cambiarlo. *Falta* = el archivo no existe y hay
que crearlo. *Hecho* = implementado y probado. Si depende de otra pieza, se indica.

## 1. Cambios en archivos que ya están en el repositorio

| Integrante | Archivo | Qué cambiar | Decisión | Estado |
|:---|:---|:---|:---|:---|
| Fabricio | `rtl-p2/top.sv` | Parámetro `ROM_SYNC` (la instancia `IMEM` pasa a `rom_sync` con el siguiente PC). `MEM_MODE = 2` instancia `mem_hierarchy` en lugar de la conexión directa; `DMEM` queda como almacenamiento de la RAM. Agregar `mem_re_b`. `cache_stall` = stall de la jerarquía o de `vaciarc`. El carril de escritura de la LSU se comparte con `lcont`. Conectar `measure_enable` desde `cache_isa_unit`, instanciar los contadores (`perf_vliw_monitor`, `perf_cache_l1d`, `perf_cache_l2`, `perf_memory`, `perf_stage_counters`) y sacar `flush_req`/`flush_done` para los testbenches | D1, D2, D16, D17, D18 (extra: instrucciones) | Modificar (hecho: `ROM_SYNC`) |
| Fabricio | `rtl-p2/mem_stall_model.sv` | Frenar también los accesos del puerto B (`vcr`, `camcon`): primero A y después B, con un stall más, para probar el congelamiento con la cripto antes de tener la jerarquía | D17 | Modificar |
| Fabricio | `tb-p2/tb_pipeline_stall.sv` | Casos con `vcr` y `camcon` en el mismo bundle que una carga, con el puerto B frenado (`camcon` rota una sola vez), y la misma prueba con `ROM_SYNC = 1` | D1, D17 | Modificar |
| Fabricio | `docs/memory-interfaces.md` | Sección 5 con el bus versión 2 (`l2_gnt`, `l2_rvalid`, `l2_wdirty`, `l2_rdirty`); sección 6 con 25 MHz, handshake, timeout y forwarding del eviction buffer; sección 7 con la cadena de vaciado y `vaciarc`; sección 8 con el árbitro del puerto B; cerrar los pendientes de la sección 9 | D9, D12 a D18 | Modificar |
| Fabricio | `docs/microarchitecture.md` | Sistema extendido sin borrar lo del proyecto 1: diagrama con ROM síncrona, jerarquía, buffers, controlador y contadores; tiempos; L2 en etapas (#35) | D1, D2, D11 | Modificar, al final |
| José | `rtl-p2/cache_defs.sv` | `L1D_WRITE_POLICY` fija pasa a parámetro con `WP_WRITE_BACK` por defecto; `L1L2_INCLUSION_POLICY` = `INCL_EXCLUSIVE` por defecto; asignación por defecto `AP_WRITE_ALLOC`; agregar `N_MSHR` (1 a 4, 2 por defecto) | D3, D4, D5, D8 (extras: exclusiva y non-blocking) | Modificar |
| José | `rtl-p2/l1d_arrays.sv` | Bit sucio por línea (marcar en un store, leer para la víctima y limpiar en el vaciado); leer la línea completa de la víctima | D4, D16 | Modificar |
| José | `rtl-p2/l1d_cache.sv` | Write-back con write-allocate. Víctimas al write buffer con `l2_wdirty` (exclusiva: todas; NINE con write-back: solo las sucias). `l2_rdirty` deja la línea sucia. M2 y M3 con el bus versión 2 (`l2_gnt`, `l2_rvalid`). En exclusiva, un miss a una línea que está en el write buffer espera su drenado. MSHR de stores (`N_MSHR`): stores que fallan sin stall, mezcla, hit durante un miss y carga a una línea pendiente. Recorrido de sus líneas sucias en el vaciado. `$fatal` con write-through + exclusiva | D3, D4, D5, D7, D8, D9, D16 (extras: exclusiva, non-blocking y pipeline) | Modificar |
| José | `rtl-p2/l1d_write_buffer.sv` | Bit sucio por entrada; búsqueda por línea para la espera de la exclusiva; quitar los 60 warnings de Icarus (`@*` sensible a todo un arreglo) | D3, D7 | Modificar |
| José | `tb-p2/tb_l1d_cache.sv` | Su modelo de L2 pasa al bus versión 2; los casos de hoy quedan con write-through + NINE como configuración explícita | D9 | Modificar |
| José | `tb-p2/tb_l1d_write_buffer.sv` | Casos con el bit sucio y la búsqueda por línea | D7 | Modificar |
| José | `docs/l1d-cache.md` | Tabla de políticas con write-back, exclusiva, MSHR y bus versión 2 (#32) | D3 a D9 | Modificar |
| Alejandro | `rtl-p2/cache_defs.sv` | Sección nueva de la L2: 16 KB, 4 vías, 128 conjuntos, líneas de 32 B, campos de la dirección, `L2_HIT_CYCLES = 8` y códigos de reemplazo (PLRU, Random) | D10 | Modificar |
| Dylan | `rtl-p2/cache_defs.sv` | Sección nueva de la memoria: `MEM_DIV = 4`, `TMEM = 25 + 7 × MEM_DIV`, `MEM_TIMEOUT = 256` y `EB_DEPTH = 4` (4 a 16) | D12, D14, D15 | Modificar |
| Javier | `rtl-p2/perf_cache_l1d.sv` | Eventos nuevos: víctimas limpias y sucias, movimientos de la L2 a la L1-D, hits durante un miss, stores sin stall y ciclos con los MSHR llenos | D3, D8 | Modificar, después de los cambios de José |
| Javier | `tb-p2/tb_perf_cache_l1d_k1a.sv` | Casos de los eventos nuevos; su modelo de L2 pasa al bus versión 2 | D3, D8, D9 | Modificar |
| Javier | `tools/assembler.py` | `vaciarc`, `medir imm` y `lcont rg, sel` (tipo `1001101`, solo slot 1); `lcont` escribe `rg`, así entra solo a la revisión N+3 como una carga | D18 (extra: instrucciones) | Modificar |
| Javier | `tests/test_assembler.py`, `tests/test_isa.py` | Codificación exacta de las 3 instrucciones, rechazo fuera del slot 1 y regla N+3 de `lcont` | D18 | Modificar |
| Javier | `tests/rtl/tb_archivo.sv`, `tests/rtl/tb_assembled_program.sv`, `tests/rtl/tb_ce1108_program.sv` | Antes de leer `DUT.DMEM.mem`, activar `flush_req` y esperar `flush_done` (con `MEM_MODE = 0` es inmediato) (#28) | D16 | Modificar |
| Javier | `tools/run_program.py`, `Makefile` | Opción para elegir la configuración (`MEM_MODE` y parámetros de caché, con `defparam`) para la regresión en dos modos (#9) y las comparaciones | D16, comparaciones | Modificar |
| Javier | `docs/isa.md`, `docs/compiler-integration.md` | Sección del tipo `1001101` (codificación, slot, semántica y tabla de `sel`) y aviso formal a CE1108 de que son opcionales para `balc` | D18 | Modificar |
| Javier | `docs/performance-analysis.md`, `README.md` | Metodología, resultados de las comparaciones y cómo correrlas (#36, #37) | Comparaciones | Modificar, al final |
| Todos | `docs/simulation.md` | Cada uno agrega las filas de sus testbenches nuevos | Pruebas | Modificar |

## 2. Archivos nuevos por integrante

| Integrante | Archivo | Qué agregar | Decisión | Estado |
|:---|:---|:---|:---|:---|
| Fabricio | `rtl-p2/rom_sync.sv` | ROM síncrona leída con el siguiente PC, con la misma carga `+IMEM=`, la instancia `IMEM` y el arreglo `memory` de hoy | D1 | Hecho |
| Fabricio | `rtl-p2/l1d_port_arbiter.sv` | Junta los puertos A (LSU) y B (cripto) sobre el puerto único de la L1-D: A primero, B después; `camcon` lee y escribe la misma palabra y la escribe una sola vez | D17 | Falta, usa `l1d_cache.sv` |
| Fabricio | `rtl-p2/l2_model.sv` | L2 de prueba con el bus versión 2: siempre acierta, responde en 8 ciclos y lee y escribe `DMEM`. Sirve para conectar la L1-D antes de tener la L2 real | D9 | Falta |
| Fabricio | `rtl-p2/mem_hierarchy.sv` | Jerarquía con la interfaz de `memory.sv` más `cache_stall`, `flush_req`/`flush_done` y eventos: árbitro, `l1d_cache`, `l2_cache` (o `l2_model`), `eviction_buffer` y `mem_controller` | D9, D16 | Falta, empieza con la L1-D y `l2_model` |
| Fabricio | `rtl-p2/excl_checker.sv` | Checker solo de simulación: ninguna línea válida en la L1-D y la L2 a la vez | D3 (extra: exclusiva) | Falta, después de `l2_cache.sv` |
| Fabricio | `rtl-p2/l2_cache.sv` | La L2 bloqueante pasa a 4 etapas (recepción, etiquetas, datos, respuesta) con valid/ready; acepta una petición por ciclo y un miss detiene S2 | D11 (extra: pipeline interno) | Falta, después de la L2 bloqueante de Alejandro |
| Fabricio | `tb-p2/tb_rom_sync.sv` | El mismo bundle que la memoria combinacional en cada ciclo, con saltos, excepciones y congelamiento | D1 | Hecho |
| Fabricio | `tb-p2/tb_port_b.sv` | `vcr` y `camcon` solos y en el mismo bundle que una carga, con `MEM_MODE` 1 y 2 | D17 | Falta |
| Fabricio | `tb-p2/tb_mem_hierarchy.sv` | Latencias de 0, +8 y +8 + 53 ciclos; los programas del proyecto 1 con `MEM_MODE = 2`; el checker de exclusividad sin errores | D2, D3, D12 | Falta |
| Fabricio | `tb-p2/tb_l2_pipeline.sv` | Una petición por ciclo, peticiones al mismo conjunto, un miss que detiene y respuestas en orden | D11 | Falta |
| José | `tb-p2/tb_l1d_writeback.sv` | Write-back y exclusiva: víctimas limpias y sucias, `l2_rdirty`, espera por una línea en el write buffer y vaciado | D3, D4, D7, D16 | Falta |
| José | `tb-p2/tb_l1d_mshr.sv` | Stores sin stall, mezcla en el MSHR, carga a una línea pendiente, MSHR llenos y `N_MSHR` = 1, 2 y 4 | D8 (extra: non-blocking) | Falta |
| Alejandro | `rtl-p2/l2_arrays.sv` | Etiquetas, válido, sucio y datos de 16 KB, 4 vías y 128 conjuntos | D10 | Falta |
| Alejandro | `rtl-p2/l2_replacement.sv` | PLRU de árbol (3 bits por conjunto) y Random con LFSR; vía libre primero | D10 | Falta |
| Alejandro | `rtl-p2/l2_cache.sv` | Bus versión 2 con `l2_gnt` solo cuando está libre (bloqueante). Write-back y write-allocate. `INCL_POLICY`: en exclusiva mueve la línea con `l2_rdirty`, no guarda lo que viene de la RAM y guarda las víctimas con `l2_wdirty`; en NINE copia. Víctimas sucias al eviction buffer. Hit en 8 ciclos. Vaciado de sus líneas sucias. Eventos para los contadores | D3, D9, D10, D16 (extra: exclusiva) | Falta |
| Alejandro | `tb-p2/tb_l2_cache.sv` | Hits de 8 ciclos, misses hasta la RAM, víctimas sucias, exclusiva y NINE, y vaciado | D3, D10 | Falta |
| Alejandro | `tb-p2/tb_l2_replacement.sv` | PLRU y Random | D10 | Falta |
| Alejandro | `docs/memory-hierarchy.md` | Documento obligatorio: políticas con justificación, diagramas L1/L2 y su conexión con el pipeline; reúne las secciones de José y Dylan (#34) | D3 a D16 | Falta |
| Dylan | `rtl-p2/mem_controller.sv` | `clk_mem` con divisor `MEM_DIV`; handshake de 4 fases con 2 flip-flops; Tmem exacto (25 + 7 × `MEM_DIV`); lee y escribe `DMEM` palabra por palabra en ráfaga; timeout de 256 ciclos con un reintento y `mem_error`; eventos para los contadores | D12, D13, D14 | Falta |
| Dylan | `rtl-p2/eviction_buffer.sv` | FIFO de líneas sucias (4 a 16); drena cuando el controlador está libre y no hay lecturas; reenvía la línea completa en un miss de L2; si se llena, la L2 espera | D15 | Falta |
| Dylan | `rtl-p2/perf_memory.sv` | Accesos (lecturas y escrituras), ciclos de transferencia y uso del ancho de banda (#14) | D12 | Falta |
| Dylan | `tb-p2/tb_mem_controller.sv` | Tmem = 53 exacto (39 y 60 con `MEM_DIV` 2 y 5), ráfagas, y memoria trabada con reintento y `mem_error` | D12, D13, D14 | Falta |
| Dylan | `tb-p2/tb_eviction_buffer.sv` | Buffer lleno, orden, forwarding y prioridad de las lecturas | D15 | Falta |
| Dylan | `docs/memory-hierarchy.md` | Sección de memoria principal y eviction buffer con el Tmem calculado (#33) | D12 a D15 | Falta, en el documento de Alejandro |
| Javier | `rtl-p2/decoder_cache_isa.sv` | Decodifica el tipo `1001101` en el slot 1 (ID): `vaciarc`, `medir` y `lcont` | D18 (extra: instrucciones) | Falta |
| Javier | `rtl-p2/cache_isa_unit.sv` | En EX: `medir` (registro de `measure_enable`, en 1 al reset), `lcont` (elige el contador con `sel` y registra el resultado como la LSU) y `vaciarc` (`flush_req` hasta `flush_done`, con stall) | D18 | Falta |
| Javier | `rtl-p2/perf_stage_counters.sv` | Ciclos ocupados, con burbuja y congelados en IF, ID, EX y WB (#8) | D19 | Falta |
| Javier | `rtl-p2/perf_cache_l2.sv` | Accesos de lectura y escritura desde la L1-D, hits y misses por tipo, movimientos y víctimas hacia la RAM (#26) | D3, D10 | Falta |
| Javier | `tb-p2/tb_cache_isa.sv` | Las 3 instrucciones sobre `top`, con `MEM_MODE` 0 y 2 | D18 | Falta |
| Javier | `tb-p2/tb_perf_stage_counters.sv`, `tb-p2/tb_perf_cache_l2.sv` | Pruebas de los contadores nuevos | D19, D10 | Falta |
| Javier | `examples/bench_secuencial.asm`, `examples/bench_aleatorio.asm`, `examples/bench_stride.asm` | Benchmarks de acceso a memoria con su `.expected.json` (#29) | Comparaciones | Falta |
| Javier | `examples/archivos/archivo18k.bin` | Archivo de 18 KB para `make archivo`: cabe en la jerarquía con exclusiva (20 KB) y no con NINE (16 KB) | D3 | Falta |
| Javier | `tools/comparar_configuraciones.py` | Corre los benchmarks con cada configuración de la sección 5 de las decisiones y genera la tabla de resultados (#30, #31) | Comparaciones | Falta |
