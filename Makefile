# ==============================================================================
#  Makefile de simulación - Procesador VLIW (CE4301, Proyecto Grupal I)
#
#  Uso:
#    make sim              compila y ejecuta todos los testbenches de tb/ y tb-p2/
#    make tb_alu           compila y ejecuta sólo tb/tb_alu.sv
#    make waves TB=tb_alu  abre en GTKWave el .vcd de ese testbench
#    make list             lista los testbenches disponibles
#    make archivo          cifra y descifra un archivo en el procesador
#                          (ARCHIVO=<ruta>, por defecto examples/archivos/mensaje.txt)
#    make descifrar        descifra un archivo ya cifrado con una llave dada
#                          (ARCHIVO=<cifrado> LLAVE=<K0,K1,K2,K3>)
#    make test-assembler   pruebas del ensamblador (no requieren simulador)
#    make test-programs    ejecuta los programas de examples/ sobre el RTL
#
#  Integración con CE1108 (CE1108_ROOT=<repositorio de Compiladores>):
#    make ce1108-source                programa fuente examples/ce1108_programa.bal
#    make test-ce1108-source           pruebas del modo fuente
#    make compiladores-factorial       factorial con el generador de funciones
#    make test-compiladores-funciones  pruebas del generador de funciones
#
#    make clean            borra build/
#    make help             muestra esta ayuda
#
#  Variables útiles:
#    PLUSARGS="+verbose +seed=7"   argumentos para la simulación
#
#  Cada testbench se compila con todos los módulos de rtl/ y rtl-p2/ y se
#  ejecuta dentro de build/<tb>/, donde quedan el ejecutable (sim.vvp), el log
#  (sim.log) y el archivo de ondas (.vcd). Ver docs/simulation.md.
# ==============================================================================

SHELL := /bin/bash

IVERILOG ?= iverilog
VVP      ?= vvp
GTKWAVE  ?= gtkwave

# rtl/: procesador del proyecto 1. rtl-p2/: módulos nuevos del proyecto 2 y los
# del proyecto 1 que cambiaron para él (top.sv). tb/ y tb-p2/: lo mismo para los
# testbenches.
RTL_DIR    := rtl
RTL_P2_DIR := rtl-p2
TB_DIR     := tb
TB_P2_DIR  := tb-p2
BUILD_DIR  := build

