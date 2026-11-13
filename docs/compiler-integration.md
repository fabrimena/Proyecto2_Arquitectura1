# Integración con CE1108

Contrato de interfaz entre nuestro procesador y el compilador del grupo de Compiladores (CE1108), y
evidencia de la validación conjunta (sección 6 del enunciado). Nuestro ensamblador funciona sin el
compilador y cubre las 34 instrucciones del ISA original. La extensión opcional de caché
y medición tiene soporte de ensamblado y componentes independientes; su conexión a `top` está pendiente.

## Contrato

- Codificación exacta de cada instrucción y green card: [isa.md](isa.md). Sintaxis del ensamblador:
  [simulation.md](simulation.md), sección 12.
- Bundle de 128 bits; el PC avanza 16 bytes. Orden del fuente: `ALU | LSU | BRU | CRIPTO`, con la ALU
  en los bits bajos. NOP es la palabra 0 en cualquier slot.
- Registros: x0 = 0, x1 = `ra`, x2 = `sp`, x3 = `gp` (`0x4000`), x4–x15 temporales y x16–x31
  preservados entre llamadas.
- Regla N+3: un valor escrito en el bundle N se lee desde el N+3; entre productor y consumidor van 2
  bundles independientes o NOP.
- `sye` y `syer` guardan PC + 16; `ret` equivale a `syer x0, ra, 0`. Los saltos relativos van en bytes
  desde el PC del bundle, en múltiplos de 16.
- `.mem`: 32 dígitos hexadecimales por bundle para la memoria de instrucciones. `.bin`: 16 bytes
  *little-endian* por bundle.
- No hay instrucción para detenerse: un programa termina en un bucle estable.

**Entrega del contrato.** El repositorio de Compiladores tiene la rama `docs/contrato-arquitectura`
(commit `d772425`, 11 de octubre de 2026) con copias de `isa.md` y de la sintaxis del ensamblador, ya
con `syer`, el enlace PC + 16 y la regla N+3. Su backend (`docs/backend_binario.md`) codifica los
bundles según ese contrato.

## Formas de ejecutar código de CE1108

| Forma | Comando | Qué demuestra |
|:---|:---|:---|
| Compilador `balc` | `balc -s` y `tools/run_program.py` | Programas completos: bucles, condiciones, funciones y matrices |
| Generador de funciones | `make compiladores-factorial` | Factorial con llamada, marco de pila y retorno |
| Programa fuente lineal | `make ce1108-source` | Declaraciones y asignaciones, sin precargar memoria |
| Operadores con bucles | `tools/run_ce1108_source.py` | División, residuo y potencia |
| Expresión lineal | `tools/run_ce1108.py` | La primera salida del generador |

Requisitos para compilar el código de CE1108: `sudo apt install build-essential flex uthash-dev` y una
copia de su repositorio. Las pruebas se hicieron con su rama `development` (commit `2ee0fa8`), que
reúne todos los módulos. En los comandos `make`, `CE1108_ROOT` es la ruta a esa copia.

### Compilador `balc`

```bash
cd <repositorio de CE1108> && make                 # genera balc
./balc -s -m programa.bal                          # programa.asm, .mem y .bin; -m muestra el mapa de memoria
python3 tools/run_program.py --input programa.asm --expect-memory esperado.json --cycles 100000
python3 tools/run_program.py --input programa.asm --cycles 100000 --trace   # traza dinámica
```

- El `.asm` de `balc` usa nuestra sintaxis, y nuestro ensamblador genera a partir de él un `.mem`
  idéntico byte por byte al de `balc`. Su `.bin` es un contenedor (encabezado de 48 bytes, código y
  datos) cuya sección de código coincide con nuestro `.bin`; no se carga directamente en la memoria de
  instrucciones.
- El programa arma `gp = 0x4000` y `sp = 0x10000`, llama a `main` con `syer x1, x13, 0`, vuelve con
  `syer x0, ra, 0` y termina en un bucle. Las variables de `main` quedan en la pila, en
  `0x10000 − marco + desplazamiento` (`-m` muestra el desplazamiento y el marco es el `restai` inicial
  de `main`).
- **Traza dinámica.** Con `--trace`, `build/program_<nombre>/trace.txt` muestra cada cambio de
  registro y de memoria, ciclo a ciclo, con el PC y el bundle que lo produjo
  ([simulation.md](simulation.md), sección 12). Como las variables de `main` viven en la pila, su
  evolución se ve en las escrituras en memoria. En `factorial.bal`, `resultado` está en `0xFFF8` y la
  traza muestra cómo pasa por 1, 2, 6, 24 y 120:
  `grep 'M\[0xfff8\]' build/program_factorial/trace.txt`.

