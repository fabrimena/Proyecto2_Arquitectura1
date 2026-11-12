#!/usr/bin/env python3
"""Ensambla y ejecuta programas ALU/LSU/BRU/CRIPTO sobre top.

Issue #28: acepta dumps tras el handshake de vaciado confirmado por el banco;
conserva diagnósticos y descarta capturas parciales si falla el mantenimiento.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

if __package__:
    from .assembler import MAX_BUNDLES, AssemblyError, assemble_source, integer, register
else:
    from assembler import MAX_BUNDLES, AssemblyError, assemble_source, integer, register


ROOT = Path(__file__).resolve().parents[1]
# Se reservan 4 bundles de la memoria de instrucciones para el vaciado del
# pipeline después del último bundle del programa.
MAX_RUN_BUNDLES = MAX_BUNDLES - 4
IMEM_BYTES = MAX_BUNDLES * 16


class SimulationError(RuntimeError):
    """Fallo de compilación, simulación o comparación de resultados."""


def tool(variable: str, default: str) -> str:
    name = os.environ.get(variable, default)
    found = shutil.which(name)
    if not found:
        raise SimulationError(f"no se encontró {name}; instale Icarus Verilog (iverilog y vvp)")
    return found


def read_expected(path: Path) -> dict[int, int]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not raw:
        raise SimulationError("el archivo esperado debe ser un objeto JSON no vacío: {\"x1\": 7}")
    result = {}
    for key, value in raw.items():
        reg = register(key)
        if reg in result:
            raise SimulationError(f"x{reg} aparece más de una vez usando distintos alias")
        if isinstance(value, bool) or not isinstance(value, (str, int)):
            raise SimulationError(f"valor esperado inválido para {key}")
        number = integer(value) if isinstance(value, str) else value
        if not -(1 << 31) <= number <= (1 << 32) - 1:
            raise SimulationError(f"valor esperado de {key} fuera de 32 bits")
        result[reg] = number & 0xffffffff
    return result


def run_logged(command: list[str], cwd: Path, log: Path, timeout: int) -> str:
    try:
        result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or b"").decode("utf-8", errors="replace")
        log.write_text(output, encoding="utf-8")
        raise SimulationError(f"tiempo máximo excedido; consulte {log}") from exc
    output = result.stdout.decode("utf-8", errors="replace")
    log.write_text(output, encoding="utf-8")
    if result.returncode or "[FAIL]" in output:
        detail = "\n".join(output.splitlines()[-12:])
        raise SimulationError(f"falló {Path(command[0]).name}; consulte {log}\n{detail}")
    return output


ABI_NAMES = {1: "ra", 2: "sp", 3: "gp"}


def signed(value: int) -> int:
    return value - (1 << 32) if value & 0x80000000 else value


def source_labels(source: str) -> dict[int, str]:
    """PC de cada etiqueta, con el mismo recorrido que assemble_source."""
    labels: dict[int, str] = {}
    count = 0
    for raw_line in source.splitlines():
        code = re.split(r"#|;|//", raw_line, maxsplit=1)[0].strip()
        match = re.match(r"^([A-Za-z_][A-Za-z_0-9]*):", code)
        if match:
            labels[count * 16] = f"{labels[count * 16]}, {match[1]}" if count * 16 in labels else match[1]
            code = code[match.end():].strip()
        if code:
            count += 1
    return labels


def trace_text(name: str, program, labels: dict[int, str], raw: list[str]) -> str:
    """Convierte la traza del testbench en una tabla legible: un cambio por línea."""
    bundles = {b.pc: " | ".join(i.text for i in b.instructions) for b in program.bundles}
    rows: list[tuple[int, int, str]] = []
    counts = {"REG": 0, "MEM": 0, "ESTADO": 0, "JUMP": 0, "TRAP": 0}
    loop_pc, loop_repeats, loop_last = None, 0, 0

    def close_loop() -> None:
        nonlocal loop_pc, loop_repeats
        if loop_repeats:
            rows.append((loop_last, loop_pc,
                         f"(se repite {loop_repeats} veces más, hasta el ciclo {loop_last})"))
        loop_pc, loop_repeats = None, 0

    for line in raw:
        parts = line.split()
        cycle, kind, pc = int(parts[0]), parts[1], int(parts[2], 16)
        counts[kind] += 1
        if kind == "JUMP" and int(parts[3], 16) == pc and loop_pc == pc:
            loop_repeats, loop_last = loop_repeats + 1, cycle
            continue
        close_loop()
        if kind == "REG":
            reg, old, new = int(parts[3]), int(parts[4], 16), int(parts[5], 16)
            alias = f"/{ABI_NAMES[reg]}" if reg in ABI_NAMES else ""
            change = f"x{reg}{alias}: 0x{old:08x} -> 0x{new:08x} ({signed(new)})"
        elif kind == "MEM":
            address, data, enables = int(parts[3], 16), int(parts[4], 16), parts[5]
            if enables == "1111":
                change = f"M[0x{address & ~3:04x}] = 0x{data:08x} ({signed(data)})"
            else:
                lane = 3 - enables.index("1")
                change = f"M[0x{address:04x}] = 0x{(data >> 8 * lane) & 0xff:02x} (byte)"
        elif kind == "ESTADO":
            (init_old, auth_old), (init_new, auth_new) = parts[3], parts[4]
            change = f"ESTADO: AUTH {auth_old} -> {auth_new}, INIT {init_old} -> {init_new}"
        elif kind == "JUMP":
            target = int(parts[3], 16)
            label = f" ({labels[target % IMEM_BYTES]})" if target % IMEM_BYTES in labels else ""
            change = f"salto tomado a 0x{target:04x}{label}"
            if target == pc:
                loop_pc, loop_last = pc, cycle
        else:
            change = f"excepción de privilegio -> 0x{int(parts[3], 16):04x} (TRAP)"
        rows.append((cycle, pc, change))
    close_loop()
    header = [f"# Traza dinámica de {name}",
              "# Un cambio de estado por línea, en el ciclo en que ocurre: registros en WB;",
              "# ESTADO en WB; memoria, saltos tomados y excepciones en EX. Entre paréntesis, el valor",
              "# en decimal.",
              f"# {'ciclo':>6}  {'PC':<6}  {'cambio':<46}  bundle (ALU | LSU | BRU | CRIPTO)"]
    body = []
    for cycle, pc, change in rows:
        # La memoria de instrucciones toma el PC módulo su tamaño
        label = f"{labels[pc % IMEM_BYTES]}: " if pc % IMEM_BYTES in labels else ""
        bundle = bundles.get(pc % IMEM_BYTES, "nop (fuera del programa)")
        body.append(f"{cycle:>8}  0x{pc:04x}  {change:<46}  {label}{bundle}")
    footer = (f"# {counts['REG']} escrituras de registros, {counts['MEM']} escrituras en memoria, "
              f"{counts['ESTADO']} cambios de ESTADO, {counts['JUMP']} saltos tomados y "
              f"{counts['TRAP']} excepciones")
    return "\n".join(header + body + [footer]) + "\n"


def run_program(source: Path, workdir: Path, expected: dict[int, int] | None = None,
                vcd: bool = True, expected_memory: dict[int, int] | None = None,
                cycles: int | None = None, trace: bool = False) -> dict[int, int]:
    source = source.resolve()
    source_text = source.read_text(encoding="utf-8")
    program = assemble_source(source_text)
    if cycles is not None and not len(program.bundles) + 4 <= cycles <= 100000:
        raise SimulationError("cycles debe cubrir el programa y ser menor o igual a 100000")
    for address, value in (expected_memory or {}).items():
        if address % 4 or not 0 <= address <= 65532 or not 0 <= value <= 0xffffffff:
            raise SimulationError("memoria esperada: direcciones alineadas de 64 KiB y valores de 32 bits")
    if len(program.bundles) > MAX_RUN_BUNDLES:
        raise SimulationError(f"la prueba admite hasta {MAX_RUN_BUNDLES} bundles; reserva 4 "
                              f"ciclos de vaciado antes de superar las {MAX_BUNDLES} entradas "
                              "de la memoria de instrucciones")
    compiler, simulator = tool("IVERILOG", "iverilog"), tool("VVP", "vvp")
    workdir = workdir.resolve()
    generated = [workdir / name for name in
                 ("program.mem", "program.lst", "sim.vvp", "compile.log",
                  "sim.log", "registers.txt", "program.vcd", "memory.txt",
                  "trace_raw.txt", "trace.txt")]
    if source in generated:
        raise SimulationError("el archivo fuente no puede ser una salida dentro del directorio de trabajo")
    workdir.mkdir(parents=True, exist_ok=True)
    memory, listing, binary, compile_log, sim_log, dump, wave, memdump, raw_trace, trace_file = generated
    memory.write_text(program.memory_text(), encoding="ascii")
    listing.write_text(program.listing_text(), encoding="utf-8")
    # Evitar aceptar un dump viejo si una ejecución nueva no lo produce.
    memdump.unlink(missing_ok=True)
    dump.unlink(missing_ok=True)
    wave.unlink(missing_ok=True)
    raw_trace.unlink(missing_ok=True)
    trace_file.unlink(missing_ok=True)
    # rtl/: procesador del proyecto 1; rtl-p2/: módulos del proyecto 2 (y top.sv)
    rtl = [str(p) for d in ("rtl", "rtl-p2") for p in sorted((ROOT / d).glob("*.sv"))]
    run_logged([compiler, "-g2012", "-Wall", "-Wno-timescale",
                "-I", str(ROOT / "rtl"), "-I", str(ROOT / "rtl-p2"), "-I", str(ROOT / "tb"),
                "-s", "tb_assembled_program", "-o", str(binary), *rtl,
                str(ROOT / "tests/rtl/tb_assembled_program.sv")],
               ROOT, compile_log, 30)
    command = [simulator, "-n", str(binary), f"+MEM={memory}",
               f"+REGDUMP={dump}", f"+BUNDLES={len(program.bundles)}",
               f"+MEMDUMP={memdump}", f"+CYCLES={cycles or len(program.bundles) + 4}"]
    if vcd:
        command.append(f"+VCD={wave}")
    if trace:
        command.append(f"+TRACE={raw_trace}")
    # El código0 por sí solo no confirma persistencia: exigimos el marcador
    # del handshake y el cierre normal del banco en ESTA ejecución. El RTL
    # distingue flancos del programa de mantenimiento; el timeout de pared da
    # margen para flush, sin reemplazar el timeout de protocolo del testbench.
    try:
        output = run_logged(command, workdir, sim_log, 30)
        flushed = re.search(r"^\[FLUSH\] fase=assembled modo=[012] espera=[0-9]+ salida=[0-9]+$",
                            output, re.MULTILINE)
        finished = f"[OK] programa ejecutado: {len(program.bundles)} bundles; 32 registros definidos"
        if not flushed or finished not in output:
            raise SimulationError(f"simulación sin confirmación de vaciado o finalización; consulte {sim_log}")
        if not dump.is_file() or not memdump.is_file():
            raise SimulationError(f"simulación sin dumps nuevos completos; consulte {sim_log}")
    except (OSError, SimulationError):
        # Puede existir un snapshot parcial de registros si el flush falla luego.
        # Invalidamos solo nuestros dos dumps; conservamos logs, traza y ondas
        # para diagnóstico y nunca aceptamos restos de una ejecución anterior.
        dump.unlink(missing_ok=True)
        memdump.unlink(missing_ok=True)
        raise
    if trace:
        trace_file.write_text(trace_text(source.name, program, source_labels(source_text),
                                         raw_trace.read_text(encoding="ascii").splitlines()),
                              encoding="utf-8")
    registers = {}
    for line in dump.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"x([0-9]+) ([0-9a-fA-F]{8})", line)
        if not match:
            raise SimulationError(f"dump de registros inválido: {line}")
        reg, value = int(match[1]), int(match[2], 16)
        if reg > 31 or reg in registers:
            raise SimulationError("dump con un registro duplicado o fuera de rango")
        registers[reg] = value
    if set(registers) != set(range(32)):
        raise SimulationError("el dump no contiene exactamente los 32 registros")
    mismatches = [f"x{reg}: obtenido 0x{registers[reg]:08x}, esperado 0x{value:08x}"
                  for reg, value in (expected or {}).items() if registers[reg] != value]
    words = memdump.read_text(encoding="ascii").splitlines()
    if len(words) != 16384 or any(not re.fullmatch(r"[0-9a-fA-F]{8}", w) for w in words):
        raise SimulationError("dump de memoria incompleto o con valores X/Z")
    for address, value in (expected_memory or {}).items():
        actual = int(words[address // 4], 16)
        if actual != value:
            mismatches.append(f"mem[0x{address:04x}]: obtenido 0x{actual:08x}, esperado 0x{value:08x}")
    if mismatches:
        raise SimulationError("resultados incorrectos:\n" + "\n".join(mismatches))
    return registers


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="programa ensamblador")
    parser.add_argument("--workdir", type=Path, help="salidas; por defecto build/program_<nombre>")
    parser.add_argument("--expect", type=Path, help="JSON de registros esperados")
    parser.add_argument("--no-vcd", action="store_true", help="omitir la traza VCD")
    parser.add_argument("--expect-memory", type=Path, help='JSON {"0x100": "0x0000007f"}')
    parser.add_argument("--cycles", type=int, help="ciclos de ejecución para programas con saltos")
    parser.add_argument("--trace", action="store_true",
                        help="traza dinámica en trace.txt: cada cambio de registro o memoria, ciclo a ciclo")
    args = parser.parse_args(argv)
    workdir = args.workdir or ROOT / "build" / f"program_{args.input.stem}"
    try:
        expected = read_expected(args.expect) if args.expect else None
        expected_memory = None
        if args.expect_memory:
            raw = json.loads(args.expect_memory.read_text(encoding="utf-8"))
            if not isinstance(raw, dict) or not raw:
                raise SimulationError("memoria esperada debe ser un objeto JSON no vacío")
            expected_memory = {}
            for address, value in raw.items():
                if isinstance(value, bool) or not isinstance(value, (str, int)):
                    raise SimulationError("valor de memoria inválido")
                number = integer(address)
                if number in expected_memory:
                    raise SimulationError("dirección de memoria repetida")
                expected_memory[number] = integer(value) if isinstance(value, str) else value
        registers = run_program(args.input, workdir, expected, not args.no_vcd, expected_memory, args.cycles,
                                args.trace)
    except (OSError, UnicodeError, ValueError, SimulationError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    if expected or expected_memory:
        print(f"[PASS] {len(expected or {})} registros y {len(expected_memory or {})} palabras coinciden")
    else:
        print("[OK] ejecución terminada; use --expect para verificar los resultados")
    for reg, value in registers.items():
        if value:
            print(f"x{reg:<2} = 0x{value:08x}")
    print(f"Memoria, listado, logs y registros: {workdir.resolve()}")
    if args.trace:
        print(f"Traza dinámica: {(workdir / 'trace.txt').resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
