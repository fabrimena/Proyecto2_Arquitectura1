#!/usr/bin/env python3
"""Prueba la expresión de test_generacion --ejemplo en el top real."""
import argparse
from pathlib import Path
import sys

if __package__:
    from .assembler import assemble_source
    from .bundle_linear import bundle_linear
    from .run_program import MAX_RUN_BUNDLES, ROOT, SimulationError, run_logged, tool
else:
    from assembler import assemble_source
    from bundle_linear import bundle_linear
    from run_program import MAX_RUN_BUNDLES, ROOT, SimulationError, run_logged, tool


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path, help='salida lineal de --ejemplo')
    parser.add_argument('--workdir', type=Path, default=ROOT/'build/ce1108')
    args = parser.parse_args()
    try:
        work = args.workdir.resolve()
        outputs = [work/name for name in ('program.asm', 'program.mem', 'program.lst', 'program.bin', 'sim.vvp', 'compile.log', 'sim.log')]
        if args.input.resolve() in outputs:
            raise SimulationError('la entrada no puede ser una salida de esta prueba')
        source = bundle_linear(args.input.read_text(encoding='utf-8'))
        program = assemble_source(source)
        if len(program.bundles) > MAX_RUN_BUNDLES:
            raise SimulationError(f'la prueba admite hasta {MAX_RUN_BUNDLES} bundles')
        work.mkdir(parents=True, exist_ok=True)
        asm, mem, listing, binary, executable, compile_log, sim_log = outputs
        asm.write_text(source, encoding='utf-8')
        mem.write_text(program.memory_text(), encoding='ascii')
        listing.write_text(program.listing_text(), encoding='utf-8')
        binary.write_bytes(program.binary())
        rtl = [str(p) for d in ('rtl', 'rtl-p2') for p in sorted((ROOT/d).glob('*.sv'))]
        run_logged([tool('IVERILOG', 'iverilog'), '-g2012', '-I', str(ROOT/'rtl'),
                    '-I', str(ROOT/'rtl-p2'), '-s', 'tb_ce1108_program', '-o', str(executable),
                    *rtl,
                    str(ROOT/'tests/rtl/tb_ce1108_program.sv')], ROOT, compile_log, 30)
        output = run_logged([tool('VVP', 'vvp'), '-n', str(executable),
                            f'+MEM={mem}', f'+BUNDLES={len(program.bundles)}'], work, sim_log, 10)
        if '[PASS]' not in output:
            raise SimulationError('la simulación no confirmó el resultado')
        print(output.strip())
    except (OSError, ValueError, SimulationError) as exc:
        print(f'Error: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
