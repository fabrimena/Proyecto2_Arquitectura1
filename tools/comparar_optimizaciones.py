#!/usr/bin/env python3
"""Compara variantes reales de CE1108, sin inventar niveles -O (#31).

Entrada: manifiesto JSON con compiler_root/commit, programas BAL, variantes con
level/argv/cut_advances y observables DMEM semánticos. argv usa placeholders
{compiler}, {source}, {binary}; nunca shell. balc debe generar source.asm/.mem.
Salida externa nueva: fuentes, comandos, ASM, imágenes, M2 independiente, RTL,
CSV/JSON/Markdown. No cambia CE1108 ni su backend. Un solo nivel se valida pero
se declara PARCIAL, sin porcentajes de optimización. Cortes son observaciones
acordadas por el manifiesto; no certifican semánticamente retorno de main.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import re
import struct
if __package__:
    from . import run_program as r
    from . import ce1108_dce
    from .assembler import assemble_source
    from .comparar_configuraciones import row
else:
    import run_program as r
    import ce1108_dce
    from assembler import assemble_source
    from comparar_configuraciones import row


def sha(path):
    """Hash de bytes para procedencia; nunca sustituye un oráculo funcional."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate_variants(variants):
    """Rechaza nombres duplicados o copias del mismo ASM presentadas como niveles."""
    if not variants or len({v['level'] for v in variants})!=len(variants):
        raise r.SimulationError('niveles ausentes o duplicados')
    if len({v['image_sha256'] for v in variants})!=len(variants):
        raise r.SimulationError('imágenes idénticas no son niveles distintos')
    if len({v['observations_sha256'] for v in variants})!=1:
        raise r.SimulationError('observables semánticos distintos')


