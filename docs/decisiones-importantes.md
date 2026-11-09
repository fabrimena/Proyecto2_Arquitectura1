# Decisiones importantes del proyecto 2

Propuesta del 7 de noviembre de 2026 sobre `develop` (`3d9e3df`). Reúne las decisiones de diseño que
faltaban, las que cambian porque el grupo decidió hacer todos los créditos extra del enunciado y quién
aplica cada una. Las que ya estaban tomadas y no afectan lo que falta se mantienen.

La regla del proyecto sigue igual: el procesador del proyecto 1 (`rtl/`) no se modifica, todo lo nuevo
va en `rtl-p2/` y `tb-p2/`, y con la caché desactivada todas las pruebas del proyecto 1 dan exactamente
lo mismo. La única extensión del ISA es la que permite el enunciado (sección 4.4).

**Acción inmediata:** la política exclusiva tiene que acordarse con el profesor antes de la iteración 4
(enunciado 3.2.4 y 7.1.4). El correo sale antes de que empiece la L2 (sección 4.1).

## 1. Punto de partida

| Bloque | Estado en `develop` | Responsable |
|:---|:---|:---|
| Congelamiento del núcleo y modelo de stalls | Hecho y probado (`tb_pipeline_stall`) | Fabricio |
| Contadores de ciclos, bundles, instrucciones, saltos y eventos de la L1-D | Hechos y probados, sin conectar a `top` | Javier |
| L1-D y write buffer | Hechos y probados solos: write-through, NINE, no-write-allocate, LRU, forwarding, 4 entradas, 1 MSHR. Sin conectar a `top` y sin puerto B | José |
| Memoria principal y eviction buffer | Sin empezar | Dylan |
| L2 | Sin empezar | Alejandro |
| ROM de instrucciones, puerto B y conexión de la jerarquía en `top` | Pendientes | Fabricio |

`make sim`: 33 PASS, 0 FAIL. `make test-programs`: 14 OK. Hay 60 warnings de Icarus, todos de
`rtl-p2/l1d_write_buffer.sv` (`@*` sensible a todo un arreglo, en `tb_l1d_write_buffer`, `tb_l1d_cache`
y `tb_perf_cache_l1d_k1a`); el proyecto 1 terminó con 0 y conviene dejarlo igual (José).

## 2. Resumen

