# Jerarquía de memoria del procesador VLIW

> Proyecto Grupal 2, CE4301. Documento obligatorio #34.
> A cargo de **Alejandro Vásquez Oviedo**, con las secciones de **José García Izaguirre** (L1-D y
> write buffer) y de **Dylan Guerrero González** (memoria principal, controlador y eviction buffer).
> Decisiones: [decisiones-importantes.md](decisiones-importantes.md) (D3 a D16; secciones 3.3 a 3.5,
> 3.7 y 4.1). Contrato de señales: [memory-interfaces.md](memory-interfaces.md).
> Documentos de detalle: [l1d-cache.md](l1d-cache.md) (José) y
> [memory-main-eviction-buffer.md](memory-main-eviction-buffer.md) (Dylan).

---

## 1. Vista general

La jerarquía tiene tres niveles de almacenamiento, más un buffer de líneas sucias entre la caché
intermedia y la memoria principal:

```text
   LSU (puerto A)  y  cripto (puerto B)
            |            |
            +----- l1d_port_arbiter ----+
                                         |
                                   l1d_cache                 4 KB, 2 vías, 64 conjuntos
                                   (write buffer L1-D -> L2)
                                         |
                            bus versión 2 (L1-D <-> L2)
                                         |
                              l2_cache  (o l2_model)        16 KB, 4 vías, 128 conjuntos
                                         |
                              líneas sucias desalojadas
                                         |
                              eviction_buffer                4 líneas sucias (EB_DEPTH)
                                         |
                              mem_controller                  25 MHz, Tmem = 53 ciclos
                                         |
                                    RAM (DMEM)                64 KB, 16 384 palabras
```

### 1.1 Los tres niveles de un vistazo

| Nivel | Módulo | Capacidad | Organización | Línea | Acierto | Fallo |
|:---|:---|---:|:---|---:|:---|:---|
| L1-D | `l1d_cache.sv` | 4 KB | 2 vías, 64 conjuntos | 32 B (8 palabras) | dentro de EX, sin etapa MEM | 8 ciclos si la L2 acierta; 8 + 53 si va a la RAM |
| L2 | `l2_cache.sv` | 16 KB | 4 vías, 128 conjuntos | 32 B (8 palabras) | 8 ciclos | 8 + Tmem = **61** ciclos con Tmem = 53 |
| Memoria | `mem_controller.sv` | 64 KB | 16 384 palabras de 32 bits | ráfaga de 8 palabras | — | Tmem = 25 + 7 × MEM_DIV = **53** |

Entre la L2 y la memoria está el **eviction buffer**: una FIFO de 4 líneas sucias (4 a 16) que absorbe
las víctimas de la L2 y que además puede reenviar una línea sucia a un fallo de la L2 sin ir a la RAM
(*forwarding*), ahorrando los 53 ciclos de la memoria.

### 1.2 Capacidad útil e inclusividad

| Política de inclusión | Contenido | Capacidad útil de datos distintos |
|:---|:---|---:|
| **Exclusiva** (la de por defecto) | La L1-D y la L2 nunca tienen la misma línea válida a la vez | 4 KB + 16 KB = **20 KB** |
| NINE (parámetro) | La L2 guarda copia de las líneas que la L1-D tiene | **16 KB** (la L1-D duplica lo de la L2) |

La exclusiva convierte a la L2 en la caché *víctima* de la L1-D: las líneas que la L1-D va dejando atrás
terminan en la L2, sin duplicarse. Es el motivo de que el archivo de prueba de 18 KB
(`examples/archivos/archivo18k.bin`) quepa en la configuración exclusiva y no en la de NINE.

### 1.3 Estado de integración (a 15 de noviembre de 2026)

Este documento describe el diseño, que es lo que está implementado y probado. Lo que **todavía no**
está conectado en el RTL es lo siguiente, y conviene decirlo claro:

| Lo que hay | Lo que falta |
|:---|:---|
| `rtl-p2/l1d_cache.sv`, `rtl-p2/l1d_arrays.sv`, `rtl-p2/l1d_write_buffer.sv`, `rtl-p2/l1d_replacement.sv`, `rtl-p2/l1d_port_arbiter.sv` | — |
| `rtl-p2/l2_cache.sv` y `rtl-p2/l2_arrays.sv` (L2 real, completa y probada) | su instancia en `mem_hierarchy.sv` (issue #27, de Fabricio) |
| `rtl-p2/mem_controller.sv`, `rtl-p2/eviction_buffer.sv` | su instancia en `mem_hierarchy.sv` (issue #27) |
| `rtl-p2/top.sv` con `MEM_MODE = 2` y `flush_req`/`flush_done` | — |

Hoy, con `MEM_MODE = 2`, `mem_hierarchy.sv` instancia `l1d_port_arbiter` → `l1d_cache` → **`l2_model`**
(la L2 de prueba de Fabricio, que siempre acierta) → `DMEM`. La L2 real, el eviction buffer y el
controlador de memoria **no están todavía en el camino del procesador**: existen, están probados por
separado y son sustituibles por `l2_model` sin cambiar la interfaz, pero el cambio es el issue #27.

---

## 2. La L1-D y el write buffer L1-D → L2 (José)

La L1-D es una caché de **4 KB, asociativa por conjuntos de 2 vías, con líneas de 32 bytes** (128 bloques
en 64 conjuntos; enunciado 3.2.2). El acceso ocurre **dentro de EX**, sin etapa MEM: un acierto
responde en el mismo ciclo que lo hacía `memory.sv` en el proyecto 1, así que ni la regla N+3 ni la
latencia de las cargas cambian.

```text
 15        11 10         5 4      2 1    0
+------------+------------+--------+------+
|  etiqueta  |   índice   | palabra| byte |
|   5 bits   |   6 bits   | 3 bits |2 bits|
+------------+------------+--------+------+
\_________________________/\______________/
  dirección de línea (11)   desplazamiento de bloque
```

Sus políticas, todas por parámetro (`rtl-p2/cache_defs.sv`):

| Parámetro | Configuración final | Otras opciones | Justificación |
|:---|:---|:---|:---|
| `WRITE_POLICY` | **Write-back** | write-through | La exclusiva lo exige: con write-through cada store iría a la L2, que no tiene la línea. Además, un store que acierta no gasta ancho de banda |
| `INCL_POLICY` | **Exclusiva** | NINE | L1-D ∩ L2 = ∅: caben 4 + 16 = 20 KB distintos y la L2 hace de caché víctima de la L1-D |
| `ALLOC_POLICY` | Write-allocate | no-write-allocate | La combinación típica con write-back |
| `REPL_POLICY` | LRU | FIFO, RANDOM | Con 2 vías, LRU exacto cuesta 1 bit por conjunto, igual que FIFO, y aprovecha la localidad temporal |
| `RAW_POLICY` | Forwarding (solo con NINE) | stall | Un miss no espera al drenado. Con exclusiva siempre se espera |
| `WB_DEPTH` | 4 | 2 a 8 | Absorbe ráfagas de víctimas sin agrandar el comparador del forwarding |
| `N_MSHR` | 2 | 1 a 4 | Crédito extra non-blocking. `N_MSHR = 1` es la caché bloqueante, para comparar |

El camino del acierto es combinacional (E1 → E2 → E3 → E4, con acceso paralelo a las dos vías); el
camino del fallo está segmentado en M1 (asignación), M2 (solicitud a la L2), M3 (llenado, víctima y
forwarding de bytes). El detalle completo, con los casos de cada combinación de políticas, está en
[l1d-cache.md](l1d-cache.md).

**Lo que le toca a la L2.** La L1-D le pide una línea por el bus versión 2 y le devuelve una línea sucia
cuando desaloja. En exclusiva, la línea que la L1-D le entrega **sustituye** a la que la L2 tuviera de
esa dirección; en NINE, la L2 guarda su copia. Esas dos diferencias son la política de inclusión que
la L2 tiene que respetar.

---

## 3. La L2 (Alejandro)

### 3.1 Geometría

La geometría de la L2 **no es una decisión de diseño**: la fija el enunciado 3.2.3.

| Parámetro | Valor |
|:---|---:|
| Capacidad | 16 KB |
| Vías | 4 |
| Tamaño de línea | 32 B (8 palabras de 32 bits) |
| Líneas | 512 |
| Conjuntos | 128 |
| Acierto | 8 ciclos |
| Política de escritura | write-back con write-allocate |
| Inclusión | `INCL_EXCLUSIVE` por defecto; `INCL_NINE` como parámetro |

```text
 15    12 11        5 4      2 1    0
+------- +-----------+--------+------+
| tag   |   índice  | palabra| byte |
| 4 bits|   7 bits  | 3 bits |2 bits|
+-------+-----------+--------+------+
\______________/\____________________/
  línea (12 bits)    desplazamiento

  conjunto = addr[11:5]      tag = addr[15:12]      offset = addr[4:0]
```

Cada conjunto tiene sus cuatro vías con un bit de validez (V), un bit sucio (D), la etiqueta de 4 bits
y la línea de 256 bits. El almacenamiento está en `rtl-p2/l2_arrays.sv`, que es el módulo hermano de
`rtl-p2/l1d_arrays.sv`: **no decide nada**, solo guarda y entrega. Un solo puerto de lectura
(combinacional, multiplexado) entrega a la vez las cuatro vías del conjunto, para comparar las cuatro
etiquetas en paralelo; un puerto de escritura escribe una línea completa; y un tercer puerto limpia
**solo** el bit sucio, que es lo que necesita el vaciado.

### 3.2 Políticas y su justificación

| Política | Elección | Justificación |
|:---|:---|:---|
| **Escritura** | write-back + write-allocate | Es lo que exige la inclusividad exclusiva: si la L1-D tiene la línea y la L2 no, un store que llega a la L2 tiene que poder guardar la línea completa. Con write-through el store iría siempre a la L2, que no la tiene, y el hold del write buffer se quedaría esperando una respuesta que nunca llega. Con write-allocate, un store parcial trae la línea vieja, la mezcla con los bytes nuevos y guarda el resultado sucio |
| **Inclusión** | `INCL_EXCLUSIVE` por defecto, `INCL_NINE` como parámetro | Exclusiva: L1-D ∩ L2 = ∅, así que la L2 es la caché víctima de la L1-D y no se duplica ninguna línea (notas 6.2.4). El profesor aprobó la exclusiva como crédito extra. NINE queda disponible como parámetro para comparar, y en NINE la copia que guarda la L2 se queda sucia si la línea vino reenviada por el eviction buffer, porque ese buffer solo guarda líneas sucias |
| **Reemplazo** | PLRU de **árbol** por defecto; Random (LFSR) como segunda política | Un LRU exacto de 4 vías necesita 5 bits por conjunto y lógica de orden. El PLRU de árbol usa 3 bits por conjunto (raíz, nodo izquierdo y nodo derecho) y se acerca al LRU con una actualización simple. **Es una aproximación, no un LRU exacto**, y así se documenta. Random sirve de línea base en las comparaciones. Si hay una vía libre, se usa esa primero |
| **Latencia** | acierto en 8 ciclos; fallo en 8 + Tmem | El enunciado pide 8 ciclos de acierto. En el fallo, el presupuesto de 8 ciclos de la caché y la latencia del nivel inferior se suman: 8 + 53 = 61 |

El LFU aproximado se descartó: necesita contadores por vía y una política de envejecimiento, y en
nuestros benchmarks no aporta nada frente al PLRU de árbol.

### 3.3 Cómo funciona por dentro

La L2 es **bloqueante**: `l2_gnt` solo está en alto cuando la caché está libre, así que se atiende una
petición a la vez. El bus versión 2 separa la aceptación de la respuesta:

```text
  l2_req, l2_we, l2_addr, l2_wline, l2_be, l2_wdirty
                |
                v
        +---------------+   l2_gnt (solo si está libre)
        |   S_IDLE      |------------------------> acepta la petición
        +---------------+
                |  fallo
                v
        +---------------+   read_req, read_addr
        |  S_RD_WAIT   |-----------------------> pide la línea al nivel inferior
        +---------------+
                |
                v
        +---------------+   evict_valid, evict_addr, evict_line
        |   S_EVICT    |-----------------------> la víctima sucia baja al EB
        +---------------+
                |
                v
        +---------------+   l2_rvalid, l2_rline, l2_rdirty
        |  S_RD_FETCH  |------------------------> entrega la línea
        +---------------+
```

Y en el camino de escritura, `S_WR_STORE` → `S_WR_COMMIT`: el estado de confirmación existe porque la
escritura en los arreglos ocurre en el flanco que cierra `S_WR_STORE`. Sin él, la siguiente petición
compararía la etiqueta contra el contenido viejo, fallaría el acierto y, en un llenado, mandaría dos
líneas a la misma vía.

Detalle importante del handshake de desalojo: `evict_valid` es un pulso de **un ciclo**, pero no puede
desasertarse en el mismo ciclo en que se decide desalojar, porque es una salida registrada. El
handshake se mira en el ciclo siguiente, con el valor ya registrado. Si se comprobara `evict_ready`
en el ciclo de entrada, el pulso se cancelaría solo y el nivel inferior nunca vería la línea.

### 3.4 La L2 y el eviction buffer

La L2 y el eviction buffer se hablan con dos interfaces distintas:

| Interfaz | Señales | Para qué |
|:---|:---|:---|
| Desalojo | `evict_valid`, `evict_addr`, `evict_line` → `evict_ready` | La L2 entrega una línea sucia que desalojó |
| Lectura | `read_req`, `read_addr` → `read_ready`, `read_line`, `read_forwarded` | La L2 pide una línea al nivel inferior |

`read_forwarded` en alto significa que la línea que llegó venía reenviada por el eviction buffer, es
decir, **sucia**. Con NINE la copia que guarda la L2 tiene que quedar sucia en ese caso; si se guardara
limpia, al desalojarla se perderían los datos. Con exclusiva no se guarda nada: la línea se mueve a la
L1-D y se le entrega sucia (`l2_rdirty`).

---

## 4. Eventos de la L2 (para los contadores de rendimiento)

`rtl-p2/l2_cache.sv` expone **diez eventos**, todos pulsos de **un ciclo**, con la misma convención que
usa `l1d_cache.sv`. Están pensados para que los contadores de `perf_cache_l2.sv` (issue #26, de Javier)
no tengan que interpretar el bus: basta con contar pulsos.

| Evento | Cuándo se pulsa |
|:---|:---|
| `ev_l2_rd_hit` | Una lectura aceptada **acertó** en la L2 |
| `ev_l2_rd_miss` | Una lectura aceptada **falló** en la L2 |
| `ev_l2_wr_hit` | Una escritura aceptada **acertó** en la L2 |
| `ev_l2_wr_miss` | Una escritura aceptada **falló** en la L2 |
| `ev_l2_fill` | Una línea **entró** en la L2 (relleno por lectura o por escritura) |
| `ev_l2_evict` | Una línea sucia **salió por reemplazo** al eviction buffer |
| `ev_l2_writeback` | Una línea sucia **bajó al eviction buffer durante el vaciado** |
| `ev_l2_invalid` | Invalidación hacia atrás: la L2 tira su copia porque la línea pasa a estar solo en la L1-D (**solo en exclusiva**) |
| `ev_l2_read_req` | La L2 **pidió** una línea al nivel inferior |
| `ev_l2_write_req` | La L2 **entregó** una línea al nivel inferior (se ofrece en cada ciclo del desalojo) |

Tres precisiones que evitan malinterpretar los contadores:

- `ev_l2_evict` y `ev_l2_writeback` son cosas distintas: el primero es una víctima por **reemplazo** y el
  segundo una línea bajada en el **vaciado**. `ev_l2_writeback` solo puede aparecer en un vaciado.
- `ev_l2_write_req` se pulsa en cada ciclo en que la L2 ofrece la línea, así que **no** es 1 a 1 con el
  handshake del eviction buffer: es mayor o igual que `ev_l2_evict + ev_l2_writeback`.
- `ev_l2_invalid` solo existe en exclusiva. En NINE la L2 conserva su copia y no hay invalidación hacia
  atrás.

Relaciones que se pueden comprobar directamente con los contadores (están en los testbenches de la L2):

| Relación | En exclusiva | En NINE |
|:---|:---|:---|
| Lecturas y escrituras aceptadas | `rd_hit + rd_miss` = lecturas aceptadas; `wr_hit + wr_miss` = escrituras aceptadas | igual |
| Rellenos | `fill` = escrituras fallidas | `fill` = lecturas fallidas + escrituras fallidas |
| Invalidaciones | `invalid` = `rd_hit` | `invalid` = 0 |
| Peticiones al nivel inferior | `read_req` = lecturas fallidas + escrituras parciales | igual |

---

## 5. La memoria principal, el controlador y el eviction buffer (Dylan)

La memoria principal se modela con **64 KB** (16 384 palabras de 32 bits) y se accede por líneas de
32 bytes. El controlador `mem_controller.sv` la maneja a **25 MHz** con `MEM_DIV = 4`: el reloj de
memoria se deriva del de la CPU con un divisor continuo y la línea completa se entrega en el ciclo 53.

| `MEM_DIV` | Frecuencia RAM | Primer dato | Entre palabras | `TMEM` |
|---:|---:|---:|---:|---:|
| 2 | 50 MHz | ciclo 25 | 2 ciclos | 39 |
| **4** | **25 MHz** | **ciclo 25** | **4 ciclos** | **53** |
| 5 | 20 MHz | ciclo 25 | 5 ciclos | 60 |

`TMEM = 25 + 7 × MEM_DIV`. El controlador separa su máquina de estados en el dominio de la CPU y en el
de la RAM, y cruza los eventos con *toggles* y sincronizadores de dos registros. Si un intento no
termina en `MEM_TIMEOUT = 256` ciclos, emite `timeout_event` y hace **un** reintento; si ese tampoco
termina, genera `mem_error` y `error_event`.

El **eviction buffer** es una FIFO de 4 líneas sucias (4 a 16). Recibe las víctimas sucias de la L2, las
drena en orden hacia la RAM (la cabeza solo se retira cuando la RAM confirma la escritura sin error) y
**reenvía** a la L2 la versión más reciente de una línea que todavía tiene pendiente, evitando leer una
copia obsoleta de la memoria. Las lecturas pendientes tienen prioridad sobre el inicio de nuevos
drenados.

El detalle completo, con el análisis del cruce de relojes, el manejo de errores y la lista de
testbenches, está en [memory-main-eviction-buffer.md](memory-main-eviction-buffer.md).

---

## 6. La cadena de vaciado

El vaciado (`vaciarc`, o el `flush_req` que ponen los testbenches) baja todas las líneas sucias hasta
la RAM en cinco pasos:

```text
  1. MSHR         esperar a que no haya MSHR pendientes
  2. L1-D         recorrer 64 conjuntos x 2 vías -> write buffer
  3. write buffer esperar a que quede vacio
  4. L2           recorrer 512 líneas -> eviction buffer
  5. EB           esperar a que quede vacío -> flush_done = 1
```

Las líneas quedan **válidas y limpias** (no se invalidan), así que el programa puede seguir después de
un vaciado: la L2 se queda con su copia, pero con el bit sucio en 0, porque a partir de ahí la L2 y la
RAM tienen lo mismo.

| Nivel | Señales del vaciado | Nota |
|:---|:---|:---|
| L1-D (José) | `flush_req`, `flush_done` | `flush_done` es un **nivel**: se mantiene en alto mientras `flush_req` siga en alto |
| L2 (Alejandro) | `flush_req`, `flush_done`, `lower_drained` | Misma convención que la L1-D. `lower_drained` es una **entrada**: el nivel inferior ya no tiene líneas sucias pendientes |
| Eviction buffer | `busy` | `lower_drained = !busy`: el buffer está drenado cuando no tiene líneas en la FIFO ni una transferencia en curso |

Mientras dura el vaciado la L2 **no acepta peticiones** (`l2_gnt = 0`), y sigue detenida hasta que
`flush_req` baja: es exactamente lo que hace la L1-D. El orden importa: el pedido de vaciado de la L2
tiene que subir **después** de que la L1-D haya terminado el suyo.

La L2 barre sus 512 líneas con un puntero de 9 bits (7 del conjunto y 2 de la vía) usando el mismo
puerto de lectura multiplexado que los accesos normales. Cuando encuentra una línea sucia la baja al
eviction buffer y, con un puerto aparte, le **limpia solo el bit sucio**: la etiqueta y los datos no se
tocan, así que la copia sigue siendo válida.

---

## 7. Latencias de un acceso

Con la configuración por defecto (`MEM_DIV = 4`, `Tmem = 53`):

| Camino | Ciclos |
|:---|---:|
| L1-D acierta | dentro de EX, sin penalización extra |
| L1-D falla y la L2 acierta | 8 |
| L1-D falla y la L2 falla | 8 + 53 = **61** |
| Vaciado completo (L1-D + L2 + RAM) | el de la cadena de la sección 6 |

En la L2, un fallo dura 8 + Tmem = 61 ciclos: el presupuesto de 8 ciclos de la caché más la latencia
del nivel inferior. El desalojo de una víctima sucia **no** suma ciclos: se paga con el presupuesto de
8 del acceso.

---

## 8. Diagramas: la L1-D, la L2 y el pipeline

### 8.1 El acceso y dónde se detiene el núcleo

```text
   IF     ID      EX                             WB
   |      |       |                              |
          |  +----+------------------------------+---+
          |  | LSU: direccion y offset           |   el acceso a la cache esta DENTRO de EX
          |  | (base + offset)                   |   no hay etapa MEM: un acierto responde
          |  |                                    |   en el mismo ciclo que memory.sv
          |  |   E1  E2  E3   E4                  |
          |  |  dir  des.  acceso  resultado     |
          |  |       amb.  paralelo             |
          |  +------------------------------------+
          |         |  ^          (stall si falla)
          |         |  +-- l2_req / l2_gnt / l2_rvalid (bus version 2)
          |         +-- l1d_port_arbiter (puerto B de la cripto)
```

Un fallo de la caché **congela** el núcleo con `cache_stall` hasta que la L1-D tenga la respuesta. Con
la L2 real conectada, el fallo se resuelve en 8 ciclos (si la L2 acierta) o en 61 (si hay que ir a la
RAM).

### 8.2 La L2 por dentro

```text
        peticion del bus (version 2)
                    |
        +-----------v-----------+
        |  l2_cache.sv          |   decide: hit, miss, victimaria, inclusividad
        |                       |   latencias: hit 8, fallo 8 + Tmem
        |  +------------------+ |
        |  | l2_arrays.sv     | |   128 conjuntos x 4 vias
        |  |  V, D, tag, linea| |   un puerto de lectura multiplexado
        |  +------------------+ |   un puerto de escritura
        +-----------------------+   un puerto para limpiar solo el bit sucio
                    |
                    v
        +-----------------------+
        |  l2_replacement.sv    |   PLRU de arbol (3 bits por conjunto)
        |                       |   o Random con LFSR de 8 bits
        +-----------------------+
                    |
                    v
              eviction_buffer
```

### 8.3 El camino de una escritura

```text
  store con write-back
        |
        +-- acierta en la L2 --> se mezclan los bytes, la linea queda SUCIA
        |
        +-- falla en la L2 --> write-allocate: se pide la linea vieja al nivel
                                inferior, se mezclan los bytes y se guarda
        |
        v
  la linea sucia sale de la L2 cuando:
        - la desaloja otra linea (reemplazo)  --> eviction buffer --> RAM
        - se vacia la cache                   --> eviction buffer --> RAM
```

---

## 9. Pendientes

| Pendiente | Quién | Referencia |
|:---|:---|:---|
| Instanciar la L2 real (y el eviction buffer y el controlador) en `mem_hierarchy.sv`, sustituyendo `l2_model` | Fabricio | issue #27 |
| Checker de exclusividad: que ninguna línea esté válida en la L1-D y en la L2 a la vez | Fabricio | `rtl-p2/excl_checker.sv` |
| L2 en 4 etapas con valid/ready (la L2 bloqueante ya existe) | Fabricio | decisión 11 |
| Contadores de la L2 con los eventos `ev_l2_*` | Javier | issue #26, sección 4 |
| Cerrar la cadena de vaciado de extremo a extremo con la jerarquía conectada | Fabricio | sección 6 |
| CDC para síntesis: relojes, sincronizadores y buses multibit | Dylan | `memory-main-eviction-buffer.md`, sección 3 |

Los contratos de señales de cada uno de estos enlaces están en
[memory-interfaces.md](memory-interfaces.md).
