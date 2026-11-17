"""Enlaza y ejecuta el productor DCE real del IDE CE1108 fuera de ambos árboles.

No transforma BAL en Python ni toca CE1108. El Makefile consultado con -Bn
aporta su lista actual de fuentes; se sustituye únicamente el main de pruebas
por el adaptador público. Todos los comandos, fuentes y hashes quedan registrados.
"""
from pathlib import Path
import hashlib
import json
import shlex
import subprocess

if __package__:
    from . import run_program as r
else:
    import run_program as r


def build(root, work):
    """Compila un adaptador en work NUEVO; root solo se lee.

    Recibe Paths resueltos del compilador y directorio externo existente. Retorna
    binario y procedencia (argv, SHA de módulos y ejecutable). Make -Bn nunca se
    ejecuta: se lee su receta de enlace sin correr flex/bison ni tests. Rechaza
    recetas ambiguas, fuentes ausentes o salida interna con SimulationError;
    errores de compilación/IO conservan sus diagnósticos originales.
    """
    root,work=Path(root).resolve(),Path(work).resolve()
    if work==root or root in work.parents or work==r.ROOT or r.ROOT in work.parents:
        raise r.SimulationError('adaptador DCE requiere destino externo')
    recipe=subprocess.check_output(['make','-Bn','tests/test_ide_dce'],cwd=root,text=True)
    candidates=[shlex.split(line) for line in recipe.splitlines()
                if 'tests/test_ide_dce.c' in line and ' -o ' in line]
    if len(candidates)!=1:raise r.SimulationError('receta DCE ambigua o ausente')
    args=candidates[0];command=[r.tool('CC','cc')];sources=[]
    for token in args[1:args.index('-o')]:
        if token=='tests/test_ide_dce.c':command.append(str(r.ROOT/'tools/ce1108_aplicar_dce.c'))
        elif token.startswith('-I'):command.append('-I'+str(root/token[2:]))
        elif token.endswith('.c'):
            source=root/token
            if not source.is_file():raise r.SimulationError('fuente DCE ausente: '+token)
            sources.append(source);command.append(str(source))
        elif token.startswith('-'):command.append(token)
        else:raise r.SimulationError('argumento inesperado en receta DCE: '+token)
    binary=work/'aplicar_dce'
    command+=['-o',str(binary)]
    r.run_logged(command,work,work/'dce-build.log',120)
    identity=dict(command=command,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  modules_sha256={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
    (work/'dce-producer.json').write_text(json.dumps(identity,indent=2)+'\n')
    return binary,identity


def apply(binary, source, destination, work):
    """Invoca ide_dce_analizar, conserva entradas y exige transformación acreditada.

    source es la copia externa, destination debe faltar y work recibe logs.
    Devuelve procedencia con hashes de entrada/salida. No borra salidas parciales.
    Rechaza copia idéntica o diagnóstico sin cambios; no inventa otro nivel.
    """
    binary,source,destination,work=map(Path,(binary,source,destination,work))
    destination=destination.resolve();work=work.resolve()
    if destination.parent!=work or work==r.ROOT or r.ROOT in work.parents:
        raise r.SimulationError('destino DCE debe pertenecer a su captura externa')
    if destination.exists():raise r.SimulationError('destino DCE reutilizado')
    command=[str(binary),str(source),str(destination)]
    output=r.run_logged(command,work,work/'dce-transform.json',60)
    result=json.loads(output)
    if (result.get('producer')!='ide_dce_analizar' or result.get('changed') is not True or
            not destination.is_file() or source.read_bytes()==destination.read_bytes()):
        raise r.SimulationError('DCE no produjo una variante distinta')
    result.update(command=command,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  transformed_sha256=hashlib.sha256(destination.read_bytes()).hexdigest())
    return result


def comparison_manifest(root):
    """Prepara los dos contrastes DCE acreditados por B5 en el snapshot actual.

    root se lee sin cambios. Devuelve manifiesto con comandos y mapas semánticos
    por variante; los cortes son observaciones tras retiro, no fin de main.
    Exige el commit CE1108 y fuentes conocidos para impedir reutilizar los cortes
    con otra generación. Otro snapshot necesita B5 nuevo y --manifest explícito;
    no se inventa un horizonte restando bundles. No ejecuta el compilador.
    """
    root=Path(root).resolve()
    commit=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
    if commit!='08c8701c7bc6e58461f54b69a90a1a6fe85d0145':
        raise r.SimulationError('cortes DCE B5 no acreditados para este commit; use --manifest con evidencia nueva')
    specs=[('puntajes','ejercicio3_puntajes.bal','063c5fca57fc3ed1685af64e56aa7ad95ef0c27d32f23709eb0109e12718019a',
            {'resultado':24,'combinado':13,'total':37},
            [(2748,None,{'resultado':'0xfff0','combinado':'0xfff8','total':'0xfffc'}),
             (2742,'ide-dce',{'resultado':'0xfff4','combinado':'0xfff8','total':'0xfffc'})]),
           ('dce_funciones','dce/dce_ensamblador.bal','9fe31fcb5aab6768b92f32ded322da85baca41901312e59e6706b9f8676b7bec',
            {'cuadrado4':16,'suma_hasta5':15},
            [(6193,None,{'cuadrado4':'0xffec','suma_hasta5':'0xfff0'}),
             (2176,'ide-dce',{'cuadrado4':'0xfff0','suma_hasta5':'0xfff4'})])]
    programs=[]
    for name,file,digest,values,variants in specs:
        source=root/'examples'/file
        if hashlib.sha256(source.read_bytes()).hexdigest()!=digest:
            raise r.SimulationError('fuente DCE distinta de la acreditada por B5: '+file)
        records=[]
        for cut,transform,addresses in variants:
            record=dict(level=transform or 'tradicional',argv=['{compiler}','-s','-o','{binary}','{source}'],
                        cut_advances=cut,observation_addresses=addresses,
                        cut_contract='B5: retorno compatible retirado y continuación NOP; main no certificado')
            if transform:record['transform']=transform
            records.append(record)
        programs.append(dict(name=name,source=str(source),semantic_observations=values,variants=records))
    return dict(compiler_root=str(root),compiler_commit=commit,programs=programs)
