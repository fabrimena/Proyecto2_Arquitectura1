#!/usr/bin/env python3
"""Ensamblador VLIW: ALU | LSU | BRU | CRIPTO, 128 bits por bundle."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys


TYPE_REG = 0b1101010
TYPE_IMM = 0b1000000


def _imem_bundles() -> int:
    """Capacidad de la memoria de instrucciones: IMEM_BUNDLES de rtl/isa_defs.sv."""
    defs = Path(__file__).resolve().parents[1] / "rtl" / "isa_defs.sv"
    try:
        match = re.search(r"IMEM_BUNDLES\s*=\s*(\d+)", defs.read_text(encoding="utf-8"))
    except OSError:
        match = None
    return int(match[1]) if match else 1024


MAX_BUNDLES = _imem_bundles()  # bundles de instruction_memory (rtl/isa_defs.sv)
READ_DISTANCE = 3


@dataclass(frozen=True)
class Spec:
    form: str
    operation: int
    shift: bool = False


SPECS = {
    "suma": Spec("R", 0b1000),
    "resta": Spec("R", 0b1001),
    "cader": Spec("R", 0b1010),
    "cizq": Spec("R", 0b1011),
    "and": Spec("R", 0b1100),
    "or": Spec("R", 0b1101),
    "xor": Spec("R", 0b1110),
    "cder": Spec("R", 0b1111),
    "mrq": Spec("R", 0b0101),
    "myq": Spec("R", 0b0110),
    "sumai": Spec("I", 0b0000),
    "restai": Spec("I", 0b0001),
    "cizqi": Spec("I", 0b0010, True),
    "cderi": Spec("I", 0b0011, True),
    "caderi": Spec("I", 0b0100, True),
    "xori": Spec("I", 0b0101),
    "andi": Spec("I", 0b0110),
    "ori": Spec("I", 0b0111),
}

ALIASES = {"cero": 0, "zero": 0, "ra": 1, "sp": 2, "gp": 3}
ALIASES.update({f"t{i}": i + 4 for i in range(12)})
ALIASES.update({f"s{i}": i + 16 for i in range(16)})

LSU_OPS = {"guardap": 0, "guardab": 1, "cargai": 8, "cargabai": 9}
BRU_OPS = {"igualsi": 1, "igualno": 2, "menora": 4, "mayoroigual": 8}
CRYPTO_OPS = {"fsl": 0, "fsli": 1, "ell": 2, "vcr": 3, "camcon": 4, "setpwd": 5}
# Extensión opcional del proyecto II, separada de los 34 mnemónicos originales.
# Solo el slot LSU la admite; el tipo distinto conserva sus codificaciones.
CACHE_OPS = {"vaciarc": 0, "medir": 1, "lcont": 2}


class AssemblyError(ValueError):
    """Error de sintaxis, codificación o calendarización del programa."""


@dataclass(frozen=True)
class Instruction:
    word: int
    reads: tuple[int, ...]
    writes: tuple[int, ...]
    text: str
    slot: int = 0
    target: int | None = None
    conditional: bool = False
    indirect: bool = False  # syer: el destino sale de un registro


@dataclass(frozen=True)
class Bundle:
    index: int
    line: int
    instructions: tuple[Instruction, ...]

    @property
    def word(self) -> int:
        # Slot 0 ocupa los bits bajos; readmemh imprime primero los altos.
        return sum(ins.word << (32 * slot)
                   for slot, ins in enumerate(self.instructions))

    @property
    def pc(self) -> int:
        return self.index * 16


@dataclass(frozen=True)
class Program:
    bundles: tuple[Bundle, ...]

    def memory_text(self) -> str:
        return "".join(f"{b.word:032x}\n" for b in self.bundles)

    def binary(self) -> bytes:
        return b"".join(b.word.to_bytes(16, "little") for b in self.bundles)

    def listing_text(self) -> str:
        header = "# bundle  PC          línea  [CRIPTO BRU LSU ALU] hexadecimal\n"
        rows = []
        for b in self.bundles:
            slots = " | ".join(i.text for i in b.instructions)
            rows.append(f"{b.index:02d}        0x{b.pc:08x}  {b.line:5d}  "
                        f"{b.word:032x}  {slots}\n")
        return header + "".join(rows)


def register(token: str) -> int:
    name = token.strip().lower()
    if name in ALIASES:
        return ALIASES[name]
    if re.fullmatch(r"x(?:0|[1-9][0-9]?)", name):
        value = int(name[1:])
        if value <= 31:
            return value
    raise AssemblyError(f"registro inválido '{token}'; use x0–x31 o un alias ABI")


def integer(token: str) -> int:
    if not re.fullmatch(r"[+-]?(?:0[xX][0-9a-fA-F]+|0[bB][01]+|[0-9]+)", token):
        raise AssemblyError(f"inmediato inválido '{token}'; use decimal, 0x o 0b")
    raw = token.lstrip("+-")
    base = 16 if raw.lower().startswith("0x") else 2 if raw.lower().startswith("0b") else 10
    return int(token, base)


def bounded(token: str, low: int, high: int) -> int:
    value = integer(token)
    if not low <= value <= high:
        raise AssemblyError(f"inmediato fuera de rango: {low}..{high}")
    return value


def encode_instruction(text: str, *, pc: int = 0,
                       labels: dict[str, int] | None = None) -> Instruction:
    parts = text.strip().split(None, 1)
    if not parts:
        raise AssemblyError("slot vacío; escriba nop explícitamente")
    mnemonic = parts[0].lower()
    operand_text = parts[1] if len(parts) == 2 else ""
    operands = [x.strip() for x in operand_text.split(",")] if operand_text else []
    if any(not x for x in operands):
        raise AssemblyError("hay un operando vacío")

    if mnemonic == "nop":
        if operands:
            raise AssemblyError("nop no recibe operandos")
        return Instruction(0, (), (), text.strip())

    if mnemonic == "ret":
        if operands:
            raise AssemblyError("ret no recibe operandos")
        base = encode_instruction("syer x0, ra, 0")
        return Instruction(base.word, base.reads, base.writes, text.strip(), base.slot, indirect=True)

    if mnemonic in {"csi", "csd"}:
        raise AssemblyError("csi/csd no existen en el ISA: se eliminaron porque rompían el aislamiento de la bóveda")
    if mnemonic == "camcom":
        mnemonic = "camcon"

    def count(n):
        if len(operands) != n:
            raise AssemblyError(f"{mnemonic} requiere {n} operandos separados por comas")

    def result(word, reads=(), writes=(), slot=0, target=None, conditional=False, indirect=False):
        return Instruction(word, tuple(r for r in reads if r),
                           tuple(r for r in writes if r), text.strip(), slot, target, conditional, indirect)

    if mnemonic in CACHE_OPS:
        # Se construye desde cero: ningún operando puede ocupar un campo RSV.
        # lcont declara el destino como productor, incluso con selector reservado;
        # así las comprobaciones RAW/WAW y N+3 del grafo también cubren esta carga.
        word = (0b1001101 << 25) | (CACHE_OPS[mnemonic] << 21)
        if mnemonic == "vaciarc":
            count(0)
            return result(word, slot=1)
        if mnemonic == "medir":
            count(1)
            return result(word | bounded(operands[0], 0, 1), slot=1)
        count(2)
        rd = register(operands[0])
        selector = bounded(operands[1], 0, 63)
        return result(word | (rd << 11) | selector, writes=(rd,), slot=1)

    if mnemonic in LSU_OPS:
        count(3)
        first, second = map(register, operands[:2])
        imm = bounded(operands[2], -1024, 1023)
        load = mnemonic in {"cargai", "cargabai"}
        base, data = (second, first) if load else (first, second)
        word = (0b1001001 << 25) | (LSU_OPS[mnemonic] << 21) | (base << 16) | (data << 11) | (imm & 2047)
        return result(word, (base,) if load else (base, data), (data,) if load else (), 1)

    if mnemonic == "syer":
        # rg = PC + 16; PC = (rf1 + offset) con los 4 bits bajos en 0.
        count(3)
        rd, rs1 = map(register, operands[:2])
        offset = bounded(operands[2], -1024, 1023)
        word = (0b1001011 << 25) | (1 << 21) | (rd << 16) | (rs1 << 11) | (offset & 2047)
        return result(word, (rs1,), (rd,), 2, indirect=True)

    if mnemonic in BRU_OPS or mnemonic == "sye":
        jump = mnemonic == "sye"
        count(2 if jump else 3)
        token = operands[-1]
        if labels is not None and token in labels:
            offset = labels[token] - pc
        else:
            offset = integer(token)
        bits = 16 if jump else 11
        if not -(1 << (bits - 1)) <= offset < (1 << (bits - 1)):
            raise AssemblyError(f"salto fuera de rango de {bits} bits")
        if offset % 16:
            raise AssemblyError("el salto debe estar alineado a un bundle (16 bytes)")
        if jump:
            rd = register(operands[0])
            word = (0b1001011 << 25) | (rd << 16) | (offset & 65535)
            return result(word, (), (rd,), 2, pc + offset)
        rs1, rs2 = map(register, operands[:2])
        word = (0b1000001 << 25) | (BRU_OPS[mnemonic] << 21) | (rs1 << 16) | (rs2 << 11) | (offset & 2047)
        return result(word, (rs1, rs2), (), 2, pc + offset, True)

    if mnemonic in CRYPTO_OPS:
        fields = {"fsl": ("rd", "r1", "lk", "rk"), "fsli": ("rd", "r1", "lk", "rk"),
                  "ell": ("lk", "off", "rs1", "rs2"), "vcr": ("dir_cand",),
                  "camcon": ("dir", "imm"), "setpwd": ("rs",)}[mnemonic]
        count(len(fields))
        if any("=" in o for o in operands):
            named = {}
            for operand in operands:
                pair = operand.split("=")
                if len(pair) != 2 or pair[0].strip().lower() in named:
                    raise AssemblyError("operandos nombrados inválidos o repetidos")
                named[pair[0].strip().lower()] = pair[1].strip()
            if set(named) != set(fields):
                raise AssemblyError("campos esperados: " + ", ".join(fields))
            operands = [named[f] for f in fields]
            operands = ["x" + o if f in {"rd", "r1", "rs1", "rs2", "rs"} and o.isdecimal() else o
                        for f, o in zip(fields, operands)]
        word = (2 << 25) | (CRYPTO_OPS[mnemonic] << 21)
        if mnemonic in {"fsl", "fsli"}:
            rd, rs = map(register, operands[:2])
            if rd < 2 or rs < 2 or rd % 2 or rs % 2:
                raise AssemblyError("Feistel requiere pares de registros desde x2 hasta x30")
            lk, rk = [bounded(o, 0, 3) for o in operands[2:]]
            return result(word | (lk << 19) | (rk << 17) | (rd << 12) | (rs << 7),
                          (rs, rs + 1), (rd, rd + 1), 3)
        if mnemonic == "ell":
            lk, off = [bounded(o, 0, 3) for o in operands[:2]]
            rs1, rs2 = map(register, operands[2:])
            if off not in (0, 2) or rs1 % 2 or rs2 % 2:
                raise AssemblyError("ell requiere off 0 o 2 y registros pares")
            return result(word | (lk << 19) | (off << 17) | (rs1 << 12) | (rs2 << 7), (rs1, rs2), (), 3)
        if mnemonic == "setpwd":
            rs = register(operands[0])
            return result(word | rs, (rs,), (), 3)
        address = bounded(operands[0], 0, 65535)
        shift = bounded(operands[1], 0, 31) if mnemonic == "camcon" else 0
        return result(word | (address << 5) | shift, (), (), 3)
    if mnemonic not in SPECS and mnemonic not in {"mov", "not"}:
        raise AssemblyError(f"instrucción desconocida '{mnemonic}'")

    count = 2 if mnemonic in {"mov", "not"} else 3
    if len(operands) != count:
        raise AssemblyError(f"{mnemonic} requiere {count} operandos separados por comas")

    # Las pseudoinstrucciones ocupan un slot; no agregan bundles ocultos.
    if mnemonic == "mov":
        base = encode_instruction(f"suma {operands[0]}, {operands[1]}, x0")
        return Instruction(base.word, base.reads, base.writes, text.strip())
    if mnemonic == "not":
        base = encode_instruction(f"xori {operands[0]}, {operands[1]}, -1")
        return Instruction(base.word, base.reads, base.writes, text.strip())

    spec = SPECS[mnemonic]
    rd, rs1 = register(operands[0]), register(operands[1])
    if spec.form == "R":
        rs2 = register(operands[2])
        word = (TYPE_REG << 25) | (spec.operation << 21) | (rd << 16) | (rs1 << 11) | (rs2 << 6)
        reads = (rs1, rs2)
    else:
        imm = integer(operands[2])
        low, high = (0, 2047) if spec.shift else (-1024, 1023)
        if not low <= imm <= high:
            raise AssemblyError(f"inmediato de {mnemonic} fuera de rango: {low}..{high}")
        word = (TYPE_IMM << 25) | (spec.operation << 21) | (rs1 << 16) | (rd << 11) | (imm & 0x7ff)
        reads = (rs1,)
    return Instruction(word, tuple(r for r in reads if r), (rd,) if rd else (), text.strip())


def assemble_source(source: str) -> Program:
    lines, labels = [], {}
    for line_number, raw_line in enumerate(source.splitlines(), 1):
        code = re.split(r"#|;|//", raw_line, maxsplit=1)[0].strip()
        match = re.match(r"^([A-Za-z_][A-Za-z_0-9]*):", code)
        if match:
            name = match[1]
            if name in labels:
                raise AssemblyError(f"línea {line_number}: etiqueta repetida '{name}'")
            labels[name] = len(lines) * 16
            code = code[match.end():].strip()
        if code:
            lines.append((line_number, code))
    if not lines:
        raise AssemblyError("el programa no contiene bundles")
    if len(lines) > MAX_BUNDLES:
        raise AssemblyError(f"la memoria actual admite como máximo {MAX_BUNDLES} bundles")
    bundles = []
    for index, (line_number, code) in enumerate(lines):
        try:
            slots = ("nop | nop | nop | nop" if code.lower() == "nop" else code).split("|")
            if len(slots) != 4:
                raise AssemblyError("un bundle requiere 4 slots: ALU | LSU | BRU | CRIPTO")
            instructions = tuple(encode_instruction(slot, pc=index * 16, labels=labels) for slot in slots)
            for slot, ins in enumerate(instructions):
                if ins.word and slot != ins.slot:
                    raise AssemblyError(f"'{ins.text}' corresponde al slot {ins.slot}, no al {slot}")
                if ins.target is not None and not 0 <= ins.target < len(lines) * 16:
                    raise AssemblyError("el destino del salto está fuera del programa")
                for other in instructions[slot + 1:]:
                    if set(ins.writes) & set(other.writes):
                        raise AssemblyError("conflicto WAW entre slots del mismo bundle")
                    if set(ins.writes) & set(other.reads) or set(other.writes) & set(ins.reads):
                        raise AssemblyError("dependencia RAW entre slots del mismo bundle")
            bundles.append(Bundle(index, line_number, instructions))
        except AssemblyError as exc:
            raise AssemblyError(f"línea {line_number}: {exc}") from exc

    # Se revisan ambos caminos de cada salto y también los ciclos del grafo.
    # No se aprovechan los ciclos de flush: es una planificación conservadora.
    # syer no tiene sucesores: su destino no se conoce al ensamblar y, como
    # todo salto tomado anula 2 bundles, lo que se ejecuta después ya ve sus
    # escrituras y las de los bundles anteriores.
    def successors(index):
        branch = bundles[index].instructions[2]
        result = []
        if branch.indirect:
            return result
        if branch.target is not None:
            result.append(branch.target // 16)
        if (branch.target is None or branch.conditional) and index + 1 < len(bundles):
            result.append(index + 1)
        return result

    for producer in bundles:
        writes = {r for ins in producer.instructions for r in ins.writes}
        frontier = set(successors(producer.index))
        for distance in range(1, READ_DISTANCE):
            for index in frontier:
                consumer = bundles[index]
                reads = {r for ins in consumer.instructions for r in ins.reads}
                conflict = writes & reads
                if conflict:
                    reg = min(conflict)
                    raise AssemblyError(f"línea {consumer.line}: dependencia RAW en x{reg}: "
                                        f"el bundle {producer.index} lo escribe y se lee a distancia {distance}; "
                                        "deje dos bundles independientes o nop")
            frontier = {n for index in frontier for n in successors(index)}
    return Program(tuple(bundles))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="programa .asm")
    parser.add_argument("--output", required=True, type=Path, help="bundles .mem para readmemh")
    parser.add_argument("--listing", type=Path, help="listado con PC, línea y código hexadecimal")
    parser.add_argument("--binary", type=Path, help="binario little-endian, 16 bytes por bundle")
    args = parser.parse_args(argv)
    try:
        destinations = [p for p in (args.output, args.listing, args.binary) if p is not None]
        resolved = [path.resolve() for path in destinations]
        if args.input.resolve() in resolved or len(set(resolved)) != len(resolved):
            raise AssemblyError("la entrada y cada salida deben tener rutas distintas")
        program = assemble_source(args.input.read_text(encoding="utf-8"))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(program.memory_text(), encoding="ascii")
        if args.binary:
            args.binary.parent.mkdir(parents=True, exist_ok=True)
            args.binary.write_bytes(program.binary())
        if args.listing:
            args.listing.parent.mkdir(parents=True, exist_ok=True)
            args.listing.write_text(program.listing_text(), encoding="utf-8")
    except (OSError, UnicodeError, AssemblyError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print(f"Ensamblado: {len(program.bundles)} bundles, {16 * len(program.bundles)} bytes; "
          f"PC 0x00000000..0x{program.bundles[-1].pc:08x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
