"""test_memory_modes.py — regresión arquitectónica del issue #9.

Ejecuta programas iguales en memoria directa (0) y L1-D WB/WA/EXCLUSIVA (2),
con l2_model provisional. Recibe fixtures originales y referencias de ISA;
produce aserciones unittest, dumps completos, diagnósticos y registros JSON.
Reutiliza los diez escenarios RTL positivos de test_cpu_program, sin editar sus
fuentes ni obtener expectativas desde el DUT. Los escenarios adicionales aíslan
memoria, control y puerto B. Cada modo conserva su propia elaboración y destino.

La captura reutiliza el flush del #28: GPR al corte de avances efectivos y DMEM
persistente después de done. Se comparan 32 valores de 32 bits y 16384 palabras,
además de los oráculos. Los stalls pueden cambiar el tiempo, no el estado final.
No certifica terminación semántica de main, L2 definitiva ni rendimiento de un
benchmark; un corte no quiescente sigue siendo un error.

Depende de Python, unittest, el ensamblador vigente e Icarus. No modifica ISA,
RTL, ejemplos, cachés, políticas ni Compiladores. TemporaryDirectory posee los
recursos normales. P9_EVIDENCE_DIR permite conservarlos en un destino externo
nuevo; nunca escribe artefactos en ROOT. Las mutaciones alteran solo copias o
respondedores diagnósticos, conservando el oráculo y el productor real.
"""
from __future__ import annotations

import contextlib
import copy
from dataclasses import dataclass, replace
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import test_cpu_program as legacy
from tools import run_program as runner
from tools.assembler import AssemblyError

ROOT = Path(__file__).resolve().parents[1]
HAVE_ICARUS = shutil.which(os.environ.get('IVERILOG', 'iverilog')) and shutil.which(os.environ.get('VVP', 'vvp'))


@dataclass(frozen=True)
class Snapshot:
    """Captura observable y su procedencia; no consulta privados de caché.

    directory posee los archivos leídos. Las tuplas preservan el orden x0..31 y
    palabra0..16383. image contiene bytes reales, no solo un hash. metadata es el
    reporte validado del runner; el comparador vuelve a contrastar su horizonte.
    """
    directory: Path
    mode: int
    registers: tuple[int, ...]
    memory: tuple[int, ...]
    image: bytes
    metadata: dict


def read_snapshot(directory: Path, mode: int) -> Snapshot:
    """Lee una captura externa completa o lanza SimulationError identificable.

    Recibe destino y modo previsto. No crea archivos ni modifica resultados.
    Rechaza registros duplicados/omitidos, hex inválido, X/Z, memoria truncada,
    metadatos de otro modo e imagen cambiada. Los analizadores son independientes
    de la comparación entre modos; una salida parcial no es una divergencia RTL.
    OSError/JSONDecodeError conservan la identificación de un error de archivos.
    """
    registers = {}
    for line in (directory/'registers.txt').read_text().splitlines():
        match = re.fullmatch(r'x([0-9]+) ([0-9a-fA-F]{8})', line)
        if not match:
            raise runner.SimulationError('captura GPR inválida o X/Z')
        reg, value = int(match[1]), int(match[2], 16)
        if reg > 31 or reg in registers:
            raise runner.SimulationError('captura GPR duplicada o fuera de rango')
        registers[reg] = value
    if set(registers) != set(range(32)):
        raise runner.SimulationError('captura GPR incompleta: se requieren 32 registros')
    words = (directory/'memory.txt').read_text().splitlines()
    if len(words) != 16384 or any(not re.fullmatch(r'[0-9a-fA-F]{8}', w) for w in words):
        raise runner.SimulationError('captura DMEM incompleta o X/Z')
    image = (directory/'program.mem').read_bytes()
    metadata = json.loads((directory/'execution.json').read_text())
    if metadata.get('schema') != 1 or (metadata.get('requested_mode'), metadata.get('effective_mode')) != (mode, mode):
        raise runner.SimulationError('captura con modo no acreditado')
    if metadata.get('image_sha256') != hashlib.sha256(image).hexdigest():
        raise runner.SimulationError('captura con imagen diferente de la ejecutada')
    return Snapshot(directory, mode, tuple(registers[r] for r in range(32)),
                    tuple(int(w, 16) for w in words), image, metadata)


