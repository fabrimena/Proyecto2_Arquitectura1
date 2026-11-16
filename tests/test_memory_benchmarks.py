"""Issue #29: patrones, oráculos completos, RTL real y controles de sensibilidad.

Entradas: fixtures versionados, contratos #9/#28, Icarus y unittest. Salidas:
aserciones y evidencia externa opcional P29_EVIDENCE_DIR. Los casos estáticos
no requieren simulador; los reales elaboran doce ejecuciones (dos rondas).
Ningún negativo altera producción: muta copias de archivos ya válidos y exige
la excepción/diagnóstico específico, nunca un fallo de infraestructura genérico.
Cada propietario temporal se libera al terminar; la evidencia elegida se conserva.
"""
from __future__ import annotations

import contextlib
import copy
import csv
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from tools import run_memory_benchmarks as bench
from tools.assembler import AssemblyError, assemble_source

ROOT = Path(__file__).resolve().parents[1]
HAVE_ICARUS = shutil.which(os.environ.get('IVERILOG', 'iverilog')) and shutil.which(os.environ.get('VVP', 'vvp'))
# Direcciones calculadas por la especificación de Fisher-Yates, fijadas como
# oráculo literal adicional: modificar semilla o pasos no puede cambiarlo solo.
RANDOM_ADDRESSES = (3328,192,576,3200,2432,1216,2816,1600,1408,448,2368,3744,800,
                    3584,1472,3936,480,3872,256,1120,896,3776,768,2112,2944,2176,
                    3072,3008,1728,1760,64,3136)