| # | Decisión | Elección | Antes | Responsable |
|:---:|:---|:---|:---|:---|
| 1 | ROM de instrucciones | Síncrona, leída con el siguiente PC; 1024 bundles | Combinacional (pendiente #3) | Fabricio |
| 2 | Acceso a la caché | Dentro de EX, sin etapa MEM | Se mantiene | Fabricio |
| 3 | Inclusión L1-D/L2 | **Exclusiva** (crédito extra); NINE queda como parámetro | NINE | José, Alejandro |
| 4 | Escritura de la L1-D | Write-back; write-through queda como parámetro | Write-through | José |
| 5 | Asignación de la L1-D | Write-allocate con write-back; no-write-allocate con write-through | No-write-allocate | José |
| 6 | Reemplazo de la L1-D | LRU (FIFO y Random como parámetro) | Se mantiene | José |
| 7 | Write buffer | 4 entradas. RAW: forwarding de palabra con NINE, espera de línea con exclusiva | 4, forwarding | José |
| 8 | Misses de la L1-D | **Non-blocking** para stores, 2 MSHR (1 a 4) | Bloqueante, 1 MSHR | José |
| 9 | Bus L1-D/L2 | Versión 2: aceptación (`l2_gnt`) separada de la respuesta (`l2_rvalid`) | Una petición a la vez | José, Alejandro |
| 10 | L2 | Write-back y write-allocate; PLRU de árbol (Random como parámetro) | Sin empezar | Alejandro |
| 11 | Pipeline interno | L1-D: camino del miss en etapas (hecho). **L2 en 4 etapas** | Solo L1-D | José, Fabricio |
| 12 | Memoria principal | 25 MHz (divisor entre 4), Tmem = 53 | Sin empezar | Dylan |
| 13 | Cruce de relojes | Handshake `req`/`ack` con 2 flip-flops | Pendiente | Dylan |
| 14 | Timeout | 256 ciclos, un reintento y después error | Pendiente | Dylan |
| 15 | Eviction buffer | 4 entradas (4 a 16), forwarding de línea, lecturas primero | Pendiente | Dylan |
| 16 | Vaciado | MSHR → L1-D → write buffer → L2 → eviction buffer → RAM | Solo el write buffer | José, Alejandro |
| 17 | Puerto B (cripto) | Entra a la L1-D después del puerto A | Pendiente | Fabricio |
| 18 | Instrucciones nuevas | **`vaciarc`, `medir` y `lcont`**, tipo `1001101`, slot 1 | No se agregaban | Javier, Fabricio |
| 19 | Contadores por etapa | Ocupado, burbuja y congelado en IF, ID, EX y WB | Pendiente (#8) | Javier |

## 3. Decisiones obligatorias que faltaban

### 3.1 ROM de instrucciones síncrona (Fabricio, #3)

El enunciado (3.2.1) pide una ROM síncrona que entregue un bundle por ciclo sin stalls. Hoy
`rtl/instruction_memory.sv` lee de forma combinacional con `pc`. Si la lectura se registrara con `pc`, el
bundle llegaría un ciclo tarde y cambiaría la penalización de los saltos.

**Decisión:** un módulo nuevo, `rtl-p2/rom_sync.sv`, que registra la lectura en el flanco de `core_clk`
con la dirección del siguiente PC, calculada con la misma regla de `rtl/pc_branch.sv`:

```
next_pc = reset ? 0 : (redirect ? redirect_pc : pc + 16)
always @(posedge core_clk) bundle <= memory[next_pc];
```

En el mismo flanco en que `pc` toma `next_pc`, la ROM toma `memory[next_pc]`, así que durante todo el ciclo
el bundle es `memory[pc]`, igual que hoy. La ROM es síncrona y no cambia nada visible para el software:
siguen iguales la penalización de 2 ciclos de los saltos, la regla N+3, el ensamblador y el compilador.
Como usa `core_clk`, se congela junto con el PC.

- Se mantienen la instancia `IMEM`, el arreglo `memory` y la carga con `+IMEM=`, para que
  `tb_assembled_program`, `tb_ce1108_program` y los demás testbenches carguen el programa igual. El
  programa tiene que estar cargado antes de un flanco con `reset` en 1, porque en ese flanco la ROM lee
  el bundle 0. Los 4 testbenches de métricas que cargaban el programa después de ese flanco
  (`tb_perf_top_d3`, `tb_perf_branch_d4a`, `tb_perf_stall_d5a` y `tb_perf_vliw_monitor_d4b1`) dan un
  flanco más con `reset` en 1 después de cargarlo; sus métricas no cambian.
- 1024 bundles (16 KB, dentro del máximo de 64 KB). Agrandarla cambiaría `IMEM_BUNDLES` y `TRAP_VECTOR`
  en `rtl/isa_defs.sv`, que el ensamblador también lee.
- Parámetro `ROM_SYNC` en `top` (1 por defecto; 0 = la memoria combinacional del proyecto 1). La prueba
  es la regresión completa: con `ROM_SYNC = 1` los resultados y los ciclos tienen que ser idénticos.
- Con esto #3 ya no depende de la respuesta del profesor.

### 3.2 Acceso a la caché dentro de EX (se mantiene)

El enunciado (3.1.1) deja elegir entre EX y una etapa MEM. Se mantiene EX: un hit de la L1-D responde en
el mismo ciclo que la memoria del proyecto 1, así que no cambian la regla N+3, la latencia de las cargas
ni el código que generan el ensamblador y `balc`. Una etapa MEM obligaría a cambiar el compilador de
CE1108.

### 3.3 Memoria principal (Dylan, #10, #11 y #14)

- **Frecuencia:** 25 MHz, con `clk_mem` generado por un divisor entre 4 (cambia cada 2 ciclos de `clk`).
  Tmem = 25 + 7 × ⌈100/25⌉ = **53 ciclos**. Una razón entera evita un PLL (Icarus no lo modela) y da un
  Tmem exacto; además es el ejemplo del enunciado, fácil de comprobar en la defensa. El parámetro
  `MEM_DIV` permite comparar: 2 (50 MHz, Tmem 39), 4 (25 MHz, 53) y 5 (20 MHz, 60).
- **Almacenamiento:** la misma `DMEM` de `top`, así los testbenches siguen leyendo `DUT.DMEM.mem` después
  del vaciado.
- **Latencia:** el controlador la cuenta en ciclos del procesador: 25 hasta la primera palabra y después
  una palabra por flanco del reloj de memoria (cada 4 ciclos). La L2 ve exactamente 53 ciclos y el
  testbench lo verifica.
- **Cruce de dominios:** handshake de 4 fases. `req` sale del dominio del procesador y `ack` del de
  memoria, y cada uno pasa por 2 flip-flops en el dominio que lo recibe; la dirección y los datos no
  cambian mientras `req` está en 1. Es el método estándar para pasar un pedido a la vez (una línea); una
  FIFO asíncrona solo vale la pena con muchos datos seguidos.
- **Timeout:** si una transferencia no termina en 256 ciclos del procesador (unas 4,8 veces Tmem), el
  controlador la reintenta una vez; si vuelve a fallar, pone `mem_error` en 1, lo cuenta y la simulación
  reporta `$error`. Es lo que hace un controlador real con una memoria que no responde, y se prueba
  forzando una memoria trabada en el testbench.
- **Contadores (sección 5.3):** accesos (lecturas y escrituras por separado), ciclos de transferencia
  (Tmem por acceso) y uso del ancho de banda = ciclos ocupados / ciclos totales. Es la misma fracción del
  máximo teórico, que es una línea cada Tmem ciclos.

### 3.4 Eviction buffer (Dylan, #12)

- 4 entradas por defecto (parámetro de 4 a 16). Cada entrada guarda una línea sucia completa.
- **Drenado:** cuando el controlador está libre y no hay lecturas pendientes. Las lecturas van primero
  porque el núcleo las está esperando. Si el buffer se llena, la L2 espera.
- **RAW:** un miss de L2 busca primero su línea en el buffer. Si está, se reenvía la línea completa sin ir
  a memoria y la entrada sigue drenándose normalmente. Ahorra 53 ciclos en una línea recién desalojada,
  y como la entrada igual llega a la RAM no quedan datos viejos.

### 3.5 L2 (Alejandro, #21 a #25)

- **Write-back** (obligatorio) y **write-allocate**. Una escritura de línea completa (víctima de la L1-D)
  se guarda sin leer la memoria. Una escritura parcial (solo con la L1-D en write-through, para la
  comparación) trae la línea y después escribe sus bytes.
- **Reemplazo:** PLRU de árbol por defecto (3 bits por conjunto) y Random con LFSR como segunda política.
  Un LRU exacto de 4 vías necesita 5 bits por conjunto y lógica de orden; el PLRU de árbol se le acerca con
  3 bits y una actualización simple. Random sirve de línea base en la comparación. El LFU aproximado
  necesita contadores por vía y envejecimiento, y no aporta en nuestros benchmarks. Si hay una vía
  libre, se usa esa primero.
- Se construye desde el inicio con el bus versión 2 (sección 4.3), dando `l2_gnt` solo cuando está libre
  (bloqueante). Así la segmentación posterior no cambia la interfaz.

### 3.6 Puerto B de la unidad cripto (Fabricio, #20)

`vcr` y `camcon` entran a la L1-D como un acceso más. `top` calcula `mem_re_b` igual que `mem_re`. Si en
un bundle accede la LSU y también la cripto, se atiende primero el puerto A y después el B (un ciclo más
de stall, solo en ese caso). `camcon` lee y escribe la misma palabra en la L1-D y la escribe una sola vez,
en el último ciclo, como en el modelo de stalls. Con exclusiva y write-back esto es obligatorio: la copia
más nueva de una palabra puede estar en la L1-D, en un buffer, en la L2 o en la RAM.

### 3.7 Vaciado (José y Alejandro #24, Javier #28)

1. Esperar a que no haya MSHR pendientes.
2. La L1-D recorre sus 64 conjuntos × 2 vías y manda las líneas sucias al write buffer.
3. Esperar a que el write buffer quede vacío.
4. La L2 recorre sus líneas y manda las sucias al eviction buffer.
5. Esperar a que el eviction buffer quede vacío; entonces `flush_done` = 1.

Las líneas quedan válidas y limpias (no se invalidan), así que el programa puede seguir después de un
vaciado. Lo inicia `flush_req`, que usan `tb_archivo`, `tb_assembled_program` y `tb_ce1108_program`
antes de leer la memoria, o la instrucción `vaciarc` (sección 4.4). Javier adapta las herramientas.

### 3.8 Contadores por etapa (Javier, #8)

Para IF, ID, EX y WB: ciclos con un bundle válido, ciclos con burbuja (anulado por un salto o una
excepción) y ciclos congelados por la caché. ID, EX y WB salen de `perf_pipeline_monitor`, que ya sigue
el valid y la causa de anulación de esas etapas; IF se agrega con `!reset` y el congelamiento.

## 4. Créditos extra

### 4.1 Política exclusiva (José y Alejandro; acuerdo con el profesor: Fabricio)

El enunciado (3.2.4) la ofrece como crédito extra en lugar de inclusiva o NINE: L1-D ∩ L2 = ∅. Un hit en
L2 ante un miss en L1-D mueve la línea en vez de copiarla, y lo que la L1-D desaloja va a la L2 en vez de
descartarse, como en una caché víctima.

**Por qué la elegimos**

1. **Más capacidad.** Con NINE una línea puede estar en la L1-D y en la L2 a la vez, y en la jerarquía
   caben 16 KB distintos. Con exclusiva no hay copias y caben 4 + 16 = 20 KB. Por ejemplo, un archivo de
   18 KB en `make archivo` (cifrar y después descifrar recorre dos veces los mismos datos) cabe completo
   con exclusiva y no con NINE. Javier agrega ese archivo a los benchmarks.
2. **Lo que sale de la L1-D no se pierde.** La L2 funciona como caché víctima de la L1-D (lección 14b):
   volver a pedir una línea recién desalojada cuesta 8 ciclos y no 8 + Tmem = 61.
3. **No perdemos nada con un solo núcleo.** La ventaja de la inclusiva (filtrar el snooping entre varias
   L1) no aplica aquí.
4. **NINE queda como parámetro.** La comparación entre NINE y exclusiva sale del mismo diseño (rúbrica 3b
   y 3c), y si el profesor no la aprueba se usa NINE sin rehacer nada.

**Qué cambia respecto a lo que hay:** la L1-D pasa a **write-back con write-allocate**. Con write-through
cada store iría a la L2, que no tiene esa línea porque está en la L1-D: la L2 tendría que guardarla
(dejaría de ser exclusiva) o mandar el store a la RAM (Tmem por store).

| Situación | NINE (lo que hay) | Exclusiva |
|:---|:---|:---|
| Store con hit en L1-D | Escribe en la L1-D y va al write buffer | Escribe solo en la L1-D y marca la línea sucia |
| Miss en L1-D, hit en L2 | La línea se copia; la L2 la conserva | La línea se mueve con su bit sucio y la L2 la invalida |
| Miss en L1-D y en L2 | La línea queda en la L1-D y en la L2 | La línea queda solo en la L1-D |
| La L1-D desaloja | La línea se descarta (está limpia) | La línea va a la L2 por el write buffer, limpia o sucia |
| La L2 recibe una víctima | No ocurre | La guarda; si el conjunto está lleno, su propia víctima sucia va al eviction buffer y una limpia se descarta |
| Vaciado | Write buffer → L2 → RAM | La L1-D también manda sus líneas sucias (sección 3.7) |

- **Bit sucio:** viaja con la línea. `l2_rdirty` (de la L2 a la L1-D en el llenado) y `l2_wdirty` (de la
  L1-D a la L2 con la víctima). Una línea solo se escribe en la RAM cuando sale sucia de la L2.
- **RAW en el write buffer:** si un miss de la L1-D pide una línea que todavía está en el write buffer
  (una víctima en camino), espera a que esa entrada llegue a la L2 y después la pide (hit de 8 ciclos).
  Si se reenviara desde el buffer, la línea quedaría en la L1-D y, cuando la entrada drene, también en la
  L2. Es un caso raro (volver a usar una línea que acaba de salir). Con NINE sigue el forwarding de
  palabra de José.
- **Parámetros:** `INCL_POLICY` (`INCL_NINE` o `INCL_EXCLUSIVE`, ya definidos en `cache_defs.sv`) y
  `WRITE_POLICY` (`WP_WRITE_THROUGH` o `WP_WRITE_BACK`). Combinaciones válidas: write-through + NINE,
  write-back + NINE y write-back + exclusiva. Write-through + exclusiva se rechaza con `$fatal` al inicio.
- **Verificación:** un checker solo de simulación en la integración: cada vez que la L2 guarda una línea,
  esa línea no puede estar válida en la L1-D, y cada vez que la L1-D se llena, la línea no puede quedar
  válida en la L2. Contadores nuevos: víctimas de la L1-D a la L2 (limpias y sucias), movimientos de la
  L2 a la L1-D y líneas que la L2 manda a la RAM.
- **Acuerdo con el profesor:** Fabricio manda el correo con esta sección ahora, antes de que Alejandro
  empiece la L2. Si no la aprueba, `INCL_POLICY = INCL_NINE` queda por defecto y la exclusiva se presenta
  solo como comparación.

### 4.2 Caché non-blocking (José; contadores: Javier)

El enunciado (7.1.4) la propone para grupos avanzados: varias peticiones en curso (1 a 4) mientras se
atiende un miss.

**Límite de nuestro procesador:** el hardware no puede hacer scoreboarding (enunciado 3.1.1). Una carga
que falla tiene que detener el bundle, porque su registro se escribe en WB a una distancia fija (regla
N+3) y nadie revisa si el dato ya llegó. Los stores no escriben registros, así que pueden seguir.

**Decisión:** MSHR para stores. `N_MSHR` de 1 a 4, **2 por defecto** (1 = la caché bloqueante de hoy,
para comparar).

- Un store que falla, con un MSHR libre, guarda la dirección de línea, sus bytes y el dato, pide la línea y
  el núcleo **no se detiene**.
- Otro store a una línea pendiente se mezcla en su MSHR, sin detenerse.
- Una carga que acierta en otra línea sigue (hit under miss).
- Una carga a una línea pendiente toma el dato del MSHR si tiene sus 4 bytes; si no, espera ese llenado.
- Una carga que falla detiene el bundle, como hoy. Los llenados pendientes se atienden primero, en orden.
- Un store que falla con todos los MSHR ocupados espera a que se libere uno.
- El puerto B (`vcr`, `camcon`) se trata como carga.
- Al llegar la línea se mezclan los bytes del MSHR, la línea queda sucia y la víctima se elige en ese
  momento (así dos MSHR del mismo conjunto no eligen la misma vía).
- El vaciado y `vaciarc` esperan a que no quede ningún MSHR pendiente.

**Por qué 2:** cada store que no se detiene ahorra 8 o 61 ciclos. Con 2 MSHR el comparador extra es
pequeño (2 direcciones de línea de 11 bits); 4 solo ayuda en ráfagas largas de stores, y el parámetro
permite medir 1, 2 y 4.

**Dónde se nota:** en stores a líneas que no están en la L1-D, como el prólogo de las funciones de `balc`
(guarda `ra` y los registros en un marco de pila nuevo) y los benchmarks que escriben arreglos. En
`cifrar_archivo.asm` no cambia nada, porque cada store va a la línea que se acaba de cargar.

Contadores (Javier): hits durante un miss, stores que no se detuvieron y ciclos de stall por MSHR llenos.

### 4.3 Pipeline interno de las cachés (L1-D: José, ya hecho; L2: Fabricio)

El enunciado (3.3) lo deja como mejora avanzada; la división de tareas ya lo había tomado.

- **L1-D:** el camino del hit tiene que ser combinacional (1 ciclo, sección 3.2). El camino del miss ya
  está en etapas desacopladas con valid/ready: M1 asignación, M2 solicitud, M3 llenado y D1 drenado
  (`docs/l1d-cache.md`, sección 4). Se mantiene.
- **L2 en 4 etapas** con registros y valid/ready entre ellas:

  | Etapa | Qué hace |
  |:---|:---|
  | S1 Recepción | Acepta una petición (`l2_gnt`) y la registra |
  | S2 Etiquetas | Compara las 4 vías, decide hit o miss y elige la víctima |
  | S3 Datos | Lee o escribe el arreglo; en una lectura con hit, una cadena de registros completa los 8 ciclos |
  | S4 Respuesta | Entrega `l2_rvalid`, `l2_rline` y `l2_rdirty`, en orden |

  Un hit sigue tardando 8 ciclos (enunciado 3.2.3), pero la L2 puede aceptar una petición por ciclo: el
  drenado del write buffer y los llenados de los MSHR se superponen. Un miss de L2 detiene S2 hasta que
  llega la línea (no se reordenan respuestas). Si S2 y S3 tienen peticiones al mismo conjunto, S2 espera
  un ciclo.
- **Por qué:** es lo que convierte el non-blocking en ganancia real. Sin una L2 segmentada, los misses
  pendientes se atienden uno detrás del otro.

**Bus L1-D/L2 versión 2** (reemplaza la sección 5 de `memory-interfaces.md`):

| Señal | Hacia | Bits | Significado |
|:---|:---|:---:|:---|
| `l2_req` | L2 | 1 | Hay una petición |
| `l2_gnt` | L1-D | 1 | La L2 la aceptó en este ciclo (`l2_req` y `l2_gnt` en 1) |
| `l2_we` | L2 | 1 | 0 = leer una línea, 1 = escribir |
| `l2_addr` | L2 | 32 | Dirección alineada a 32 bytes |
| `l2_wline` | L2 | 256 | Datos de la línea (palabra 0 en los bits bajos) |
| `l2_be` | L2 | 32 | Bytes válidos de `l2_wline` |
| `l2_wdirty` | L2 | 1 | La víctima que se escribe está sucia (exclusiva) |
| `l2_rvalid` | L1-D | 1 | Un ciclo en 1 con la respuesta de una lectura, en orden |
| `l2_rline` | L1-D | 256 | Línea leída |
| `l2_rdirty` | L1-D | 1 | La línea que se mueve estaba sucia en la L2 (exclusiva) |

Las escrituras terminan al ser aceptadas y no tienen respuesta. Las salidas de la L2 salen de registros,
como pide hoy la L1-D. José cambia M2 y M3 para usar `l2_gnt` y `l2_rvalid`; Alejandro construye la L2
con este bus desde el principio, bloqueante; Fabricio la segmenta cuando la versión bloqueante pasa sus
pruebas, como dice la división de tareas.

### 4.4 Instrucciones de control de caché y medición (Javier; enganche en `top`: Fabricio)

El enunciado (3.1.2) permite agregar instrucciones de control de caché y de medición con códigos que no
se usaron en el proyecto 1. Es la única extensión permitida del ISA: hay que documentar la codificación,
el slot y la semántica en `docs/` y comunicarla a CE1108.

**Tipo nuevo `1001101` (caché y medición), solo en el slot 1.** Ningún tipo del proyecto 1 lo usa
(`1001001`, `1000000`, `1001011`, `1000001`, `1101010`, `0000010` y `0000000` para NOP).

| Instrucción | ID [24:21] | Campos | Semántica |
|:---|:---:|:---|:---|
| `vaciarc` | 0000 | Sin campos (resto en 0) | Vacía toda la jerarquía hasta la RAM (sección 3.7). El bundle se detiene hasta `flush_done` |
| `medir imm` | 0001 | `imm` [0] | 1 = los contadores cuentan, 0 = se pausan sin borrarse. Al reset cuentan |
| `lcont rg, sel` | 0010 | `rg` [15:11], `sel` [5:0] | `rg` ← contador `sel`: bits [4:0] = cuál, bit 5 = mitad alta. Se lee en EX y se escribe como una carga (regla N+3) |

| `sel` | Contador | `sel` | Contador |
|:---:|:---|:---:|:---|
| 0 | Ciclos | 7 | Escrituras de la L1-D con hit |
| 1 | Bundles | 8 | Escrituras de la L1-D con miss |
| 2 | Instrucciones (no NOP) | 9 | Hits de la L2 |
| 3 | Ciclos de stall por memoria | 10 | Misses de la L2 |
| 4 | Ciclos perdidos por saltos | 11 | Accesos a la RAM |
| 5 | Lecturas de la L1-D con hit | 12 | Ciclos de transferencia de la RAM |
| 6 | Lecturas de la L1-D con miss | 13 a 31 | 0 (reservados) |

- **Compatibilidad:** `rtl/decoder_lsu.sv` pone `valid = 0` con un tipo que no conoce, así que el
  procesador del proyecto 1 las trata como NOP. Ningún programa existente cambia y `balc` no tiene que
  generarlas.
- **Por qué estas tres:** `vaciarc` deja la memoria final lista sin depender del testbench. `medir` y
  `lcont` permiten que un benchmark mida solo su parte central, sin el arranque, que es lo que necesita la
  iteración 5 para comparar programas de CE1108 con distintos niveles de optimización.
- **Implementación:** `rtl-p2/decoder_cache_isa.sv` (lee el slot 1 en ID) y `rtl-p2/cache_isa_unit.sv`
  (EX: `medir`, `lcont` con el resultado registrado como la LSU y `vaciarc` con `flush_req`), hechos por
  Javier. En `top`, Fabricio conecta el resultado de `lcont` al carril de escritura de la LSU, el
  `measure_enable` de los contadores y el stall de `vaciarc`. Javier también agrega los 3 mnemónicos al
  ensamblador (con `lcont` en la revisión N+3 como una carga) y sus pruebas, documenta el tipo en
  `docs/isa.md` y `docs/compiler-integration.md` y avisa formalmente a CE1108.

## 5. Configuración por defecto y comparaciones

**Configuración final:** ROM síncrona; L1-D write-back, write-allocate, LRU, write buffer de 4 entradas y
2 MSHR; exclusiva; L2 con PLRU y 4 etapas; eviction buffer de 4 entradas; memoria a 25 MHz (Tmem 53).

**Comparaciones** (Javier, #30), cambiando un parámetro a la vez:

| Comparación | Valores |
|:---|:---|
| Inclusión | NINE contra exclusiva (las dos con write-back) |
| Escritura de la L1-D | Write-through + no-write-allocate contra write-back + write-allocate (NINE) |
| Reemplazo de la L1-D | LRU, FIFO y Random |
| Reemplazo de la L2 | PLRU y Random |
| Misses pendientes | `N_MSHR` = 1, 2 y 4 |
| L2 | Bloqueante contra 4 etapas |
| Memoria | 25 MHz (Tmem 53) contra 50 MHz (Tmem 39) |

Con los benchmarks secuencial, aleatorio y con stride (#29), `make archivo` con un archivo de 18 KB y
los programas de `balc`.

## 6. Quién hace qué

Según la división de tareas del 28 de octubre y los issues asignados.

- **Fabricio:** ROM síncrona (#3); correo al profesor por la exclusiva; puerto B por la L1-D (#20);
  conexión de la L1-D (#19) y de la jerarquía completa (#27) en `top`; checker de exclusividad; L2 en 4
  etapas; enganche de las instrucciones nuevas; `docs/microarchitecture.md` (#35).
- **José:** L1-D con write-back, bit sucio y víctimas hacia la L2 (#15, #16); exclusiva en la L1-D;
  MSHR non-blocking; bus versión 2 en M2 y M3; RAW de línea en el write buffer (#17); vaciado de la L1-D
  (#24); pruebas (#18); quitar los 60 warnings del write buffer; `docs/l1d-cache.md` (#32).
- **Alejandro:** L2 con bus versión 2, write-back y write-allocate (#21); PLRU y Random (#22); exclusiva
  en la L2 (#23); vaciado de la L2 (#24); pruebas (#25); `docs/memory-hierarchy.md` con estas decisiones
  (#34).
- **Dylan:** memoria a 25 MHz con `MEM_DIV`, handshake y timeout (#10, #11); eviction buffer con
  forwarding (#12); pruebas con Tmem = 53 exacto y memoria trabada (#13); contadores de memoria (#14);
  documentación (#33).
- **Javier:** contadores por etapa (#8); contadores de L2, exclusiva y MSHR (#26); instrucciones
  `vaciarc`, `medir` y `lcont` en RTL y en el ensamblador, con su documentación y el aviso a CE1108;
  herramientas con el vaciado (#28); benchmarks, incluido el archivo de 18 KB (#29); comparaciones (#30,
  #31); `docs/performance-analysis.md` y README (#36, #37).

Issues nuevos que hacen falta: acuerdo de la exclusiva con el profesor, exclusiva en la L1-D, exclusiva en
la L2, MSHR non-blocking, bus versión 2, L2 en etapas, instrucciones de caché y medición, y checker de
exclusividad.

## 7. Orden y punto de corte

| Fecha | Meta |
|:---|:---|
| 8 de noviembre | Correo al profesor; el grupo aprueba el bus versión 2; empieza la ROM síncrona |
| 12 de noviembre | Memoria y eviction buffer; L2 bloqueante con bus versión 2; L1-D con write-back y exclusiva; puerto B y L1-D conectados en `top`; instrucciones nuevas |
| 15 de noviembre | Jerarquía completa en `top` con vaciado y regresión en los dos modos; MSHR non-blocking |
| 17 de noviembre | L2 en 4 etapas |
| 18 y 19 de noviembre | Benchmarks, comparaciones y documentos |
| 20 de noviembre, 23:55 | Entrega |

Lo obligatorio va primero. Un crédito extra que no pase sus pruebas el 17 de noviembre se deja apagado
por parámetro (`INCL_POLICY = INCL_NINE`, `N_MSHR = 1`, L2 bloqueante), sin borrarlo, y se documenta
hasta dónde llegó.