| Programa de ejemplo de CE1108 | Qué ejercita | Resultado en el procesador |
|:---|:---|:---|
| `factorial.bal` | Bucle y multiplicación | 5! = 120 |
| `ejercicio2_busqueda_matriz.bal` | Matriz, bucles anidados y condiciones | Fila 0, columna 1 |
| `ejercicio3_puntajes.bal` | Funciones anidadas y control | 24, 0, 13 y 37 |
| `llamadas.bal` | Funciones con parámetros | 14 |
| `division_residuo_potencia.bal` | División, residuo y potencia | −3, −2 y 1024 |
| `multiplicacion.bal` | Multiplicación con negativos | −42 |

En los 6 programas `sp` termina en `0x10000` y la dirección 0 no cambia.

### Módulos de CE1108 con nuestros adaptadores

`tools/run_ce1108_source.py` compila los módulos de CE1108 (lexer de Flex, parser, tabla de símbolos y
generadores) con un pequeño programa en C (`tools/ce1108_source.c` o, con `--functions`,
`tools/ce1108_functions.c`), sin modificarlos. Convierte su salida en bundles con
`tools/bundle_linear.py` (solo ALU y LSU) o `tools/bundle_control.py` (también saltos, etiquetas y
retornos, con 2 NOP entre instrucciones y antes de cada destino; un salto condicional fuera de rango
pasa a ser la condición inversa más un `sye`). Después ensambla y ejecuta en `top`. Guarda fuente,
código generado, registros, memoria, ondas y un `evidence.json` con los commits y las huellas de los
módulos en `build/ce1108_fuente/`.

```bash
make ce1108-source CE1108_ROOT=<ruta>                 # examples/ce1108_programa.bal
make test-ce1108-source CE1108_ROOT=<ruta>            # 8 pruebas del modo fuente
make compiladores-factorial CE1108_ROOT=<ruta>        # factorial de 5
make test-compiladores-funciones CE1108_ROOT=<ruta>   # 0!, 1!, 5!, 7!, 12! y casos de error
```

- **Programa fuente** (`examples/ce1108_programa.bal`): una `main` sin parámetros con enteros y
  booleanos. El programa inicializa `gp` y las variables, sin precarga del testbench: a = 8, b = 3,
  r = 10 y valido = 1 quedan en `0x4000`–`0x400C`.
- **Operadores con bucles**: `euclides` (división con signo), `euler` (residuo) y `descartes`
  (potencia). Usan x8–x15 además de x4–x7. Una división por cero o un exponente negativo se rechazan si
  son literales; si vienen de una variable, el programa se detiene en un bucle sin escribir el
  resultado. Ejemplo: `division_residuo_potencia.bal` con `--cycles 20000` da q = −3, r = −2 y
  p = 1024.
- **Funciones** (`--functions`): el código arma `gp = 0x4000` y `sp = 0x10000`, como `balc`, llama
  a `main` con `sye x1`, guarda y restaura `ra` y `sp`, y al volver escribe 1 en `0x4000` como señal
  de fin. El factorial usa un marco de 16 bytes (n en `0xFFF4`, resultado en `0xFFF8`, i en
  `0xFFFC`); 5! ocupa 163 bundles.

### Expresión lineal

```bash
python3 tools/run_ce1108.py --input examples/ce1108.linear
```

