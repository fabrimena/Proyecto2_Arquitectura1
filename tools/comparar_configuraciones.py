#!/usr/bin/env python3
"""Compara políticas reales con imágenes, oráculos y ventanas constantes (#30).

Entradas: benchmarks #29 y parámetros admitidos por run_program. Salidas: una
carpeta externa nueva con ejecuciones independientes, CSV, JSON y Markdown.
Requiere Icarus/Python. No modifica cachés, Git ni fuentes; conserva evidencia
parcial ante error. La repetición acredita determinismo, no significancia.
No simula una L2 bloqueante mediante MODEL: esa dimensión necesita otra versión
real y reproducible, y queda identificada por separado en el informe.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
from pathlib import Path
import sys

if __package__:
    from . import run_memory_benchmarks as b
    from .perf_report import configuration, ratio
else:
    import run_memory_benchmarks as b
    from perf_report import configuration, ratio

# Cada contraste declara referencia y campos modificados. WT/NWA es una política
# compuesta bajo NINE; no se mezcla con exclusiva, combinación prohibida por RTL.
CASES = dict(exclusiva={}, nine={'INCL_POLICY':1},
    wt_nwa={'INCL_POLICY':1,'WRITE_POLICY':0,'ALLOC_POLICY':0},
    fifo={'L1_REPL_POLICY':1}, random_l1={'L1_REPL_POLICY':2},
    random_l2={'L2_REPL_POLICY':1}, mshr1={'N_MSHR':1}, mshr4={'N_MSHR':4},
    div2={'MEM_DIV':2})
PAIRS = [('exclusiva','nine',{'INCL_POLICY'}),('nine','wt_nwa',{'WRITE_POLICY','ALLOC_POLICY'}),
    ('exclusiva','fifo',{'L1_REPL_POLICY'}),('exclusiva','random_l1',{'L1_REPL_POLICY'}),
    ('exclusiva','random_l2',{'L2_REPL_POLICY'}),('exclusiva','mshr1',{'N_MSHR'}),
    ('exclusiva','mshr4',{'N_MSHR'}),('exclusiva','div2',{'MEM_DIV'})]


def validate_pair(a, c, allowed):
    """Exige igualdad de programa/entrada/corte y una sola dimensión declarada.

    Recibe metadatos ya cotejados contra logs/dumps por read_capture. No lee ni
    escribe; BenchmarkError localiza mezcla de configuraciones o poblaciones.
    Una ventana pausada no es comparable con una totalmente activa.
    """
    for key in ('image_sha256','initial_memory_sha256','cut'):
        if a[key]!=c[key]:
            raise b.BenchmarkError('comparación incompatible: '+key)
    if a['stats']['avances']!=c['stats']['avances']:
        raise b.BenchmarkError('ventanas distintas: horizonte')
    if (a['metrics']['vliw'][0]!=a['stats']['flancos'] or
        c['metrics']['vliw'][0]!=c['stats']['flancos']):
        raise b.BenchmarkError('ventanas distintas: medición pausada')
    differences={k for k in a['configuration'] if a['configuration'][k]!=c['configuration'][k]}
    if differences!=set(allowed):
        raise b.BenchmarkError('configuración incorrecta para contraste: '+str(differences))
    if a['configuration']['L2_MODEL'] or c['configuration']['L2_MODEL']:
        raise b.BenchmarkError('L2 real confundida con modelo')


def row(name, repetition, config_name, metadata, directory):
    """Aplana métricas conservando sus vectores y denominadores en el JSON.

    El CSV recibe escalares; no suma residencias de etapas ni tiempos solapados
    de niveles. service/access es servicio L1 observado, no AMAT teórico total.
    """
    m=metadata['metrics']; v=m['vliw']; l1=m['l1']; l2=m['l2']; ram=m['ram']; s=metadata['stats']
    result=dict(benchmark=name,repetition=repetition,configuration=config_name,
        cycles=v[0],bundles=v[1],instructions=v[2],ipc=m['ipc'],cpi=m['cpi'],
        stalls=v[3],branch_penalty=v[4],maintenance=s['flush'],
        l1_reads=l1[0]+l1[1],l1_writes=l1[2]+l1[3],l1_hits=l1[0]+l1[2],l1_misses=l1[1]+l1[3],
        l1_hit_rate=m['l1_hit_rate'],l1_miss_rate=m['l1_miss_rate'],
        l2_reads=l2[0]+l2[1],l2_writes=l2[2]+l2[3],l2_hits=l2[0]+l2[2],l2_misses=l2[1]+l2[3],
        l2_hit_rate=m['l2_hit_rate'],l2_miss_rate=m['l2_miss_rate'],
        mshr_alloc=l1[14],mshr_merge=l1[15],mshr_load=l1[16],hit_under_miss=l1[17],mshr_full=l1[18],
        completed_l1=m['k1b'][0],service_l1=m['k1b'][1],wait_l1=m['k1b'][2],
        observed_service_l1=m['l1_observed_service'],ram_reads=ram[0],ram_writes=ram[1],
        ram_busy=ram[2],ram_measured=ram[3],ram_utilization=m['ram_utilization'],
        l2_write_offer_cycles=l2[9], image_sha256=metadata['image_sha256'],
        architecture='PASS: 32 GPR y 16384 palabras contrastados con oráculo',directory=str(directory))
    for k,stage in enumerate(m['stages']):
        for label,value in zip(('occupied','bubbles','stalls','stalled_occupied'),stage):
            result[f'stage{k}_{label}']=value
    return result


def validate_rows(rows, repetitions):
    """Rechaza cohortes incompletas, duplicadas y contadores imposibles antes de publicar."""
    keys=[(r['benchmark'],r['repetition'],r['configuration']) for r in rows]
    expected={(n,i,c) for n in b.NAMES for i in range(1,repetitions+1) for c in CASES}
    if len(keys)!=len(expected) or set(keys)!=expected:
        raise b.BenchmarkError('reporte duplicado o incompleto')
    for r in rows:
        if r['cycles']!=872+r['stalls'] or r['bundles']>r['cycles'] or r['instructions']>4*r['bundles']:
            raise b.BenchmarkError('contadores incompatibles en reporte')
        if r['maintenance']<=0 or r['ram_busy']>r['ram_measured']:
            raise b.BenchmarkError('mantenimiento/tiempos incoherentes')


def run(output, repetitions=2, blocking_report=None):
    """Ejecuta nueve configuraciones por tres fuentes; cada ronda elabora de nuevo.

    El destino debe ser externo e inexistente. Las capturas se contrastan contra
    gold anterior al hardware y entre repeticiones. Publica resúmenes solo tras
    validar toda la matriz y ocho contrastes de una dimensión por benchmark.
    """
    output=Path(output).resolve()
    if output==b.ROOT or b.ROOT in output.parents or output.exists():
        raise b.BenchmarkError('destino externo NUEVO requerido')
    if type(repetitions) is not int or not 1<=repetitions<=10:
        raise b.BenchmarkError('repeticiones requiere entero 1..10')
    output.mkdir(parents=True)
    rows=[]; metas={}; old={}
    for n in b.NAMES:
        plan=b.prepare_oracle(n)
        frozen=output/(n+'.asm'); frozen.write_bytes(plan.source.read_bytes())
        plan=b.replace(plan,source=frozen)
        for i in range(1,repetitions+1):
            for c,values in CASES.items():
                directory=output/f'{n}-{i}-{c}'
                state=b.execute_mode(plan,directory,2,values)
                md=json.loads((directory/'execution.json').read_text())
                if md['metrics']['k1b'][4] or md['metrics']['k1b'][5]:
                    raise b.BenchmarkError('protocolo L1 incompleto en corte')
                # La evidencia conserva el estado completo; el hash no sustituye
                # las comparaciones de cada palabra y registro del lector previo.
                repeat_key=(n,c)
                signature=(state.registers,state.memory,state.stats,md['metrics'])
                if repeat_key in old and old[repeat_key]!=signature:
                    raise b.BenchmarkError('repetición no determinista')
                old[repeat_key]=signature
                metas[n,i,c]=md
                rows.append(row(n,i,c,md,directory))
                print(f'[PASS] {n} ronda={i} {c}: E={state.stats["flancos"]}',flush=True)
    contrasts=[]
    for n in b.NAMES:
        for ref,variant,fields in PAIRS:
            for i in range(1,repetitions+1):
                a,c=metas[n,i,ref],metas[n,i,variant]
                validate_pair(a,c,fields)
                contrasts.append(dict(benchmark=n,repetition=i,reference=ref,variant=variant,
                    fields=sorted(fields),cycles_change_percent=100*(c['metrics']['vliw'][0]/a['metrics']['vliw'][0]-1)))
    validate_rows(rows,repetitions)
    report=dict(schema=1,configurations={k:configuration(v) for k,v in CASES.items()},
        repetitions=repetitions,rows=rows,contrasts=contrasts,
        blocking_reference='NO EJECUTADA en esta invocación; MODEL no es bloqueante.')
    if blocking_report is not None:
        report['pipeline_contrasts']=blocking_contrasts(report,Path(blocking_report))
        report['blocking_reference']='REAL histórica contrastada; solo difiere rtl-p2/l2_cache.sv'
    (output/'comparaciones.json').write_text(json.dumps(report,indent=2)+'\n')
    with (output/'comparaciones.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    lines=['| Programa | Configuración | Ciclos | IPC | L1 hit/miss | L2 hit/miss | RAM R/W | Flush |',
           '|---|---|---:|---:|---:|---:|---:|---:|']
    for r in rows:
        if r['repetition']==1:
            lines.append(f'| {r["benchmark"]} | {r["configuration"]} | {r["cycles"]} | {r["ipc"]:.6f} | {r["l1_hits"]}/{r["l1_misses"]} | {r["l2_hits"]}/{r["l2_misses"]} | {r["ram_reads"]}/{r["ram_writes"]} | {r["maintenance"]} |')
    (output/'comparaciones.md').write_text('\n'.join(lines)+'\n')
    return report


def blocking_contrasts(report, historical):
    """Contrasta la L2 bloqueante histórica usando capturas reales acreditadas.

    La referencia es un summary.json de run_memory_benchmarks, no un número
    escrito manualmente. Relee gold/traza/binario y exige que todos los RTL sean
    idénticos salvo l2_cache.sv; así un proveedor MODEL o un núcleo diferente no
    pueden presentarse como segmentación de L2. No modifica ninguna captura.
    """
    old=json.loads(Path(historical).read_text())
    if old.get('l2')!='REAL' or old.get('repetitions')!=report['repetitions']:
        raise b.BenchmarkError('referencia bloqueante no es L2 REAL o faltan rondas')
    b.validate_report(old['rows'],old['repetitions'])
    rows=[]
    for current in report['rows']:
        if current['configuration']!='exclusiva':continue
        matched=[x for x in old['rows'] if x['benchmark']==current['benchmark'] and
                 x['repetition']==current['repetition'] and x['mode']==2]
        if len(matched)!=1:raise b.BenchmarkError('referencia bloqueante duplicada o ausente')
        directory=Path(matched[0]['directory']);plan=b.prepare_oracle(current['benchmark'])
        b.read_capture(directory,2,plan)
        b.read_capture(Path(current['directory']),2,plan)
        a=json.loads((directory/'execution.json').read_text())
        c=json.loads((Path(current['directory'])/'execution.json').read_text())
        validate_pair(a,c,set())
        if set(a['rtl_sha256'])!=set(c['rtl_sha256']):
            raise b.BenchmarkError('inventario RTL histórico incompatible')
        differences={k for k in a['rtl_sha256'] if a['rtl_sha256'][k]!=c['rtl_sha256'][k]}
        if differences!={'rtl-p2/l2_cache.sv'}:
            raise b.BenchmarkError('comparación bloqueante cambia otros productores: '+str(differences))
        rows.append(dict(benchmark=current['benchmark'],repetition=current['repetition'],
            blocking_cycles=a['stats']['flancos'],pipeline_cycles=c['stats']['flancos'],
            blocking_l2_sha256=a['rtl_sha256']['rtl-p2/l2_cache.sv'],
            pipeline_l2_sha256=c['rtl_sha256']['rtl-p2/l2_cache.sv'],
            cycles_change_percent=100*(c['stats']['flancos']/a['stats']['flancos']-1),
            historical_directory=str(directory)))
    return rows


def capacity(output):
    """Mide una segunda pasada de 576 líneas del archivo intacto de 18 KiB.

    Primera pasada con medir 0 calienta la jerarquía; la segunda acumula checksum
    con medir 1. Misma precarga byte a byte y horizonte lógico para NINE/exclusiva.
    El resultado demuestra comportamiento observado, no una capacidad asociativa
    ideal: las colisiones por conjunto y el reemplazo también influyen.
    """
    output=Path(output).resolve()
    if output==b.ROOT or b.ROOT in output.parents or output.exists():
        raise b.BenchmarkError('destino externo NUEVO requerido')
    output.mkdir(parents=True)
    content=(b.ROOT/'examples/archivos/archivo18k.bin').read_bytes()
    if len(content)!=18432 or hashlib.sha256(content).hexdigest()!=b.FILE_SHA256:
        raise b.BenchmarkError('archivo18k alterado')
    raw=bytearray(65536);raw[512:512+len(content)]=content
    words=[int.from_bytes(raw[k:k+4],'little') for k in range(0,65536,4)]
    initial=output/'inicial.mem';initial.write_text(''.join(f'{v:08x}\n' for v in words))
    lines=['nop | medir 0 | nop | nop','sumai x21,x0,37 | nop | nop | nop','nop','nop',
           'cizqi x21,x21,9 | nop | nop | nop','nop','nop']
    for phase in ('warm','measure'):
        lines+=['sumai x20,x0,512 | nop | nop | nop','sumai x6,x0,0 | nop | nop | nop','nop','nop']
        if phase=='measure':lines+=['nop | medir 1 | nop | nop']
        lines += [f'{phase}: nop | cargai x5,x20,0 | nop | nop','sumai x20,x20,32 | nop | nop | nop','nop','nop',
                  f'suma x6,x6,x5 | nop | menora x20,x21,{phase} | nop']
    lines+=['nop | medir 0 | nop | nop','sumai x7,x0,1 | nop | nop | nop',
            'nop','nop','fin: nop | nop | sye x0,fin | nop']
    source=output/'capacidad18k.asm';source.write_text('\n'.join(lines)+'\n')
    program=b.assemble_source(source.read_text()); horizon=len(program.bundles)+4+2*575*7
    expected={r:0 for r in range(32)}
    expected.update({5:words[(512+575*32)//4],6:sum(words[(512+k*32)//4] for k in range(576))&0xffffffff,
                     7:1,20:18944,21:18944})
    rows=[];previous={}
    for i in (1,2):
        for name,cfg in [('exclusiva',{}),('nine',{'INCL_POLICY':1})]:
            directory=output/f'{name}-{i}'
            regs=b.runner.run_program(source,directory,expected,False,{4*k:v for k,v in enumerate(words)},
                horizon,False,2,cfg,initial,300,True)
            # El oráculo compara cada dirección en bytes, incluso regiones sin
            # demandas. La relectura contrasta también el dump completo posterior.
            actual=tuple(int(s,16) for s in (directory/'memory.txt').read_text().splitlines())
            if tuple(regs[r] for r in range(32))!=tuple(expected[r] for r in range(32)) or actual!=tuple(words):
                raise b.BenchmarkError('oráculo capacidad: GPR/DMEM completo')
            md=json.loads((directory/'execution.json').read_text())
            if name in previous and previous[name]!=md['metrics']:
                raise b.BenchmarkError('capacidad no determinista')
            previous[name]=md['metrics']
            rows.append(row('capacidad18k',i,name,md,directory))
    report=dict(schema=1,file_sha256=b.FILE_SHA256,logical_lines_per_pass=576,
                passes=2,horizon=horizon,window='solo segunda pasada, medir 1 hasta medir 0',rows=rows)
    (output/'capacidad.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


def main(argv=None):
    """CLI con código 0 tras matriz válida; 1 conserva diagnóstico y evidencia parcial."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--repeat',type=int,default=2)
    parser.add_argument('--capacity',action='store_true',help='dos pasadas del archivo18k; salida capacidad.json')
    parser.add_argument('--blocking-report',type=Path,help='summary.json histórico de L2 real bloqueante')
    args=parser.parse_args(argv)
    try:
        capacity(args.output) if args.capacity else run(args.output,args.repeat,args.blocking_report)
    except (OSError,ValueError,b.BenchmarkError,b.runner.SimulationError) as exc:
        print('[FAIL] '+str(exc),file=sys.stderr);return 1
    return 0

if __name__=='__main__':
    raise SystemExit(main())
