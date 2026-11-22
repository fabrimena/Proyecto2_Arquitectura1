# Documentación del proyecto 2

Índice de la documentación del Proyecto Grupal II (CE4301): jerarquía de caché L1-D/L2, memoria
principal y análisis de rendimiento sobre el procesador VLIW del proyecto 1. Cómo instalar, compilar y
ejecutar está en el [README del repositorio](../README.md).

## Empezar aquí: los tres documentos que pide el enunciado (8.1.2)

| Documento | Contenido |
|:---|:---|
| [memory-hierarchy.md](memory-hierarchy.md) | 1. Arquitectura de la jerarquía de memoria: políticas de escritura, reemplazo e inclusión (exclusiva) con su justificación, write buffer y eviction buffer con su manejo del riesgo RAW, latencias y diagramas de la L1-D, la L2 y su relación con el pipeline (sección 8) |
| [microarchitecture.md](microarchitecture.md) | 2. Organización y microarquitectura: diagrama del sistema ([`img/diagrama_proyecto2.svg`](../img/diagrama_proyecto2.svg)), pipeline, congelamiento del núcleo, cachés, buffers, controlador de memoria, contadores y flujo de datos e instrucciones |
| [performance-analysis.md](performance-analysis.md) | 3. Análisis de rendimiento y validación: la sección «Resumen de resultados» tiene la metodología, los benchmarks, las tasas por nivel, el AMAT, la utilización de la RAM, la comparación de configuraciones y la justificación de las decisiones |

## Arquitectura y componentes

| Documento | Contenido |
|:---|:---|
| [memory-interfaces.md](memory-interfaces.md) | Señales entre bloques: núcleo y jerarquía, modos de `top` (`MEM_MODE`), congelamiento del núcleo, bus L1-D/L2 (versión 2), eviction buffer y memoria principal, vaciado y puerto B de la cripto |
| [l1d-cache.md](l1d-cache.md) | Caché L1-D y write buffer: políticas, MSHR, forwarding y parámetros |
| [memory-main-eviction-buffer.md](memory-main-eviction-buffer.md) | Memoria principal, controlador con cruce de relojes y timeouts, y eviction buffer |

## ISA y compilador

| Documento | Contenido |
|:---|:---|
| [isa.md](isa.md) | ISA del proyecto 1 sin cambios y las instrucciones nuevas `vaciarc`, `medir` y `lcont` (codificación, slot y semántica) |
| [compiler-integration.md](compiler-integration.md) | Contrato con el compilador de CE1108 y cómo se ejecutan sus programas sobre el RTL |

## Decisiones

| Documento | Contenido |
|:---|:---|
| [decisiones-importantes.md](decisiones-importantes.md) | Decisiones de diseño D1 a D19, quién hizo cada parte y comparación de la L2 bloqueante con la de 4 etapas |

## Pruebas

| Documento | Contenido |
|:---|:---|
| [simulation.md](simulation.md) | Herramientas, comandos y qué verifica cada testbench de `tb/` y `tb-p2/` |

## Evidencia de verificación por issue ([`verificacion/`](verificacion/))

Reportes de cada bloque de métricas y de las herramientas, con sus comandos y resultados. Son
registros de la fecha en que se hizo cada bloque; el estado vigente está en
[performance-analysis.md](performance-analysis.md).

| Documento | Contenido |
|:---|:---|
| [verificacion-cierre-javier.md](verificacion/verificacion-cierre-javier.md) | Cierre de las métricas y el rendimiento: cobertura por issue, pruebas, medidas y límites |
| [perf-cache-l1d-k1a.md](verificacion/perf-cache-l1d-k1a.md) | #26, K1-A: contadores de eventos de la L1-D |
| [perf-cache-l1d-k1b.md](verificacion/perf-cache-l1d-k1b.md) | #26, K1-B: servicio y espera de cada acceso a la L1-D |
| [perf-stage-counters.md](verificacion/perf-stage-counters.md) | #8: contadores de ocupación y congelamiento por etapa |
| [perf-d3-validacion-top.md](verificacion/perf-d3-validacion-top.md) | #7, D3: validación de las métricas contra `top` |
| [perf-d4a-recuperacion-saltos.md](verificacion/perf-d4a-recuperacion-saltos.md) | #7, D4-A: ciclos perdidos por saltos |
| [perf-d4b1-modulo-metricas.md](verificacion/perf-d4b1-modulo-metricas.md) | #7, D4-B1: módulo de métricas VLIW |
| [perf-d5a-validacion-stalls.md](verificacion/perf-d5a-validacion-stalls.md) | #7, D5-A: métricas durante los congelamientos |
| [perf-integracion-top.md](verificacion/perf-integracion-top.md) | Integración de las métricas VLIW, de etapas y de la L1-D en el procesador |
| [regresion-dos-modos-p9.md](verificacion/regresion-dos-modos-p9.md) | #9: regresión con y sin la jerarquía de caché |
| [flush-herramientas-p28.md](verificacion/flush-herramientas-p28.md) | #28: vaciado de la caché en las herramientas de ejecución |
| [benchmarks-memoria-p29.md](verificacion/benchmarks-memoria-p29.md) | #29: benchmarks secuencial, aleatorio y stride |

## Proceso del equipo ([`proceso/`](proceso/))

| Documento | Contenido |
|:---|:---|
| [guia-desarrollo.md](proceso/guia-desarrollo.md) | Plan de trabajo del 7 de noviembre: qué archivos tocaba cada integrante y su estado |
| [guion-defensa-javier.md](proceso/guion-defensa-javier.md) | Guion de la defensa del aporte de Javier (métricas, benchmarks y compilador) |
