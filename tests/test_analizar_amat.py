"""Verifica AMAT de cohortes L1 y procedencia sin ejecutar ni modificar hardware.

Los tiempos dirigidos son una referencia de cálculo, no medidas de rendimiento.
Los ensayos de archivos usan un testimonio sintético y un parser sustituido;
el parser RTL real se verifica en las regresiones previas y al analizar las54
capturas reales. Ningún valor de esta fixture se publica como simulación.
"""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import analizar_amat as a


def fixture_metrics():
    """Siete accesos conocidos: lecturas1,1,9,5 y stores1,1,1; total19 ciclos."""
    return dict(vliw=[30, 0, 0, 0, 0],
                classes=[[2, 2, 0], [2, 14, 12], [1, 1, 0], [2, 2, 0]],
                k1b=[7, 19, 12, 5, 0, 0], l1=[99, 99, 99, 99])


class MeanTests(unittest.TestCase):
    """Comprueba valores y ponderación contra duraciones independientes dirigidas."""

    def test_known_means_and_weighted_identity(self):
        """Espera19/7 global,4 lectura y1 store; contrasta HR×TH+MR×TM."""
        result = a.l1_amat(fixture_metrics())
        self.assertEqual(result['all']['amat_cycles'], 19 / 7)
        self.assertEqual(result['reads']['amat_cycles'], 4)
        self.assertEqual(result['writes']['amat_cycles'], 1)
        for name in ('all', 'reads', 'writes'):
            p = result[name]
            self.assertAlmostEqual(p['amat_cycles'],
                                   p['hit_rate'] * p['hit_mean_cycles'] +
                                   p['miss_rate'] * p['miss_mean_cycles'])

    def test_store_miss_is_not_ram_persistence(self):
        """Stores miss aceptados en1 ciclo siguen valiendo1, sin sumar Tmem53."""
        writes = a.l1_amat(fixture_metrics())['writes']
        self.assertEqual(writes['misses'], 2)
        self.assertEqual(writes['miss_mean_cycles'], 1)
        self.assertEqual(writes['service_cycles'], 3)

    def test_uses_completed_cohort_not_k1a(self):
        """K1-A contiene396 eventos ajenos a la cohorte; el denominador debe ser7."""
        data = fixture_metrics()
        data['k1b'][4] = 2
        result = a.l1_amat(data)
        self.assertEqual(result['all']['accesses'], 7)
        self.assertEqual(result['all']['amat_cycles'], 19 / 7)
        self.assertEqual(result['excluded_completions'], 2)

    def test_zero_window(self):
        """Sin acceso completo todas las medias y tasas quedan indefinidas."""
        result = a.l1_amat(dict(vliw=[0], classes=[[0, 0, 0] for _ in range(4)], k1b=[0] * 6))
        self.assertIsNone(result['all']['amat_cycles'])
        self.assertIsNone(result['all']['hit_rate'])
        self.assertIsNone(result['reads']['amat_cycles'])

    def test_only_misses(self):
        """Un miss observado de9 ciclos define AMAT9 aun sin media de hits."""
        result = a.l1_amat(dict(vliw=[9], classes=[[0, 0, 0], [1, 9, 8], [0, 0, 0], [0, 0, 0]],
                               k1b=[1, 9, 8, 0, 0, 0]))
        self.assertEqual(result['all']['amat_cycles'], 9)
        self.assertIsNone(result['all']['hit_mean_cycles'])

    def test_rejects_broken_cohorts_and_protocol(self):
        """Muta identidades, población vacía con tiempo y error de protocolo; exige rechazo."""
        for kind in ('sum', 'duration', 'window', 'empty', 'protocol'):
            data = fixture_metrics()
            if kind == 'sum':
                data['k1b'][0] += 1
            elif kind == 'duration':
                data['classes'][0][1] += 1
            elif kind == 'window':
                data['vliw'][0] = 18
            elif kind == 'empty':
                data['classes'][0] = [0, 2, 2]
            else:
                data['k1b'][5] = 1
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                a.l1_amat(data)

    def test_rejects_types_and_wrap(self):
        """Enteros negativos, bool, fracciones y valores fuera de64 bits no son medidas válidas."""
        for invalid in (-1, True, 1.5, 1 << 64):
            data = fixture_metrics()
            data['classes'][0][0] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                a.l1_amat(data)

    def test_does_not_modify_input(self):
        """Derivar conserva íntegro el objeto de entrada, incluidos otros contadores."""
        data = fixture_metrics()
        before = copy.deepcopy(data)
        a.l1_amat(data)
        self.assertEqual(data, before)


