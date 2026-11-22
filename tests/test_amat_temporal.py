"""Contrasta cálculos temporales con duraciones y poblaciones independientes.

Fixtures son datos dirigidos, nunca resultados de RTL. Los tests de elaboración
ejecutan el runner real en destinos nuevos; las demás pruebas no crean procesos.
Cada rechazo se exige por categoría para no aceptar fallos de infraestructura.
"""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import analizar_amat as a, perf_report as p, run_program as r


def cohort():
    """Prepara dos reads L2 de 8/13 y RAM read/write de 54; sin efectos externos."""
    l2 = [1, 1, 8, 13, 19, 0, 0, 0, 0, 2, 1, 1, 2, 0]
    ram = [1, 1, 54, 54, 106, 0, 0, 0, 0, 0, 0, 0, 0, 0,
           0, 0, 2, 2, 54, 1, 100, 154]
    return l2, ram


def log_fixture():
    """Genera formato histórico vacío y coherente; no representa una simulación."""
    lengths = dict(PERF_VLIW=5, PERF_L1=19, PERF_K1B=6, PERF_L2=10, PERF_RAM=6)
    lengths.update({'PERF_STAGE'+str(k):4 for k in range(4)})
    lengths.update({'PERF_CLASS'+str(k):3 for k in range(4)})
    return '\n'.join('['+name+']'+' 0'*size for name,size in lengths.items())+'\n'


