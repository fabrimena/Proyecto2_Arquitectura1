# Caché L1-D y write buffer L1-D → L2

> Proyecto Grupal 2, CE4301. Bloque de José García Izaguirre.
> Esta es la sección de la L1-D y del write buffer que se integra en `docs/memory-hierarchy.md`
> (a cargo de Alejandro). Interfaces: [memory-interfaces.md](memory-interfaces.md). Decisiones:
> [decisiones-importantes.md](decisiones-importantes.md) (D3 a D9, D16; secciones 3.7, 4.1 y 4.2).
> Las referencias "notas" son a las notas de clase del curso (Dr.-Ing. Jeferson González, 2026).

## 1. Archivos

| Archivo | Contenido |
|:---|:---|
| `rtl-p2/cache_defs.sv` | Constantes: geometría, campos de la dirección, códigos de las políticas, valores por defecto, bus L1-D ↔ L2 versión 2 |
| `rtl-p2/l1d_cache.sv` | Control de la L1-D: hit, miss segmentado, MSHR, víctimas, write buffer, vaciado, eventos |
| `rtl-p2/l1d_arrays.sv` | Bits V y D, etiquetas y datos de las 2 vías; puerto A (núcleo), puerto B (llenado y vaciado), un puerto de escritura |
| `rtl-p2/l1d_replacement.sv` | Reemplazo LRU, FIFO o RANDOM (LFSR) |
| `rtl-p2/l1d_write_buffer.sv` | Write buffer FIFO de 2 a 8 entradas (stores o víctimas, con bit sucio) y forwarding por bytes |
| `tb-p2/tb_l1d_replacement.sv` | Pruebas de las tres políticas de reemplazo |
| `tb-p2/tb_l1d_write_buffer.sv` | Pruebas del write buffer (dirigidas y aleatorias, profundidades 2, 3, 4 y 8) |
| `tb-p2/tb_l1d_cache.sv` | Pruebas de write-through + NINE (dirigidas y 6 configuraciones aleatorias) |
| `tb-p2/tb_l1d_writeback.sv` | Pruebas de write-back y de la política exclusiva (dirigidas y 8 configuraciones aleatorias) |
| `tb-p2/tb_l1d_mshr.sv` | Pruebas de los MSHR non-blocking (dirigidas, ráfagas y 6 configuraciones aleatorias) |

## 2. Geometría

4 KB, asociativa por conjuntos de 2 vías, líneas de 32 B (8 palabras): 128 bloques en 64 conjuntos
(enunciado 3.2.2; notas 6.2.1 y 6.2.2). La dirección es de 16 bits, igual que `memory.sv` (64 KB), para
que la caché vea las mismas palabras que la memoria del proyecto 1:

```
 15        11 10         5 4      2 1    0
+------------+------------+--------+------+
|  etiqueta  |   índice   | palabra| byte |
|   5 bits   |   6 bits   | 3 bits |2 bits|
+------------+------------+--------+------+
\_________________________/\______________/
  dirección de línea (11)   desplazamiento de bloque
```

Cada entrada guarda validez (V), sucio (D), etiqueta y la línea (notas 6.2.1 y 6.2.3). D solo se usa con
write-back; con write-through queda siempre en 0.

## 3. Políticas

Todas son parámetros de `l1d_cache` (códigos en `cache_defs.sv`), para que las comparaciones de la
sección 5 de `decisiones-importantes.md` salgan del mismo diseño.