`examples/ce1108.linear` viene del
[commit 4f225a0 de CE1108](https://github.com/Izaguirre1g/Proyecto-Parte-1-Compiladores-e-Interpretes-Definici-n-de-Sintaxis-de-Lenguaje/commit/4f225a0f34bac7adf9934181ebc8d0772589b242):
6 instrucciones para `r : (a gauss b) neumann 1;`, que el adaptador lleva a 16 bundles. El testbench
precarga `gp = 0x4000`, a = 8 y b = 3, y comprueba r = 10 en `0x4008`.

## Resultados

Reproducidos el 13 de octubre de 2026 con Icarus Verilog 12.0 y la rama `development` de CE1108
(`2ee0fa8`):

| Prueba | Resultado |
|:---|:---|
| `make sim` | 21 PASS, 0 FAIL |
| `make test-assembler` | 44 pruebas correctas; cubren las 34 instrucciones |
| `make test-programs` | 14 pruebas correctas |
| `balc` con los 6 programas de ejemplo | 6 de 6 correctos |
| `make ce1108-source` y `make test-ce1108-source` | PASS y 8 de 8 |
| `make compiladores-factorial` y `make test-compiladores-funciones` | PASS y 3 de 3 |
| `division_residuo_potencia.bal` con `run_ce1108_source.py` | PASS |
| `tools/run_ce1108.py` | PASS: (8 + 3) − 1 = 10 |

## Extensión opcional de caché y medición: D18-A

El contrato aprobado está en [decisiones-importantes.md, sección 4.4](decisiones-importantes.md#44-instrucciones-de-control-de-caché-y-medición-javier-enganche-en-top-fabricio).
La codificación y el protocolo completo se describen en
[isa.md](isa.md#extensión-opcional-de-caché-y-medición--d18-a). No cambia el formato de bundle,
la ISA original, los alias, las pseudoinstrucciones ni la regla N+3. CE1108 **no necesita generar**
estas instrucciones para conservar su compatibilidad; no se modificó su repositorio.

| Mnemónico | Slot | Tipo [31:25] / ID [24:21] | Operandos y campos |
|:---|:---:|:---|:---|
| `vaciarc` | 1 LSU | `1001101` / `0000` | Sin operandos; [20:0] cero |
| `medir imm` | 1 LSU | `1001101` / `0001` | imm 0–1 en [0]; [20:1] cero |
| `lcont rg, sel` | 1 LSU | `1001101` / `0010` | rg x0–x31 en [15:11], sel 0–63 en [5:0]; resto cero |

`sel[5]` elige mitad baja (0) o alta (1); `sel[4:0]` el contador:
0 ciclos, 1 bundles, 2 instrucciones no NOP, 3 stall de memoria, 4 penalización de saltos,
5/6 lecturas L1-D hit/miss, 7/8 escrituras L1-D hit/miss, 9/10 hits/misses L2,
11 accesos RAM y 12 ciclos de transferencia RAM. IDs 13–31 leen cero en ambas mitades.
No son nuevas métricas: L2/RAM deben suministrarse cuando existan; fuentes no disponibles
deberán conectarse a cero y declararse no disponibles, sin interpretar ese cero como ausencia de tráfico.

El ensamblador valida aridad, registros, inmediatos, slot, RAW/WAW y N+3. `lcont` es productor
del registro aunque lea un selector reservado. Captura en EX y conserva resultado/destino
para WB; el consumidor debe ir a partir de N+3. x0 descarta la escritura. No lee registros fuente.
Los controles `medir`/`vaciarc` no escriben registros. No se reescriben programas ni se insertan
bundles para acomodar los riesgos. Las palabras exactas y los errores se prueban por separado
de los casos originales, que conservan sus expectativas.

`medir 0` pausa sin borrar y `medir 1` reanuda; reset habilita medición. El nuevo enable rige
después del flanco de aceptación en EX. Dos lecturas alta/baja no son atómicas; pausar permitirá
leer el acumulado estable una vez integrada la habilitación. IPC = instrucciones/ciclos se calcula
externamente; para cero ciclos se informa N/D.

La unidad usa reloj general. Una emisión requiere validez, permiso explícito `ex_advance`
y `issue_ready`; una respuesta registrada se consume con `complete_valid`/`complete_ready`.
Durante freeze se retienen resultado/destino y no se repite la escritura. Tras emitir, el
adaptador debe avanzar EX o retirar la validez para evitar volver a emitir el mismo bundle.
Estos son puertos del componente independiente y requieren coordinarse con Fabricio.

`vaciarc` acepta con ack bajo, retiene `flush_req` hasta `flush_done=1`, retira req y espera
que done vuelva a cero antes de responder. X/Z no confirma. Un proveedor inmediato puede
confirmar el primer ciclo activo de req; uno retardado mantiene la espera. El adaptador debe
detener el avance del procesador sin detener el reloj de la unidad. Reset cancela la operación,
por lo que exige reinicio coordinado; no acredita persistencia. No hay HALT ni timeout implícito.

**D18-A: componentes independientes implementados y probados. El soporte en el ensamblador
no significa que `top` ya ejecute estas instrucciones.** El LSU actual deja este tipo inactivo.
Quedan pendientes: conexión del decoder y la unidad a `top`, enable real de contadores, ruta de
escritura LSU/WB para `lcont`, stall por `vaciarc`, handshake definitivo con Fabricio, L2 y garantía
de persistencia hasta RAM. Las pruebas aisladas no sustituyen pruebas de las tres instrucciones
en el procesador completo, y no demuestran vaciado completo de la jerarquía.
