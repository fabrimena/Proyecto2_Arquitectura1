"""Contratos #31 y contraste real contra balc/M2/RTL, sin niveles ficticios.

CE1108_ROOT habilita las pruebas de integración en destinos temporales externos.
Los negativos verifican procedencia, observables y ausencia de ASM productivo;
no cuentan un timeout o un compilador ausente como detección satisfactoria.
"""
import copy
import contextlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from tools import comparar_optimizaciones as o


class VariantTests(unittest.TestCase):
    """Valida contratos de variantes con referencias sintéticas identificadas como pruebas de Python."""
    def seed(self):
        """Referencia de contrato puro; estos hashes sintéticos no acreditan RTL."""
        return [dict(level='a',image_sha256='1',observations_sha256='x'),
                dict(level='b',image_sha256='2',observations_sha256='x')]

    def test_distinct_images_same_observables(self):
        """Acepta dos registros de contrato con imágenes distintas e iguales observables; no acredita RTL."""
        o.validate_variants(self.seed())

    def test_identical_images_not_levels(self):
        """Repite la imagen con otra etiqueta; exige rechazo de niveles ficticios."""
        data=self.seed();data[1]['image_sha256']='1'
        with self.assertRaisesRegex(o.r.SimulationError,'imágenes idénticas'):o.validate_variants(data)

    def test_duplicate_level(self):
        """Repite el nombre de nivel; exige identidad única en el manifiesto."""
        data=self.seed();data[1]['level']='a'
        with self.assertRaisesRegex(o.r.SimulationError,'duplicados'):o.validate_variants(data)

    def test_different_observables(self):
        """Cambia la referencia semántica de una variante; impide comparar resultados distintos."""
        data=self.seed();data[1]['observations_sha256']='z'
        with self.assertRaisesRegex(o.r.SimulationError,'observables semánticos'):o.validate_variants(data)

    def test_no_levels(self):
        """Entrega una lista vacía; exige al menos una variante real declarada."""
        with self.assertRaisesRegex(o.r.SimulationError,'ausentes'):o.validate_variants([])

    def test_single_level_allowed_partial(self):
        # Validar una referencia es útil, pero run debe publicarla como PARCIAL.
        """Permite validar una referencia única; su publicación debe permanecer parcial."""
        o.validate_variants(self.seed()[:1])


@unittest.skipUnless(os.environ.get('CE1108_ROOT'),'requiere CE1108_ROOT; skip no acredita integración')
class CompilerTests(unittest.TestCase):
    """Contrasta balc real y M2 con RTL0/2 y aplica negativos a copias independientes."""
    @classmethod
    def setUpClass(cls):
        """Prepara ejecuciones reales nuevas fuera del repositorio; una falla de preparación no cuenta como negativo."""
        cls.owner=contextlib.ExitStack()
        requested=os.environ.get('P31_EVIDENCE_DIR')
        cls.work=Path(requested).resolve() if requested else Path(cls.owner.enter_context(tempfile.TemporaryDirectory(prefix='p31-tests-')))
        if requested:cls.work.mkdir(parents=True,exist_ok=False)
        cls.manifest=o.baseline_manifest(Path(os.environ['CE1108_ROOT']))
        cls.path=cls.work/'manifest.json';cls.path.write_text(json.dumps(cls.manifest))
        cls.report=o.run(cls.path,cls.work/'positive')

    @classmethod
    def tearDownClass(cls):
        """Libera solo temporales propios; los destinos explícitos de evidencia se conservan."""
        cls.owner.close()

    def test_three_real_baselines_two_modes(self):
        """Revisa seis ejecuciones balc/M2/RTL; espera estado parcial y ausencia de porcentajes inventados."""
        self.assertEqual(len(self.report['rows']),6)
        self.assertTrue(self.report['status'].startswith('PARCIAL'))
        for program in self.report['programs']:
            variant=program['variants'][0]
            self.assertIsNone(variant['cycle_change_percent'])
            self.assertEqual(variant['compiler_commit'],self.manifest['compiler_commit'])
            self.assertGreater(variant['bundles_static'],0)

    def test_known_semantic_results(self):
        # Los oráculos previos son 120,21,37, además de los estados M2 completos.
        """Relee memoria de ambos modos; verifica los observables BAL previos 120,21,37."""
        for index,program in enumerate(self.manifest['programs']):
            for mode in (0,2):
                memory=(self.work/f'positive/{program["name"]}-0/mode-{mode}/memory.txt').read_text().splitlines()
                for a,v in program['observations'].items():self.assertEqual(int(memory[int(a,0)//4],16),v)

    def test_wrong_compiler_commit(self):
        """Declara otro SHA de compilador; exige rechazo antes de publicar el experimento."""
        manifest=copy.deepcopy(self.manifest);manifest['compiler_commit']='0'*40
        path=self.work/'wrong-commit.json';path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(o.r.SimulationError,'commit de compilador'):o.run(path,self.work/'wrong-commit')

    def test_ir_option_not_productive_level(self):
        # --dce sí existe, pero solo reporta IR. No debe aceptarse como ASM
        # optimizado ni reutilizarse el binario de la ejecución positiva.
        """Ejecuta --dce real; espera ausencia de ASM productivo, sin reutilizar salidas previas."""
        manifest=copy.deepcopy(self.manifest);manifest['programs']=manifest['programs'][:1]
        manifest['programs'][0]['variants'][0]['argv']=['{compiler}','--dce','{source}']
        path=self.work/'ir.json';path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(o.r.SimulationError,'no produce ASM/binario real'):o.run(path,self.work/'ir')

    def test_wrong_semantic_oracle(self):
        """Cambia factorial esperado a119; exige discrepancia semántica con M2 antes de medir RTL."""
        manifest=copy.deepcopy(self.manifest);manifest['programs']=manifest['programs'][:1]
        manifest['programs'][0]['observations']['0xfff8']=119
        path=self.work/'oracle.json';path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(o.r.SimulationError,'oráculo semántico incorrecto'):o.run(path,self.work/'oracle')

    def test_existing_output_rejected(self):
        """Intenta reutilizar evidencia positiva; exige destino nuevo sin sobrescribir datos."""
        with self.assertRaisesRegex(o.r.SimulationError,'externo NUEVO'):o.run(self.path,self.work/'positive')

if __name__=='__main__':unittest.main()
