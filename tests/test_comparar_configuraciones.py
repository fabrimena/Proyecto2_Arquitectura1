"""Contrastes #30: contratos puros y mutaciones específicas de evidencia RTL real.

La semilla se genera de nuevo fuera del repositorio. Cada negativo conserva los
archivos nominales y altera una sola propiedad, exigiendo su diagnóstico. Ningún
fallo de Icarus, timeout o archivo ausente puede aprobar un control de datos.
"""
import copy
import contextlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from tools import comparar_configuraciones as c
from tools import perf_report as p


class ContractTests(unittest.TestCase):
    """Valida dimensiones, dominios y denominadores sin depender del simulador."""
    def test_matrix_one_dimension(self):
        # Cada par debe cambiar exactamente los campos autorizados; detectar una
        # política adicional evita atribuir sus ciclos a otra variable.
        """Compara los parámetros normalizados de cada par; espera solo su dimensión declarada."""
        for a,b,fields in c.PAIRS:
            x,y=p.configuration(c.CASES[a]),p.configuration(c.CASES[b])
            self.assertEqual({k for k in x if x[k]!=y[k]},fields)

    def test_illegal_policy(self):
        # WT con exclusiva se rechaza antes de elaborar o truncar parámetros.
        """Solicita WT con exclusiva; espera rechazo antes de cualquier elaboración RTL."""
        with self.assertRaisesRegex(ValueError,'política prohibida'):
            p.configuration({'WRITE_POLICY':0})

    def test_parameters_not_truncated(self):
        # Tipos Python bool y valores fuera del ancho no deben convertirse en
        # políticas legales por el truncamiento de logic del RTL.
        """Prueba tipos y códigos fuera de contrato; evita que el ancho RTL o bool los normalicen."""
        for key,value in [('N_MSHR',0),('L2_MODEL',2),('MEM_DIV',True),('L1_REPL_POLICY',3),('XX',0)]:
            with self.subTest(key=key),self.assertRaises(ValueError):p.configuration({key:value})

    def test_blocking_rejects_provisional_model(self):
        # Un summary del modelo siempre-hit no puede representar una L2
        # bloqueante real, aunque sus cifras de duración parezcan plausibles.
        """Presenta un reporte MODEL; exige rechazo como referencia bloqueante real."""
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'summary.json';path.write_text('{"l2":"MODEL"}')
            with self.assertRaisesRegex(c.b.BenchmarkError,'no es L2 REAL'):
                c.blocking_contrasts({'repetitions':2},path)

    def test_zero_population(self):
        # Una ventana sin ciclos no produce IPC definido, ni una tasa cero falsa.
        """Comprueba cociente conocido y denominador cero; espera None para población vacía."""
        self.assertIsNone(p.ratio(0,0));self.assertEqual(p.ratio(6,3),2)