def run(manifest_path, output):
    """Compila cada variante de nuevo, contrasta contra M2 y verifica el RTL.

    Los GPR pueden cambiar entre niveles; cada variante se verifica COMPLETA
    contra M2 y todas deben cumplir el mismo oráculo DMEM semántico previo. Los
    ciclos son hasta su propio corte declarado. El manifiesto debe justificar
    cortes equivalentes antes de interpretar porcentajes como speedup de main.
    """
    manifest_path=Path(manifest_path).resolve();output=Path(output).resolve()
    manifest=json.loads(manifest_path.read_text());root=Path(manifest['compiler_root']).resolve()
    if output.exists() or output==r.ROOT or r.ROOT in output.parents or root==output or root in output.parents:
        raise r.SimulationError('destino externo NUEVO requerido')
    if not manifest.get('programs'):
        raise r.SimulationError('programas ausentes')
    actual=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
    if actual!=manifest['compiler_commit']:
        raise r.SimulationError('commit de compilador distinto del manifiesto')
    # Se compila el observador con los módulos públicos actuales, siempre fuera
    # de CE1108. El productor M2 conserva su implementación y no se reinterpreta.
    modules=sorted((root/'src/Simulador_VLIW').glob('*.c'))
    if not modules:modules=sorted(root.glob('src/sim_*.c'))
    if not modules:raise r.SimulationError('módulos M2 no disponibles')
    output.mkdir(parents=True)
    (output/'manifest.json').write_bytes(manifest_path.read_bytes())
    # El productor opcional pertenece al IDE real: no se modifica balc ni se
    # interpreta --dce como si emitiera ASM. Su adaptador solo llama la API pública.
    transformed=any(v.get('transform')=='ide-dce' for p in manifest['programs'] for v in p['variants'])
    dce_binary=dce_identity=None
    if transformed:dce_binary,dce_identity=ce1108_dce.build(root,output)
    observer=output/'observar_m2'
    cc=[r.tool('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-I',str(root/'include'),
        str(r.ROOT/'tools/ce1108_observar_m2.c'),*[str(p) for p in modules],'-o',str(observer)]
    r.run_logged(cc,output,output/'observer-build.log',60)
    rows=[];details=[];partial=False
    for program in manifest['programs']:
        name=program['name'];source=Path(program['source']).resolve()
        observations=program.get('semantic_observations',program.get('observations'))
        if not re.fullmatch(r'[a-zA-Z0-9_-]+',name):
            raise r.SimulationError('nombre de programa inválido')
        if not observations:raise r.SimulationError('oráculo semántico vacío')
        if not isinstance(observations,dict) or any(type(v) is not int or not 0<=v<1<<32 for v in observations.values()):
            raise r.SimulationError('valores semánticos inválidos')
        variants=[]
        for i,variant in enumerate(program['variants']):
            work=output/f'{name}-{i}';work.mkdir()
            snapshot=work/'source.bal'
            transformation=None
            if variant.get('transform') not in (None,'ide-dce'):
                raise r.SimulationError('transformación desconocida')
            if variant.get('transform')=='ide-dce':
                original=work/'original.bal';original.write_bytes(source.read_bytes())
                transformation=ce1108_dce.apply(dce_binary,original,snapshot,work)
            else:snapshot.write_bytes(source.read_bytes())
            binary=work/'program.bin';asm=work/'source.asm'
            variables=dict(compiler=str(root/'balc'),source=str(snapshot),binary=str(binary))
            argv=variant['argv']
            if not isinstance(argv,list) or not argv or any(not isinstance(v,str) for v in argv):
                raise r.SimulationError('argv de compilación inválido')
            command=[v.format(**variables) for v in argv]
            if Path(command[0]).resolve()!=root/'balc':
                raise r.SimulationError('productor distinto de balc acreditado')
            r.run_logged(command,work,work/'compiler.log',60)
            if not asm.is_file() or not binary.is_file():
                raise r.SimulationError('variante no produce ASM/binario real')
            image=work/'program.mem'
            assembled=assemble_source(asm.read_text())
            if [int(s,16) for s in image.read_text().splitlines()]!=[int(s,16) for s in assembled.memory_text().splitlines()]:
                raise r.SimulationError('ASM e imagen del compilador distintos')
            # MEM no transporta la sección inicial DMEM de BALB. Esta versión
            # acredita solo imágenes sin datos iniciales; rechazarlas es preferible
            # a ejecutar una inicialización diferente de la emitida por balc.
            payload=binary.read_bytes()
            if len(payload)<48 or payload[:4]!=b'BALB':
                raise r.SimulationError('contenedor BALB inválido')
            fields=struct.unpack('<11I',payload[4:48])
            if fields[8] or fields[3] or fields[6]:
                raise r.SimulationError('BALB requiere datos iniciales/entrada no soportados por este comparador')
            if (fields[:3]!=(1,48,len(payload)) or fields[4]!=48 or
                fields[5]!=len(assembled.binary()) or payload[48:]!=assembled.binary()):
                raise r.SimulationError('BALB y ensamblado no coinciden')
            horizon=variant['cut_advances']
            if type(horizon) is not int or not len(assembled.bundles)+4<=horizon<=100000:
                raise r.SimulationError('corte fuera de contrato')
            observer_out=r.run_logged([str(observer),str(image),str(horizon),str(work/'m2.dmem')],
                work,work/'m2.json',60)
            gold=json.loads(observer_out);raw=(work/'m2.dmem').read_bytes()
            if len(raw)!=65536 or len(gold['registers'])!=32 or gold['traps']:
                raise r.SimulationError('referencia M2 incompleta o con excepción')
            expected={k:int.from_bytes(raw[k:k+4],'little') for k in range(0,65536,4)}
            # Los temporales y el marco pueden cambiar entre variantes. Los
            # observables nombrados conservan significado/valor, pero su dirección
            # se acredita por variante; cada estado completo se coteja contra M2.
            for observable,value in observations.items():
                address=variant.get('observation_addresses',{}).get(observable,observable)
                if not isinstance(address,str) or not re.fullmatch(r'(?:0x[0-9a-fA-F]+|[0-9]+)',address):
                    raise r.SimulationError('dirección semántica ausente o inválida: '+observable)
                numeric=int(address,0)
                if numeric%4 or not 0<=numeric<=65532 or expected[numeric]!=value:
                    raise r.SimulationError('oráculo semántico incorrecto: '+observable)
            states=[]
            for mode in (0,2):
                directory=work/f'mode-{mode}'
                r.run_program(asm,directory,dict(enumerate(gold['registers'])),False,expected,horizon,False,mode)
                md=json.loads((directory/'execution.json').read_text());states.append(md)
                if not md.get('architecture_state') or md['architecture_state']['crypto']!=gold['crypto'] or md['architecture_state']['traps']:
                    raise r.SimulationError('estado criptográfico o excepciones distintos de M2')
                summary=row(name,1,variant['level']+f'-mode{mode}',md,directory)
                # Medias de servicio por cohorte, sin reemplazar los accesos de
                # clasificación/aceptación anteriores. En modo0 quedan N/D.
                temporal=md['metrics'].get('temporal')
                summary.update(l2_read_amat_cycles=temporal['l2']['amat_cycles'] if temporal else None,
                    l2_completed_reads=temporal['l2']['accesses'] if temporal else None,
                    ram_mean_cycles=temporal['ram']['mean_cycles'] if temporal else None,
                    ram_completed_transactions=temporal['ram']['accesses'] if temporal else None,
                    temporal_available=temporal['available'] if temporal else False)
                rows.append(summary)
            record=dict(level=variant['level'],compiler_commit=actual,compiler_sha256=sha(root/'balc'),
                compiler_command=command,observer_command=cc,
                compiler_worktree_status=subprocess.check_output(['git','-C',str(root),'status','--porcelain'],text=True),
                compiler_modules_sha256={str(p.relative_to(root)):sha(p) for p in modules},source_sha256=sha(snapshot),asm_sha256=sha(asm),binary_sha256=sha(binary),
                image_sha256=sha(image),bundles_static=len(assembled.bundles),
                original_source_sha256=sha(source),transformation=transformation,
                transform_producer=dce_identity if transformation else None,
                observation_addresses=variant.get('observation_addresses'),
                instructions_static=sum(ins.text.lower()!='nop' for b in assembled.bundles for ins in b.instructions),
                observations_sha256=hashlib.sha256(json.dumps(observations,sort_keys=True).encode()).hexdigest(),
                horizon=horizon,cut_contract=variant.get('cut_contract','declarado; no certificado semánticamente'),
                metrics=states[1]['metrics'],directory=str(work))
            variants.append(record)
            print(f'[PASS] {name} {variant["level"]}: M2 completo y RTL modos 0/2',flush=True)
        validate_variants(variants)
        partial|=len(variants)<2
        for v in variants:
            v['cycle_change_percent']=(100*(v['metrics']['vliw'][0]/variants[0]['metrics']['vliw'][0]-1)
                if len(variants)>1 else None)
        details.append(dict(program=name,variants=variants))
    report=dict(status='PARCIAL: un solo nivel real' if partial else 'COMPARACIÓN DE VARIANTES VALIDADA',
        compiler_commit=actual,programs=details,rows=rows,
        limitations='Porcentajes hasta cortes declarados; no certifican retorno semántico de main ni niveles -O inexistentes.')
    (output/'optimizaciones.json').write_text(json.dumps(report,indent=2)+'\n')
    with (output/'optimizaciones.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    lines=['| Programa | Variante/modo | Ciclos | IPC |','|---|---|---:|---:|']
    lines += [f'| {x["benchmark"]} | {x["configuration"]} | {x["cycles"]} | {x["ipc"]:.6f} |' for x in rows]
    (output/'optimizaciones.md').write_text(report['status']+'\n\n'+'\n'.join(lines)+'\n')
    return report


def baseline_manifest(root):
    """Prepara las tres referencias reales B5, sin escribir dentro de CE1108.

    Los cortes pertenecen a la generación tradicional documentada en B5; M2 y
    RTL deben coincidir al mismo avance. No se reutilizan para otro optimizador.
    Los observables se calculan por la semántica BAL: factorial(5)=120,
    whale=10+10+1 y puntajes=(2+3+5+6+8)+(2+3+5+1+2)=37.
    """
    root=Path(root).resolve()
    commit=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
    specs=[('factorial','factorial',3403,{'0xfff8':120}),
           ('whale','whale',247,{'0xfffc':21}),
           ('puntajes','ejercicio3_puntajes',2748,{'0xfff0':24,'0xfff4':0,'0xfff8':13,'0xfffc':37})]
    programs=[]
    for name,file,cut,observations in specs:
        programs.append(dict(name=name,source=str(root/f'examples/{file}.bal'),observations=observations,
            variants=[dict(level='tradicional',argv=['{compiler}','-s','-o','{binary}','{source}'],
                cut_advances=cut,cut_contract='B5: observación tras retorno retirado; no certifica main')]))
    return dict(compiler_root=str(root),compiler_commit=commit,programs=programs)


def main(argv=None):
    """CLI: 0 significa variantes comprobadas; PARCIAL permanece explícito en JSON.

    --compiler-root prepara la única variante tradicional acreditada; --manifest
    incorpora niveles nuevos con sus propios comandos/cortes/observables. El
    manifiesto temporal se copia a la evidencia antes de liberar sus recursos.
    """
    p=argparse.ArgumentParser(description=__doc__)
    group=p.add_mutually_exclusive_group(required=True)
    group.add_argument('--manifest',type=Path)
    group.add_argument('--compiler-root',type=Path)
    p.add_argument('--ide-dce',action='store_true',help='contrastes tradicional/IDE DCE con cortes B5 acreditados')
    p.add_argument('--output',type=Path,required=True);args=p.parse_args(argv)
    if args.ide_dce and not args.compiler_root:p.error('--ide-dce requiere --compiler-root')
    try:
        if args.manifest:run(args.manifest,args.output)
        else:
            with tempfile.TemporaryDirectory(prefix='ce1108-manifest-') as temporary:
                path=Path(temporary)/'manifest.json'
                prepared=ce1108_dce.comparison_manifest(args.compiler_root) if args.ide_dce else baseline_manifest(args.compiler_root)
                path.write_text(json.dumps(prepared,indent=2)+'\n')
                run(path,args.output)
    except (OSError,ValueError,KeyError,r.SimulationError,subprocess.SubprocessError) as exc:
        print('[FAIL] '+str(exc),file=sys.stderr);return 1
    return 0

if __name__=='__main__':raise SystemExit(main())
