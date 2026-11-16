#!/usr/bin/env python3
"""Benchmarks independientes #29: fuente VLIW -> dos modos RTL -> oráculo completo.

Entradas: tres ASM/JSON versionados, reset a cero y herramientas de run_program.
Salidas: directorio externo NUEVO con capturas, trazas, execution.json, CSV/JSON.
No cambia RTL, ISA, políticas ni el runner anterior. Usa avances/flancos del banco,
no tiempo de pared para rendimiento. L2 es MODEL: no exporta hits L2 ni AMAT.
Cada invocación posee sus destinos; un error conserva diagnóstico y retorna fallo.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import csv
import hashlib
import itertools
import json
from pathlib import Path
import re
import sys
import time
import uuid

if __package__:
    from . import run_program as runner
    from .assembler import assemble_source, integer, register
else:
    import run_program as runner
    from assembler import assemble_source, integer, register

ROOT = Path(__file__).resolve().parents[1]
NAMES = ('secuencial', 'aleatorio', 'stride')
SEED = 0x29c0de
FILE_SEED = 0x18b00b5
FILE_SHA256 = 'c98e65ae5a58f7925bdc75bd3325ff60603df3c7113f5852bcccc2784fd920c3'
# Las columnas no mezclan mantenimiento con ejecución ni tamaño con retiros.
COLUMNS = ('repetition', 'benchmark', 'pattern', 'accesses', 'reads', 'writes',
           'useful_bytes', 'logical_bytes', 'span_bytes', 'lines', 'sets', 'mode', 'advances',
           'execution_edges', 'stalls', 'maintenance_edges', 'architecture',
           'image_sha256', 'directory')


class BenchmarkError(RuntimeError):
    """Contrato inválido de programa, captura o reporte; distinto de fallo de infraestructura."""


@dataclass(frozen=True)
class Oracle:
    """Referencia previa al DUT, propiedad del experimento y sin recursos abiertos.

    source identifica el ASM; image es el ensamblado esperado. registers/memory
    representan TODO el estado visible. stores contiene PC/dirección/dato/máscara
    en orden; reads los datos esperados. cycles fija el corte len(bundles)+4.
    """
    name: str
    source: Path
    image: bytes
    bundles: int
    cycles: int
    addresses: tuple[int, ...]
    registers: tuple[int, ...]
    memory: tuple[int, ...]
    stores: tuple[tuple[int, int, int, int], ...]
    reads: tuple[int, ...]


@dataclass(frozen=True)
class Capture:
    """Captura validada de un modo; conserva ubicación, bytes y estado completos.

    stats proviene de marcadores contrastados con execution.json. El objeto no
    posee el directorio ni lo borra. No presupone que el otro modo sea correcto.
    """
    directory: Path
    mode: int
    image: bytes
    registers: tuple[int, ...]
    memory: tuple[int, ...]
    stats: dict


def addresses(name: str) -> tuple[int, ...]:
    """Devuelve las 32 direcciones canónicas, sin consultar programa ni DUT.

    name selecciona patrón; otro nombre produce BenchmarkError. Aleatorio usa
    Fisher-Yates y LCG32 explícitos con semilla fija; no toca random global ni
    archivos. Stride 2048 preserva el índice de los 64 conjuntos de dos vías.
    """
    if name == 'secuencial':
        return tuple(4 * i for i in range(32))
    if name == 'stride':
        return tuple(2048 * i for i in range(32))
    if name != 'aleatorio':
        raise BenchmarkError('benchmark desconocido')
    pool = list(range(128))
    state = SEED
    for i in range(127, 0, -1):
        state = (1664525 * state + 1013904223) & 0xffffffff
        j = state % (i + 1)
        pool[i], pool[j] = pool[j], pool[i]
    return tuple(32 * i for i in pool[:32])


def archive_bytes() -> bytes:
    """Genera exactamente 18432 bytes reproducibles, sin recursos ni estado externo.

    LCG32 con FILE_SEED; cada byte toma los ocho bits altos del nuevo estado.
    No es un generador criptográfico: solo datos binarios diversos para Feistel4.
    El llamador decide dónde conservarlos; esta función nunca escribe archivos.
    """
    state = FILE_SEED
    data = bytearray()
    for _ in range(18432):
        state = (1664525 * state + 1013904223) & 0xffffffff
        data.append(state >> 24)
    return bytes(data)


def prepare_oracle(name: str, examples: Path = ROOT / 'examples') -> Oracle:
    """Verifica ASM/JSON y prepara referencias ISA antes de cualquier ejecución.

    Recibe nombre y carpeta de fixtures. Solo lee; OSError/errores de ensamblado
    conservan su causa y BenchmarkError identifica desacuerdos semánticos. El
    intérprete estático admite únicamente las formas acotadas de estos programas:
    ALU sumai/cizqi/suma, guardap/cargai y salto final a sí mismo. No es simulador
    del pipeline: N+3, WAW/RAW, slots e IMEM los verifica assemble_source existente.
    Se contrastan direcciones con el patrón canónico, datos 1..32 y dos pasadas;
    jamás se obtiene gold de dumps ni se adopta el modo0 como verdad.
    """
    expected_addresses = addresses(name)
    source = examples / f'bench_{name}.asm'
    program = assemble_source(source.read_text(encoding='utf-8'))
    if not 1 <= len(program.bundles) <= runner.MAX_RUN_BUNDLES:
        raise BenchmarkError('capacidad IMEM del runner excedida')
    regs, memory = [0] * 32, [0] * 16384
    accesses, stores, reads = [], [], []
    for bundle in program.bundles:
        for slot, ins in enumerate(bundle.instructions):
            parts = re.split(r'[\s,]+', ins.text.strip().lower())
            op, args = parts[0], parts[1:]
            if op == 'nop':
                continue
            if slot == 0 and op in ('sumai', 'cizqi', 'suma'):
                rd, rs = register(args[0]), register(args[1])
                value = (regs[rs] + integer(args[2]) if op == 'sumai' else
                         regs[rs] << (integer(args[2]) & 31) if op == 'cizqi' else
                         regs[rs] + regs[register(args[2])])
                if rd:
                    regs[rd] = value & 0xffffffff
            elif slot == 1 and op in ('guardap', 'cargai'):
                first, second = register(args[0]), register(args[1])
                base = second if op == 'cargai' else first
                address = regs[base] + integer(args[2])
                if address % 4 or not 0 <= address <= 65532:
                    raise BenchmarkError('dirección de memoria inválida')
                accesses.append((op, address))
                if op == 'guardap':
                    memory[address // 4] = regs[second]
                    stores.append((bundle.pc, address, regs[second], 15))
                else:
                    value = memory[address // 4]
                    reads.append(value)
                    if first:
                        regs[first] = value
            elif slot == 2 and op == 'sye' and bundle is program.bundles[-1] and ins.target == bundle.pc and not ins.writes:
                pass  # Reposo útil, sin HALT, enlace ni efectos posteriores.
            else:
                raise BenchmarkError('instrucción fuera del contrato del benchmark')
    last = program.bundles[-1].instructions[2]
    if last.target != program.bundles[-1].pc or last.writes or last.indirect:
        raise BenchmarkError('falta salto final de reposo')
    planned = [('guardap', a) for a in expected_addresses] + [('cargai', a) for a in expected_addresses] * 2
    if accesses != planned:
        raise BenchmarkError(f'patrón {name} o cantidad de accesos incorrecto')
    gold = [0] * 16384
    for i, a in enumerate(expected_addresses):
        gold[a // 4] = i + 1
    gold_regs = [0] * 32
    for r, value in {4:32, 5:32, 6:1056, 7:1, 20:expected_addresses[-1] // 1024 * 1024}.items():
        gold_regs[r] = value
    if regs != gold_regs or memory != gold or reads != list(range(1, 33)) * 2:
        raise BenchmarkError('semántica del programa difiere del oráculo independiente')
    expected = runner.read_expected(examples / f'bench_{name}.expected.json')
    raw = json.loads((examples / f'bench_{name}.memory.json').read_text())
    if not isinstance(raw, dict):
        raise BenchmarkError('expectativa de memoria debe ser un objeto')
    mem_expected = {integer(k):v for k, v in raw.items()}
    if (len(raw) != len(mem_expected) or set(expected) != set(range(32)) or
        tuple(expected[r] for r in range(32)) != tuple(gold_regs) or
        any(type(v) is not int for v in mem_expected.values()) or
        mem_expected != {a:i+1 for i,a in enumerate(expected_addresses)}):
        raise BenchmarkError('expectativa JSON alterada o incompleta')
    return Oracle(name, source, program.memory_text().encode('ascii'), len(program.bundles),
                  len(program.bundles)+4, expected_addresses, tuple(regs), tuple(gold), tuple(stores), tuple(reads))


def validate_trace(path: Path, oracle: Oracle) -> None:
    """Contrasta escrituras ordenadas, lecturas y llegada al reposo en traza real.

    Lee trace_raw sin modificarlo. BenchmarkError distingue una pérdida/cambio de
    efectos de un archivo ausente (OSError). El banco registra niveles incluso en
    freeze: se colapsan solo repeticiones adyacentes del mismo store, y del valor
    de x5. Esto es válido aquí porque PCs de stores y valores de cargas adyacentes
    son distintos; no sirve para programas arbitrarios. wb_pc no se usa para
    identificar loads, pues el trazador anterior lo actualiza con clk general.
    La aceptación final se acredita además con progreso, checksum y estado total.
    """
    stores, loads, jumps = [], [], []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) < 4 or not parts[0].isdigit():
            raise BenchmarkError('traza mal formada')
        kind = parts[1]
        if kind == 'MEM' and len(parts) == 6:
            stores.append((int(parts[2], 16), int(parts[3], 16), int(parts[4], 16), int(parts[5], 2)))
        elif kind == 'REG' and len(parts) == 6:
            if int(parts[3]) == 5:
                loads.append(int(parts[5], 16))
        elif kind == 'JUMP' and len(parts) == 4:
            jumps.append((int(parts[2], 16), int(parts[3], 16)))
        else:
            raise BenchmarkError('traza contiene excepción, estado cripto o evento inválido')
    if tuple(k for k, _ in itertools.groupby(stores)) != oracle.stores:
        raise BenchmarkError('orden/dato/máscara de escrituras incorrecto')
    if tuple(k for k, _ in itertools.groupby(loads)) != oracle.reads:
        raise BenchmarkError('datos u orden de cargas incorrecto')
    final_pc = (oracle.bundles - 1) * 16
    if not jumps or any(pair != (final_pc, final_pc) for pair in jumps):
        raise BenchmarkError('no se observó salto final de reposo')


def read_capture(directory: Path, mode: int, oracle: Oracle, since_ns: int = 0) -> Capture:
    """Valida procedencia, formato, configuración y oráculos de una ejecución nueva.

    directory contiene salidas exclusivas; since_ns es la frontera de creación
    usada únicamente para detectar restos, NO para medir rendimiento. Lee todos
    los archivos sin alterarlos. BenchmarkError identifica errores de estado,
    imagen, frescura o reporte; el parser heredado conserva SimulationError para
    marcadores inválidos. Los 32 GPR y 16384 words se revisan sin truncar zip.
    """
    for filename in ('program.mem', 'sim.vvp', 'sim.log', 'registers.txt', 'memory.txt', 'trace_raw.txt', 'execution.json'):
        p = directory / filename
        if not p.is_file() or p.stat().st_mtime_ns < since_ns:
            raise BenchmarkError('salida ausente u obsoleta: ' + filename)
    image = (directory / 'program.mem').read_bytes()
    if image != oracle.image:
        raise BenchmarkError('imagen de programa distinta')
    output = (directory / 'sim.log').read_text()
    finish = f'[OK] programa ejecutado: {oracle.bundles} bundles; 32 registros definidos'
    if output.splitlines().count(finish) != 1 or '[FAIL]' in output:
        raise BenchmarkError('finalización no acreditada')
    parsed = runner.execution_metadata(output, mode, oracle.bundles, oracle.cycles)
    metadata = json.loads((directory / 'execution.json').read_text())
    if (metadata.get('schema') != 1 or metadata.get('requested_mode') != mode or
        metadata.get('effective_mode') != mode or metadata.get('stats') != parsed['stats']):
        raise BenchmarkError('execution.json incoherente con modo/estadística real')
    if (metadata.get('image_sha256') != hashlib.sha256(image).hexdigest() or
        metadata.get('binary_sha256') != hashlib.sha256((directory/'sim.vvp').read_bytes()).hexdigest() or
        f'-Ptb_assembled_program.MEM_MODE={mode}' not in metadata.get('compile_command', []) or
        f'+REQUESTED_MEM_MODE={mode}' not in metadata.get('simulation_command', [])):
        raise BenchmarkError('procedencia de elaboración incoherente')
    regs = {}
    for line in (directory/'registers.txt').read_text().splitlines():
        match = re.fullmatch(r'x([0-9]+) ([0-9a-fA-F]{8})', line)
        if not match or int(match[1]) in regs or not 0 <= int(match[1]) <= 31:
            raise BenchmarkError('dump GPR inválido')
        regs[int(match[1])] = int(match[2], 16)
    if set(regs) != set(range(32)):
        raise BenchmarkError('dump GPR incompleto')
    words = (directory/'memory.txt').read_text().splitlines()
    if len(words) != 16384 or any(not re.fullmatch(r'[0-9a-fA-F]{8}', s) for s in words):
        raise BenchmarkError('dump DMEM truncado o inválido')
    values = tuple(int(s, 16) for s in words)
    registers = tuple(regs[r] for r in range(32))
    for r, (actual, expected) in enumerate(zip(registers, oracle.registers)):
        if actual != expected:
            raise BenchmarkError(f'oráculo GPR x{r}: {actual:08x} != {expected:08x}')
    if len(oracle.registers) != 32 or len(oracle.memory) != 16384:
        raise BenchmarkError('oráculo incompleto')
    for i, (actual, expected) in enumerate(zip(values, oracle.memory)):
        if actual != expected:
            raise BenchmarkError(f'oráculo DMEM 0x{4*i:04x}: {actual:08x} != {expected:08x}')
    validate_trace(directory/'trace_raw.txt', oracle)
    return Capture(directory, mode, image, registers, values, parsed['stats'])


def compare_captures(a: Capture, b: Capture) -> None:
    """Compara modos 0/2 al mismo horizonte, TODOS los GPR/DMEM e imagen real.

    Recibe capturas ya validadas con su oráculo. Sin archivos/efectos, retorna
    None o BenchmarkError con la categoría precisa; igualdad entre modos no
    reemplaza la validación independiente anterior ni exige iguales flancos.
    """
    if (a.mode, b.mode) != (0, 2) or a.stats['avances'] != b.stats['avances']:
        raise BenchmarkError('comparación con modo/horizonte incompatible')
    if a.image != b.image:
        raise BenchmarkError('comparación de imágenes distintas')
    if len(a.registers) != 32 or len(b.registers) != 32 or a.registers != b.registers:
        raise BenchmarkError('comparación GPR diferente o incompleta')
    if len(a.memory) != 16384 or len(b.memory) != 16384 or a.memory != b.memory:
        raise BenchmarkError('comparación DMEM diferente o incompleta')


def execute_mode(oracle: Oracle, directory: Path, mode: int) -> Capture:
    """Reserva un destino NUEVO, invoca run_program real y relee sus evidencias.

    Recibe referencia previa, destino externo y modo. No acepta directorios
    existentes ni vuelve a usar dumps/binarios. Retorna Capture; los errores del
    runner/OS se propagan y conservan logs. since_ns solo acredita novedad de
    archivos en este proceso. El llamador posee los recursos y decide conservarlos.
    """
    if mode not in (0, 2) or type(mode) is not int:
        raise BenchmarkError('modo requiere entero 0 o 2')
    directory = directory.resolve()
    if directory == ROOT or ROOT in directory.parents:
        raise BenchmarkError('evidencia debe estar fuera del repositorio')
    if directory.exists():
        raise BenchmarkError('destino obsoleto o reutilizado')
    directory.mkdir(parents=True, exist_ok=False)
    since_ns = time.time_ns()
    result = runner.run_program(oracle.source, directory, dict(enumerate(oracle.registers)),
                                False, {a:oracle.memory[a//4] for a in oracle.addresses},
                                oracle.cycles, True, mode)
    state = read_capture(directory, mode, oracle, since_ns)
    if tuple(result[r] for r in range(32)) != state.registers:
        raise BenchmarkError('retorno API distinto del dump')
    return state


def report_row(oracle: Oracle, capture: Capture, repetition: int) -> dict:
    """Convierte medidas RTL a una fila, con unidades y población explícitas.

    No lee ni cambia archivos. Conteos de accesos son estáticos comprobados con
    oráculo/traza; no son contadores de hits. No suma cuatro stalls por etapa ni
    atribuye flancos de flush a ejecución. Sin interfaz exportada, no inventa IPC,
    K1-A/B ni métricas L2 a partir de duración o de solicitudes de línea.
    """
    a, s = oracle.addresses, capture.stats
    return dict(repetition=repetition, benchmark=oracle.name, pattern=oracle.name,
                accesses=96, reads=64, writes=32, useful_bytes=128, logical_bytes=384,
                span_bytes=max(a)-min(a)+4, lines=len({x//32 for x in a}),
                sets=len({(x//32)%64 for x in a}), mode=capture.mode,
                advances=s['avances'], execution_edges=s['flancos'], stalls=s['stalls'],
                maintenance_edges=s['flush'], architecture='EQUIVALENTE Y CORRECTO',
                image_sha256=hashlib.sha256(capture.image).hexdigest(), directory=str(capture.directory))


def validate_report(rows: list[dict], repetitions: int) -> None:
    """Exige esquema cerrado, población e identidades antes de publicar CSV/JSON.

    rows proviene de capturas nuevas; repetitions fija las seis filas por ronda.
    No cambia recursos. BenchmarkError detecta estadísticas adulteradas, modos
    omitidos o repetidos y cohortes incompatibles; no acredita significancia.
    """
    keys = [(r['repetition'], r['benchmark'], r['mode']) for r in rows]
    intended = {(i, n, m) for i in range(1, repetitions+1) for n in NAMES for m in (0, 2)}
    if len(keys) != len(intended) or set(keys) != intended:
        raise BenchmarkError('reporte incompleto o duplicado')
    for row in rows:
        if set(row) != set(COLUMNS):
            raise BenchmarkError('esquema de reporte inválido')
        population = addresses(row['benchmark'])
        # La geometría describe bytes útiles y extensión de direcciones, no el
        # tráfico físico. Se contrasta para no publicar una cohorte adulterada.
        if (row['pattern'] != row['benchmark'] or row['span_bytes'] != max(population)-min(population)+4 or
            row['lines'] != len({x//32 for x in population}) or
            row['sets'] != len({(x//32)%64 for x in population}) or
            row['accesses'] != 96 or row['reads'] != 64 or row['writes'] != 32 or
            row['useful_bytes'] != 128 or row['logical_bytes'] != 384 or row['advances'] != 872 or
            row['execution_edges'] != row['advances']+row['stalls'] or row['stalls'] < 0 or
            (row['mode'] == 0 and (row['stalls'] != 0 or row['maintenance_edges'] != 0)) or
            (row['mode'] == 2 and row['maintenance_edges'] <= 0) or
            row['architecture'] != 'EQUIVALENTE Y CORRECTO'):
            raise BenchmarkError('conteos o estadísticas del reporte incoherentes')


def run_benchmarks(output: Path, examples: Path = ROOT/'examples', repetitions: int = 1) -> dict:
    """Ejecuta la matriz completa y publica solo resultados verificados.

    output debe ser un destino externo inexistente; examples aporta fixtures.
    repetitions es entero positivo acotado, para repetir sin reutilizar capturas.
    Posee y conserva salidas parciales ante fallo; summary.json/CSV solo aparecen
    después de validar todas las parejas y su repetibilidad. No realiza Git.
    """
    if type(repetitions) is not int or not 1 <= repetitions <= 10:
        raise BenchmarkError('repeticiones requiere entero 1..10')
    output = output.resolve()
    if output == ROOT or ROOT in output.parents:
        raise BenchmarkError('evidencia debe estar fuera del repositorio')
    output.mkdir(parents=True, exist_ok=False)
    plans = [prepare_oracle(n, examples) for n in NAMES]
    rows, previous = [], {}
    for iteration in range(1, repetitions+1):
        for plan in plans:
            work = output/f'{iteration:02d}-{plan.name}'
            work.mkdir()
            # Conservar fuente y gold ANTES de invocar hardware acredita origen.
            source = work/'input.asm'
            source.write_bytes(plan.source.read_bytes())
            (work/'oracle.json').write_text(json.dumps(dict(addresses=plan.addresses,
                registers=plan.registers, memory=plan.memory, cycles=plan.cycles), indent=2)+'\n')
            # Ambos modos leen esta misma copia externa, no una fuente que otra
            # sesión pudiera editar entre las dos elaboraciones.
            frozen_plan = replace(plan, source=source)
            states = [execute_mode(frozen_plan, work/f'mode-{m}', m) for m in (0, 2)]
            compare_captures(*states)
            for state in states:
                key = (plan.name, state.mode)
                if key in previous:
                    old = previous[key]
                    if (old.registers, old.memory, old.stats) != (state.registers, state.memory, state.stats):
                        raise BenchmarkError('repetición no determinista')
                previous[key] = state
                rows.append(report_row(plan, state, iteration))
    validate_report(rows, repetitions)
    report = dict(schema=1, run_id=str(uuid.uuid4()), l2='MODEL', repetitions=repetitions,
                  counter_interface='solo EXEC_STATS; K1/IPC/L2 no exportados por esta API',
                  rows=rows, addresses={p.name:p.addresses for p in plans})
    with (output/'summary.csv').open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(rows)
    (output/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    return report


def main(argv: list[str] | None = None) -> int:
    """CLI: ejecuta matriz externa y muestra flancos, sin estimaciones de pared.

    argv opcional facilita pruebas; salida 0 solo tras comparar todas las parejas.
    argparse conserva código 2 para sintaxis; errores de OS/formato/RTL/contrato
    retornan 1 con diagnóstico. No elimina ni sobrescribe evidencia anterior.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='directorio externo NUEVO')
    parser.add_argument('--repeat', type=int, default=1, help='rondas independientes (1..10)')
    args = parser.parse_args(argv)
    try:
        report = run_benchmarks(args.output, repetitions=args.repeat)
    except (OSError, ValueError, KeyError, BenchmarkError, runner.SimulationError) as exc:
        print(f'[FAIL] {exc}', file=sys.stderr)
        return 1
    for row in report['rows']:
        print(f"[PASS] {row['benchmark']} modo={row['mode']} accesos={row['accesses']} "
              f"A={row['advances']} E={row['execution_edges']} S={row['stalls']} F={row['maintenance_edges']}")
    print(f'Evidencia: {args.output.resolve()}; L2=MODEL, sin comparación de políticas del #30')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