| Parámetro | Configuración final | Otras opciones | Justificación |
|:---|:---|:---|:---|
| `WRITE_POLICY` | **Write-back** | write-through | Lo exige la exclusiva: con write-through cada store iría a la L2, que no tiene la línea (notas 6.2.3). Además los stores que aciertan no gastan ancho de banda hacia la L2 |
| `INCL_POLICY` | **Exclusiva** (crédito extra, aprobada por el profesor) | NINE | L1-D ∩ L2 = ∅ (notas 6.2.4): caben 4 + 16 = 20 KB distintos y la L2 hace de caché víctima de la L1-D (notas 6.3.3) |
| `ALLOC_POLICY` | Write-allocate | no-write-allocate | La combinación típica con write-back (notas 6.2.3). Por defecto sigue a `WRITE_POLICY`: write-allocate con write-back y no-write-allocate con write-through |
| `REPL_POLICY` | LRU | FIFO, RANDOM | Con 2 vías, LRU exacto cuesta 1 bit por conjunto, igual que FIFO, y aprovecha la localidad temporal (notas 6.1 y 6.2.3) |
| `RAW_POLICY` | Forwarding (solo con NINE) | stall | Un miss no espera al drenado (notas 6.3.5). Con exclusiva siempre se espera (ver sección 5) |
| `WB_DEPTH` | 4 | 2 a 8 | Absorbe ráfagas de víctimas sin agrandar mucho el comparador del forwarding |
| `N_MSHR` | 2 | 1 a 4 | Crédito extra non-blocking (sección 4). 1 = caché bloqueante, para comparar |
| `L2_BUS_V2` | 1 (bus versión 2) | 0 = bus anterior (`l2_ready`) | Ver sección 6 |

Combinaciones válidas: write-through + NINE, write-back + NINE y write-back + exclusiva. Write-through +
exclusiva y la inclusiva se rechazan con `$fatal` al inicio.

Los valores por defecto de `l1d_cache` son la configuración final de esta tabla (constantes
`L1D_DEFAULT_*`, `WB_DEPTH_DEFAULT` y `L1D_N_MSHR_DEFAULT` de `cache_defs.sv`, y `L2_BUS_V2 = 1`). Para
medir otra configuración se pasan los parámetros al instanciar, sin tocar el diseño. Los testbenches
pasan siempre su configuración explícita; por ejemplo, `tb_l1d_cache` usa write-through + NINE y
`tb_l1d_writeback` usa `N_MSHR = 1` porque mide la caché bloqueante.

**Qué hace cada combinación:**

| Situación | write-through + NINE | write-back + NINE | write-back + exclusiva |
|:---|:---|:---|:---|
| Store que acierta | L1-D y write buffer | Solo L1-D, línea sucia | Solo L1-D, línea sucia |
| Miss, hit en L2 | La línea se copia | La línea se copia | La línea se **mueve** con su bit sucio (`l2_rdirty`); la L2 la invalida |
| La L1-D desaloja | Se descarta (está limpia) | Sucia: al write buffer; limpia: se descarta | **Siempre** al write buffer, limpia o sucia (`l2_wdirty`) |
| Vaciado | Drenar el write buffer | Las sucias al buffer (quedan válidas y limpias) y drenar | Las sucias se **mueven** a la L2 (quedan inválidas) y drenar |

**Reemplazo.** LRU y FIFO guardan 1 bit por conjunto que apunta a la víctima, con la misma fórmula: al
usar la vía `w`, el bit pasa a `~w`. LRU lo actualiza en cada hit y en cada llenado; FIFO solo en los
llenados. RANDOM usa un LFSR de 8 bits (x⁸+x⁶+x⁵+x⁴+1) que avanza en cada llenado, así la simulación es
repetible. Si hay una vía vacía se usa esa antes que la política.

**La víctima se elige al llenar, no al pedir** (D8). Mientras la línea viaja, el conjunto puede cambiar (un
MSHR anterior del mismo conjunto se llenó). Así dos misses del mismo conjunto no escogen la misma vía.

## 4. Pipeline de la caché

### Camino del hit (dentro de EX, combinacional)

Las 4 etapas del acceso segmentado a caché (notas 6.3.1, figura 6.8) están separadas y rotuladas en el
código, pero sin registros entre ellas, porque un hit debe responder en el mismo ciclo que `memory.sv`
(no cambian la regla N+3 ni la latencia de las cargas):

```
E1 dirección -> E2 desambiguación -> E3 acceso paralelo        -> E4 resultado
(la LSU suma    (etiqueta, índice,   (etiquetas y datos de las     (multiplexor de vía
 base + offset)  palabra)             2 vías a la vez, 2 comp.)     y de palabra)
```

