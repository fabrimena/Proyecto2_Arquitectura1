#!/usr/bin/env python3
"""Deriva medias observadas de capturas existentes, sin ejecutar ni cambiar RTL.

Entrada: comparaciones.json con filas que remiten a execution.json y sus logs,
imágenes y binarios. Requiere Python y las herramientas del proyecto. Salida:
JSON/CSV en un directorio externo nuevo; nunca reescribe la evidencia original.
Las cohortes K1-B contienen solo demandas completas dentro de la habilitación.
La media incluye espera y finalización en el puerto L1, no persistencia RAM.
La extensión temporal 1 acredita lecturas L2 y transacciones RAM completas.
Los logs históricos carecen de esos tiempos y conservan None. No se suman
niveles solapados ni se sustituyen tiempos por constantes nominales.
ValueError/SimulationError rechazan datos incompatibles; OSError conserva fallos
de archivos. El análisis exige una época sin desbordamiento de contadores.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import sys

if __package__:
    from . import run_program as runner
else:
    import run_program as runner


def l1_amat(metrics, wire_layout=False):
    """Calcula medias de la misma cohorte, sin mezclar los eventos K1-A.

    Recibe vectores K1-B (count/service/wait por RH,RM,WH,WM), total de ciclos
    y diagnósticos. Devuelve accesos, tiempos, tasas y AMAT por lectura/escritura
    y conjunto. Cada duración incluye su flanco final: un acceso sin espera vale
    un ciclo. Rechaza errores de protocolo, identidades rotas y aritmética que
    requiera wrap; una población vacía produce None. No modifica metrics.
    wire_layout=True interpreta el puerto real: últimos campos exclusiones,
    errores y pendiente. False conserva la API histórica de fixtures (no-wait,
    exclusiones, errores); nunca se aplica ese layout a logs RTL en analyze.
    """
    classes = metrics['classes']
    total = metrics['k1b']
    measured = metrics['vliw'][0]
    if (not isinstance(classes, list) or len(classes) != 4 or
            any(not isinstance(c, list) or len(c) != 3 for c in classes) or
            not isinstance(total, list) or len(total) != 6):
        raise ValueError('forma K1-B inválida')
    values = [measured, *total, *(v for c in classes for v in c)]
    if any(type(v) is not int or not 0 <= v < 1 << 64 for v in values):
        raise ValueError('contador K1-B fuera de contrato')
    if total[4 if wire_layout else 5]:
        raise ValueError('protocolo K1-B con errores')
    if (any(c[1] != c[0] + c[2] or (not c[0] and c[1]) for c in classes) or
            any(sum(c[k] for c in classes) != total[k] for k in range(3)) or
            total[1] > measured or
            (total[5] > 1 if wire_layout else total[3] > total[0])):
        raise ValueError('cohorte K1-B incompatible o desbordada')

    def population(hit, miss):
        """Pondera hits/misses de una sola población; no usa tiempos de otro nivel."""
        nh, sh, wh = hit
        nm, sm, wm = miss
        count = nh + nm
        return dict(accesses=count, hits=nh, misses=nm,
                    service_cycles=sh + sm, wait_cycles=wh + wm,
                    hit_rate=nh / count if count else None,
                    miss_rate=nm / count if count else None,
                    hit_mean_cycles=sh / nh if nh else None,
                    miss_mean_cycles=sm / nm if nm else None,
                    # ΣT/N equivale a HR×E[T|hit]+MR×E[T|miss]. Se suma
                    # servicio de accesos, nunca busy global de niveles solapados.
                    amat_cycles=(sh + sm) / count if count else None)

    hits = [classes[0][k] + classes[2][k] for k in range(3)]
    misses = [classes[1][k] + classes[3][k] for k in range(3)]
    return dict(all=population(hits, misses),
                reads=population(classes[0], classes[1]),
                writes=population(classes[2], classes[3]),
                excluded_completions=total[3 if wire_layout else 4],
                pending=total[5] if wire_layout else None,
                population='K1-B: demandas completas, íntegramente habilitadas',
                unit='ciclos clk; espera más flanco de finalización',
                store_completion='aceptación del puerto L1; no persistencia RAM')


def read_capture(directory, row):
    """Relee testimonio y hashes antes de derivar; no recertifica el oráculo CPU.

    La arquitectura ya fue validada por el runner de benchmarks. Aquí se exige
    configuración/ventana y métricas idénticas entre log y metadatos, imagen y
    binario intactos y la misma fila del informe. Se evita aceptar otro ensayo
    como fuente del AMAT sin alterar el formato de los reportes anteriores.
    """
    directory = Path(directory)
    path = directory / 'execution.json'
    metadata = json.loads(path.read_text())
    if not isinstance(metadata, dict) or metadata.get('validation') != 'PASS':
        raise ValueError('captura sin validación anterior')
    stats = metadata['stats']
    parsed = runner.execution_metadata(
        (directory / 'sim.log').read_text(), metadata['effective_mode'],
        stats['bundles'], stats['avances'], metadata['configuration'])
    if parsed['metrics'] != metadata['metrics'] or parsed['stats'] != stats:
        raise ValueError('log y captura incompatibles')
    for filename, field in [('program.mem', 'image_sha256'), ('sim.vvp', 'binary_sha256')]:
        if hashlib.sha256((directory / filename).read_bytes()).hexdigest() != metadata[field]:
            raise ValueError('hash de captura incompatible: ' + filename)
    if (row['cycles'] != metadata['metrics']['vliw'][0] or
            row['image_sha256'] != metadata['image_sha256']):
        raise ValueError('fila y captura incompatibles')
    return metadata, hashlib.sha256(path.read_bytes()).hexdigest()


def analyze(report_path, output):
    """Publica un derivado nuevo, dejando byte a byte intactas las ejecuciones.

    Cada fila conserva programa/configuración/ronda y ventana de su captura.
    No agrega rondas ni poblaciones diferentes. Un fallo conserva diagnósticos
    y no publica un resumen como si hubiera concluido satisfactoriamente.
    """
    report_path, output = Path(report_path).resolve(), Path(output).resolve()
    if output.exists() or output == runner.ROOT or runner.ROOT in output.parents:
        raise ValueError('destino externo NUEVO requerido')
    report = json.loads(report_path.read_text())
    if not isinstance(report, dict) or not isinstance(report.get('rows'), list) or not report['rows']:
        raise ValueError('filas ausentes')
    rows, keys = [], set()
    for row in report['rows']:
        key = row['benchmark'], row['configuration'], row['repetition']
        if key in keys:
            raise ValueError('fila duplicada')
        keys.add(key)
        md, digest = read_capture(row['directory'], row)
        temporal = md['metrics'].get('temporal')
        rows.append(dict(benchmark=key[0], configuration=key[1], repetition=key[2],
                         l1=l1_amat(md['metrics'], wire_layout=True), directory=row['directory'],
                         l1_available=md['effective_mode'] == 2 and bool(md['configuration']['PERF_ENABLE']),
                         execution_sha256=digest, cycles_measured=md['metrics']['vliw'][0],
                         # Las primeras capturas no registraban el control de
                         # ventana. Conservar ausencia evita inventar su armado;
                         # numeradores/denominadores siguen viniendo de su log.
                         cut=md['cut'], measurement_control=md.get('measurement_control'),
                         temporal=temporal,
                         l2_amat_cycles=temporal['l2']['amat_cycles'] if temporal else None,
                         ram_amat_cycles=temporal['ram']['mean_cycles'] if temporal else None,
                         hierarchical_amat_cycles=None))
    measured = all(r['temporal'] and r['temporal']['available'] for r in rows)
    result = dict(schema=2, issue26_status='MEDICIÓN OBSERVABLE COMPLETA' if measured else 'PARCIAL',
                  source_report=str(report_path),
                  source_sha256=hashlib.sha256(report_path.read_bytes()).hexdigest(),
                  limitation=('Lecturas L2 y éxitos RAM por cohorte; L2 posted sin respuesta de escritura. '
                              'RAM no tiene hits/misses. No se suman latencias jerárquicas solapadas. '
                              'Una captura histórica sin extensión temporal conserva medias L2/RAM null.'),
                  rows=rows)
    output.mkdir(parents=True)
    (output / 'amat.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    with (output / 'amat.csv').open('w', newline='') as file:
        writer = csv.writer(file)
        writer.writerow(['benchmark', 'configuration', 'repetition', 'l1_accesses',
                         'l1_amat_cycles', 'l1_read_amat_cycles', 'l1_write_amat_cycles',
                         'l2_amat_cycles', 'ram_amat_cycles', 'hierarchical_amat_cycles'])
        for row in rows:
            writer.writerow([row['benchmark'], row['configuration'], row['repetition'],
                             row['l1']['all']['accesses'],
                             *(row['l1'][p]['amat_cycles'] for p in ('all', 'reads', 'writes')),
                             row['l2_amat_cycles'], row['ram_amat_cycles'], None])
    return result


def main(argv=None):
    """CLI: devuelve 0 tras publicar el derivado o 1 ante datos/rutas inválidos."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = analyze(args.report, args.output)
    except (OSError, ValueError, KeyError, TypeError, runner.SimulationError) as exc:
        print('[FAIL] ' + str(exc), file=sys.stderr)
        return 1
    print(f'[PASS] {len(result["rows"])} cohortes; {result["issue26_status"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
