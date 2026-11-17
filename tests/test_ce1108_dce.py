"""Acredita el DCE productivo del IDE, sin llamarlo nivel -O ni cambiar CE1108.

CE1108_ROOT habilita el productor real. Los casos dirigidos conservan valores
semánticos, permiten marcos diferentes y comparan cada variante contra M2/RTL.
Los cortes proceden de B5 sobre las imágenes actuales, no de restar bundles.
"""
import contextlib
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest

from tools import ce1108_dce as d, comparar_optimizaciones as o


class DestinationTests(unittest.TestCase):
    """Valida límites de escritura sin ejecutar el productor ni crear archivos."""
    def test_build_rejects_compiler_tree(self):
        """Prepara raíz como destino; solicita build; exige rechazo; protege CE1108; detecta salida interna."""
        with self.assertRaisesRegex(o.r.SimulationError,'externo'):d.build(Path('/tmp/fake-ce'),Path('/tmp/fake-ce'))

    def test_apply_rejects_architecture_tree(self):
        """Prepara destino versionado; solicita DCE; exige rechazo previo; protege Arquitectura; detecta ruta invasiva."""
        with self.assertRaisesRegex(o.r.SimulationError,'captura externa'):
            d.apply(Path('/missing'),Path('/missing'),o.r.ROOT/'source.bal',o.r.ROOT)


@unittest.skipUnless(os.environ.get('CE1108_ROOT'),'requiere CE1108_ROOT; skip no acredita productor')
class ProductiveTests(unittest.TestCase):
    """El productor se compila nuevo y cada imagen se ejecuta en M2 y RTL0/2."""
    @classmethod
    def setUpClass(cls):
        """Prepara manifiesto externo y corre cuatro variantes reales; ningún fallo de setup cuenta como negativo."""
        cls.owner=contextlib.ExitStack()
        requested=os.environ.get('P31_DCE_EVIDENCE_DIR')
        cls.work=Path(requested).resolve() if requested else Path(cls.owner.enter_context(tempfile.TemporaryDirectory(prefix='dce-productive-')))
        if requested:cls.work.mkdir(parents=True,exist_ok=False)
        cls.root=Path(os.environ['CE1108_ROOT']).resolve()
        cls.data=d.comparison_manifest(cls.root);cls.path=cls.work/'manifest.json'
        cls.path.write_text(json.dumps(cls.data,indent=2)+'\n')
        cls.report=o.run(cls.path,cls.work/'positive')

    @classmethod
    def tearDownClass(cls):
        """Libera solo destinos temporales propios; conserva la evidencia persistente solicitada."""
        cls.owner.close()

    def test_eight_real_executions(self):
        """Lee cuatro variantes; exige ocho RTL y cuatro M2 válidos; acredita producción; detecta IR como binario."""
        self.assertEqual(len(self.report['rows']),8)
        self.assertEqual(self.report['status'],'COMPARACIÓN DE VARIANTES VALIDADA')
        for program in self.report['programs']:
            self.assertEqual(len(program['variants']),2)
            before,after=program['variants']
            self.assertNotEqual(before['image_sha256'],after['image_sha256'])
            self.assertEqual(after['transformation']['producer'],'ide_dce_analizar')
            self.assertTrue(after['transform_producer']['modules_sha256'])

    def test_static_counts_from_actual_images(self):
        """Cuenta imágenes emitidas; espera801/795 y528/435; acredita DCE real; detecta etiquetas sin cambios."""
        expected={'puntajes':[801,795],'dce_funciones':[528,435]}
        for program in self.report['programs']:
            self.assertEqual([v['bundles_static'] for v in program['variants']],expected[program['program']])

    def test_semantic_results_with_different_frames(self):
        """Relee DMEM0/2 con mapas por variante; exige24/13/37 y16/15; permite marcos; detecta dirección vieja."""
        for program in self.data['programs']:
            for index,variant in enumerate(program['variants']):
                for mode in (0,2):
                    words=(self.work/f'positive/{program["name"]}-{index}/mode-{mode}/memory.txt').read_text().splitlines()
                    self.assertEqual(len(words),16384)
                    for name,value in program['semantic_observations'].items():
                        self.assertEqual(int(words[int(variant['observation_addresses'][name],0)//4],16),value)

    def test_own_cuts_not_baseline_reuse(self):
        """Lee cortes declarados; exige2748/2742 y6193/2176; conserva punto B5; detecta horizonte copiado."""
        self.assertEqual([[v['horizon'] for v in p['variants']] for p in self.report['programs']],[[2748,2742],[6193,2176]])

    def test_factorial_dce_copy_is_not_another_level(self):
        """Transforma factorial real sin cambios; exige rechazo específico; evita fabricar otra variante."""
        work=self.work/'unchanged';work.mkdir();source=work/'input.bal'
        source.write_bytes((self.root/'examples/factorial.bal').read_bytes())
        with self.assertRaisesRegex(o.r.SimulationError,'variante distinta'):
            d.apply(self.work/'positive/aplicar_dce',source,work/'output.bal',work)

    def test_wrong_semantic_address(self):
        """Desplaza resultado a palabra cero; ejecuta M2; exige oráculo incorrecto; detecta mapa de marco erróneo."""
        data=copy.deepcopy(self.data);data['programs']=data['programs'][:1]
        data['programs'][0]['variants']=data['programs'][0]['variants'][:1]
        data['programs'][0]['variants'][0]['observation_addresses']['resultado']='0x0'
        path=self.work/'wrong-address.json';path.write_text(json.dumps(data))
        with self.assertRaisesRegex(o.r.SimulationError,'oráculo semántico incorrecto'):
            o.run(path,self.work/'wrong-address')


if __name__=='__main__':unittest.main()
