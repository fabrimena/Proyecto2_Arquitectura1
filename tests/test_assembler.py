"""Codificación, formato del bundle, errores y calendarización del assembler."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from tools.assembler import (ALIASES, AssemblyError, MAX_BUNDLES, SPECS, assemble_source,
                             encode_instruction, integer, register)


ROOT = Path(__file__).resolve().parents[1]


class EncodingTests(unittest.TestCase):
    def test_all_instructions_against_fixed_machine_words(self):
        # Constantes de la referencia de campos, independientes del encoder.
        cases = {
            "suma x5,x2,x3": 0xd50510c0,
            "resta x5,x2,x3": 0xd52510c0,
            "cader x5,x2,x3": 0xd54510c0,
            "cizq x5,x2,x3": 0xd56510c0,
            "and x5,x2,x3": 0xd58510c0,
            "or x5,x2,x3": 0xd5a510c0,
            "xor x5,x2,x3": 0xd5c510c0,
            "cder x5,x2,x3": 0xd5e510c0,
            "mrq x5,x2,x3": 0xd4a510c0,
            "myq x5,x2,x3": 0xd4c510c0,
            "sumai x5,x2,-7": 0x80022ff9,
            "restai x5,x2,-7": 0x80222ff9,
            "cizqi x5,x2,7": 0x80422807,
            "cderi x5,x2,7": 0x80622807,
            "caderi x5,x2,7": 0x80822807,
            "xori x5,x2,-7": 0x80a22ff9,
            "andi x5,x2,-7": 0x80c22ff9,
            "ori x5,x2,-7": 0x80e22ff9,
        }
        self.assertEqual(set(SPECS), {s.split()[0] for s in cases})
        for instruction, expected in cases.items():
            with self.subTest(instruction=instruction):
                self.assertEqual(encode_instruction(instruction).word, expected)

    def test_match_constants_in_actual_rtl(self):
        rtl = (ROOT / "rtl/isa_defs.sv").read_text()
        names = {"suma": "OP_SUM", "resta": "OP_RESTA", "cader": "OP_CADER",
                 "cizq": "OP_CIZQ", "and": "OP_AND", "or": "OP_OR",
                 "xor": "OP_XOR", "cder": "OP_CDER", "mrq": "OP_MRQ",
                 "myq": "OP_MYQ", "sumai": "OP_SUMI", "restai": "OP_RESTAI",
                 "cizqi": "OP_CIZQI", "cderi": "OP_CDERI", "caderi": "OP_CADERI",
                 "xori": "OP_XORI", "andi": "OP_ANDI", "ori": "OP_ORI"}
        for mnemonic, name in names.items():
            with self.subTest(mnemonic=mnemonic):
                match = re.search(rf"\b{name}\s*=\s*4'b([01]{{4}})", rtl)
                self.assertIsNotNone(match, f"faltó {name} en el RTL")
                self.assertEqual(SPECS[mnemonic].operation, int(match[1], 2))
        for name, expected in (("TYPE_REG", 106), ("TYPE_IMM", 64)):
            match = re.search(rf"\b{name}\s*=\s*7'b([01]{{7}})", rtl)
            self.assertIsNotNone(match)
            self.assertEqual(int(match[1], 2), expected)

    def test_register_field_positions_and_reserved_bits(self):
        for reg in range(32):
            with self.subTest(reg=reg):
                word = encode_instruction(f"suma x{reg},x{reg},x{reg}").word
                self.assertEqual((word >> 16) & 31, reg)
                self.assertEqual((word >> 11) & 31, reg)
                self.assertEqual((word >> 6) & 31, reg)
                self.assertEqual(word & 63, 0)
                word = encode_instruction(f"sumai x{reg},x{31-reg},-1").word
                self.assertEqual((word >> 16) & 31, 31 - reg)
                self.assertEqual((word >> 11) & 31, reg)
                self.assertEqual(word & 2047, 2047)

    def test_immediate_limits(self):
        for mnemonic in ("sumai", "restai", "xori", "andi", "ori"):
            for value in (-1024, -1, 0, 1023):
                with self.subTest(mnemonic=mnemonic, value=value):
                    self.assertEqual(encode_instruction(f"{mnemonic} x31,x0,{value}").word & 2047,
                                     value & 2047)
            for value in (-1025, 1024):
                with self.subTest(mnemonic=mnemonic, value=value):
                    with self.assertRaisesRegex(AssemblyError, "fuera de rango"):
                        encode_instruction(f"{mnemonic} x1,x0,{value}")

    def test_shift_field_is_unsigned(self):
        for mnemonic in ("cizqi", "cderi", "caderi"):
            for value in (0, 31, 32, 2047):
                with self.subTest(mnemonic=mnemonic, value=value):
                    self.assertEqual(encode_instruction(f"{mnemonic} x1,x2,{value}").word & 2047, value)
            for value in (-1, 2048):
                with self.assertRaises(AssemblyError):
                    encode_instruction(f"{mnemonic} x1,x2,{value}")

    def test_pseudoinstructions(self):
        self.assertEqual(encode_instruction("nop").word, 0)
        self.assertEqual(encode_instruction("mov x5,x2").word, 0xd5051000)
        self.assertEqual(encode_instruction("not x5,x2").word, 0x80a22fff)

    def test_abi_registers_and_numeral_bases(self):
        for alias, number in ALIASES.items():
            with self.subTest(alias=alias):
                self.assertEqual(register(alias), number)
                self.assertEqual(register(alias.upper()), number)
        for text, expected in (("010", 10), ("0xff", 255), ("-0x10", -16),
                               ("0b101", 5), ("+0b11", 3), ("-1024", -1024)):
            self.assertEqual(integer(text), expected)
        self.assertEqual(encode_instruction("SuMa gp, ra, sp").word, 0xd5030880)

    def test_invalid_syntax_and_registers(self):
        invalid = ["", "nop x1", "suma x1,x2", "sumai x1,x2,", "suma x32,x0,x0",
                   "suma x-1,x0,x0", "suma x01,x0,x0", "suma t12,x0,x0",
                   "sumai x1,x0,1.5", "sumai x1,x0,label", "mov x1,x2,x3", "add x1,x2,x3"]
        for instruction in invalid:
            with self.subTest(instruction=instruction), self.assertRaises(AssemblyError):
                encode_instruction(instruction)

    def test_ambiguous_secure_loads_are_rejected(self):
        for mnemonic in ("csi", "csd"):
            with self.assertRaisesRegex(AssemblyError, "aislamiento"):
                encode_instruction(mnemonic + " x1,2,0")


class ProgramTests(unittest.TestCase):
    def test_readmemh_order_pc_and_line_numbers(self):
        source = "# título\n\nsuma x5,x2,x3 | nop | nop | nop\nnop\n"
        program = assemble_source(source)
        self.assertEqual(program.memory_text(), "000000000000000000000000d50510c0\n" + "0" * 32 + "\n")
        self.assertEqual([b.pc for b in program.bundles], [0, 16])
        self.assertEqual([b.line for b in program.bundles], [3, 4])
        self.assertIn("0x00000010", program.listing_text())

    def test_comments_and_explicit_nop(self):
        program = assemble_source("nop # uno\nnop ; dos\nnop // tres\nNOP | NOP | NOP | NOP\n")
        self.assertEqual(len(program.bundles), 4)
        self.assertEqual(set(program.memory_text().splitlines()), {"0" * 32})

    def test_four_slots_and_placement(self):
        invalid = ["suma x1,x0,x0", "nop | nop", "nop | | nop | nop",
                   "nop | suma x1,x0,x0 | nop | nop", "nop | mov x0,x0 | nop | nop"]
        for line in invalid:
            with self.subTest(line=line), self.assertRaises(AssemblyError):
                assemble_source(line)

    def test_raw_distances_one_and_two_rejected_three_and_four_accepted(self):
        for distance in (1, 2, 3, 4):
            source = "sumai x4,x0,7 | nop | nop | nop\n" + "nop\n" * (distance - 1)
            source += "suma x5,x4,x0 | nop | nop | nop\n"
            with self.subTest(distance=distance):
                if distance < 3:
                    with self.assertRaisesRegex(AssemblyError, "dependencia RAW en x4"):
                        assemble_source(source)
                else:
                    self.assertEqual(len(assemble_source(source).bundles), distance + 1)

    def test_independent_bundles_count_as_separation(self):
        source = "\n".join(["sumai x1,x0,7 | nop | nop | nop",
                            "sumai x2,x0,8 | nop | nop | nop",
                            "sumai x3,x0,9 | nop | nop | nop",
                            "mov x4,x1 | nop | nop | nop"])
        self.assertEqual(len(assemble_source(source).bundles), 4)

    def test_self_update_and_latest_writer(self):
        self.assertEqual(len(assemble_source("sumai x1,x1,1 | nop | nop | nop\n").bundles), 1)
        source = ("sumai x1,x0,1 | nop | nop | nop\n" + "nop\n" * 2 +
                  "sumai x1,x1,1 | nop | nop | nop\nmov x2,x1 | nop | nop | nop")
        with self.assertRaisesRegex(AssemblyError, "bundle 3"):
            assemble_source(source)

    def test_x0_writes_create_no_dependency(self):
        source = "sumai x0,x0,9 | nop | nop | nop\nsuma x1,x0,x0 | nop | nop | nop\n"
        self.assertEqual(len(assemble_source(source).bundles), 2)

    def test_line_number_in_error(self):
        with self.assertRaisesRegex(AssemblyError, "línea 4:"):
            assemble_source("# comentario\n\nnop\nsuma x1,x0\n")

    def test_capacity_and_empty_program(self):
        self.assertEqual(len(assemble_source("nop\n" * MAX_BUNDLES).bundles), MAX_BUNDLES)
        with self.assertRaisesRegex(AssemblyError, f"{MAX_BUNDLES} bundles"):
            assemble_source("nop\n" * (MAX_BUNDLES + 1))
        with self.assertRaisesRegex(AssemblyError, "no contiene"):
            assemble_source("# comentario\n")

    def test_example_covers_every_implemented_instruction(self):
        source = (ROOT / "examples/alu_isa.asm").read_text()
        program = assemble_source(source)
        used = {b.instructions[0].text.split()[0] for b in program.bundles}
        self.assertTrue(set(SPECS) <= used)
        self.assertTrue({"mov", "not"} <= used)
        self.assertEqual(len(program.bundles), 24)

    def test_cli_failure_preserves_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            source, memory = directory / "invalid.asm", directory / "out.mem"
            source.write_text("suma x32,x0,x0 | nop | nop | nop\n")
            memory.write_text("original\n")
            result = subprocess.run([sys.executable, str(ROOT / "tools/assembler.py"),
                                     "--input", str(source), "--output", str(memory)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("registro inválido", result.stderr)
            self.assertEqual(memory.read_text(), "original\n")

    def test_cli_memory_and_listing(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            memory, listing = directory / "out.mem", directory / "out.lst"
            result = subprocess.run([sys.executable, str(ROOT / "tools/assembler.py"),
                                     "--input", str(ROOT / "examples/dependencias.asm"),
                                     "--output", str(memory), "--listing", str(listing)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(memory.read_text().splitlines()), 4)
            self.assertIn("0x00000030", listing.read_text())


class CacheEncodingTests(unittest.TestCase):
    """Extensión opcional: oráculos literales y rechazo estricto sin alterar el ISA anterior."""

    def test_cache_fixed_words(self):
        # Los literales se obtienen de la tabla de campos, no del encoder.
        cases = {"vaciarc": 0x9a000000, "medir 0": 0x9a200000,
                 "medir 1": 0x9a200001, "lcont x5,0": 0x9a402800,
                 "lcont x31,63": 0x9a40f83f, "lcont x0,32": 0x9a400020}
        for source, expected in cases.items():
            with self.subTest(source=source):
                ins = encode_instruction(source)
                self.assertEqual(ins.word, expected)
                self.assertEqual(ins.slot, 1)
                self.assertEqual(ins.reads, ())

    def test_all_counter_selectors_halves_and_destinations(self):
        # Todo rd y los 64 selectores son legales; 13–31 no son RSV del formato.
        for rd in range(32):
            for selector in range(64):
                with self.subTest(rd=rd, selector=selector):
                    ins = encode_instruction(f"lcont x{rd},{selector}")
                    self.assertEqual(ins.word, 0x9a400000 + rd * 2048 + selector)
                    self.assertEqual(ins.writes, (rd,) if rd else ())
                    self.assertEqual(ins.word & 0x001f07c0, 0)

    def test_cache_operand_count_and_syntax(self):
        # No se permite usar operandos adicionales para escribir campos reservados.
        invalid = ["vaciarc 0", "vaciarc x1", "vaciarc ,", "medir", "medir 0,1",
                   "medir 1 0", "medir imm=1", "lcont", "lcont x1", "lcont x1,",
                   "lcont ,1", "lcont x1,1,0", "lcont x1 1", "lcont rd=x1,sel=0"]
        for source in invalid:
            with self.subTest(source=source), self.assertRaises(AssemblyError):
                encode_instruction(source)

    def test_cache_invalid_immediates(self):
        # medir solo admite un bit; sel es un entero sin signo de seis bits.
        for source in ("medir -1", "medir 2", "medir 0x100", "medir 1.0", "medir x1",
                       "lcont x1,-1", "lcont x1,64", "lcont x1,0x100000000",
                       "lcont x1,1.5", "lcont x1,label", "lcont x1,x2"):
            with self.subTest(source=source), self.assertRaises(AssemblyError):
                encode_instruction(source)

    def test_cache_invalid_registers(self):
        # No se flexibiliza el parser de registros para la nueva instrucción.
        for register_name in ("x32", "x-1", "x01", "t12", "32", "rd"):
            with self.subTest(register=register_name), self.assertRaises(AssemblyError):
                encode_instruction(f"lcont {register_name},0")

    def test_cache_aliases_bases_and_no_hidden_operands(self):
        # Los alias y bases numéricas usan el mismo contrato que el ISA anterior.
        self.assertEqual(encode_instruction("LCONT ra,0b100000").word, 0x9a400820)
        self.assertEqual(encode_instruction("medir 0x1").word, 0x9a200001)
        for source in ("vaciarc", "medir 0", "medir 1"):
            ins = encode_instruction(source)
            self.assertEqual((ins.reads, ins.writes, ins.target, ins.indirect), ((), (), None, False))

    def test_cache_slot_binary_and_cli(self):
        # Se comprueba tanto el bundle como la salida CLI con un literal de 128 bits.
        source = "nop | lcont x5,32 | nop | nop\n"
        expected = "00000000000000009a40282000000000\n"
        program = assemble_source(source)
        self.assertEqual(program.memory_text(), expected)
        self.assertEqual(program.binary(), bytes.fromhex(expected.strip())[::-1])
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "cache.asm").write_text(source)
            result = subprocess.run([sys.executable, str(ROOT / "tools/assembler.py"),
                                     "--input", str(folder / "cache.asm"),
                                     "--output", str(folder / "cache.mem")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((folder / "cache.mem").read_text(), expected)


if __name__ == "__main__":
    unittest.main()
