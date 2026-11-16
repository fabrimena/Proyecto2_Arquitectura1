"""Campos LSU/BRU/cripto, saltos y conflictos entre slots."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.assembler import AssemblyError, assemble_source, encode_instruction

ROOT = Path(__file__).resolve().parents[1]


class IsaTests(unittest.TestCase):
    def test_fixed_words(self):
        cases = {
            'guardap x3,x4,-4': 0x920327fc,
            'guardab x3,x4,-4': 0x922327fc,
            'cargai x5,x3,4': 0x93032804,
            'cargabai x5,x3,4': 0x93232804,
            'igualsi x4,x5,-16': 0x82242ff0,
            'igualno x4,x5,-16': 0x82442ff0,
            'menora x4,x5,-16': 0x82842ff0,
            'mayoroigual x4,x5,-16': 0x83042ff0,
            'sye x1,32': 0x96010020,
            'syer x0,ra,0': 0x96200800,
            'syer x12,x9,21': 0x962c4815,
            'syer x7,x20,-32': 0x9627a7e0,
            'fsl x6,x2,1,3': 0x040e6100,
            'fsli x6,x2,1,3': 0x042e6100,
            'ell 2,2,x4,x6': 0x04544300,
            'vcr 0x2000': 0x04640000,
            'camcon 0x10,7': 0x04800207,
            'setpwd x5': 0x04a00005,
        }
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(encode_instruction(source).word, expected)

    def test_official_named_crypto_operands(self):
        pairs = [('fsl RK=3, rd=6, LK=1, r1=2', 'fsl x6,x2,1,3'),
                 ('ell LK=2,off=2,rs1=4,rs2=6', 'ell 2,2,x4,x6'),
                 ('vcr dir_cand=0x2000', 'vcr 0x2000'),
                 ('camcom dir=0x10,imm=7', 'camcon 0x10,7'),
                 ('setpwd rs=5', 'setpwd x5')]
        for left, right in pairs:
            self.assertEqual(encode_instruction(left).word, encode_instruction(right).word)

    def test_crypto_restrictions(self):
        invalid = ['fsl x0,x2,0,0', 'fsli x31,x2,0,0', 'fsl x2,x3,0,0',
                   'fsl x2,x4,4,0', 'fsl x2,x4,0,-1', 'ell 0,1,x2,x4',
                   'ell 0,3,x2,x4', 'ell 0,0,x1,x4', 'vcr 65536',
                   'vcr -1', 'camcon 0,32', 'setpwd rs=32',
                   'fsl rd=2,r1=4,LK=0,LK=1', 'setpwd bad=5']
        for source in invalid:
            with self.subTest(source=source), self.assertRaises(AssemblyError):
                encode_instruction(source)
        self.assertEqual(encode_instruction('fsl x30,x30,3,3').writes, (30, 31))
        self.assertEqual(encode_instruction('vcr 65535').word & 31, 0)

    def test_memory_immediate_limits(self):
        for name in ('guardap', 'guardab', 'cargai', 'cargabai'):
            for offset in (-1024, 1023):
                self.assertEqual(encode_instruction(f'{name} x2,x4,{offset}').word & 2047, offset & 2047)
            for offset in (-1025, 1024):
                with self.assertRaises(AssemblyError):
                    encode_instruction(f'{name} x2,x4,{offset}')

    def test_jump_limits_and_alignment(self):
        for source in ('sye x1,-32768', 'sye x1,32752', 'igualsi x1,x2,-1024', 'igualsi x1,x2,1008'):
            encode_instruction(source)
        for source in ('sye x1,32768', 'sye x1,-32784', 'igualsi x1,x2,1024', 'sye x1,4'):
            with self.assertRaises(AssemblyError):
                encode_instruction(source)

    def test_syer_and_ret(self):
        ret = encode_instruction('ret')
        self.assertEqual(ret.word, encode_instruction('syer x0,ra,0').word)
        self.assertEqual((ret.reads, ret.writes, ret.slot), ((1,), (), 2))
        self.assertEqual(encode_instruction('syer x12,x9,0').writes, (12,))
        for offset in (-1024, 1023):
            self.assertEqual(encode_instruction(f'syer x0,x1,{offset}').word & 2047, offset & 2047)
        for source in ('syer x0,x1,-1025', 'syer x0,x1,1024', 'syer x0,x1',
                       'syer x0,x1,fin', 'ret x1'):
            with self.subTest(source=source), self.assertRaises(AssemblyError):
                encode_instruction(source)
        with self.assertRaises(AssemblyError):
            assemble_source('nop | nop | nop | nop\nret | nop | nop | nop')

    def test_return_has_no_fallthrough(self):
        # Después de ret se ejecuta el retorno, no el bundle siguiente: no hay RAW.
        assemble_source('sumai x4,x0,1 | nop | nop | nop\nnop | nop | ret | nop\n'
                        'mov x5,x4 | nop | nop | nop')
        with self.assertRaisesRegex(AssemblyError, 'RAW'):
            assemble_source('sumai x4,x0,1 | nop | nop | nop\nnop\nmov x5,x4 | nop | nop | nop')

    def test_labels_forward_backward_and_pc_relative(self):
        program = assemble_source('start: nop | nop | sye x0,end | nop\nnop\nend: nop | nop | igualsi x0,x0,start | nop')
        self.assertEqual(program.bundles[0].instructions[2].word & 65535, 32)
        self.assertEqual(program.bundles[2].instructions[2].word & 2047, 2016)
        for source in ('a: nop\na: nop', 'nop | nop | sye x0,missing | nop',
                       'nop | nop | sye x0,end | nop\nend:', 'nop | nop | sye x0,-16 | nop'):
            with self.assertRaises(AssemblyError):
                assemble_source(source)

    def test_slot_layout_and_binary_order(self):
        source = 'suma x5,x2,x3 | guardap x0,x4,256 | igualno x0,x0,0 | vcr 256'
        bundle = assemble_source(source)
        expected = '046020008240000092002100d50510c0'
        self.assertEqual(bundle.memory_text(), expected + '\n')
        self.assertEqual(bundle.binary(), bytes.fromhex(expected)[::-1])
        for source in ('cargai x1,x2,0 | nop | nop | nop', 'nop | nop | vcr 0 | nop'):
            with self.assertRaises(AssemblyError):
                assemble_source(source)

    def test_cross_slot_raw_waw_including_pair_high_register(self):
        for source in ('sumai x4,x0,1 | guardap x0,x4,0 | nop | nop',
                       'sumai x4,x0,1 | cargai x4,x0,0 | nop | nop',
                       'sumai x7,x0,1 | nop | nop | fsl x6,x2,0,0',
                       'sumai x3,x0,1 | nop | nop | fsl x6,x2,0,0'):
            with self.subTest(source=source), self.assertRaises(AssemblyError):
                assemble_source(source)

    def test_raw_across_taken_jump_and_backedge(self):
        for source in ('sumai x4,x0,1 | nop | sye x0,target | nop\nnop\nnop\ntarget: mov x5,x4 | nop | nop | nop',
                       'loop: sumai x4,x4,1 | nop | igualno x0,x0,loop | nop'):
            with self.assertRaisesRegex(AssemblyError, 'RAW'):
                assemble_source(source)
        assemble_source('sumai x4,x0,1 | nop | sye x0,target | nop\ntarget: nop\nnop\nmov x5,x4 | nop | nop | nop')

    def test_cli_binary_and_no_overwriting_input(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source, mem, binary = folder/'p.asm', folder/'p.mem', folder/'p.bin'
            source.write_text('nop')
            cmd = [sys.executable, str(ROOT/'tools/assembler.py'), '--input', str(source), '--output', str(mem), '--binary']
            result = subprocess.run(cmd + [str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(binary.read_bytes(), bytes(16))
            result = subprocess.run(cmd + [str(source)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(source.read_text(), 'nop')

    def test_all_examples_assemble(self):
        for path in sorted((ROOT/'examples').glob('*.asm')):
            with self.subTest(path=path.name):
                assemble_source(path.read_text())


class CacheIsaTests(unittest.TestCase):
    """Comprueba que lcont participa de los riesgos del VLIW como un load."""

    def test_cache_only_in_lsu_slot(self):
        # Todos los mnemónicos nuevos se rechazan en los otros tres slots.
        for instruction in ('vaciarc', 'medir 1', 'lcont x4,0'):
            for slot in range(4):
                slots = ['nop'] * 4
                slots[slot] = instruction
                with self.subTest(instruction=instruction, slot=slot):
                    if slot == 1:
                        self.assertEqual(len(assemble_source(' | '.join(slots)).bundles), 1)
                    else:
                        with self.assertRaisesRegex(AssemblyError, 'slot 1'):
                            assemble_source(' | '.join(slots))

    def test_lcont_same_bundle_raw_waw(self):
        # Incluye la mitad alta de un par Feistel: una lectura cero reservada
        # sigue siendo productora y no puede eludir los conflictos del bundle.
        cases = [('sumai x4,x0,1 | lcont x4,0 | nop | nop', 'WAW'),
                 ('mov x5,x4 | lcont x4,13 | nop | nop', 'RAW'),
                 ('nop | lcont x4,0 | igualsi x4,x0,0 | nop', 'RAW'),
                 ('nop | lcont x3,0 | nop | fsl x6,x2,0,0', 'RAW'),
                 ('nop | lcont x7,0 | nop | fsl x6,x2,0,0', 'WAW')]
        for source, error in cases:
            with self.subTest(source=source), self.assertRaisesRegex(AssemblyError, error):
                assemble_source(source)

    def test_lcont_n_plus_three(self):
        # A distancia 1/2 la lectura es prematura; 3/4 conservan N+3.
        for selector in (0, 12, 13, 31, 32, 63):
            for distance in (1, 2, 3, 4):
                source = 'nop | lcont x4,%d | nop | nop\n' % selector
                source += 'nop\n' * (distance - 1) + 'mov x5,x4 | nop | nop | nop'
                with self.subTest(selector=selector, distance=distance):
                    if distance < 3:
                        with self.assertRaisesRegex(AssemblyError, 'RAW en x4'):
                            assemble_source(source)
                    else:
                        self.assertEqual(len(assemble_source(source).bundles), distance + 1)

    def test_lcont_dependencies_across_control_flow(self):
        # El calendario sigue el salto tomado, aunque haya NOP en el camino omitido.
        source = ('nop | lcont x4,0 | sye x0,target | nop\nnop\nnop\n'
                  'target: mov x5,x4 | nop | nop | nop')
        with self.assertRaisesRegex(AssemblyError, 'RAW'):
            assemble_source(source)
        source = ('nop | lcont x4,0 | sye x0,target | nop\n'
                  'target: nop\nnop\nmov x5,x4 | nop | nop | nop')
        self.assertEqual(len(assemble_source(source).bundles), 4)

    def test_lcont_dependencies_on_conditional_paths_and_backedge(self):
        # Se revisan el camino secuencial, el tomado y el retorno a un ciclo.
        cases = [
            'nop | lcont x4,0 | igualno x0,x0,far | nop\nmov x5,x4 | nop | nop | nop\nfar: nop',
            'nop | lcont x4,0 | igualno x0,x0,far | nop\nnop\nnop\nfar: mov x5,x4 | nop | nop | nop',
            'loop: mov x5,x4 | nop | nop | nop\nnop | lcont x4,0 | sye x0,loop | nop',
        ]
        for source in cases:
            with self.subTest(source=source), self.assertRaisesRegex(AssemblyError, 'RAW'):
                assemble_source(source)

    def test_lcont_x0_and_effect_free_controls(self):
        # x0 no crea dependencias. medir/vaciarc no escriben registros ocultos.
        program = assemble_source('sumai x0,x0,1 | lcont x0,0 | nop | nop\n'
                                  'mov x4,x0 | medir 0 | nop | nop\n'
                                  'sumai x5,x0,1 | vaciarc | nop | nop')
        self.assertEqual(len(program.bundles), 3)
        self.assertEqual(program.bundles[0].instructions[1].writes, ())

    def test_lcont_unknown_mnemonic_and_bad_bundle_rejected(self):
        # No se agrega una vía de escape para emitir palabras crudas o IDs desconocidos.
        for source in ('nop | vaciarc 1 | nop | nop', 'nop | medir 1,0 | nop | nop',
                       'nop | lcont x1,64 | nop | nop', 'nop | cache 0 | nop | nop'):
            with self.subTest(source=source), self.assertRaises(AssemblyError):
                assemble_source(source)


if __name__ == '__main__':
    unittest.main()