def compare_snapshots(a: Snapshot, b: Snapshot, expected: dict[int, int], memory: tuple[int, ...]) -> dict:
    """Contrasta entradas, horizonte, todos los resultados y un oráculo externo.

    Devuelve estado y TODAS las diferencias para guardarlas fuera de consola.
    SimulationError indica comparación no válida (configuración, imagen, corte o
    tamaño distintos), separado de una divergencia de datos. expected y memory
    deben prepararse desde ISA/fixtures antes de observar salidas; nunca desde a.
    No escribe archivos ni altera capturas. Las diferencias temporales se aceptan.
    """
    if (a.mode, b.mode) != (0, 2):
        raise runner.SimulationError('comparación requiere modos efectivos 0 y 2')
    if a.image != b.image:
        raise runner.SimulationError('imágenes de programa distintas')
    if a.metadata['stats']['avances'] != b.metadata['stats']['avances']:
        raise runner.SimulationError('puntos de ejecución diferentes')
    if len(a.registers) != 32 or len(b.registers) != 32 or len(a.memory) != 16384 or len(b.memory) != 16384 or len(memory) != 16384:
        raise runner.SimulationError('capturas u oráculo incompletos')
    # Revisar todos los registros detecta corrupción ajena a los resultados del
    # JSON parcial; revisar DMEM completa detecta stores a direcciones incorrectas.
    registers = [dict(register=f'x{i}', mode0=x, mode2=y) for i, (x, y) in enumerate(zip(a.registers, b.registers)) if x != y]
    words = [dict(word=i, byte_address=4*i, mode0=x, mode2=y) for i, (x, y) in enumerate(zip(a.memory, b.memory)) if x != y]
    oracle = []
    for state in (a, b):
        for reg, value in expected.items():
            if state.registers[reg] != value:
                oracle.append(dict(mode=state.mode, register=f'x{reg}', expected=value, actual=state.registers[reg]))
        for i, (actual, value) in enumerate(zip(state.memory, memory)):
            if actual != value:
                oracle.append(dict(mode=state.mode, word=i, byte_address=4*i, expected=value, actual=actual))
    # Dos salidas equivocadas pero iguales no acreditan corrección. Un error de
    # infraestructura se lanza antes y nunca se convierte en DIFERENTE.
    status = 'DIFERENTE' if registers or words else 'MISMA SALIDA, PERO EXPECTATIVA INCORRECTA' if oracle else 'EQUIVALENTE Y CORRECTO'
    return dict(status=status, register_differences=registers, memory_differences=words,
                oracle_differences=oracle, files=[str(a.directory), str(b.directory)])


