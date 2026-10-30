# Análisis de rendimiento — Proyecto II

## Issue #7, bloque A: contador de ciclos

`rtl/perf_counters.sv` es un módulo independiente, todavía sin conexión al
procesador. Este bloque solo mide ciclos; los demás eventos del issue #7 quedan
para bloques posteriores. No cambia la ISA, el pipeline ni las memorias.

### Interfaz y semántica

| Señal | Sentido | Semántica |
|:---|:---|:---|
| `clk` | Entrada | Reloj de muestreo; actualización en el flanco positivo |
| `reset` | Entrada | Reset síncrono activo en 1, prioritario sobre la habilitación |
| `measure_enable` | Entrada | En 1 permite contar el flanco; en 0 conserva el valor |
| `cycle_count[63:0]` | Salida | Número acumulado de flancos habilitados desde el último reset |

En cada flanco positivo:

1. Si `reset = 1`, el resultado es cero, incluso con `measure_enable = 1`.
2. Si `reset = 0` y `measure_enable = 1`, se suma uno.
3. Si ambas entradas están en cero, se conserva el valor.

Deshabilitar pausa la medición sin borrarla. Volver a habilitar continúa el
acumulado; una medición independiente requiere aplicar reset durante al menos un
flanco positivo. No se garantiza un valor inicial antes del primer reset.
El contador es unsigned de 64 bits y desborda módulo 2^64, sin saturación.

### Límites de medición

El primer flanco con reset inactivo y habilitación activa está incluido. El primer
flanco con habilitación inactiva está excluido. Cambiar las entradas entre flancos
no actualiza el contador; tampoco lo hace un flanco negativo. Las entradas deben
estar estables alrededor del flanco positivo. En simulación se observa la salida
después de las asignaciones no bloqueantes (NBA), para evitar carreras.

Ejemplo después del reset: habilitaciones `1, 1, 1, 0, 0, 1` producen los valores
`1, 2, 3, 3, 3, 4`. Los intervalos separados se acumulan.

Cuando se integre al procesador deberá usarse el reloj `clk` sin detener. Este
módulo no infiere inicio ni fin de programa; quien lo instancie define la ventana
mediante `measure_enable` y reset. La integración se realizará en otro bloque.

### Pruebas y reproducción

```bash
make tb_perf_counters
make sim
make test-assembler
make test-programs
make archivo
```

El Makefile descubre automáticamente los archivos nuevos; no necesita cambios.
`tb_perf_counters` usa las utilidades de autoverificación del proyecto y compara
los 64 bits completos. Comprueba reset inicial y durante ejecución, prioridad,
pausa/reanudación, ventanas de uno y varios flancos, cambios entre flancos y
ausencia de actualización en flancos negativos. Para comprobar acarreo hacia el
bit 32 y desbordamiento de 64 bits, precarga el registro por jerarquía únicamente
en el testbench; no agrega mecanismos de carga al módulo.

### Evidencia de validación

Base: `main`, commit `787e380f13177a3420b726c6826941edee8fade9`.
Entorno: Ubuntu, Icarus Verilog/VVP 12.0, Python 3.12.3 y GNU Make 4.3.

Antes de modificar código se ejecutaron los cuatro comandos siguientes desde
`main`. Todos terminaron con código de salida 0.

| Comando | Resultado previo |
|:---|:---|
| `make sim` | 21 PASS, 0 FAIL, 0 NO-COMPILA, 0 SIN-CHEQUEO |
| `make test-assembler` | 44 pruebas OK: 21 + 13 + 4 + 6 |
| `make test-programs` | 14 pruebas OK |
| `make archivo` | 7 verificaciones RTL; comparación binaria correcta de 386 bytes |

En `make archivo`, el archivo predeterminado es
`examples/archivos/mensaje.txt`: cifrado en 989 ciclos y descifrado en 989 ciclos.
Los logs RTL y los archivos de memoria/binarios previos se preservaron en
`build/perf_block_a/before/`, con hashes en `sha256.json`. Las salidas de unittest
y los códigos de salida previos quedaron registrados en la sesión de ejecución.
`build/` contiene evidencia local ignorada por Git.

Después de implementar el bloque A en `feat/7-contadores-base`:

| Comando | Resultado posterior | Código de salida |
|:---|:---|:---:|
| `make tb_perf_counters` | PASS, 21 verificaciones | 0 |
| `make sim` | 22 PASS, 0 FAIL, 0 NO-COMPILA, 0 SIN-CHEQUEO | 0 |
| `make test-assembler` | 44 pruebas OK | 0 |
| `make test-programs` | 14 pruebas OK | 0 |
| `make archivo` | 7 verificaciones RTL; 386 bytes idénticos al original | 0 |

Los 51 archivos preservados (logs, imágenes de memoria y binarios) son idénticos
byte a byte a los generados después del cambio. El cifrado y el descifrado siguen
tardando 989 ciclos cada uno. El único testbench añadido a `make sim` es
`tb_perf_counters`. No se observaron fallos preexistentes ni regresiones.

Evidencia posterior: `build/tb_perf_counters/sim.log`,
`build/perf_block_a/after/{sim,test-assembler,test-programs,archivo}.log`,
`build/perf_block_a/after/results.json` y
`build/perf_block_a/after/comparison.json`. Estas pruebas no validan integración
con el pipeline ni cachés: esas implementaciones todavía no forman parte del bloque A.