E3 usa **acceso paralelo** (notas 6.3.1, figura 6.9): se leen las dos vías de etiquetas y datos a la vez y
un multiplexor elige la que acertó (hardware de la figura 6.5). Es la opción de menor latencia, a cambio de
leer siempre las dos vías de datos. La L1-D entrega la palabra completa; la LSU elige el byte y extiende el
signo en `cargabai`, igual que con `memory.sv`. Los stores con byte enables (`guardab`) escriben solo los
bytes de `be`.

### Camino del miss (etapas con valid/ready, mejora opcional del enunciado 3.3)

```
             +----------------+ valid: sin RAW que obligue  +--------------------+
 acceso ---->| M1 asignación  | a esperar y, con write-back,| M2 solicitud       |---> l2_req
 que falla   | (MSHR, o miss  | un lugar en el write buffer | (lectura de línea) |
             |  bloqueante)   |---------------------------->|                    |
             +----------------+ ready: l2_gnt               +---------+----------+
                                                                      | l2_rvalid
                                                            +---------v----------+
                                                            | M3 llenado         |---> dato al núcleo
                                                            | víctima, forwarding|     (bypass, si era
                                                            | bytes del MSHR     |      su miss)
                                                            +---------+----------+
                                                                      | víctima
 en paralelo:  D1 drenado: cabeza del write buffer -> L2   <----------+ (write buffer)
```

- **M1** registra el miss (notas 6.3.4). Un load que falla detiene al núcleo (miss bloqueante). Un store
  que falla, con MSHR, ocupa uno y el núcleo sigue (ver más abajo).
- **M2** pide la línea a la L2: la del MSHR más viejo si hay alguno; si no, la del acceso. Espera si la
  línea tiene entradas en el write buffer y no hay forwarding (RAW), y con write-back espera un lugar libre
  en el write buffer para la víctima de M3.
- **M3** elige la víctima en ese momento, por el puerto B de los arreglos. La víctima va al write buffer si
  está sucia, o siempre con exclusiva. La línea nueva se corrige con el write buffer (forwarding, solo
  NINE) y se escribe en su vía. Si era el miss del acceso, el dato sale al núcleo en ese mismo ciclo y se
  aplica el store si es write-allocate. Si era de un MSHR, se le ponen encima los bytes de sus stores y
  queda sucia.
- **D1** drena el write buffer sin detener al núcleo cuando el bus está libre. M2 tiene prioridad.
  Mientras hay una lectura pendiente no se drena, por dos razones: el lugar reservado para la víctima
  sigue libre, y la L2 responde la lectura antes de recibir cualquier escritura posterior (el forwarding
  ve todas las entradas que la L2 todavía no tiene).

### MSHR non-blocking para stores (crédito extra, D8; notas 6.3.4)

Se activan con write-back + write-allocate y `N_MSHR` ≥ 2. Una carga que falla siempre detiene el bundle:
el hardware no hace scoreboarding y su registro se escribe a distancia fija (regla N+3). Los stores no
escriben registros, así que pueden seguir.

```
           MSHR 0 (más viejo)        MSHR 1                ...   MSHR N_MSHR-1
         +------------------------+------------------------+-----+-------------+
         | línea | bytes | datos  | línea | bytes | datos  |     |             |
         +------------------------+------------------------+-----+-------------+
```

| Caso | Qué pasa |
|:---|:---|
| Store que falla, MSHR libre | Ocupa uno con su línea, sus bytes y su dato; **0 ciclos** de stall |
| Store a una línea con MSHR | Se mezcla en ese MSHR; 0 ciclos |
| Store que falla, MSHR llenos | Espera a que se llene el más viejo |
| Load o store que acierta | Sigue normal (hit under miss) |
| Load a una línea con MSHR | Toma la palabra del MSHR si tiene sus 4 bytes; si no, espera la línea |
| Load que falla en otra línea | Espera a que se vacíen los MSHR y hace su miss bloqueante (los llenados salen en orden) |
| Ciclo de llenado de un MSHR | Los stores esperan 1 ciclo: hay un solo puerto de escritura en los arreglos |
| Vaciado | Empieza cuando no queda ningún MSHR ocupado |