class TemporalTests(unittest.TestCase):
    """Las mutaciones controladas deben fallar por su contrato concreto."""

    def test_known_weighted_l2(self):
        """Prepara 8/13; deriva media; espera10.5; acredita ponderación; detecta denominador ajeno."""
        result=p.temporal_metrics(*cohort(),True)['l2']
        self.assertEqual(result['amat_cycles'],10.5)
        self.assertEqual(result['amat_cycles'],result['hit_rate']*8+result['miss_rate']*13)
        self.assertIsNone(result['write_amat_cycles'])

    def test_ram_success_population(self):
        """Prepara dos éxitos54; deriva; espera54; separa read/write; detecta busy como duración."""
        result=p.temporal_metrics(*cohort(),True)['ram']
        self.assertEqual((result['accesses'],result['mean_cycles']),(2,54))
        self.assertEqual(result['read_mean_cycles'],54)
        self.assertEqual(result['write_mean_cycles'],54)
        self.assertIsNone(result['hit_rate'])

    def test_failure_not_in_success_mean(self):
        """Agrega fracaso513/2TO/1retry; deriva; éxito sigue54; separa cohortes; detecta contaminación."""
        l2,ram=cohort()
        ram[5:7]=[1,513];ram[10]=2;ram[12]=1;ram[16]=ram[17]=3
        ram[18:]=[513,1,200,713]
        result=p.temporal_metrics(l2,ram,True)['ram']
        self.assertEqual(result['mean_cycles'],54)
        self.assertEqual(result['failure_mean_cycles'],513)

    def test_retry_keeps_single_transaction(self):
        """Alarga read a300 con1TO; deriva; N sigue2; conserva retry; detecta aceptación duplicada."""
        l2,ram=cohort();ram[2]=300;ram[4]=352;ram[9]=ram[11]=1
        result=p.temporal_metrics(l2,ram,True)['ram']
        self.assertEqual(result['accesses'],2)
        self.assertEqual(result['mean_cycles'],177)
        self.assertEqual(result['success_retries'],1)

    def test_zero_population(self):
        """Prepara vectores cero; deriva; esperaNone; evita cero ficticio; detecta división por cero."""
        result=p.temporal_metrics([0]*14,[0]*22,True)
        self.assertIsNone(result['l2']['amat_cycles'])
        self.assertIsNone(result['ram']['mean_cycles'])

    def test_pending_and_pause(self):
        """Prepara pendientes excluidas por pausa; deriva; no media; conserva identidad; detecta final inventado."""
        l2=[0]*14;ram=[0]*22
        l2[7]=l2[8]=l2[9]=l2[13]=1;ram[14]=ram[16]=1
        result=p.temporal_metrics(l2,ram,True)
        self.assertEqual(result['l2']['pending_ineligible'],1)
        self.assertEqual(result['ram']['pending_eligible'],0)
        self.assertIsNone(result['ram']['mean_cycles'])

    def test_excluded_completions(self):
        """Añade finales excluidos; deriva; medias iguales; acredita ventanas; detecta denominador ampliado."""
        l2,ram=cohort();l2[5]=1;l2[9]+=1;l2[12]+=1
        ram[7]=1;ram[8]=1;ram[16]+=2;ram[17]+=2
        result=p.temporal_metrics(l2,ram,True)
        self.assertEqual(result['l2']['amat_cycles'],10.5)
        self.assertEqual(result['ram']['mean_cycles'],54)

    def test_bad_l2_time(self):
        """Muta servicio sin espera; analiza; exige tiempo L2 inválido; detecta off-by-one."""
        l2,ram=cohort();l2[2]+=1
        with self.assertRaisesRegex(ValueError,'población/tiempo L2'):p.temporal_metrics(l2,ram,True)

    def test_bad_l2_population(self):
        """Muta aceptación; analiza; exige población inválida; detecta denominador de L1 prestado."""
        l2,ram=cohort();l2[9]=96
        with self.assertRaisesRegex(ValueError,'población/tiempo L2'):p.temporal_metrics(l2,ram,True)

    def test_bad_classification(self):
        """Traslada count sin tiempo; analiza; exige clase vacía inválida; detecta hit/miss desalineados."""
        l2,ram=cohort();l2[0]=0;l2[1]=2
        with self.assertRaisesRegex(ValueError,'población/tiempo L2'):p.temporal_metrics(l2,ram,True)

    def test_bad_association(self):
        """Muta fecha final; analiza; exige fechas inválidas; detecta respuesta de otro acceso."""
        l2,ram=cohort();ram[21]+=1
        with self.assertRaisesRegex(ValueError,'fechas de transacción'):p.temporal_metrics(l2,ram,True)

    def test_duplicate_acceptance(self):
        """Duplica aceptación RAM sin pendiente; analiza; exige población inválida; detecta req contado por nivel."""
        l2,ram=cohort();ram[16]+=1
        with self.assertRaisesRegex(ValueError,'población/tiempo/reintento RAM'):p.temporal_metrics(l2,ram,True)

    def test_protocol_is_fatal(self):
        """Marca error L2/RAM por separado; analiza; exige protocolo inválido; impide publicar medias dudosas."""
        for level,index in ((0,6),(1,13)):
            vectors=cohort();vectors[level][index]=1
            with self.subTest(level=level),self.assertRaisesRegex(ValueError,'protocolo temporal'):
                p.temporal_metrics(*vectors,True)

    def test_failed_retry_contract(self):
        """Inventa retry sin timeout; analiza; exige contrato inválido; evita convertir fracaso en éxito."""
        l2,ram=cohort();ram[11]=1
        with self.assertRaisesRegex(ValueError,'reintento RAM'):p.temporal_metrics(l2,ram,True)

    def test_wrong_configuration(self):
        """Ofrece tiempos en modelo o PERF0; analiza; exige no real; detecta configuración equivocada."""
        with self.assertRaisesRegex(ValueError,'sin jerarquía real'):p.temporal_metrics(*cohort(),False)

    def test_types_and_width(self):
        """Muta ancho/tipo; analiza; exige rechazo; conserva unsigned64; detecta bool, negativos y overflow."""
        for value in (-1,True,1.5,1<<64):
            l2,ram=cohort();l2[0]=value
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,'forma/ancho'):
                p.temporal_metrics(l2,ram,True)

    def test_no_mutation(self):
        """Copia entrada; deriva; compara bytes lógicos; acredita pureza; detecta normalización destructiva."""
        vectors=cohort();before=copy.deepcopy(vectors)
        p.temporal_metrics(*vectors,True);self.assertEqual(vectors,before)

    def test_no_sum_of_overlapping_levels(self):
        """Prepara medias10.5/54; deriva; suma jerárquicaNone; evita doble cargo de servicio solapado."""
        result=p.temporal_metrics(*cohort(),True)
        self.assertIsNone(result['hierarchical_sum_cycles'])

    def test_actual_k1b_layout(self):
        """Prepara exclusiones3 y pendiente1; analiza layout real; acepta media1; detecta pendiente como error."""
        data=dict(vliw=[10],classes=[[1,1,0],[0,0,0],[0,0,0],[0,0,0]],k1b=[1,1,0,3,0,1])
        result=a.l1_amat(data,wire_layout=True)
        self.assertEqual(result['excluded_completions'],3)
        self.assertEqual(result['pending'],1)
        data['k1b'][4]=1
        with self.assertRaisesRegex(ValueError,'protocolo K1-B'):a.l1_amat(data,wire_layout=True)

    def test_legacy_log_stays_legacy(self):
        """Lee log sin extensión; parsea; no añade claves; preserva hashes semánticos de54 capturas antiguas."""
        result=p.metrics(log_fixture(),0,p.configuration())
        self.assertNotIn('temporal',result)

    def test_optional_pair_required(self):
        """Añade solo marcador L2; parsea; exige RAM ausente; impide degradación silenciosa a histórico."""
        with self.assertRaisesRegex(ValueError,'PERF_RAM_LATENCY'):
            p.metrics(log_fixture()+'[PERF_L2_LATENCY]'+' 0'*14+'\n',0,p.configuration())

    def test_optional_markers_unique(self):
        """Duplica marcador válido; parsea; exige duplicado; detecta dos capturas mezcladas."""
        suffix='[PERF_L2_LATENCY]'+' 0'*14+'\n[PERF_RAM_LATENCY]'+' 0'*22+'\n'
        with self.assertRaisesRegex(ValueError,'duplicado'):
            p.metrics(log_fixture()+suffix+suffix,0,p.configuration())

    def test_unavailable_is_not_zero_latency(self):
        """Añade extensión cero en modo0; parsea; availableFalse y mediaNone; detecta latencia cero fabricada."""
        suffix='[PERF_L2_LATENCY]'+' 0'*14+'\n[PERF_RAM_LATENCY]'+' 0'*22+'\n'
        result=p.metrics(log_fixture()+suffix,0,p.configuration())['temporal']
        self.assertFalse(result['available']);self.assertIsNone(result['ram']['mean_cycles'])

    def test_historical_control_not_recorded(self):
        """Prepara captura antigua sin control; analiza; esperaNone y PARCIAL; preserva ausencia; detecta inferencia inventada."""
        with tempfile.TemporaryDirectory(prefix='amat-legacy-control-') as work:
            work=Path(work);capture=work/'capture';capture.mkdir()
            md=dict(validation='PASS',stats=dict(bundles=1,avances=5),effective_mode=2,
                    configuration={'PERF_ENABLE':1},cut='fixture',
                    metrics=dict(vliw=[0],classes=[[0,0,0] for _ in range(4)],k1b=[0]*6))
            for file,key in [('program.mem','image_sha256'),('sim.vvp','binary_sha256')]:
                payload=('fixture:'+file).encode();(capture/file).write_bytes(payload)
                md[key]=hashlib.sha256(payload).hexdigest()
            (capture/'sim.log').write_text('fixture sin RTL\n')
            (capture/'execution.json').write_text(json.dumps(md))
            report=work/'report.json'
            report.write_text(json.dumps(dict(rows=[dict(benchmark='fixture',configuration='fixture',
                repetition=1,cycles=0,image_sha256=md['image_sha256'],directory=str(capture))])))
            with patch.object(a.runner,'execution_metadata',return_value=copy.deepcopy(md)):
                result=a.analyze(report,work/'out')
            self.assertIsNone(result['rows'][0]['measurement_control'])
            self.assertEqual(result['issue26_status'],'PARCIAL')


