## Memoria principal, controlador y eviction buffer

**Responsable:** Dylan Guerrero González  
**Issue:** #33 — Documentar memoria principal y eviction buffer  
**Implementación:** `rtl-p2/mem_controller.sv`, `rtl-p2/eviction_buffer.sv`, `rtl-p2/perf_memory.sv`  
**Contrato de señales:** `docs/memory-interfaces.md`

### 1. Organización y estado de integración

La memoria principal se modela con una capacidad de **64 KB**, direcciones de byte de 32 bits dentro del rango válido `0x0000` a `0xFFFF`, y acceso físico mediante **16 384 palabras de 32 bits**. La unidad de transferencia entre cachés y memoria es una línea de **32 bytes (256 bits)**, compuesta por ocho palabras consecutivas. Las solicitudes de línea se alinean a 32 bytes (`addr[4:0] = 0`). La palabra 0 ocupa `line[31:0]` y la palabra 7 ocupa `line[255:224]`.

Los módulos de controlador y eviction buffer tienen interfaces compatibles y cuentan con una prueba de integración. Sin embargo, en la versión revisada de `rtl-p2/mem_hierarchy.sv` la jerarquía de `MEM_MODE=2` todavía conecta `l1d_port_arbiter` → `l1d_cache` → `l2_model` → DMEM. **No se debe presentar la L2 real, el controlador y el eviction buffer como integrados al procesador** hasta reemplazar ese modelo y verificar el camino completo.

```text
Camino actual de MEM_MODE=2:
CPU (puertos A/B) -> árbitro -> L1-D -> l2_model -> DMEM

Camino previsto con la L2 real:
CPU -> L1-D -> L2 real -> [eviction buffer] -> controlador -> RAM
                                   ^                  |
                                   +--- lecturas -----+
```

El eviction buffer recibe las líneas sucias desalojadas de L2, ofrece *forwarding* a lecturas coincidentes y permite que el controlador procese lecturas o drene escrituras hacia RAM. La relación específica entre arbitraje de L2 y sus entradas debe terminarse durante la integración.

### 2. Frecuencia de RAM y latencia

El procesador opera a **100 MHz**. El controlador genera `clk_mem` a partir de `clk` mediante un divisor continuo; la generación no se reinicia al aceptar una solicitud. El parámetro `MEM_DIV` establece la relación entre las frecuencias. La implementación validada admite valores 2 a 5; las pruebas realizadas cubren 2, 4 y 5.

| `MEM_DIV` | Frecuencia RAM | Primer dato entregado | Intervalo entre palabras | `TMEM` (línea completa) |
|---:|---:|---:|---:|---:|
| 2 | 50 MHz | ciclo 25 | 2 ciclos CPU | 39 ciclos CPU |
| **4** | **25 MHz** | **ciclo 25** | **4 ciclos CPU** | **53 ciclos CPU** |
| 5 | 20 MHz | ciclo 25 | 5 ciclos CPU | 60 ciclos CPU |

Se utiliza la ecuación:

`TMEM = 25 + 7 × MEM_DIV`

En la configuración predeterminada (`MEM_DIV=4`) la entrega de las palabras se programa para los ciclos **25, 29, 33, 37, 41, 45, 49 y 53**, contados desde la solicitud aceptada por el controlador en los escenarios normales verificados. La línea completa se anuncia mediante `ram_ready` al terminar su entrega y recibir la confirmación de RAM.

**Precarga y distinción de eventos.** El controlador ejecuta los accesos físicos a RAM anticipadamente, pero retiene los datos hasta su fecha nominal. Esta decisión corresponde a la aclaración del profesor: se permite precargar siempre que el dato se devuelva en el ciclo 25 y se respete la tasa de transferencia. En simulación, para `MEM_DIV=4`, los accesos internos ocurrieron en los ciclos 14, 18, 22, 26, 30, 34, 38 y 42, mientras que **las entregas al solicitante** ocurrieron en 25, 29, 33, 37, 41, 45, 49 y 53. Por lo tanto, **no se debe confundir el instante de acceso físico con el de entrega externa**.

La secuencia de 25 a `TMEM` describe el **intento normal sin timeout**. En presencia de una transferencia detenida y un reintento, la entrega puede demorarse: se prioriza completar la operación válida, mantener la cadencia entre palabras y evitar datos del intento fallido. No se garantiza `TMEM` exacto bajo una falla de memoria.