Los MSHR forman una cola: se piden y se llenan en orden de llegada. Hay **una lectura a la L2 en vuelo a la
vez**. Con la L2 bloqueante no se pierde nada; con la L2 de 4 etapas (Fabricio) se podrían superponer
lecturas, y eso queda como mejora. Con `N_MSHR` = 1 la caché es exactamente la bloqueante.

### Latencias (medidas en `tb_l1d_cache`, `tb_l1d_writeback` y `tb_l1d_mshr`, L2 de 8 ciclos)

| Caso | Ciclos de stall |
|:---|:---:|
| Hit en L1-D (load o store) | 0 |
| Miss en L1-D, hit en L2 | 8 |
| Miss con víctima sucia (o limpia con exclusiva) | 8 (la víctima sale por el write buffer) |
| Miss en L1-D, miss en L2 | 8 + Tmem (lo agrega la L2) |
| Store que falla con no-write-allocate | 0 |
| Store que falla con un MSHR libre | 0 |
| Store que falla con los MSHR llenos | hasta que se llene el más viejo + 1 (8 en la prueba 6 de `tb_l1d_mshr`) |
| Load que falla con un MSHR ocupado | lo que falte de ese llenado + 1 + 8 (17 en la prueba 7) |
| Miss a una línea que está en el write buffer, con exclusiva | lo que tarde en drenarse + 8 |
| Miss mientras se drena una entrada del write buffer | lo que falte del drenado + 8 |
| Store con el write buffer lleno (write-through) | hasta que se libere una entrada (6 en la prueba 8 de `tb_l1d_cache`) |

## 5. Write buffer L1-D → L2

FIFO circular de `WB_DEPTH` entradas (enunciado 3.4; notas 6.3.5, figura 6.12). Cada entrada es
`{línea addr[15:5], máscara de 32 bytes, 256 bits de datos, sucio}`, el mismo formato del bus hacia la L2
(`l2_wline`, `l2_be`, `l2_wdirty`): "escribe estos bytes de esta línea". Puede ser:

- **un store** (write-through, o miss con no-write-allocate): sus 1 o 4 bytes;
- **una víctima** (write-back): la línea completa con su bit sucio;
- **una línea del vaciado**: completa y sucia.

El núcleo solo espera al buffer si está lleno (riesgo estructural).

**Riesgo RAW en memoria** (notas 6.3.5, figura 6.13). Si un miss pide una línea que todavía tiene
entradas en el buffer, la L2 devolvería datos viejos:

- NINE + `RAW_FORWARD`: se pide igual y, al llegar la línea, se le ponen encima los bytes pendientes, de
  la entrada más vieja a la más nueva (gana la más reciente).
- NINE + `RAW_STALL`: la solicitud espera hasta que el buffer drene esas entradas.
- **Exclusiva: siempre se espera** (D7). La entrada es una víctima en camino; si se reenviara, la línea
  quedaría en la L1-D y, al drenarse, también en la L2. Después se pide a la L2, que la devuelve con su
  bit sucio (`l2_rdirty`).

## 6. Interfaz

**Núcleo** (puerto A de `memory.sv` más `stall` = `cache_stall`): `re`, `we`, `be`, `addr`, `wdata`,
`rdata`, `stall`. `stall` depende solo del acceso y de registros (las salidas de la L2 deben salir de
registros), así que está estable antes del flanco de bajada. Cada store escribe una sola vez, en el ciclo
en que `stall = 0`. El puerto B de la unidad cripto lo junta Fabricio sobre este puerto único y, para los
MSHR, se trata como carga.

**L2, bus versión 2** (D9; tabla completa en `cache_defs.sv`, sección 4):

| Señal | Dirección | Significado |
|:---|:---:|:---|
| `l2_req`, `l2_we`, `l2_addr` | L1-D → L2 | Petición: lectura de línea o escritura con máscara |
| `l2_wline`, `l2_be`, `l2_wdirty` | L1-D → L2 | Datos, bytes a escribir y si la línea va sucia |
| `l2_gnt` | L2 → L1-D | La L2 aceptó la petición en este ciclo |
| `l2_rvalid`, `l2_rline`, `l2_rdirty` | L2 → L1-D | Respuesta de una lectura, en orden; con exclusiva, si la línea llega sucia |