RTL_SRCS := $(sort $(wildcard $(RTL_DIR)/*.sv)) $(sort $(wildcard $(RTL_P2_DIR)/*.sv))
TB_SRCS  := $(sort $(wildcard $(TB_DIR)/tb_*.sv)) $(sort $(wildcard $(TB_P2_DIR)/tb_*.sv))
TB_HDRS  := $(wildcard $(TB_DIR)/*.svh $(TB_P2_DIR)/*.svh)
TBS      := $(basename $(notdir $(TB_SRCS)))

# -g2012          SystemVerilog
# -I              rutas para los `include (isa_defs.sv, cache_defs.sv, tb_utils.svh)
# -Wno-timescale  sólo algunos archivos declaran `timescale e Icarus avisaría
#                 en cada módulo que lo hereda
IVFLAGS  ?= -g2012 -Wall -Wno-timescale -I $(RTL_DIR) -I $(RTL_P2_DIR) -I $(TB_DIR) -I $(TB_P2_DIR)

# -n: $stop se comporta como $finish, la simulación nunca queda esperando
VVPFLAGS ?= -n
PLUSARGS ?=

TB ?=

# $(call compile,<testbench>,<archivo del testbench>)
compile = $(IVERILOG) $(IVFLAGS) -s $(1) -o $(BUILD_DIR)/$(1)/sim.vvp $(RTL_SRCS) $(2)


.PHONY: all sim list clean help waves check-tools $(TBS)

all: sim


help:
	@sed -n '2,30p' Makefile | sed 's/^# \{0,1\}//'


check-tools:
	@command -v $(IVERILOG) > /dev/null || { \
	    echo "No se encontró $(IVERILOG). Instale Icarus Verilog: sudo apt install iverilog"; exit 1; }


list:
	@printf '%s\n' $(TBS)


# ------------------------------------------------------------------------------
#  Un target por testbench: make tb_alu
# ------------------------------------------------------------------------------

# El archivo del testbench se busca en tb/ y en tb-p2/ ($< es la ruta encontrada).
vpath tb_%.sv $(TB_DIR) $(TB_P2_DIR)

$(BUILD_DIR)/%/sim.vvp: %.sv $(RTL_SRCS) $(TB_HDRS) | check-tools
	@mkdir -p $(@D)
	$(call compile,$*,$<)

$(TBS): %: $(BUILD_DIR)/%/sim.vvp
	@cd $(BUILD_DIR)/$* && set -o pipefail && $(VVP) $(VVPFLAGS) sim.vvp $(PLUSARGS) 2>&1 | tee sim.log


# ------------------------------------------------------------------------------
#  make sim: compila y ejecuta todos los testbenches y muestra un resumen.
#
#  Estado de cada testbench:
#    PASS          imprimió [PASS] y terminó con código 0
#    FAIL          imprimió [FAIL] o terminó con código distinto de 0
#    SIN-CHEQUEO   corrió sin errores pero no se autoverifica (no usa
#                  tb_utils.svh), hay que revisar su salida a mano
#    NO-COMPILA    error de compilación (ver build/<tb>/compile.log)
#
#  Termina con error si algún testbench quedó en FAIL o NO-COMPILA.
# ------------------------------------------------------------------------------

sim: check-tools
	@echo "Simulando $(words $(TBS)) testbenches con $$($(IVERILOG) -V 2>&1 | head -1)"
	@pass=0; fail=0; nochk=0; bad=0; \
	for src in $(TB_SRCS); do \
	    tb=$$(basename $$src .sv); \
	    mkdir -p $(BUILD_DIR)/$$tb; \
	    if $(call compile,$$tb,$$src) > $(BUILD_DIR)/$$tb/compile.log 2>&1; then \
	        ( cd $(BUILD_DIR)/$$tb && $(VVP) $(VVPFLAGS) sim.vvp $(PLUSARGS) > sim.log 2>&1 ); rc=$$?; \
	        if [ $$rc -ne 0 ] || grep -q '\[FAIL\]' $(BUILD_DIR)/$$tb/sim.log; then \
	            st=FAIL; fail=$$((fail+1)); \
	        elif grep -q '\[PASS\]' $(BUILD_DIR)/$$tb/sim.log; then \
	            st=PASS; pass=$$((pass+1)); \
	        else \
	            st=SIN-CHEQUEO; nochk=$$((nochk+1)); \
	        fi; \
	    else \
	        st=NO-COMPILA; bad=$$((bad+1)); \
	    fi; \
	    printf '  %-12s %s\n' "$$st" "$$tb"; \
	done; \
	echo "Resumen: $$pass PASS, $$fail FAIL, $$bad NO-COMPILA, $$nochk SIN-CHEQUEO"; \
	echo "Logs y ondas en $(BUILD_DIR)/<testbench>/"; \
	[ $$fail -eq 0 ] && [ $$bad -eq 0 ]


# ------------------------------------------------------------------------------
#  make waves TB=tb_alu
# ------------------------------------------------------------------------------

waves:
	@[ -n "$(TB)" ] || { echo "Uso: make waves TB=<testbench>   (ver make list)"; exit 1; }
	@vcd=$$(ls $(BUILD_DIR)/$(TB)/*.vcd 2>/dev/null | head -1); \
	[ -n "$$vcd" ] || { echo "No hay .vcd para $(TB). Ejecute primero: make $(TB)"; exit 1; }; \
	echo "Abriendo $$vcd"; \
	$(GTKWAVE) $$vcd > /dev/null 2>&1 &


clean:
	rm -rf $(BUILD_DIR)


# Pruebas del ensamblador: no requieren simulador.
.PHONY: test-assembler test-programs
test-assembler:
	python3 -m unittest discover -s tests -p 'test_assembler.py' -v
	python3 -m unittest discover -s tests -p 'test_isa.py' -v
	python3 -m unittest discover -s tests -p 'test_bundler.py' -v
	python3 -m unittest discover -s tests -p 'test_bundle_control.py' -v

# Ejecuta contra el RTL real; falla si el resultado es incorrecto.
test-programs: check-tools
	@command -v $(VVP) > /dev/null || { echo "No se encontró $(VVP)"; exit 1; }
	IVERILOG=$(IVERILOG) VVP=$(VVP) python3 -m unittest discover -s tests -p 'test_cpu_program.py' -v


# Regresión del issue #9: ambos modos ejecutan el mismo programa y se comparan
# 32 GPR y toda DMEM después del flush. No se agrega como dependencia de sim.
.PHONY: test-memory-modes
test-memory-modes: check-tools
	@command -v $(VVP) > /dev/null || { echo "No se encontró $(VVP)"; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 IVERILOG=$(IVERILOG) VVP=$(VVP) python3 -m unittest discover -s tests -p 'test_memory_modes.py' -v


# Issue #29: suite independiente; no agrega trabajo a sim ni cambia sus targets.
# Sin P29_EVIDENCE_DIR usa temporales externos; con ella exige un destino nuevo.
.PHONY: test-memory-benchmarks bench-memory
test-memory-benchmarks: check-tools
	@command -v $(VVP) > /dev/null || { echo "No se encontró $(VVP)"; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 IVERILOG=$(IVERILOG) VVP=$(VVP) python3 -m unittest discover -s tests -p 'test_memory_benchmarks.py' -v

# El llamador elige un directorio externo NUEVO para conservar CSV, JSON y dumps.
# El runner rechaza rutas internas, destinos existentes y repeticiones inválidas.
BENCH_OUTPUT ?=
BENCH_REPETITIONS ?= 1
bench-memory: check-tools
	@test -n "$(BENCH_OUTPUT)" || { echo "Use BENCH_OUTPUT=<directorio externo nuevo>"; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 IVERILOG=$(IVERILOG) VVP=$(VVP) python3 tools/run_memory_benchmarks.py --output "$(BENCH_OUTPUT)" --repeat "$(BENCH_REPETITIONS)"


# ------------------------------------------------------------------------------
#  make archivo ARCHIVO=<ruta>
#
#  Cifra y descifra un archivo de cualquier formato en el procesador:
#    1. ensambla examples/cifrar_archivo.asm y examples/descifrar_archivo.asm;
#    2. carga el archivo en la memoria de datos desde 0x200 (tools/load_file.py);
#    3. tests/rtl/tb_archivo.sv ejecuta los dos programas y guarda la memoria en
#       cifrado.mem y descifrado.mem ($writememh);
#    4. tools/extract_data.py saca cifrado.bin y descifrado.bin, y descifrado.bin
#       se compara con el original.
#  Todo queda en build/archivo/. Tamaño máximo: 65024 bytes (64 KB - 0x200).
# ------------------------------------------------------------------------------

ARCHIVO     ?= examples/archivos/mensaje.txt
ARCHIVO_DIR := $(BUILD_DIR)/archivo

.PHONY: archivo
archivo: check-tools
	@test -f "$(ARCHIVO)" || { echo "No existe el archivo $(ARCHIVO)"; exit 1; }
	@mkdir -p $(ARCHIVO_DIR)
	python3 tools/assembler.py --input examples/cifrar_archivo.asm --output $(ARCHIVO_DIR)/cifrar.mem
	python3 tools/assembler.py --input examples/descifrar_archivo.asm --output $(ARCHIVO_DIR)/descifrar.mem
	python3 tools/load_file.py --input "$(ARCHIVO)" --address 0x200 --output $(ARCHIVO_DIR)/datos.mem
	$(IVERILOG) $(IVFLAGS) -s tb_archivo -o $(ARCHIVO_DIR)/sim.vvp $(RTL_SRCS) tests/rtl/tb_archivo.sv
	@set -o pipefail; n=$$(wc -c < "$(ARCHIVO)"); \
	( cd $(ARCHIVO_DIR) && $(VVP) $(VVPFLAGS) sim.vvp +CIFRAR=cifrar.mem +DESCIFRAR=descifrar.mem \
	    +DATOS=datos.mem +BYTES=$$n $(PLUSARGS) 2>&1 | tee sim.log ) && \
	python3 tools/extract_data.py --memory $(ARCHIVO_DIR)/cifrado.mem --address 0x200 --size $$(( (n + 7) / 8 * 8 )) \
	    --format bin --output $(ARCHIVO_DIR)/cifrado.bin && \
	python3 tools/extract_data.py --memory $(ARCHIVO_DIR)/descifrado.mem --address 0x200 --size $$n \
	    --format bin --output $(ARCHIVO_DIR)/descifrado.bin && \
	cmp "$(ARCHIVO)" $(ARCHIVO_DIR)/descifrado.bin && \
	echo "[PASS] $(ARCHIVO): descifrado.bin es idéntico al original ($$n bytes)"


# ------------------------------------------------------------------------------
#  make descifrar ARCHIVO=<cifrado> LLAVE=<K0,K1,K2,K3>
#
#  Descifra en el procesador un archivo que ya viene cifrado con Feistel4
#  (bloques de 8 bytes, L y R en little-endian) usando la llave dada: 4 palabras
#  de 32 bits en hexadecimal; K0 es la de la primera ronda. Ejecuta solo
#  examples/descifrar_archivo.asm (tb_archivo con +SOLO_DESCIFRAR) y deja el
#  resultado en build/descifrar/resultado.bin.
# ------------------------------------------------------------------------------

comma          := ,
LLAVE          ?=
LLAVE_PALABRAS := $(patsubst 0x%,%,$(patsubst 0X%,%,$(subst $(comma), ,$(LLAVE))))
DESCIFRAR_DIR  := $(BUILD_DIR)/descifrar

.PHONY: descifrar
descifrar: check-tools
	@test "$(origin ARCHIVO)" != "file" -a $(words $(LLAVE_PALABRAS)) -eq 4 || { \
	    echo "Uso: make descifrar ARCHIVO=<archivo cifrado> LLAVE=<K0,K1,K2,K3> (hexadecimal)"; exit 1; }
	@test -f "$(ARCHIVO)" || { echo "No existe el archivo $(ARCHIVO)"; exit 1; }
	@mkdir -p $(DESCIFRAR_DIR)
	python3 tools/assembler.py --input examples/descifrar_archivo.asm --output $(DESCIFRAR_DIR)/descifrar.mem
	python3 tools/load_file.py --input "$(ARCHIVO)" --address 0x200 --output $(DESCIFRAR_DIR)/datos.mem
	$(IVERILOG) $(IVFLAGS) -s tb_archivo -o $(DESCIFRAR_DIR)/sim.vvp $(RTL_SRCS) tests/rtl/tb_archivo.sv
	@set -o pipefail; n=$$(wc -c < "$(ARCHIVO)"); \
	( cd $(DESCIFRAR_DIR) && $(VVP) $(VVPFLAGS) sim.vvp +SOLO_DESCIFRAR +DESCIFRAR=descifrar.mem \
	    +DATOS=datos.mem +BYTES=$$n +K0=$(word 1,$(LLAVE_PALABRAS)) +K1=$(word 2,$(LLAVE_PALABRAS)) \
	    +K2=$(word 3,$(LLAVE_PALABRAS)) +K3=$(word 4,$(LLAVE_PALABRAS)) $(PLUSARGS) 2>&1 | tee sim.log ) && \
	python3 tools/extract_data.py --memory $(DESCIFRAR_DIR)/descifrado.mem --address 0x200 --size $$n \
	    --format bin --output $(DESCIFRAR_DIR)/resultado.bin && \
	echo "[PASS] $(ARCHIVO) descifrado en $(DESCIFRAR_DIR)/resultado.bin" && \
	{ command -v file > /dev/null && file $(DESCIFRAR_DIR)/resultado.bin || true; }

# Programa fuente de CE1108 usando sus módulos externos.
CE1108_ROOT ?=
.PHONY: ce1108-source test-ce1108-source
ce1108-source: check-tools
	@test -n "$(CE1108_ROOT)" || { echo "Use make ce1108-source CE1108_ROOT=<repositorio_compiladores>"; exit 1; }
	IVERILOG=$(IVERILOG) VVP=$(VVP) python3 tools/run_ce1108_source.py --compiler-root "$(CE1108_ROOT)" \
	    --input examples/ce1108_programa.bal --expect-memory examples/ce1108_programa.memory.json

test-ce1108-source: check-tools
	@test -n "$(CE1108_ROOT)" || { echo "Indique CE1108_ROOT=<repositorio_compiladores>"; exit 1; }
	CE1108_ROOT="$(CE1108_ROOT)" IVERILOG=$(IVERILOG) VVP=$(VVP) \
	    python3 -m unittest discover -s tests -p 'test_ce1108_source.py' -v

.PHONY: compiladores-factorial test-compiladores-funciones
compiladores-factorial:
	IVERILOG=$(IVERILOG) VVP=$(VVP) python3 tools/run_ce1108_source.py --functions --compiler-root "$(CE1108_ROOT)" --input "$(CE1108_ROOT)/examples/factorial.bal" --expect-memory examples/compiladores_factorial.memory.json --cycles 20000

test-compiladores-funciones:
	CE1108_ROOT="$(CE1108_ROOT)" IVERILOG=$(IVERILOG) VVP=$(VVP) python3 -m unittest discover -s tests -p 'test_compiler_functions.py' -v