def memory_oracle(stores: dict[int, int] | None = None) -> tuple[int, ...]:
    """Construye DMEM desde cero inicial y stores declarados, sin leer el DUT.

    Recibe direcciones de byte alineadas y palabras de 32 bits; devuelve toda la
    memoria. ValueError rechaza una referencia mal formada antes de comparar.
    La referencia de guardab ya debe incluir el byte combinado según little-endian.
    """
    words = [0]*16384
    for address, value in (stores or {}).items():
        if address % 4 or not 0 <= address <= 65532 or not 0 <= value <= 0xffffffff:
            raise ValueError('oráculo de memoria inválido')
        words[address//4] = value
    return tuple(words)


@unittest.skipUnless(HAVE_ICARUS, 'requiere iverilog y vvp para ejecutar RTL')
class MemoryModesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Reserva recursos externos y una pareja real para controles de lectura.

        El destino persistente debe ser nuevo y exterior a ROOT. Sin variable,
        ExitStack posee y libera los temporales. La pareja inicial usa un store
        conocido; sus salidas solo son entradas de mutaciones, nunca el oráculo.
        """
        cls.owner = contextlib.ExitStack()
        requested = os.environ.get('P9_EVIDENCE_DIR')
        if requested:
            cls.work = Path(requested).resolve()
            if cls.work == ROOT or ROOT in cls.work.parents:
                raise ValueError('P9_EVIDENCE_DIR debe estar fuera del código fuente')
            cls.work.mkdir(parents=True, exist_ok=False)
        else:
            cls.work = Path(cls.owner.enter_context(tempfile.TemporaryDirectory(prefix='p9-tests-')))
        cls.serial = 0
        cls.records = []
        case = cls('test_01_original_positive_programs')
        cls.seed_source = 'sumai x4,x0,77 | nop | nop | nop\nnop\nnop\nnop | guardap x0,x4,256 | nop | nop\n'
        cls.seed = case.pair('semilla', cls.seed_source, {4:77}, {256:77})

    @classmethod
    def tearDownClass(cls):
        """Cierra el propietario al terminar la suite, sin devolver una captura.

        ExitStack libera solo los temporales registrados por setUpClass. Los
        destinos persistentes no se registran allí y se conservan para revisión;
        nunca se borra el código fuente ni un destino elegido por otro caso.
        """
        cls.owner.close()

    def folder(self, label: str) -> Path:
        """Reserva un destino externo para la etiqueta recibida y devuelve su ruta.

        Se llama antes de producir artefactos; incrementa el índice compartido
        de la suite para separar binarios y dumps incluso con etiquetas iguales.
        mkdir propaga OSError si no puede reservarlo, sin reutilizar restos. Su
        liberación depende del propietario elegido en setUpClass.
        """
        type(self).serial += 1
        result = self.work/f'{self.serial:03d}-{label}'
        result.mkdir()
        return result

    def record(self, item: dict):
        """Acumula diagnóstico/tiempo en evidencia de la suite; no decide el PASS.

        Recibe un registro JSON compatible; conserva cada ejecución separada en
        sus archivos y publica el índice externo. No escribe en el repositorio.
        """
        self.records.append(item)
        (self.work/'results.json').write_text(json.dumps(self.records, indent=2)+'\n')

    def command(self, argv, cwd, log, timeout=60):
        """Ejecuta un argv externo con límite de pared y guarda código/salida.

        Retorna CompletedProcess incluso con error para comprobar la causa real.
        Timeout de esta infraestructura no se acredita como divergencia de RTL.
        """
        start = time.monotonic()
        result = subprocess.run([str(x) for x in argv], cwd=cwd, capture_output=True,
                                text=True, timeout=timeout, env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
        log.write_text(result.stdout+result.stderr)
        self.record(dict(command=[str(x) for x in argv], rc=result.returncode,
                         seconds=round(time.monotonic()-start, 3), log=str(log)))
        return result

    def pair(self, label, source, expected, stores=None, cycles=None, trace=False):
        """Ejecuta dos modos con fuente común y exige corrección y equivalencia.

        Recibe fuente y referencias preparadas; devuelve ambas capturas. Cada
        destino posee su compilación y datos. Si falla una simulación se propaga
        el error, sin declarar divergencia arquitectónica entre estados parciales.
        """
        work = self.folder(label)
        asm = work/'input.asm'; asm.write_text(source)
        # La referencia se conserva ANTES de ejecutar, para acreditar que no
        # nació de una salida del DUT. DMEM parte de cero más estos stores.
        (work/'oracle.json').write_text(json.dumps(dict(registers=expected, initial_memory=0, stores=stores or {}),indent=2))
        states = []
        for mode in (0, 2):
            out = work/f'modo-{mode}'
            start = time.monotonic()
            runner.run_program(asm, out, expected, False, stores, cycles, trace, mode)
            states.append(read_snapshot(out, mode))
            self.record(dict(program=label, mode=mode, rc=0, seconds=round(time.monotonic()-start,3),
                             metadata=str(out/'execution.json'), stats=states[-1].metadata['stats']))
        self.check_pair(label, states, expected, stores)
        return tuple(states)

    def check_pair(self, label, states, expected, stores):
        """Guarda todas las diferencias y muestra solo la primera ante un fallo.

        El origen del oráculo son los stores/expectativas recibidos. Un hash
        coincidente no reemplaza comparar datos. No exige tiempos iguales.
        """
        report = compare_snapshots(*states, expected, memory_oracle(stores))
        self.record(dict(program=label, comparison=report))
        first = (report['register_differences']+report['memory_differences']+report['oracle_differences'])[:1]
        self.assertEqual(report['status'], 'EQUIVALENTE Y CORRECTO',
                         f'{label}: {report["status"]}; primera={first}; evidencia={report["files"]}')
        self.assertNotEqual(states[0].metadata['binary_sha256'], states[1].metadata['binary_sha256'])

    def test_01_original_positive_programs(self):
        # Reutilizamos constructores y expectativas REALES del Proyecto I. El
        # wrapper ejecuta ambos modos; devuelve el modo0 para que el método
        # original también conserve sus aserciones y su comprobación de VCD.
        # No se extraen fixtures fingiendo que una ejecución ocurrió.
        names = ('all_18_instructions_and_pseudos', 'memory_program', 'branch_program',
                 'subroutine_call_and_return', 'two_nop_bundles_between_producer_and_consumer',
                 'immediate_signed_limits_and_logic', 'shift_amount_reduced_modulo_32',
                 'latest_write_and_self_update', 'last_bundle_reaches_writeback_at_capacity_limit',
                 'mixed_program_with_crypto')
        for name in names:
            with self.subTest(program=name):
                def execute(source, workdir, expected=None, vcd=True, expected_memory=None, cycles=None, trace=False):
                    """Puente al caso original: ejecuta y conserva sus salidas verdaderas.

                    source/expected/presupuesto son los originales. El modo0 usa
                    el destino que ese caso espera; luego se copia a evidencia
                    antes de que TemporaryDirectory lo libere. Modo2 es separado.
                    """
                    work = self.folder(name)
                    # El caso original elimina sus temporales al terminar.
                    # Conservamos fuente y referencia ahora, mientras existen,
                    # sin modificar los fixtures ni los destinos que espera.
                    (work/'input.asm').write_text(Path(source).read_text())
                    (work/'oracle.json').write_text(json.dumps(dict(registers=expected or {}, initial_memory=0, stores=expected_memory or {}),indent=2))
                    regs = runner.run_program(source, workdir, expected, vcd, expected_memory, cycles, trace, 0)
                    shutil.copytree(workdir, work/'modo-0')
                    runner.run_program(source, work/'modo-2', expected, False, expected_memory, cycles, trace, 2)
                    states = [read_snapshot(work/f'modo-{m}',m) for m in (0,2)]
                    for state in states:
                        self.record(dict(program=name, mode=state.mode, rc=0, metadata=str(state.directory/'execution.json'), stats=state.metadata['stats']))
                    self.check_pair(name, states, expected or {}, expected_memory)
                    return regs
                with mock.patch.object(legacy, 'run_program', execute):
                    getattr(legacy.CpuProgramTests(), 'test_'+name)()

    def test_02_individual_bundle_cases(self):
        # NOP/ALU/load de cero aíslan un bundle, ausencia de memoria y miss frío.
        # Cada referencia GPR se construye desde el reset, no desde el modo0.
        for name, asm, value in [('nop','nop\n',0), ('alu','sumai x4,x0,99 | nop | nop | nop\n',99),
                                 ('load','nop | cargai x4,x0,256 | nop | nop\n',0)]:
            with self.subTest(case=name):
                states = self.pair(name, asm, {r:value if r==4 else 0 for r in range(32)})
                self.assertEqual(states[0].metadata['stats']['avances'],5)
                if name=='load': self.assertGreater(states[1].metadata['stats']['stalls'],0)

    def test_03_memory_edges_partial_store_and_victim(self):
        # x20=2048,x22=4096 caen con dirección0 en el mismo conjunto (dos vías).
        # El tercer store fuerza víctima; guardab en byte1 produce 0x00007f7f.
        # x21=65472 más offset60 prueba la última palabra válida. Dos NOP tras
        # cada productor son la separación N+3 definida, no correcciones de fallos.
        lines=[]
        for instruction in ['sumai x4,x0,127','sumai x20,x0,1','cizqi x20,x20,11',
                            'suma x22,x20,x20','sumai x21,x0,1023','cizqi x21,x21,6']:
            lines += [instruction+' | nop | nop | nop','nop','nop']
        lines += ['nop | guardap x0,x4,0 | nop | nop','nop | guardab x0,x4,1 | nop | nop',
                  'nop | guardap x20,x4,0 | nop | nop','nop | guardap x22,x4,0 | nop | nop',
                  'nop | cargai x5,x0,0 | nop | nop','nop | cargai x6,x20,0 | nop | nop',
                  'nop | cargai x7,x22,0 | nop | nop','nop | guardap x21,x4,60 | nop | nop',
                  'nop | cargai x8,x21,60 | nop | nop']
        gold={r:0 for r in range(32)};gold.update({4:127,5:0x7f7f,6:127,7:127,8:127,20:2048,21:65472,22:4096})
        self.pair('memoria-bordes-victima', '\n'.join(lines)+'\n', gold,
                  {0:0x7f7f,2048:127,4096:127,65532:127})

    def test_04_finite_loop(self):
        # Tres incrementos con distancia N+3 y branch tomado dos veces. El salto
        # final sin enlace permite el mantenimiento; se espera x4=x5=3 y DMEM0.
        asm='sumai x5,x0,3 | nop | nop | nop\nnop\nnop\nloop: sumai x4,x4,1 | nop | nop | nop\nnop\nnop\nnop | nop | menora x4,x5,loop | nop\nfin: nop | nop | sye x0,fin | nop\n'
        self.pair('bucle-finito',asm,{r:3 if r in (4,5) else 0 for r in range(32)},cycles=80)

    def test_05_port_b_with_lsu(self):
        # Preparamos contraseña7 y AUTH mediante el mismo arranque del mixto.
        # LSU load junto a camcon debe leer7 antes de rotar a14. Si ambos
        # escriben, B gana con14 aunque A presente42. Detecta repetición de camcon
        # durante stalls o una lectura de DMEM vieja en lugar de la caché.
        prefix='sumai x4,x0,7 | nop | nop | nop\nsumai x6,x0,42 | nop | nop | nop\nnop\nnop\nnop | guardap x0,x4,256 | nop | setpwd x4\nnop\nnop\nnop | nop | nop | vcr 256\nnop\nnop\n'
        for op in ('cargai x5,x0,256','guardap x0,x6,256'):
            with self.subTest(lsu=op):
                expected={r:0 for r in range(32)};expected.update({4:7,6:42})
                if op.startswith('cargai'):expected[5]=7
                self.pair('puerto-b',prefix+f'nop | {op} | nop | camcon 256,1\n',expected,{256:14})

    def test_06_repetition(self):
        # La misma fuente/estado/presupuesto debe repetir estado y medidas RTL.
        # Directorios y binarios siguen siendo independientes en cada repetición.
        again=self.pair('repeticion',self.seed_source,{4:77},{256:77})
        for a,b in zip(self.seed,again):
            self.assertEqual(a.registers,b.registers);self.assertEqual(a.memory,b.memory)
            self.assertEqual(a.metadata['stats'],b.metadata['stats'])

    def test_07_default_positional_api_and_mode1(self):
        # La llamada de siete argumentos posicionales conserva modo0 y traza.
        # El modo1 también debe seguir disponible, con el mismo oráculo de store.
        work=self.folder('api-compatible');source=work/'input.asm';source.write_text(self.seed_source)
        a=runner.run_program(source,work/'default',{4:77},False,{256:77},None,True)
        for mode in (0,1):
            b=runner.run_program(source,work/f'explicit-{mode}',{4:77},False,{256:77},None,True,mode)
            state=read_snapshot(work/f'explicit-{mode}',mode)
            self.assertEqual(a,b);self.assertEqual(state.memory,memory_oracle({256:77}))
        self.assertEqual(read_snapshot(work/'default',0).metadata['stats'],read_snapshot(work/'explicit-0',0).metadata['stats'])
        self.assertTrue((work/'default/trace.txt').is_file())

    def test_08_cli(self):
        # El comando documentado ejercita argparse, elaboración y expectativa
        # externa LSU. Los inválidos deben retornar2, antes de cualquier RTL.
        work=self.folder('cli')
        argv=[sys.executable,ROOT/'tools/run_program.py','--input',ROOT/'examples/lsu_isa.asm',
              '--expect',ROOT/'examples/lsu_isa.expected.json','--expect-memory',ROOT/'examples/lsu_isa.memory.json',
              '--cycles','80','--mem-mode','2','--no-vcd','--workdir',work/'out']
        result=self.command(argv,ROOT,work/'cli.log');self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        read_snapshot(work/'out',2)
        for value in ('-1','3','True','x','1.0'):
            bad=self.command([sys.executable,ROOT/'tools/run_program.py','--input',ROOT/'examples/alu_isa.asm','--mem-mode',value],ROOT,work/f'invalid-{value}.log')
            self.assertEqual(bad.returncode,2);self.assertIn('invalid',bad.stderr)

    def test_09_invalid_api_modes(self):
        # bool es subclase de int: exigir el tipo evita aceptar True como modo1.
        # Usar una fuente inexistente prueba que se rechaza modo antes de leerla.
        for value in (-1,3,True,False,'2',2.0,None,[],{}):
            with self.subTest(value=value),self.assertRaisesRegex(runner.SimulationError,'mem_mode'):
                runner.run_program(self.work/'missing.asm',self.work/'unused',mem_mode=value)

    def mutated_snapshot(self, name, register_text=None, memory_text=None):
        """Copia una captura válida para mutar SOLO el dump del control negativo.

        Recibe reemplazos opcionales y devuelve el destino externo. Conserva
        imagen, reporte y referencias; el defecto no se introduce en el DUT.
        """
        work=self.folder(name);shutil.copytree(self.seed[1].directory,work/'capture')
        out=work/'capture'
        if register_text is not None:(out/'registers.txt').write_text(register_text)
        if memory_text is not None:(out/'memory.txt').write_text(memory_text)
        return out

    def test_10_corrupted_dump_structure(self):
        # Cada mutación viola integridad, no una expectativa de ISA. Se exige
        # la causa del lector: omisión/duplicado, formato/XZ o memoria truncada.
        regs=(self.seed[1].directory/'registers.txt').read_text();mem=(self.seed[1].directory/'memory.txt').read_text()
        cases=[('omit-reg','\n'.join(regs.splitlines()[:-1])+'\n',None,'GPR incompleta'),
               ('duplicate-reg',regs+regs.splitlines()[0]+'\n',None,'GPR duplicada'),
               ('xz-reg',regs.replace('x4 0000004d','x4 xxxxxxxx'),None,'GPR inválida'),
               ('empty-reg','',None,'GPR incompleta'),
               ('omit-word',None,'\n'.join(mem.splitlines()[:-1])+'\n','DMEM incompleta'),
               ('xz-word',None,'zzzzzzzz\n'+ '\n'.join(mem.splitlines()[1:])+'\n','DMEM incompleta'),
               ('empty-memory',None,'','DMEM incompleta')]
        for name,r,m,diagnostic in cases:
            with self.subTest(mutation=name):
                out=self.mutated_snapshot(name,r,m)
                with self.assertRaisesRegex(runner.SimulationError,diagnostic):read_snapshot(out,2)
                self.record(dict(negative=name,detected_by=diagnostic,evidence=str(out)))

    def test_11_architectural_divergences_and_bad_oracle(self):
        # Cambiar x4, una palabra conocida o la ÚLTIMA palabra ajena al store
        # debe localizar diferencias con valor, índice y dirección. Un error
        # compartido por ambos modos se clasifica aparte usando el mismo gold.
        a,b=self.seed;gold=memory_oracle({256:77})
        regs=(b.directory/'registers.txt').read_text().replace('x4 0000004d','x4 0000004c')
        words=(b.directory/'memory.txt').read_text().splitlines()
        known=words.copy();known[64]='0000004c'
        outside=words.copy();outside[-1]='00000063'
        cases=[('registro',regs,None),('palabra',None,'\n'.join(known)+'\n'),
               ('fuera-de-rango',None,'\n'.join(outside)+'\n')]
        for name,r,m in cases:
            # Se modifica un dump verdadero con hexadecimal válido: no basta
            # detectar formato. Debe informar la divergencia arquitectónica.
            out=self.mutated_snapshot(name,r,m)
            mutant=read_snapshot(out,2)
            report=compare_snapshots(a,mutant,{4:77},gold)
            self.assertEqual(report['status'],'DIFERENTE')
            self.record(dict(negative=name,comparison=report))
        report=compare_snapshots(a,b,{4:78},gold)
        self.assertEqual(report['status'],'MISMA SALIDA, PERO EXPECTATIVA INCORRECTA')
        self.record(dict(negative='equal-but-wrong-oracle',comparison=report))
        with self.assertRaisesRegex(runner.SimulationError,'resultados incorrectos'):
            work=self.folder('bad-expected');source=work/'input.asm';source.write_text(self.seed_source)
            runner.run_program(source,work/'out',{4:78},vcd=False,mem_mode=2)

    def test_12_incompatible_comparisons(self):
        # No se puede llamar divergencia a comparar otro programa, otro corte o
        # el mismo modo dos veces. Se alteran metadatos diagnósticos, no oráculos.
        a,b=self.seed
        metadata=copy.deepcopy(b.metadata);metadata['stats']['avances']+=1
        for name,mutant,diagnostic in [('imagen',replace(b,image=b.image+b'0'),'imágenes'),
                                      ('horizonte',replace(b,metadata=metadata),'puntos'),
                                      ('mismo-modo',replace(b,mode=0),'modos efectivos')]:
            with self.subTest(mutation=name),self.assertRaisesRegex(runner.SimulationError,diagnostic):
                compare_snapshots(a,mutant,{4:77},memory_oracle({256:77}))

    def fake_simulator(self, name, output, exit_code=0, produce=True):
        """Crea un ejecutable diagnóstico externo con salida/dumps controlados.

        No acredita hardware: ejercita al consumidor Python con dumps reales
        copiados del caso semilla y mensajes alterados. Si produce=True escribe
        archivos NUEVOS para que el rechazo dependa de la causa prevista.
        """
        work=self.folder(name);script=work/'simulator'
        text='#!/usr/bin/env python3\nfrom pathlib import Path\nimport sys\n'
        if produce:
            text+="args=dict(a[1:].split('=',1) for a in sys.argv[1:] if a.startswith('+') and '=' in a)\n"
            for key,filename in [('REGDUMP','registers.txt'),('MEMDUMP','memory.txt')]:
                text+=f"Path(args[{key!r}]).write_bytes(Path({str(self.seed[1].directory/filename)!r}).read_bytes())\n"
        text+=f'print({output!r})\nraise SystemExit({exit_code})\n'
        script.write_text(text);script.chmod(0o700)
        return work,script

    def test_13_protocol_markers_and_stale_outputs(self):
        # Los marcadores buenos provienen del DUT semilla real. Se modifica uno
        # por control, dejando dumps nuevos válidos: rc0 no basta para aprobar.
        # La mezcla de flush en ejecución conserva E=A+S, pero debe romper la
        # identidad de flancos totales y ser rechazada por esa comprobación.
        output=(self.seed[1].directory/'sim.log').read_text()
        mode_line=next(x for x in output.splitlines() if x.startswith('[MEM_MODE]'))
        stats_line=next(x for x in output.splitlines() if x.startswith('[EXEC_STATS]'))
        stats=self.seed[1].metadata['stats'];mixed=stats_line.replace(f'flancos={stats["flancos"]}',f'flancos={stats["flancos"]+stats["flush"]}',1).replace(f'stalls={stats["stalls"]}',f'stalls={stats["stalls"]+stats["flush"]}',1)
        cases=[('no-mode',output.replace(mode_line+'\n',''),'[MEM_MODE]'),
               ('wrong-mode',output.replace(mode_line,'[MEM_MODE] solicitado=0 efectivo=0'),'modo de memoria distinto'),
               ('duplicate-mode',output+mode_line+'\n','[MEM_MODE]'),
               ('contradictory-mode',output+'[MEM_MODE] solicitado=2 efectivo=0\n','[MEM_MODE]'),
               ('malformed-mode',output.replace(mode_line,'[MEM_MODE] efectivo=X solicitado=2'),'[MEM_MODE]'),
               ('no-flush','\n'.join(x for x in output.splitlines() if not x.startswith('[FLUSH]')),'sin confirmación'),
               ('wrong-flush-mode',output.replace('[FLUSH] fase=assembled modo=2','[FLUSH] fase=assembled modo=0'),'modo de flush'),
               ('no-finish','\n'.join(x for x in output.splitlines() if not x.startswith('[OK]')),'sin confirmación'),
               ('no-stats',output.replace(stats_line+'\n',''),'[EXEC_STATS]'),
               ('bad-horizon',output.replace(f'avances={stats["avances"]}',f'avances={stats["avances"]-1}',1),'punto de ejecución'),
               ('mixed-flush',output.replace(stats_line,mixed),'estadísticas'),
               ('failed-process',output,'falló simulator'),('stale-dumps',output,'sin dumps nuevos')]
        for name,text,diagnostic in cases:
            with self.subTest(mutation=name):
                work,script=self.fake_simulator(name,text,exit_code=1 if name=='failed-process' else 0,produce=name!='stale-dumps')
                source=work/'input.asm';source.write_text(self.seed_source);out=work/'out';out.mkdir()
                # Los archivos anteriores son formalmente válidos. El runner
                # debe retirarlos antes de ejecutar; el negativo no depende de X.
                for filename in ('registers.txt','memory.txt'):
                    shutil.copy2(self.seed[1].directory/filename,out/filename)
                with mock.patch.dict(os.environ,{'VVP':str(script)}),self.assertRaisesRegex(runner.SimulationError,re.escape(diagnostic)):
                    runner.run_program(source,out,{4:77},vcd=False,mem_mode=2)
                self.assertFalse((out/'execution.json').exists())
                self.record(dict(negative=name,detected_by=diagnostic,evidence=str(work)))

    def test_14_actual_wrong_binary(self):
        # El compilador diagnóstico copia el binario REAL modo0 en lugar de
        # elaborar modo2 y retorna0. vvp sí ejecuta ese hardware. El plusarg de
        # intención no cambia el modo: el assert del DUT debe detectar el error.
        work=self.folder('binario-incorrecto');compiler=work/'compiler'
        compiler.write_text('#!/usr/bin/env python3\nfrom pathlib import Path\nimport sys\n'+
                            f"Path(sys.argv[sys.argv.index('-o')+1]).write_bytes(Path({str(self.seed[0].directory/'sim.vvp')!r}).read_bytes())\n")
        compiler.chmod(0o700);source=work/'input.asm';source.write_text(self.seed_source)
        with mock.patch.dict(os.environ,{'IVERILOG':str(compiler)}),self.assertRaisesRegex(runner.SimulationError,'modo de memoria distinto'):
            runner.run_program(source,work/'out',vcd=False,mem_mode=2)
        self.assertIn('solicitado=2 banco=0 efectivo=0',(work/'out/sim.log').read_text())
        self.record(dict(negative='binary-mode0-for-request2',evidence=str(work)))

    def test_15_program_and_infrastructure_errors(self):
        # Estos controles acreditan manejo de errores, no divergencia de hardware.
        # Fuente inválida falla en el ensamblador; ejecutable ausente no es PASS
        # RTL; fallo de compilador y timeout de pared conservan sus diagnósticos.
        work=self.folder('errores');source=work/'bad.asm';source.write_text('no_existe | nop | nop | nop\n')
        with self.assertRaises(AssemblyError):runner.run_program(source,work/'out',vcd=False)
        source.write_text('nop\n')
        with mock.patch.dict(os.environ,{'VVP':str(work/'missing')}),self.assertRaisesRegex(runner.SimulationError,'no se encontró'):
            runner.run_program(source,work/'missing-out',vcd=False)
        compiler=work/'compiler';compiler.write_text('#!/usr/bin/env python3\nprint("diagnóstico de elaboración")\nraise SystemExit(7)\n');compiler.chmod(0o700)
        with mock.patch.dict(os.environ,{'IVERILOG':str(compiler)}),self.assertRaisesRegex(runner.SimulationError,'falló compiler'):
            runner.run_program(source,work/'compile-out',vcd=False)
        with self.assertRaisesRegex(runner.SimulationError,'tiempo máximo'):
            runner.run_logged([sys.executable,'-c','import time; print("espera diagnóstica",flush=True); time.sleep(3)'],work,work/'timeout.log',1)
        self.assertTrue((work/'timeout.log').is_file())

    def test_16_non_quiescent_cut(self):
        # El bucle continúa guardando después del corte. Se exige el rechazo del
        # #28 y ausencia de dump válido; no se desactiva el observador de reposo.
        work=self.folder('corte-activo');source=work/'input.asm'
        source.write_text('sumai x4,x0,7 | nop | nop | nop\nnop\nnop\nloop: nop | guardap x0,x4,256 | sye x0,loop | nop\n')
        with self.assertRaisesRegex(runner.SimulationError,'no quiescente'):
            runner.run_program(source,work/'out',vcd=False,cycles=12,mem_mode=2)
        self.assertFalse((work/'out/memory.txt').exists())
        self.assertFalse((work/'out/execution.json').exists())


if __name__ == '__main__':
    unittest.main()