### 3. Controlador de memoria (`mem_controller.sv`)

El controlador recibe solicitudes de líneas de 256 bits mediante `ram_req`, `ram_we`, `ram_addr` y `ram_wline`. Conserva una copia estable de los parámetros de la transacción mientras trabaja la RAM. La interfaz de línea completa devuelve `ram_rline` y señala éxito con un pulso `ram_ready`; `mem_error` informa una finalización fallida.

La entrega observable de palabras individuales utiliza tres salidas: `ram_word_valid` (pulso de palabra disponible), `ram_word_data[31:0]` y `ram_word_index[2:0]` (índice de 0 a 7). Estas señales son complementarias a `ram_ready`: este último corresponde a la línea **completa**, no a una palabra individual. En lectura se presentan las palabras en orden; en escritura se envía al acceso físico la palabra correspondiente de `ram_wline`.

La interfaz física hacia RAM está formada por `clk_mem`, `mem_word_addr[13:0]`, `mem_word_wdata[31:0]`, `mem_word_we` y `mem_word_rdata[31:0]`. La dirección de palabra deriva de la dirección base alineada y del índice de palabra.

#### Cruce de dominios de reloj (CDC)

El controlador separa una máquina de estados en el dominio CPU (`clk`) y otra en el dominio RAM (`clk_mem`). Los eventos de solicitud, finalización y cancelación utilizan **toggles** y sincronización de dos registros para cruzar entre dominios. También se sincronizan eventos de disponibilidad de palabras y sus identificadores. El controlador conserva los datos de solicitud mientras dure el intercambio y comprueba la identidad de la confirmación para evitar que una respuesta tardía complete un intento distinto.

El reloj de memoria se deriva de `clk`, pero se trata como dominio distinto para el control. Las simulaciones prueban el comportamiento lógico del handshake; **no sustituyen una revisión de CDC, recursos de reloj dedicados ni restricciones de temporización en la FPGA**. En particular, las rutas de datos multibit y los identificadores asociados a eventos requieren verificación de estabilidad y coherencia durante implementación física.

#### Timeout y reintento

`MEM_TIMEOUT` vale **256 ciclos de CPU por intento** de forma predeterminada. Si un intento no termina, el controlador emite `timeout_event` y efectúa **un único reintento**. Si el segundo intento tampoco termina, genera `mem_error` y `error_event`, solicita la cancelación y espera la confirmación de cancelación antes de admitir una nueva operación.

Una lectura reintentada no puede reutilizar palabras ni confirmaciones de la transferencia anterior. Por ello, la implementación vigente espera una **confirmación válida de la línea completa** del intento nuevo antes de entregar las palabras del reintento y conserva el intervalo de `MEM_DIV` ciclos entre ellas. `mem_hold` permite detener la transferencia física para ensayar la respuesta ante timeout.

#### Señales de instrumentación

`req_accept` indica la aceptación de una solicitud; `req_we_accepted` distingue una escritura aceptada; `transfer_busy` representa el período ocupado; `timeout_event` y `error_event` son pulsos para diagnóstico y contadores.

### 4. Eviction buffer (`eviction_buffer.sv`)

El eviction buffer almacena temporalmente **líneas sucias desalojadas de L2** en una FIFO configurable con `EB_DEPTH` entre **4 y 16 entradas**; el valor predeterminado es 4. Cada entrada conserva una dirección de línea alineada a 32 bytes y 256 bits de datos. Los punteros de cabeza y cola permiten insertar y retirar entradas, incluso en el mismo ciclo. `occupancy`, `empty`, `full` y `busy` exponen el estado del buffer.

La interfaz de desalojo recibe `evict_valid`, `evict_addr[31:0]`, `evict_line[255:0]` y entrega `evict_ready`. Una línea se inserta cuando `evict_valid && evict_ready`. El drenado se realiza en orden FIFO: **la cabeza solo se elimina cuando RAM confirma la escritura sin error**.

La interfaz de lectura recibe `read_req` y `read_addr` y entrega `read_ready`, `read_line[255:0]` y `read_forwarded`. Antes de acudir a RAM, el buffer compara la dirección solicitada con las líneas pendientes. Si existe coincidencia, devuelve la **versión más reciente** presente en la FIFO (*forwarding*), evitando leer una copia obsoleta de memoria principal. Cuando no existe coincidencia, la lectura se envía al controlador de RAM.