class ElaborationTests(unittest.TestCase):
    """Elabora RTL real en destinos nuevos y verifica modo/modelo/PERF efectivos."""

    def test_real_modes_and_observer_elimination(self):
        """Prepara aritmética sin memoria; ejecuta0/1/REAL/MODEL/PERF0; espera x1=7; detecta parámetros no propagados."""
        with tempfile.TemporaryDirectory(prefix='amat-elaboration-') as work:
            work=Path(work);source=work/'input.asm'
            source.write_text('sumai x1, x0, 7 | nop | nop | nop\n'+'nop | nop | nop | nop\n'*8)
            for index,(mode,cfg) in enumerate(((0,{}),(1,{}),(2,{}),(2,{'L2_MODEL':1}),(2,{'PERF_ENABLE':0}))):
                with self.subTest(mode=mode,cfg=cfg):
                    directory=work/str(index)
                    r.run_program(source,directory,{1:7},False,None,13,False,mode,cfg)
                    md=json.loads((directory/'execution.json').read_text())
                    self.assertEqual(md['effective_mode'],mode)
                    temporal=md['metrics']['temporal']
                    self.assertEqual(temporal['available'],mode==2 and not cfg)
                    self.assertIsNone(temporal['l2']['amat_cycles'])


if __name__=='__main__':unittest.main()
