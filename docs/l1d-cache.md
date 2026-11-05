# Caché L1-D y write buffer L1-D → L2

> Proyecto Grupal 2, CE4301. Bloque de José García Izaguirre.
> Esta es la sección de la L1-D y del write buffer que se integra en `docs/memory-hierarchy.md`
> (a cargo de Alejandro). Interfaces: [memory-interfaces.md](memory-interfaces.md).
> Las referencias "notas" son a las notas de clase del curso (Dr.-Ing. Jeferson González, 2026).

## 1. Archivos

| Archivo | Contenido |
|:---|:---|
| `rtl-p2/cache_defs.sv` | Constantes: geometría, campos de la dirección, políticas, write-through y NINE |
| `rtl-p2/l1d_cache.sv` | Control de la L1-D: hit, miss segmentado, write buffer, vaciado, eventos |
| `rtl-p2/l1d_arrays.sv` | Etiquetas, bits de validez y datos de las 2 vías (lectura paralela) |
| `rtl-p2/l1d_replacement.sv` | Reemplazo LRU, FIFO o RANDOM (LFSR) |
| `rtl-p2/l1d_write_buffer.sv` | Write buffer FIFO de 2 a 8 entradas con forwarding por bytes |
| `tb-p2/tb_l1d_replacement.sv` | Pruebas de las tres políticas de reemplazo |
| `tb-p2/tb_l1d_write_buffer.sv` | Pruebas del write buffer (dirigidas y aleatorias, profundidades 2, 3, 4 y 8) |
| `tb-p2/tb_l1d_cache.sv` | Pruebas de la L1-D con una L2 ideal (dirigidas y 6 configuraciones aleatorias) |

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
                          \______________/
                       desplazamiento de bloque
```

Cada entrada guarda validez (V), etiqueta y la línea (notas 6.2.1). No hay bit sucio (ver la sección 3).

## 3. Políticas

| Política | Decisión | Configurable | Justificación |
|:---|:---|:---:|:---|
| Escritura | **Write-through** | No | La L1-D queda siempre limpia: no necesita bit sucio, las líneas que salen se descartan y el vaciado se reduce a drenar el write buffer. El costo de escribir cada store en la L2 lo esconde el write buffer (notas 6.2.3 y 6.3.5) |
| Inclusión | **NINE** | No | Con un solo núcleo, la ventaja de la inclusión (consultar solo la L2 para la coherencia, notas 6.2.4) no aplica. NINE no requiere invalidación hacia atrás ni su contador |
| Asignación en miss de escritura | No-write-allocate | Sí (`ALLOC_POLICY`) | La combinación típica con write-through (notas 6.2.3): un store que falla va directo al buffer, sin traer la línea ni detener el núcleo |
| Reemplazo | LRU | Sí (`REPL_POLICY`: LRU, FIFO, RANDOM) | Con 2 vías, LRU exacto cuesta 1 bit por conjunto, igual que FIFO, y aprovecha la localidad temporal (notas 6.1 y 6.2.3) |
| Riesgo RAW del write buffer | Forwarding | Sí (`RAW_POLICY`: forwarding o stall) | Un miss no espera al drenado; es la estrategia preferida en procesadores modernos (notas 6.3.5) |
| Tamaño del write buffer | 4 entradas | Sí (`WB_DEPTH`: 2 a 8) | Absorbe ráfagas de stores sin agrandar mucho el comparador del forwarding |

**Reemplazo.** LRU y FIFO guardan 1 bit por conjunto que apunta a la víctima, con la misma fórmula: al
usar la vía `w`, el bit pasa a `~w`. LRU lo actualiza en cada hit y en cada llenado; FIFO solo en los
llenados. RANDOM usa un LFSR de 8 bits (x⁸+x⁶+x⁵+x⁴+1) que avanza en cada llenado, así la simulación es
repetible. Si hay una vía vacía se usa esa antes que la política.

**NINE con write-through.** Cuando la L2 desaloja una línea no avisa a la L1-D, y la copia de la L1-D sigue
siendo válida. Cuando la L1-D desaloja una línea simplemente la descarta, porque todo lo que se escribió en
ella ya está en la L2 o esperando en el write buffer. La unidad cripto (puerto B) debe pasar también por la
L1-D para no escribir la memoria "por detrás" (Fabricio).

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
             +--------------+  valid: sin RAW bloqueante  +-------------------+
 acceso ---->| M1 asignación|---------------------------->| M2 solicitud      |---> l2_req
 que falla   | (MSHR: vía)  |  ready: bus a la L2 libre   | (lectura de línea)|
             +--------------+                             +---------+---------+
                                                                    | l2_ready
                                                          +---------v---------+
                                                          | M3 llenado        |---> dato al núcleo
                                                          | forwarding+bypass |     (mismo ciclo)
                                                          +-------------------+
 en paralelo:  D1 drenado: cabeza del write buffer -> L2 cuando el bus está libre
```

- **M1** guarda en el MSHR (notas 6.3.4) la vía elegida para que no cambie durante la espera. La línea
  que había ahí se descarta en el llenado: con write-through siempre está limpia.
- **M2** pide la línea a la L2. Con `RAW_STALL` espera a que el write buffer drene los stores de esa línea.
- **M3** corrige la línea con el write buffer (forwarding), la escribe en la vía y, en ese mismo ciclo, le
  entrega el dato al núcleo y aplica el store si es write-allocate.
- **D1** drena el write buffer sin detener al núcleo. Las lecturas de M2 tienen prioridad sobre D1 porque el
  núcleo las está esperando.