Las **lecturas pendientes tienen prioridad sobre el inicio de nuevos drenados**. Una escritura ya iniciada no es interrumpida. El buffer utiliza hacia el controlador `ram_req`, `ram_we`, `ram_addr`, `ram_wline`, `ram_ready`, `ram_rline` y `ram_error`; esta última entrada recibe la señal `mem_error` del controlador.

#### Errores y recuperación de escrituras

Si falla definitivamente una escritura, el eviction buffer conserva la línea sucia y activa `write_error_blocked`, impidiendo nuevos drenados automáticos. Las lecturas pueden seguir atendiéndose, incluido el forwarding desde las entradas retenidas. Una vez disponible RAM, un pulso de `clear_write_error` permite levantar el bloqueo y reanudar los drenados. En lecturas fallidas se cancela la solicitud afectada y se informa el error; no se entrega una línea inválida como lectura exitosa.

Los pulsos `ev_push`, `ev_pop`, `ev_forward` y `ev_error` permiten supervisar inserciones, retiradas exitosas, reenvíos y errores.

### 5. Contadores de rendimiento (`perf_memory.sv`)

Los contadores usan el reloj CPU **`clk`**, no `core_clk`, porque el núcleo puede permanecer congelado durante fallos de caché. El módulo registra en contadores de 64 bits:

| Contador | Señal de incremento |
|---|---|
| `read_accesses` | `req_accept && !req_we` |
| `write_accesses` | `req_accept && req_we` |
| `transfer_cycles` | `transfer_busy` |
| `total_cycles` | Cada ciclo con `measure_enable` |
| `timeout_count` | `timeout_event` |
| `error_count` | `error_event` |

La entrada `clear` reinicia los acumulados y tiene prioridad sobre el conteo. La ocupación temporal del enlace puede calcularse externamente como `transfer_cycles / total_cycles`, cuando `total_cycles > 0`. Los ciclos realmente ocupados incluyen demoras por reintentos y fallas; por eso no siempre equivalen a un `TMEM` nominal por solicitud.

### 6. Verificación realizada

Las siguientes pruebas fueron ejecutadas y reportadas con **PASS** para los escenarios incluidos:

| Testbench | Cobertura principal |
|---|---|
| `tb_mem_controller` | Latencia nominal total de 39, 53 y 60 ciclos |
| `tb_mem_controller_verificacion` | Entrega en el ciclo 25 y cadencia de palabra; precarga; timeout |
| `tb_mem_controller_cdc` | Lecturas, escrituras, sincronización y reintentos |
| `tb_mem_controller_cdc_estres` | Reloj continuo, solicitudes consecutivas, fases, errores y recuperación |
| `tb_mem_controller_cdc_respuesta_tardia` | Rechazo de confirmaciones atrasadas y no duplicación |
| `tb_mem_controller_entrega_palabras` | Índices, datos y ciclos de entrega |
| `tb_mem_controller_prefetch_verificacion` | Precarga interna, orden y ritmo físico |
| `tb_mem_controller_reintento_palabras` | Datos nuevos tras timeout; ocho palabras sin duplicaciones |
| `tb_eviction_buffer_integracion` | Escritura, lectura, forwarding, drenado e integridad con RAM simulada |

También se verificó de forma independiente `perf_memory.sv` mediante `tb_perf_memory`, y el eviction buffer con pruebas de FIFO, prioridad, error y recuperación. Los PASS respaldan el funcionamiento **en simulación**; no demuestran por sí solos cierre de temporización, inmunidad a metastabilidad ni integración final con la L2 real.

### 7. Pendientes de integración y criterios de cierre

- **Integración de la jerarquía:** reemplazar `l2_model` en `mem_hierarchy.sv` por la L2 real y conectar sus desalojos y lecturas con `eviction_buffer` y `mem_controller`.
- **Vaciado completo:** comprobar que `flush_done` solo se afirme cuando las líneas sucias hayan atravesado todos los niveles pertinentes y hayan llegado a memoria principal.
- **CDC para síntesis:** revisar generación de reloj, restricciones, sincronizadores e integridad de los buses multibit.
- **Validación de extremo a extremo:** ejecutar programas y pruebas de jerarquía con la L2 real y memoria principal conectadas.

**Alcance de esta sección:** documenta el diseño, las interfaces y los resultados de los componentes asignados, sin atribuirles una integración con L2 que todavía no aparece en el RTL revisado.