La petición se mantiene igual hasta `l2_gnt`. Una escritura termina al ser aceptada. Con
`L2_BUS_V2 = 0` (bus anterior) `l2_ready` hace de aceptación y, en una lectura, también de respuesta.

**Vaciado** (D16; `decisiones-importantes.md` 3.7): `flush_req` / `flush_done`. La L1-D espera a que no
quede ningún miss ni MSHR. Con write-back recorre las 128 casillas por el puerto B y manda cada línea
sucia al write buffer. Después espera a que el buffer quede vacío y el bus libre. `flush_done` se mantiene
mientras `flush_req` siga en 1. Bajar la L2 a la RAM va después de `flush_done` (Alejandro).

**Eventos para los contadores** (pulsos de 1 ciclo en `clk`, Javier):

| Evento | Cuándo |
|:---|:---|
| `ev_rd_hit`, `ev_rd_miss`, `ev_wr_hit`, `ev_wr_miss` | Uno por acceso, al terminar; la clasificación es la del primer ciclo. Un store que va a un MSHR y un load servido desde un MSHR cuentan como miss (miss secundario) |
| `ev_stall` | Ciclo con stall, por cualquier causa |
| `ev_wb_full_stall`, `ev_raw_stall` | Ciclo con stall porque el write buffer está lleno / por riesgo RAW o espera de línea |
| `ev_raw_forward` | Llenado corregido con datos del write buffer |
| `ev_wb_push`, `ev_l2_read`, `ev_l2_write` | Entrada nueva en el buffer / inicio de una lectura / inicio de un drenado |
| `ev_fill` | Llegó una línea de la L2 (con exclusiva, un movimiento) |
| `ev_victim_dirty`, `ev_victim_clean` | Víctima sucia / limpia (solo exclusiva) al write buffer |
| `ev_mshr_alloc`, `ev_mshr_merge` | Store que falló y ocupó un MSHR / se mezcló en uno, sin stall |
| `ev_mshr_load` | Load servido desde un MSHR |
| `ev_hit_under_miss` | Acierto en la L1-D mientras hay MSHR ocupados |
| `ev_mshr_full_stall` | Ciclo con stall porque todos los MSHR están ocupados |

Con ellos se calculan los accesos, hits y misses de la tabla 2 del enunciado, la tasa de desaciertos del
AMAT (notas 6.2) y los contadores de los créditos extra (víctimas, movimientos, stores que no se
detuvieron).

## 7. Validación

```bash
make tb_l1d_replacement tb_l1d_write_buffer tb_l1d_cache tb_l1d_writeback tb_l1d_mshr
```

| Testbench | Qué prueba | Resultado |
|:---|:---|:---:|
| `tb_l1d_replacement` | LRU, FIFO, RANDOM; conjuntos independientes; secuencia A, B, A, C | 17/17 |
| `tb_l1d_write_buffer` | Orden FIFO, lleno/vacío, vuelta circular, forwarding, víctimas con bit sucio, búsqueda de línea; aleatoria con stores y víctimas, profundidades 2, 3, 4 y 8 | 15 613/15 613 |
| `tb_l1d_cache` | Write-through + NINE: 9 pruebas dirigidas y 6 configuraciones aleatorias | 81/81 |
| `tb_l1d_writeback` | Write-back + exclusiva: 6 pruebas dirigidas; 8 configuraciones aleatorias (WB + NINE, WB + exclusiva, WT + NINE) | 68/68 |
| `tb_l1d_mshr` | MSHR: 9 pruebas dirigidas; ráfagas y 6 configuraciones aleatorias con `N_MSHR` = 1, 2, 3 y 4 | 109/109 |

Mientras no esté la L2 real, cada testbench trae su propio modelo de L2 con el bus versión 2. El modelo
acepta de inmediato y responde a los 8 ciclos, o con latencia variable y a veces 8 + 53, como un miss de
L2. También revisa que la petición no cambie antes de `l2_gnt`. Los de write-back y MSHR separan "lo más
nuevo debajo de la L1-D" de "lo que tiene la RAM" para comprobar dos cosas:

- que una víctima limpia coincida con la RAM. Si la L1-D perdiera un bit sucio, una L2 real descartaría
  la línea;
- que con exclusiva la lectura mueva la línea con su bit sucio.

Las pruebas aleatorias comparan cada carga, y la memoria después de cada vaciado, contra una memoria de
referencia. También revisan:

- que el vaciado no deje líneas sucias ni MSHR ocupados;
- que haya exactamente un evento hit/miss por acceso;
- con exclusiva, que **ninguna línea que la L2 acepta siga válida en la L1-D**;
- que se hayan ejercitado los casos importantes de cada configuración: víctimas sucias y limpias,
  forwarding, esperas, reservas y mezclas de MSHR, loads desde un MSHR, hits durante un miss y MSHR
  llenos.

**Comparación de `N_MSHR`** (`tb_l1d_mshr`, la misma secuencia de 3000 accesos aleatorios, exclusiva):

| `N_MSHR` | Ráfaga de 6 stores que fallan (stall de cada uno) | Ciclos de la secuencia aleatoria |
|:---:|:---|:---:|
| 1 | 8, 8, 8, 8, 8, 8 | 46 603 |
| 2 | 0, 0, 8, 8, 8, 8 | 45 377 |
| 4 | 0, 0, 0, 0, 6, 8 | 44 420 |

En la secuencia aleatoria la ganancia es pequeña. La mitad de los accesos son loads, y un load que falla
espera a que se vacíen los MSHR. Los benchmarks con ráfagas de stores a líneas nuevas (prólogos de `balc`,
escritura de arreglos) deberían mostrar más diferencia. Esa medición le toca a Javier.

**Pruebas de mutación.** Para confirmar que los testbenches detectan errores, se introdujeron fallas a
propósito en una copia de `l1d_cache.sv`, y cada una hizo fallar las pruebas:

- ignorar `l2_rdirty`;
- no mandar las víctimas limpias con exclusiva;
- perder los bytes viejos al mezclar un store en un MSHR;
- ignorar los bytes del MSHR al llenar;
- dejar que un store termine en el ciclo del llenado de un MSHR.

## 8. Diferencias con `decisiones-importantes.md`

- **Vaciado con exclusiva** (3.7 dice que las líneas quedan válidas y limpias). Con NINE es así. Con
  exclusiva, una línea sucia que se manda a la L2 se **invalida** en la L1-D: si quedara válida estaría en
  los dos niveles a la vez (L1 ∩ L2 ≠ ∅). Las líneas limpias sí quedan válidas, porque no están en la L2.
  El programa puede seguir después del vaciado, solo que esas líneas vuelven a pedirse a la L2 (8 ciclos).
- **Revisión de exclusividad**: mis testbenches revisan el sentido "la L2 acepta una línea → no está en la
  L1-D". El otro sentido ("la L1-D se llena → la línea no queda en la L2") depende de la L2 real y se
  revisa en la integración.

## 9. Pendiente de otros bloques

- **Javier:** ya adaptó sus contadores (`perf_cache_l1d.sv`, `tb_perf_cache_l1d_k1a.sv`,
  [perf-cache-l1d-k1a.md](perf-cache-l1d-k1a.md)) al bus versión 2 y a los eventos de víctimas y MSHR.
  Falta medir con los benchmarks las comparaciones de `decisiones-importantes.md`, sección 5 (NINE contra
  exclusiva, write-through contra write-back, reemplazo, `N_MSHR` = 1, 2 y 4).
- **Fabricio:** conectar `l1d_cache` en `top.sv` (`MEM_MODE = 2`) y pasar el puerto B (`vcr`, `camcon`)
  por la L1-D.
- **Alejandro:** L2 real con el bus versión 2 (salidas registradas, `l2_rdirty` con exclusiva, guardar las
  víctimas limpias), su vaciado después de `flush_done`, e integrar esta sección en
  `docs/memory-hierarchy.md`.