class PatternTests(unittest.TestCase):
    """Prepara referencias previas a hardware y rechaza fuentes/fixtures alterados."""

    @classmethod
    def setUpClass(cls):
        """Lee los tres contratos nominales sin ejecutar RTL ni abrir recursos duraderos.

        prepare_oracle debe pasar antes de los negativos; un error aquí es fallo
        de preparación, nunca detección exitosa. Las tuplas se conservan inmutables.
        """
        cls.plans = {n:bench.prepare_oracle(n) for n in bench.NAMES}

    def fixture_copy(self, directory):
        """Copia los nueve fixtures a un temporal del llamador y retorna la carpeta.

        No modifica referencias originales. OSError indica infraestructura; el
        caso aplica después una mutación comprobada sobre esta copia válida.
        Con P29_EVIDENCE_DIR conserva cada mutación en un hermano externo
        terminado en -static; sin variable, el contexto recibido lo libera.
        """
        target = Path(directory)/'examples'
        if requested := os.environ.get('P29_EVIDENCE_DIR'):
            evidence = Path(requested + '-static').resolve()
            if evidence == ROOT or ROOT in evidence.parents:
                raise ValueError('evidencia estática externa requerida')
            target = evidence/self._testMethodName/'examples'
        target.mkdir(parents=True,exist_ok=False)
        for name in bench.NAMES:
            for suffix in ('asm', 'expected.json', 'memory.json'):
                shutil.copy2(ROOT/f'examples/bench_{name}.{suffix}', target)
        return target

    def test_01_assembly_slots_capacity_n_plus_three(self):
        """Ensambla las tres fuentes: espera 868 bundles y margen 4 dentro de IMEM.

        El ensamblador verifica slots/RAW/WAW/N+3; cualquier violación debe fallar
        en vez de insertar NOP o aumentar el presupuesto para ocultarla.
        """
        for plan in self.plans.values():
            with self.subTest(name=plan.name):
                p = assemble_source(plan.source.read_text())
                self.assertEqual(len(p.bundles), 868)
                self.assertEqual(plan.cycles, 872)
                self.assertLessEqual(plan.bundles, bench.runner.MAX_RUN_BUNDLES)
                self.assertTrue(all(len(b.instructions) == 4 for b in p.bundles))

    def test_02_equal_population(self):
        """Cuenta stores/lecturas con plan estático: espera 32+64 en los tres.

        Detecta población distinta disfrazada de comparación por patrón; cada
        dirección aparece una vez escrita y dos veces leída con datos conocidos.
        """
        for plan in self.plans.values():
            self.assertEqual(len(plan.stores), 32)
            self.assertEqual(plan.reads, tuple(range(1,33))*2)
            self.assertEqual(tuple(s[1] for s in plan.stores), plan.addresses)
            self.assertEqual(tuple(s[2] for s in plan.stores), tuple(range(1,33)))
            self.assertTrue(all(s[3] == 15 for s in plan.stores))

    def test_03_sequential_spatial_locality(self):
        """Prepara direcciones secuenciales; espera pasos de 4 y cuatro líneas.

        Ocho palabras por línea comprueban la población espacial sin suponer hits
        a partir de geometría ni utilizar datos del DUT como referencia.
        """
        a = self.plans['secuencial'].addresses
        self.assertEqual(a, tuple(range(0,128,4)))
        self.assertEqual(len({x//32 for x in a}),4)
        self.assertEqual([sum(x//32 == line for x in a) for line in range(4)], [8]*4)

    def test_04_random_seed_and_repeatability(self):
        """Invoca dos veces el generador y compara con 32 direcciones literales.

        Detecta cambios de semilla, orden o algoritmo; no usa random del host ni
        compara dos resultados obtenidos del procesador para definir el patrón.
        """
        self.assertEqual(bench.SEED, 0x29c0de)
        self.assertEqual(bench.addresses('aleatorio'), RANDOM_ADDRESSES)
        self.assertEqual(bench.addresses('aleatorio'), bench.addresses('aleatorio'))

    def test_05_random_distributes_lines_sets(self):
        """Agrupa el patrón fijo por línea/conjunto: espera 32 líneas y más de 4 sets.

        Reduce reutilización espacial frente a secuencial; dos etiquetas por set
        como máximo no acreditan capacidad, hits ni exclusión global de L2.
        """
        a = RANDOM_ADDRESSES
        self.assertEqual(len({x//32 for x in a}),32)
        self.assertGreater(len({(x//32)%64 for x in a}),4)
        self.assertTrue(all(sum((y//32)%64 == s for y in a) <= 2 for s in range(64)))

    def test_06_stride_constant_and_conflicting(self):
        """Resta direcciones adyacentes: espera stride 2048 y 32 etiquetas del set0.

        La geometría 32 B/64 sets/dos vías explica competencia; el ensayo real
        contrasta stalls, sin convertir automáticamente toda competencia en miss.
        """
        a = self.plans['stride'].addresses
        self.assertEqual({b-a for a,b in zip(a,a[1:])},{2048})
        self.assertEqual({(x//32)%64 for x in a},{0})
        self.assertEqual(len({x//2048 for x in a}),32)
        self.assertGreater(len(a),2)

    def test_07_address_alignment_and_bounds(self):
        """Recorre cada dirección conocida: exige palabra alineada dentro de 64 KiB.

        Detecta wrap/truncamiento que dos modos podrían compartir; stride termina
        en 63488 y ninguna referencia acepta direccionamiento fuera de DMEM.
        """
        for p in self.plans.values():
            self.assertEqual(len(set(p.addresses)),32)
            self.assertTrue(all(a%4 == 0 and 0 <= a <= 65532 for a in p.addresses))
        self.assertEqual(self.plans['stride'].addresses[-1],63488)

    def test_08_full_register_oracles(self):
        """Construye a mano los 32 registros desde reset y los cinco modificados.

        Detecta referencias parciales y corrupción de registros ajenos; checksum
        2*sum(1..32)=1056 no procede de una ejecución anterior.
        """
        for p in self.plans.values():
            expected=[0]*32
            for r,v in {4:32,5:32,6:1056,7:1,20:p.addresses[-1]//1024*1024}.items():expected[r]=v
            self.assertEqual(p.registers,tuple(expected))

    def test_09_full_memory_oracles(self):
        """Construye 16384 palabras cero más 32 stores indexados y las compara todas.

        Detecta contaminación fuera de los JSON parciales; máscaras 1111 indican
        ausencia de operaciones por byte en estos benchmarks, no su cobertura RTL.
        """
        for p in self.plans.values():
            expected=[0]*16384
            for i,a in enumerate(p.addresses):expected[a//4]=i+1
            self.assertEqual(p.memory,tuple(expected))
            self.assertEqual(sum(v != 0 for v in p.memory),32)

    def test_10_d18_not_used_and_final_rest(self):
        """Inspecciona los slots: exige solo ISA original y un salto final sin enlace.

        Detecta instrucciones de caché no integradas o terminación artificial;
        el horizonte sigue len+4 y el núcleo queda activo en el bucle de reposo.
        """
        for p in self.plans.values():
            program=assemble_source(p.source.read_text())
            self.assertFalse(any(i.word>>25 == 77 for b in program.bundles for i in b.instructions))
            last=program.bundles[-1]
            self.assertEqual(last.instructions[2].target,last.pc)
            self.assertEqual(last.instructions[2].writes,())

    def test_11_file18k_size_hash_and_generator(self):
        """Compara binario versionado con tamaño/hash fijo y generación LCG externa.

        Detecta truncamiento, semilla o contenido distinto; el hash no sustituye
        la recuperación byte a byte de make archivo ejecutada por separado.
        """
        data=(ROOT/'examples/archivos/archivo18k.bin').read_bytes()
        self.assertEqual(len(data),18432)
        self.assertEqual(hashlib.sha256(data).hexdigest(),'c98e65ae5a58f7925bdc75bd3325ff60603df3c7113f5852bcccc2784fd920c3')
        self.assertEqual(data,bench.archive_bytes())
        self.assertEqual(bench.archive_bytes(),bench.archive_bytes())
        self.assertEqual(len(set(data)),256)

    def test_12_altered_expected_register_rejected(self):
        """Copia un fixture válido, cambia x6 a 1057 y exige error de expectativa JSON.

        La preparación nominal ya pasó; no se acepta cualquier excepción ni se
        deriva la referencia nueva desde el dump para encubrir el desacuerdo.
        """
        with tempfile.TemporaryDirectory() as d:
            examples=self.fixture_copy(d);p=examples/'bench_secuencial.expected.json'
            raw=json.loads(p.read_text());raw['x6']=1057;p.write_text(json.dumps(raw))
            with self.assertRaisesRegex(bench.BenchmarkError,'expectativa JSON'):
                bench.prepare_oracle('secuencial',examples)

    def test_13_altered_expected_memory_rejected(self):
        """Muta una palabra del JSON en una copia: exige la causa expectativa JSON.

        Detecta igualdad equivocada de ambos modos con gold alterado; no toca los
        archivos nominales ni considera un error de lectura detección exitosa.
        """
        with tempfile.TemporaryDirectory() as d:
            examples=self.fixture_copy(d);p=examples/'bench_stride.memory.json'
            raw=json.loads(p.read_text());raw['0x0000']=99;p.write_text(json.dumps(raw))
            with self.assertRaisesRegex(bench.BenchmarkError,'expectativa JSON'):
                bench.prepare_oracle('stride',examples)

    def test_14_modified_random_pattern_rejected(self):
        """Copia aleatorio y desplaza solo su primer store cuatro bytes: espera patrón.

        La fuente sigue ensamblando; se detecta la dirección distinta, no sintaxis
        inválida, sin modificar el LCG ni las expectativas canónicas.
        """
        with tempfile.TemporaryDirectory() as d:
            examples=self.fixture_copy(d);p=examples/'bench_aleatorio.asm'
            old=p.read_text();self.assertIn('guardap x20,x4,256',old)
            p.write_text(old.replace('guardap x20,x4,256','guardap x20,x4,260',1))
            assemble_source(p.read_text())
            with self.assertRaisesRegex(bench.BenchmarkError,'patrón aleatorio'):
                bench.prepare_oracle('aleatorio',examples)

    def test_15_modified_stride_rejected(self):
        """Cambia una base del stride en copia válida: espera rechazo patrón stride.

        Detecta que el programa ya no recorre las direcciones declaradas aun si
        todos los accesos siguen alineados y dentro de memoria.
        """
        with tempfile.TemporaryDirectory() as d:
            examples=self.fixture_copy(d);p=examples/'bench_stride.asm'
            p.write_text(p.read_text().replace('sumai x20,x0,2 |','sumai x20,x0,3 |',1))
            assemble_source(p.read_text())
            with self.assertRaisesRegex(bench.BenchmarkError,'patrón stride'):
                bench.prepare_oracle('stride',examples)

    def test_16_n_plus_three_violation_rejected(self):
        """Retira un NOP entre productor y shift en copia: espera RAW del ensamblador.

        Detecta una planificación demasiado corta; no se ejecuta un programa
        inválido ni se amplía CYCLES para compensar lecturas prematuras.
        """
        with tempfile.TemporaryDirectory() as d:
            examples=self.fixture_copy(d);p=examples/'bench_secuencial.asm'
            old=p.read_text();p.write_text(old.replace('nop | nop | nop | nop\ncizqi', 'cizqi',1))
            with self.assertRaisesRegex(AssemblyError,'RAW'):
                bench.prepare_oracle('secuencial',examples)

    def test_17_capacity_rejected(self):
        """Prepara 1021 NOP válidos en copia: exige límite del runner antes de RTL.

        Aísla la reserva de cuatro bundles; IMEM física acepta1024 pero el flujo
        no puede usar ese margen como código útil ni truncar silenciosamente.
        """
        with tempfile.TemporaryDirectory() as d:
            examples=self.fixture_copy(d)
            (examples/'bench_secuencial.asm').write_text('nop | nop | nop | nop\n'*1021)
            with self.assertRaisesRegex(bench.BenchmarkError,'capacidad IMEM'):
                bench.prepare_oracle('secuencial',examples)


@unittest.skipUnless(HAVE_ICARUS,'requiere iverilog y vvp; un skip no valida RTL')
class RealBenchmarksTests(unittest.TestCase):
    """Dos rondas reales y mutaciones de salidas conservadas, sin tocar el DUT."""

    @classmethod
    def setUpClass(cls):
        """Reserva evidencia externa nueva y ejecuta las doce elaboraciones reales.

        P29_EVIDENCE_DIR conserva recursos; sin ella ExitStack posee temporales.
        Un error de preparación hace fallar la suite y nunca cuenta como negativo.
        """
        cls.owner=contextlib.ExitStack()
        try:
            requested=os.environ.get('P29_EVIDENCE_DIR')
            cls.work=Path(requested).resolve() if requested else Path(cls.owner.enter_context(tempfile.TemporaryDirectory(prefix='p29-tests-')))
            if cls.work == ROOT or ROOT in cls.work.parents:raise ValueError('evidencia externa requerida')
            if requested:cls.work.mkdir(parents=True,exist_ok=False)
            cls.report=bench.run_benchmarks(cls.work/'positive',repetitions=2)
            cls.plans={n:bench.prepare_oracle(n) for n in bench.NAMES}
            cls.seed=cls.work/'positive/01-secuencial/mode-2'
            cls.serial=0
            cls.negatives=[]
        except Exception:
            cls.owner.close()
            raise

    @classmethod
    def tearDownClass(cls):
        """Cierra solo temporales propios; destinos persistentes quedan para auditoría."""
        cls.owner.close()

    def mutant(self, label):
        """Copia evidencia real válida a destino único y devuelve su ruta.

        Las mutaciones del caso no tocan gold ni productores. Propaga errores de
        copia como infraestructura, sin convertirlos en detecciones nominales.
        """
        type(self).serial+=1
        out=self.work/f'negative-{self.serial:02d}-{label}'
        shutil.copytree(self.seed,out)
        return out

    def detected(self, name, directory, reason):
        """Registra una detección tras la aserción específica, en JSON externo.

        No decide PASS ni captura excepciones: el caso ya verificó la causa. La
        evidencia permite revisar mutación y salidas sin escribir en producción.
        """
        self.negatives.append(dict(name=name,directory=str(directory),reason=reason))
        (self.work/'negative-results.json').write_text(json.dumps(self.negatives,indent=2)+'\n')

    def test_01_complete_architecture_both_real_modes(self):
        """Relee los seis estados de la primera ronda y compara todo GPR/DMEM.

        Ambas configuraciones se acreditan con sus marcadores reales; igualdad
        entre modos no reemplaza los oráculos completos dentro del lector.
        """
        for name,p in self.plans.items():
            states=[bench.read_capture(self.work/f'positive/01-{name}/mode-{m}',m,p) for m in (0,2)]
            bench.compare_captures(*states)
            for state in states:
                self.assertEqual(state.registers,p.registers)
                self.assertEqual(state.memory,p.memory)
                self.assertEqual(len(state.memory),16384)
                self.assertEqual(len(state.registers),32)

    def test_02_same_image_new_bins_and_repeatable_stats(self):
        """Contrasta dos rondas reales: mismas imágenes/medidas, rutas distintas.

        Detecta diferencias de estímulo y reutilización accidental de destinos;
        el hash del binario no se toma como prueba de equivalencia arquitectónica.
        """
        for name,p in self.plans.items():
            for mode in (0,2):
                a=bench.read_capture(self.work/f'positive/01-{name}/mode-{mode}',mode,p)
                b=bench.read_capture(self.work/f'positive/02-{name}/mode-{mode}',mode,p)
                self.assertEqual(a.stats,b.stats)
                self.assertEqual(a.image,b.image)
                self.assertNotEqual(a.directory,b.directory)

    def test_03_csv_json_integrity_and_counts(self):
        """Lee CSV/JSON publicados y espera doce filas concordantes con capturas.

        Verifica población96 y E=A+S; F queda separado, sin inventar contadores L2
        o significancia estadística a partir de dos repeticiones deterministas.
        """
        folder=self.work/'positive'
        report=json.loads((folder/'summary.json').read_text())
        bench.validate_report(report['rows'],2)
        with (folder/'summary.csv').open(newline='') as f:rows=list(csv.DictReader(f))
        self.assertEqual(len(rows),12)
        for a,b in zip(rows,report['rows']):self.assertEqual(a,{k:str(v) for k,v in b.items()})
        self.assertEqual(report['l2'],'MODEL')
        for row in report['rows']:
            p=self.plans[row['benchmark']]
            state=bench.read_capture(Path(row['directory']),row['mode'],p)
            self.assertEqual(row,bench.report_row(p,state,row['repetition']))

    def test_04_observed_stride_waits(self):
        """Compara esperas reales por patrón con población/corte iguales.

        Exige stall positivo en stride y mayor que secuencial; detecta que no se
        ejercitó la jerarquía prevista. No afirma un número de misses ni L2 real.
        """
        rows={r['benchmark']:r for r in self.report['rows'] if r['mode']==2 and r['repetition']==1}
        self.assertGreater(rows['stride']['stalls'],0)
        self.assertGreater(rows['stride']['stalls'],rows['secuencial']['stalls'])

    def test_05_incorrect_register_rejected(self):
        """Muta x31, ajeno al resultado útil, en copia real: exige oráculo GPR x31.

        Detecta cobertura completa y no solo checksum; el dump sigue siendo válido
        en estructura y el fallo no depende de ausencia de archivos.
        """
        out=self.mutant('register')
        p=out/'registers.txt';p.write_text(p.read_text().replace('x31 00000000','x31 00000001'))
        with self.assertRaisesRegex(bench.BenchmarkError,'oráculo GPR x31'):bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('registro',out,'oráculo GPR x31')

    def test_06_incorrect_memory_rejected(self):
        """Muta la última palabra, fuera de los32 stores: exige oráculo DMEM0xfffc.

        Detecta comparación de 65536 bytes y corrupción compartible entre modos;
        no altera el JSON esperado ni requiere una diferencia en datos útiles.
        """
        out=self.mutant('memory');p=out/'memory.txt';words=p.read_text().splitlines();words[-1]='12345678';p.write_text('\n'.join(words)+'\n')
        with self.assertRaisesRegex(bench.BenchmarkError,'oráculo DMEM 0xfffc'):bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('palabra',out,'oráculo DMEM 0xfffc')

    def test_07_different_image_rejected(self):
        """Cambia un dígito del program.mem copiado: exige imagen distinta.

        Aísla comparación de bytes antes de hashes o dumps; los archivos restantes
        son válidos y proceden de hardware, no de un compilador ausente.
        """
        out=self.mutant('image');p=out/'program.mem';data=bytearray(p.read_bytes());data[0]=ord('1');p.write_bytes(data)
        with self.assertRaisesRegex(bench.BenchmarkError,'imagen de programa distinta'):bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('imagen',out,'imagen de programa distinta')

    def test_08_truncated_dump_rejected(self):
        """Retira una palabra del dump válido: exige DMEM truncado antes de zip.

        Detecta comparación silenciosa de prefijos; no acepta OSError como prueba
        de truncamiento y conserva todas las otras evidencias de procedencia.
        """
        out=self.mutant('truncated');p=out/'memory.txt';p.write_text('\n'.join(p.read_text().splitlines()[:-1])+'\n')
        with self.assertRaisesRegex(bench.BenchmarkError,'dump DMEM truncado'):bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('truncado',out,'dump DMEM truncado')

    def test_09_wrong_mode_marker_rejected(self):
        """Cambia solo MEM_MODE del log real a 0: exige modo de memoria distinto.

        Comprueba elaboración acreditada, aunque los estados sean iguales; no
        hace fallar Icarus ni modifica parámetros del RTL para fabricar el error.
        """
        out=self.mutant('mode');p=out/'sim.log';p.write_text(p.read_text().replace('[MEM_MODE] solicitado=2 efectivo=2','[MEM_MODE] solicitado=0 efectivo=0'))
        with self.assertRaisesRegex(bench.runner.SimulationError,'modo de memoria distinto'):bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('modo',out,'modo de memoria distinto')

    def test_10_absent_flush_marker_rejected(self):
        """Retira FLUSH de stdout real: exige marcador FLUSH ausente.

        Los dumps permanecen completos, para que el rechazo acredite protocolo
        en vez de un error de infraestructura o una captura vacía.
        """
        out=self.mutant('flush');p=out/'sim.log';p.write_text('\n'.join(s for s in p.read_text().splitlines() if not s.startswith('[FLUSH]'))+'\n')
        with self.assertRaisesRegex(bench.runner.SimulationError,r'marcador \[FLUSH\]'):bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('flush',out,'marcador FLUSH ausente')

    def test_11_incoherent_statistics_rejected(self):
        """Incrementa stalls sin flancos en el log: exige estadísticas incoherentes.

        Comprueba E=A+S antes de comparar CSV; no cuenta flancos de mantenimiento
        como stalls ni usa la duración de pared para obtener la expectativa.
        """
        out=self.mutant('stats');p=out/'sim.log';p.write_text(p.read_text().replace('stalls=0 flush=','stalls=1 flush=',1))
        with self.assertRaisesRegex(bench.runner.SimulationError,'estadísticas'):bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('estadística',out,'estadísticas incoherentes')

    def test_12_stale_output_rejected(self):
        """Antigua memory.txt artificialmente y presenta frontera nueva: exige obsoleta.

        Todos los bytes siguen válidos; se detecta frescura, no corrección de datos.
        execute_mode también debe rechazar el destino existente antes de simular.
        """
        out=self.mutant('stale');os.utime(out/'memory.txt',ns=(1,1))
        with self.assertRaisesRegex(bench.BenchmarkError,'obsoleta: memory.txt'):bench.read_capture(out,2,self.plans['secuencial'],2)
        with self.assertRaisesRegex(bench.BenchmarkError,'destino obsoleto'):bench.execute_mode(self.plans['secuencial'],out,2)
        self.detected('salida-obsoleta',out,'obsoleta: memory.txt; destino obsoleto')

    def test_13_wrong_write_order_and_byte_mask(self):
        """Invierte dos stores y altera una máscara en copias de traza real.

        Exige error de orden/dato/máscara, sin cambiar el estado final: comparar
        solo memoria podría aprobar escrituras reordenadas o parciales indebidas.
        """
        for kind in ('order','byte'):
            out=self.mutant(kind);p=out/'trace_raw.txt';lines=p.read_text().splitlines();indices=[i for i,s in enumerate(lines) if ' MEM ' in s]
            if kind=='order':lines[indices[0]],lines[indices[1]]=lines[indices[1]],lines[indices[0]]
            else:lines[indices[0]]=lines[indices[0]][:-4]+'0001'
            p.write_text('\n'.join(lines)+'\n')
            with self.assertRaisesRegex(bench.BenchmarkError,'orden/dato/máscara'):bench.read_capture(out,2,self.plans['secuencial'])
            self.detected('traza-'+kind,out,'orden/dato/máscara')

    def test_14_wrong_load_value_rejected(self):
        """Muta el primer dato REG de x5: exige datos u orden de cargas incorrecto.

        Detecta una lectura mala aun si otra escritura posterior restaurara el
        registro final; la referencia sigue siendo1..32 dos veces.
        """
        out=self.mutant('load');p=out/'trace_raw.txt';lines=p.read_text().splitlines()
        i=next(i for i,s in enumerate(lines) if len(s.split())==6 and s.split()[1]=='REG' and s.split()[3]=='5')
        parts=lines[i].split();parts[-1]='deadbeef';lines[i]=' '.join(parts);p.write_text('\n'.join(lines)+'\n')
        with self.assertRaisesRegex(bench.BenchmarkError,'datos u orden de cargas'):bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('dato-carga',out,'datos u orden de cargas')

    def test_15_compare_all_fields_and_wrong_expectation(self):
        """Muta objetos capturados completos: exige imagen/GPR/DMEM incompatibles.

        Distingue errores del comparador de rechazos de archivos; omitir el último
        elemento debe fallar, y un gold incorrecto también falla aunque modos igualen.
        """
        p=self.plans['secuencial']
        a=bench.read_capture(self.work/'positive/01-secuencial/mode-0',0,p);b=bench.read_capture(self.seed,2,p)
        for mutant,reason in [(replace(b,image=b.image+b'0'),'imágenes'),(replace(b,registers=b.registers[:-1]),'GPR'),(replace(b,memory=b.memory[:-1]),'DMEM')]:
            with self.assertRaisesRegex(bench.BenchmarkError,reason):bench.compare_captures(a,mutant)
        bad=list(p.registers);bad[31]=1
        with self.assertRaisesRegex(bench.BenchmarkError,'oráculo GPR x31'):bench.read_capture(self.seed,2,replace(p,registers=tuple(bad)))

    def test_16_bad_report_counts_rejected(self):
        """Copia filas válidas y cambia accesos/flancos o duplica una fila.

        Exige la aserción de conteos/esquema antes de publicar resultados; ninguna
        excepción de lectura, compilación o infraestructura puede aprobar el caso.
        """
        for field in ('accesses','logical_bytes','execution_edges','stalls','maintenance_edges','span_bytes','lines','sets'):
            rows=copy.deepcopy(self.report['rows']);rows[0][field]+=1
            with self.assertRaisesRegex(bench.BenchmarkError,'conteos o estadísticas'):bench.validate_report(rows,2)
        rows=copy.deepcopy(self.report['rows']);rows[-1]=rows[0]
        with self.assertRaisesRegex(bench.BenchmarkError,'incompleto o duplicado'):bench.validate_report(rows,2)

    def test_17_cli_exit_summary_and_existing_destination(self):
        """Ejecuta CLI real en destino nuevo y luego intenta reutilizarlo.

        Primera llamada debe producir seis PASS y código0; segunda retorna1 y no
        cambia summary.json. Detecta publicación de resultados viejos como nuevos.
        """
        out=self.work/'cli';cmd=[sys.executable,str(ROOT/'tools/run_memory_benchmarks.py'),'--output',str(out)]
        result=subprocess.run(cmd,capture_output=True,text=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),timeout=60)
        (self.work/'cli.log').write_text(result.stdout+result.stderr)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(result.stdout.count('[PASS]'),6)
        original=(out/'summary.json').read_bytes()
        again=subprocess.run(cmd,capture_output=True,text=True,timeout=10)
        self.assertEqual(again.returncode,1)
        self.assertEqual((out/'summary.json').read_bytes(),original)

    def test_18_cache_configuration_marker_rejected(self):
        """Cambia EXCLUSIVE por NINE en el log copiado: exige CACHE_CONFIG inválido.

        Detecta configuración no acreditada aun con modo2 y datos correctos;
        no modifica la caché ni hace fallar la compilación para aprobar el control.
        """
        out=self.mutant('configuration');p=out/'sim.log'
        p.write_text(p.read_text().replace('inclusion=EXCLUSIVE','inclusion=NINE'))
        with self.assertRaisesRegex(bench.runner.SimulationError,r'marcador \[CACHE_CONFIG\]'):
            bench.read_capture(out,2,self.plans['secuencial'])
        self.detected('configuración',out,'marcador CACHE_CONFIG inválido')


if __name__ == '__main__':
    unittest.main()
