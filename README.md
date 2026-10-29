# Proyecto1_Arquitectura1
Arquitectura VLIW Propia para Aplicaciones de Cifrado por Bloques

## Propósito

Proyecto Grupal I de CE4301 Arquitectura de Computadores I (TEC, II Semestre 2026): un procesador
VLIW con un ISA propio, descrito en SystemVerilog y simulado con Icarus Verilog.

- Cada instrucción (bundle) mide 128 bits y lleva 4 operaciones que se ejecutan a la vez: ALU, acceso
  a memoria (LSU), saltos (BRU) y una unidad criptográfica.
- El pipeline tiene 4 etapas (IF, ID, EX y WB), así que varios bundles avanzan al mismo tiempo.
- La unidad criptográfica acelera el cifrado por bloques Feistel4 con llaves guardadas en una bóveda
  protegida por contraseña: las llaves nunca salen hacia los registros ni la memoria.
- Incluye un ensamblador propio, herramientas para cargar un archivo en la memoria y extraer el
  resultado, y la integración con el compilador del curso CE1108.

## Requisitos

- [Icarus Verilog](https://steveicarus.github.io/iverilog/) 12 o posterior, GNU make, bash y
  Python 3.10 o posterior. GTKWave es opcional, para ver las ondas.
- Para compilar el código del grupo de CE1108: `build-essential`, `flex` y `uthash-dev`.

```bash
sudo apt install iverilog gtkwave make python3          # Ubuntu o WSL
sudo apt install build-essential flex uthash-dev        # solo para la integración con CE1108
```

En Windows, Icarus Verilog se instala con `winget install Icarus.Verilog`.

## Estructura

```
rtl/        procesador en SystemVerilog: top.sv, etapas, unidades, banco de registros, memorias
            e isa_defs.sv (códigos del ISA y parámetros)
tb/         testbenches de make sim (uno por módulo más los del procesador completo)
tests/      pruebas en Python y los testbenches que usan las herramientas (tests/rtl/)
tools/      assembler.py y run_program.py: ensamblador y ejecución de programas
            load_file.py y extract_data.py: carga y extracción de archivos en la memoria
            run_ce1108.py, run_ce1108_source.py y adaptadores: integración con CE1108
examples/   programas .asm, resultados esperados (.json) y archivos de prueba
docs/       isa.md, microarchitecture.md, simulation.md y compiler-integration.md
img/        diagrama de bloques
```

## Simulación

```bash
make sim                  # compila y ejecuta los 22 testbenches y muestra un resumen
make tb_alu               # un solo testbench
make waves TB=tb_alu      # abre su .vcd en GTKWave
make list                 # lista los testbenches
make clean                # borra build/
```

Cada testbench se verifica solo (termina con `[PASS]` o `[FAIL]`) y deja su log y su `.vcd` en
`build/<testbench>/`. `make sim` falla si alguno falla o no compila.

## Cifrado y descifrado de archivos

`make archivo` carga un archivo en la memoria de datos, lo cifra y lo descifra con Feistel4 en el
procesador, y comprueba que el resultado sea idéntico al original. Sirve para cualquier tipo de archivo
de hasta 65024 bytes:

```bash
make archivo                                         # texto: examples/archivos/mensaje.txt
make archivo ARCHIVO=examples/archivos/imagen.bmp    # imagen BMP de 64 × 48
make archivo ARCHIVO=examples/archivos/datos.bin     # binario de 1000 bytes
```

Ensambla `examples/cifrar_archivo.asm` y `examples/descifrar_archivo.asm`, carga el archivo con
`load_file.py`, simula los dos programas y extrae el resultado con `extract_data.py`. En
`build/archivo/` quedan `cifrado.bin` y `descifrado.bin`.

Para descifrar un archivo que ya viene cifrado con Feistel4, se indica la llave (4 palabras de 32 bits
en hexadecimal; K0 es la de la primera ronda):

```bash
make descifrar ARCHIVO=examples/archivos/secreto.bin LLAVE=1A2B3C4D,55667788,99AABBCC,DDEEFF00
```

`examples/archivos/secreto.bin` es un texto cifrado con esa llave. Ejecuta solo el programa de descifrar y deja el archivo original en `build/descifrar/resultado.bin`;
al final muestra qué tipo de archivo es (texto, imagen, etc.). Si el original no medía un múltiplo de
8 bytes, el resultado termina con hasta 7 bytes en cero, que son el relleno del cifrado.

Las herramientas también se usan por separado:

```bash
# Archivo → imagen de memoria para $readmemh, desde la dirección 0x200
./tools/load_file.py --input examples/archivos/mensaje.txt --output build/datos.mem --address 0x200

# Imagen de memoria → archivo (por ejemplo, un volcado después de cifrar)
./tools/extract_data.py --memory build/archivo/cifrado.mem --address 0x200 --size 392 \
    --output build/cifrado.bin
```

`load_file.py` informa cuántos bytes cargó y la zona de memoria que ocupan. Solo los `.hex` se leen
como texto hexadecimal; cualquier otro archivo se carga byte por byte. `extract_data.py` escribe
binario si la salida termina en `.bin` y texto hexadecimal en otro caso (`--format` lo fuerza).

## Ensamblador y programas

Los bundles se escriben en el orden `ALU | LSU | BRU | CRIPTO`; la sintaxis completa está en
[docs/simulation.md](docs/simulation.md), sección 12.

```bash
make test-assembler            # pruebas del ensamblador (no necesitan simulador)
make test-programs             # ejecuta los programas de examples/ en el procesador

python3 tools/assembler.py --input examples/alu_isa.asm \
  --output build/alu.mem --binary build/alu.bin --listing build/alu.lst

python3 tools/run_program.py --input examples/alu_isa.asm --expect examples/alu_isa.expected.json
python3 tools/run_program.py --input examples/lsu_isa.asm --expect examples/lsu_isa.expected.json \
  --expect-memory examples/lsu_isa.memory.json --cycles 80
python3 tools/run_program.py --input examples/bru_isa.asm --expect examples/bru_isa.expected.json --cycles 80
python3 tools/run_program.py --input examples/subrutina.asm --expect examples/subrutina.expected.json --cycles 60
python3 tools/run_program.py --input examples/mixto.asm --cycles 60
python3 tools/run_program.py --input examples/subrutina.asm --cycles 60 --trace   # traza dinámica
```

`run_program.py` ensambla el programa, lo carga en la memoria de instrucciones, lo simula y muestra los
registros distintos de 0. Con `--expect` (registros) y `--expect-memory` (memoria) compara contra un
JSON como `{"x5": 50}` y termina con error si algo no coincide. Deja todo en `build/program_<nombre>/`.
Con `--trace` también escribe ahí `trace.txt`, la traza dinámica: cada cambio de registro, de memoria
o de ESTADO, ciclo a ciclo, con el bundle que lo produjo.
`mixto.asm` combina las 4 unidades en un mismo bundle y usa las 6 instrucciones cripto; `subrutina.asm`
llama a una función con `sye` y vuelve con `syer`. Como el ISA no tiene una instrucción para detenerse,
los programas terminan en un bucle estable.

## Integración con CE1108

```bash
python3 tools/run_ce1108.py --input examples/ce1108.linear     # expresión: (8 + 3) - 1 = 10
make ce1108-source CE1108_ROOT=<repo de CE1108>                # programa fuente examples/ce1108_programa.bal
make compiladores-factorial CE1108_ROOT=<repo de CE1108>       # factorial con funciones
```

Los programas compilados con `balc`, el compilador de CE1108, se ejecutan con `run_program.py`. Los
pasos, el contrato y los resultados están en
[docs/compiler-integration.md](docs/compiler-integration.md).

## Documentación

| Documento | Contenido |
|:---|:---|
| [docs/isa.md](docs/isa.md) | Especificación del ISA, codificación de cada instrucción y green card |
| [docs/microarchitecture.md](docs/microarchitecture.md) | Diagrama de bloques, pipeline y módulos SystemVerilog |
| [docs/simulation.md](docs/simulation.md) | Simulación, modelo de cada componente, memoria, ensamblador y testbenches |
| [docs/compiler-integration.md](docs/compiler-integration.md) | Contrato con CE1108 y evidencia de la validación conjunta |