La caché es bloqueante (1 MSHR): el núcleo VLIW se congela en cada miss (enunciado 3.3), así que nunca llega
otro acceso mientras se atiende uno.

### Latencias (medidas en `tb_l1d_cache`)

| Caso | Ciclos de stall |
|:---|:---:|
| Hit en L1-D (load o store) | 0 |
| Miss en L1-D, hit en L2 | 8 |
| Miss en L1-D, miss en L2 | 8 + Tmem (lo agrega la L2) |
| Store que falla con no-write-allocate | 0 |
| Miss mientras se drena una entrada del write buffer | lo que falte del drenado + 8 |
| Store con el write buffer lleno | hasta que se libere una entrada (6 ciclos en la prueba 8) |

## 5. Write buffer L1-D → L2

FIFO circular de `WB_DEPTH` entradas (enunciado 3.4; notas 6.3.5, figura 6.12). Con write-through, **cada
store es una entrada** `{línea addr[15:5], máscara de 32 bytes, 256 bits de datos}`: `guardap` marca 4
bytes y `guardab` marca 1. Es el mismo formato del bus hacia la L2 (`l2_wline`, `l2_be`): "escribe estos
bytes de esta línea". El store entra al buffer en 1 ciclo y el núcleo sigue; solo espera si el buffer está
lleno (riesgo estructural).

**Riesgo RAW en memoria** (notas 6.3.5, figura 6.13). Si un miss pide una línea que todavía tiene stores en
el buffer, la L2 devolvería datos viejos:

- `RAW_FORWARD`: se pide igual y, al llegar la línea, se le ponen encima los bytes pendientes del buffer,
  de la entrada más vieja a la más nueva (gana el store más reciente).
- `RAW_STALL`: la solicitud espera hasta que el buffer drene esas entradas.

Un load que acierta en la L1-D nunca tiene riesgo RAW: con write-through, el store que acierta actualiza la
L1-D en el mismo ciclo en que entra al buffer.

## 6. Interfaz

Núcleo (puerto A de `memory.sv` más `stall` = `cache_stall`): `re`, `we`, `be`, `addr`, `wdata`,
`rdata`, `stall`. `stall` depende solo del acceso y de registros (incluido `l2_ready`, que la L2 debe
sacar de un registro). Cada store escribe una sola vez, en el ciclo en que `stall = 0`.

L2: `l2_req`, `l2_we`, `l2_addr`, `l2_wline`, `l2_be`, `l2_ready`, `l2_rline`, como en
`memory-interfaces.md` sección 5. La petición no cambia hasta `l2_ready`.

Vaciado: `flush_req` / `flush_done`. Con write-through la L1-D solo espera a que el write buffer quede
vacío y el bus libre; no recorre sus líneas, que quedan válidas. Bajar la L2 a la RAM va después de
`flush_done` (Alejandro).

Eventos para los contadores (pulsos de 1 ciclo en `clk`): `ev_rd_hit`, `ev_rd_miss`, `ev_wr_hit`,
`ev_wr_miss` (uno por acceso, al terminar), `ev_stall`, `ev_wb_full_stall`, `ev_raw_stall`,
`ev_raw_forward`, `ev_wb_push`, `ev_l2_read`, `ev_l2_write`. Con ellos se calculan los accesos, hits y
misses por lectura y escritura de la tabla 2 del enunciado y la tasa de desaciertos del AMAT (notas 6.2).

## 7. Validación

```bash
make tb_l1d_replacement tb_l1d_write_buffer tb_l1d_cache
```

| Testbench | Qué prueba | Resultado |
|:---|:---|:---:|
| `tb_l1d_replacement` | LRU, FIFO, RANDOM; conjuntos independientes; secuencia A, B, A, C | 17/17 |
| `tb_l1d_write_buffer` | Orden FIFO, lleno/vacío, vuelta circular, forwarding; aleatoria con stores reales, profundidades 2, 3, 4 y 8 | 14 248/14 248 |
| `tb_l1d_cache` | 9 pruebas dirigidas y 6 configuraciones aleatorias | 79/79 |

`tb_l1d_cache` usa una L2 ideal propia del testbench (`tb_l2_model`, 8 ciclos, o latencia variable con
"misses" de 8 + 53) mientras no esté la L2 real. Las pruebas dirigidas comprueban:

- las latencias de la tabla de la sección 4;
- que cada store llega a la L2 sin vaciado;
- el store que falla sin traer la línea;
- el forwarding RAW;
- LRU sin escrituras al desalojar;
- la espera con el buffer lleno;
- el vaciado.

Las aleatorias comparan cada carga, y la memoria de la L2 después del vaciado, contra una memoria de
referencia:

| Configuración | Write buffer | L2 |
|:---|:---:|:---|
| no-write-allocate, LRU, forwarding | 4 | 8 ciclos |
| write-allocate, FIFO, stall | 2 | variable |
| no-write-allocate, RANDOM, forwarding | 2 | variable |
| write-allocate, LRU, stall | 8 | 8 ciclos |
| write-allocate, RANDOM, forwarding | 3 | variable |
| no-write-allocate, FIFO, stall | 4 | variable |

## 8. Pendiente de otros bloques

- **Fabricio:** conectar `l1d_cache` en `top.sv` (`MEM_MODE = 2`) y pasar el puerto B (`vcr`,
  `camcon`) por la L1-D, atendiendo los dos puertos uno después del otro.
- **Alejandro:** L2 real con este protocolo (`l2_ready` registrado), su vaciado después de `flush_done`, e
  integrar esta sección en `docs/memory-hierarchy.md`.
- **Javier:** contadores a partir de los eventos `ev_*`.