@unittest.skipUnless(shutil.which('iverilog') and shutil.which('vvp'),'requiere Icarus')
class EvidenceTests(unittest.TestCase):
    """Usa capturas reales nuevas para probar lectura, procedencia y mutaciones."""
    @classmethod
    def setUpClass(cls):
        """Prepara ejecuciones reales nuevas fuera del repositorio; una falla de preparación no cuenta como negativo."""
        cls.owner=contextlib.ExitStack()
        requested=os.environ.get('P30_EVIDENCE_DIR')
        cls.work=Path(requested).resolve() if requested else Path(cls.owner.enter_context(tempfile.TemporaryDirectory(prefix='p30-tests-')))
        if requested:cls.work.mkdir(parents=True,exist_ok=False)
        cls.plan=c.b.prepare_oracle('secuencial')
        cls.state=c.b.execute_mode(cls.plan,cls.work/'real',2)
        cls.md=json.loads((cls.state.directory/'execution.json').read_text())
        cls.model=c.b.execute_mode(cls.plan,cls.work/'model',2,{'L2_MODEL':1})

    @classmethod
    def tearDownClass(cls):
        """Libera solo temporales propios; los destinos explícitos de evidencia se conservan."""
        cls.owner.close()

    @contextlib.contextmanager
    def folder(self):
        """Conserva cada mutación si se pidió evidencia; si no, posee su temporal."""
        if os.environ.get('P30_EVIDENCE_DIR'):
            yield tempfile.mkdtemp(prefix=self._testMethodName+'-',dir=self.work)
        else:
            with tempfile.TemporaryDirectory(dir=self.work) as directory:yield directory

    def mutate_log(self, old, new, diagnostic):
        """Copia la semilla y exige error del parser para una mutación comprobada."""
        with self.folder() as d:
            out=Path(d)/'capture';shutil.copytree(self.state.directory,out)
            path=out/'sim.log';text=path.read_text();self.assertIn(old,text)
            path.write_text(text.replace(old,new,1))
            with self.assertRaisesRegex(c.b.runner.SimulationError,diagnostic):
                c.b.read_capture(out,2,self.plan)

    def test_model_explicit_not_real(self):
        # El modelo mantiene arquitectura, pero no publica una L2/RAM inexistente.
        """Ejecuta MODEL con gold completo y rechaza leerlo como REAL; no atribuye eventos ficticios."""
        md=json.loads((self.model.directory/'execution.json').read_text())
        self.assertEqual(md['configuration']['L2_MODEL'],1)
        self.assertFalse(any(md['metrics']['l2']+md['metrics']['ram']))
        c.b.read_capture(self.model.directory,2,self.plan,configuration={'L2_MODEL':1})
        with self.assertRaisesRegex(c.b.runner.SimulationError,'configuración elaborada'):
            c.b.read_capture(self.model.directory,2,self.plan)

    def test_performance_disabled_preserves_architecture(self):
        # Elimina observadores al elaborar: la arquitectura y duración permanecen,
        # pero los cocientes sin población deben publicarse como None.
        """Elabora sin monitores y contrasta arquitectura/duración; espera acumulados cero e IPC no definido."""
        state=c.b.execute_mode(self.plan,self.work/'disabled',2,{'PERF_ENABLE':0})
        md=json.loads((state.directory/'execution.json').read_text())
        self.assertEqual(state.stats,self.state.stats)
        self.assertEqual(md['metrics']['vliw'],[0]*5)
        self.assertIsNone(md['metrics']['ipc'])
        self.assertFalse(any(md['metrics']['l1']+md['metrics']['l2']+md['metrics']['ram']))

    def test_empty_measurement_window(self):
        # Sin medir 0, el armado diferido no abre nunca la ventana. El procesador
        # ejecuta todo el benchmark y conserva gold, pero IPC queda no definido.
        """Ejecuta con armado que nunca se abre; espera gold correcto y ninguna observación acumulada."""
        out=self.work/'empty-window'
        c.b.runner.run_program(self.plan.source,out,dict(enumerate(self.plan.registers)),False,
            {4*k:v for k,v in enumerate(self.plan.memory)},self.plan.cycles,False,2,
            defer_measurement=True)
        md=json.loads((out/'execution.json').read_text())
        self.assertEqual(md['metrics']['vliw'],[0]*5)
        self.assertIsNone(md['metrics']['ipc'])
        self.assertEqual(md['stats'],self.md['stats'])

    def test_wrong_configuration(self):
        """Muta MSHR en el testimonio real; espera configuración elaborada distinta."""
        self.mutate_log('N_MSHR=2','N_MSHR=4','configuración elaborada')

    def test_real_model_confusion(self):
        """Renombra REAL como MODEL en una captura; exige rechazo del marcador de proveedor."""
        self.mutate_log('l2=REAL','l2=MODEL',r'marcador \[CACHE_CONFIG\]')

    def test_incompatible_counters(self):
        """Adultera bundles por encima de ciclos; exige la identidad VLIW concreta."""
        line=next(x for x in (self.state.directory/'sim.log').read_text().splitlines() if x.startswith('[PERF_VLIW]'))
        values=line.split();values[2]='999999'
        self.mutate_log(line,' '.join(values),'contadores VLIW incompatibles')

    def test_missing_flush(self):
        """Retira solo la confirmación de vaciado; dumps completos no pueden acreditar persistencia."""
        line=next(x for x in (self.state.directory/'sim.log').read_text().splitlines() if x.startswith('[FLUSH]'))
        self.mutate_log(line,'',r'marcador \[FLUSH\]')

    def test_incoherent_times(self):
        """Cambia mantenimiento sin su total; exige la identidad temporal, sin provocar un timeout."""
        value=self.md['stats']['mantenimiento_ns']
        self.mutate_log(f'mantenimiento_ns={value}',f'mantenimiento_ns={value+1}','estadísticas')

    def test_duplicate_marker(self):
        """Duplica la cabecera de L2; exige vector único y completo."""
        self.mutate_log('[PERF_L2]','[PERF_L2] 0\n[PERF_L2]','PERF_L2')

    def test_wrong_register(self):
        """Cambia x31 ajeno al checksum; exige oráculo completo de GPR."""
        with self.folder() as d:
            out=Path(d)/'capture';shutil.copytree(self.state.directory,out)
            path=out/'registers.txt';path.write_text(path.read_text().replace('x31 00000000','x31 00000001'))
            with self.assertRaisesRegex(c.b.BenchmarkError,'oráculo GPR x31'):c.b.read_capture(out,2,self.plan)

    def test_wrong_memory(self):
        """Cambia la última palabra fuera de datos útiles; exige comparación de toda DMEM."""
        with self.folder() as d:
            out=Path(d)/'capture';shutil.copytree(self.state.directory,out)
            path=out/'memory.txt';words=path.read_text().splitlines();words[-1]='ffffffff';path.write_text('\n'.join(words)+'\n')
            with self.assertRaisesRegex(c.b.BenchmarkError,'oráculo DMEM 0xfffc'):c.b.read_capture(out,2,self.plan)

    def test_stale_binary(self):
        """Modifica los bytes del binario conservando el resto; exige procedencia incoherente."""
        with self.folder() as d:
            out=Path(d)/'capture';shutil.copytree(self.state.directory,out)
            path=out/'sim.vvp';path.write_bytes(path.read_bytes()+b'\n')
            with self.assertRaisesRegex(c.b.BenchmarkError,'procedencia de elaboración'):c.b.read_capture(out,2,self.plan)

    def test_different_program_and_input(self):
        # Variaciones de imagen y entrada deben fallar aunque toda la memoria
        # final coincidiera. Se comprueban ambos hashes antes de comparar tasas.
        """Muta por separado hashes de imagen y entrada; rechaza mezclar experimentos."""
        for key in ('image_sha256','initial_memory_sha256'):
            a,b=copy.deepcopy(self.md),copy.deepcopy(self.md);b[key]='0'*64
            with self.assertRaisesRegex(c.b.BenchmarkError,key):c.validate_pair(a,b,set())

    def test_paused_or_distinct_window(self):
        """Muta corte o ciclos medidos; evita comparar una ventana pausada con otra activa."""
        for kind in ('paused','horizon'):
            a,b=copy.deepcopy(self.md),copy.deepcopy(self.md)
            if kind=='paused':b['metrics']['vliw'][0]-=1
            else:b['stats']['avances']+=1
            with self.assertRaisesRegex(c.b.BenchmarkError,'ventanas distintas'):c.validate_pair(a,b,set())

    def test_duplicate_report(self):
        """Parte de una cohorte válida y duplica una fila; exige diagnóstico de duplicación."""
        # Esta cohorte mínima es una fixture de estructura, no una medición RTL.
        # Primero debe ser aceptada; después solo se sustituye una fila por otra.
        rows=[dict(benchmark=n,repetition=1,configuration=k,cycles=872,stalls=0,
                   bundles=868,instructions=386,maintenance=653,ram_busy=212,ram_measured=872)
              for n in c.b.NAMES for k in c.CASES]
        c.validate_rows(rows,1)
        rows[-1]=rows[0]
        with self.assertRaisesRegex(c.b.BenchmarkError,'duplicado o incompleto'):
            c.validate_rows(rows,1)

if __name__=='__main__':unittest.main()