class CaptureTests(unittest.TestCase):
    """Ejercita lectura/publicación con fixtures explícitamente sintéticas."""

    def setUp(self):
        """Prepara archivos nuevos y hashes reales de bytes de fixture; no representa RTL."""
        self.owner = tempfile.TemporaryDirectory(prefix='amat-contract-')
        self.addCleanup(self.owner.cleanup)
        self.work = Path(self.owner.name)
        self.capture = self.work / 'capture'
        self.capture.mkdir()
        self.md = dict(validation='PASS', stats=dict(bundles=1, avances=5),
                       effective_mode=2, configuration={'PERF_ENABLE': 1},
                       metrics=fixture_metrics(), cut='fixture-cut', measurement_control='fixture-window')
        for name, key in [('program.mem', 'image_sha256'), ('sim.vvp', 'binary_sha256')]:
            payload = ('fixture:' + name).encode()
            (self.capture / name).write_bytes(payload)
            self.md[key] = hashlib.sha256(payload).hexdigest()
        (self.capture / 'sim.log').write_text('fixture: parser sustituido; no RTL\n')
        (self.capture / 'execution.json').write_text(json.dumps(self.md))
        self.row = dict(benchmark='fixture', configuration='fixture', repetition=1,
                        cycles=30, image_sha256=self.md['image_sha256'], directory=str(self.capture))
        self.report = self.work / 'report.json'
        self.report.write_text(json.dumps(dict(rows=[self.row])))
        self.parser = patch.object(a.runner, 'execution_metadata', return_value=copy.deepcopy(self.md))
        self.parser.start()
        self.addCleanup(self.parser.stop)

    def test_preserves_inputs_and_unavailable_metrics(self):
        """Publica derivado con L2/RAM null y PARCIAL; todos los archivos de entrada quedan iguales."""
        paths = [self.report, *self.capture.iterdir()]
        before = {str(p): p.read_bytes() for p in paths}
        result = a.analyze(self.report, self.work / 'out')
        self.assertEqual(result['issue26_status'], 'PARCIAL')
        self.assertIsNone(result['rows'][0]['l2_amat_cycles'])
        self.assertIsNone(result['rows'][0]['ram_amat_cycles'])
        self.assertIsNone(result['rows'][0]['hierarchical_amat_cycles'])
        self.assertEqual(before, {str(p): p.read_bytes() for p in paths})

    def test_rejects_reuse_and_duplicate(self):
        """Rechaza sobrescribir un destino o duplicar un ensayo sin crear un informe válido."""
        out = self.work / 'out'
        out.mkdir()
        with self.assertRaisesRegex(ValueError, 'NUEVO'):
            a.analyze(self.report, out)
        self.report.write_text(json.dumps(dict(rows=[self.row, self.row])))
        with self.assertRaisesRegex(ValueError, 'duplicada'):
            a.analyze(self.report, self.work / 'duplicate')
        self.assertFalse((self.work / 'duplicate').exists())

    def test_rejects_changed_binary(self):
        """Cambia solo el binario de fixture; debe identificar su hash incoherente."""
        (self.capture / 'sim.vvp').write_bytes(b'otro binario')
        with self.assertRaisesRegex(ValueError, 'hash.*sim.vvp'):
            a.analyze(self.report, self.work / 'out')

    def test_rejects_changed_window(self):
        """Cambia ciclos de la fila; exige la misma ventana de la captura."""
        self.row['cycles'] = 29
        with self.assertRaisesRegex(ValueError, 'fila y captura'):
            a.read_capture(self.capture, self.row)

    def test_rejects_changed_log(self):
        """El parser devuelve otro servicio; no se acepta metadata antiguo con log distinto."""
        with patch.object(a.runner, 'execution_metadata', return_value={**self.md, 'metrics': {}}):
            with self.assertRaisesRegex(ValueError, 'log y captura'):
                a.read_capture(self.capture, self.row)


if __name__ == '__main__':
    unittest.main()
