"""test_flush_tools.py: persistencia de herramientas, issue #28.

Entradas: fixtures originales, stores conocidos y modos de elaboración. Salidas:
aserciones unittest y, opcionalmente, logs/dumps/comandos de evidencia externa.
Depende de Python, ensamblador existente, Icarus y RTL actual con l2_model; no
certifica una L2 definitiva ni cambia compilador, ISA, caché o Makefile.

Ejecutar con unittest discover en una copia externa del repositorio. Los bancos
reales se elaboran con MEM_MODE 0/1/2 mediante un segundo módulo raíz defparam,
sin cambiar defaults de producción. Los oráculos son datos preparados, Feistel4
independiente y comparaciones de memoria completa; una sombra no es suficiente.

También se aísla la tarea local de handshake con un productor diagnóstico para
comprobar respuestas tardías, timeout y X/Z. No se presenta ese productor como
una caché. Las mutaciones solo afectan copias temporales del consumidor; nunca
RTL protegido, expectativas o archivos de Compiladores. No incorpora el issue9.

TemporaryDirectory posee y elimina los recursos creados. P28_EVIDENCE_DIR permite
conservarlos en un directorio externo nuevo para auditoría: allí quedan comandos,
códigos, tiempos, logs, dumps y diferencias diagnósticas. Ningún recurso se genera
en el repositorio fuente. Los subprocesos tienen timeout y el RTL otro por fase.
"""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock

from tools.assembler import assemble_source
from tools.bundle_linear import bundle_linear
from tools import run_program as runner

ROOT = Path(__file__).resolve().parents[1]
HAVE_ICARUS = shutil.which(os.environ.get('IVERILOG', 'iverilog')) and shutil.which(os.environ.get('VVP', 'vvp'))


def replace_once(text: str, old: str, new: str) -> str:
    """Sustituye un punto de adaptación verificado; rechaza cero o dos matches.

    Solo opera sobre texto que el llamador escribirá en una copia temporal. Así
    una reorganización del banco no puede dejar una prueba etiquetada como modo2
    ejecutando silenciosamente el default0 ni mutar otro bloque por accidente.
    """
    if text.count(old) != 1:
        raise AssertionError(f'adaptación requiere exactamente una coincidencia: {old!r}')
    return text.replace(old, new)


def flush_task() -> str:
    """Extrae la tarea real del consumidor, sin reimplementar su handshake.

    Devuelve declaración y endtask exactos. La extracción está anclada al nombre
    único y falla si falta el cierre. La unidad de protocolo aporta sus propias
    señales/chequeo de reposo; las pruebas de herramientas usan el banco completo.
    """
    source = (ROOT / 'tests/rtl/tb_assembled_program.sv').read_text()
    start = source.index('    task automatic flush_cache(')
    end = source.index('    endtask', start) + len('    endtask')
    return source[start:end]


def feistel_block(block: bytes, decrypt: bool = False) -> bytes:
    """Referencia Feistel4 de software, sin consultar resultados ni RTL.

    Recibe ocho bytes little-endian y devuelve el bloque cifrado o descifrado.
    Usa las subllaves originales de ejemplos; las operaciones se reducen a32 bits.
    No modifica buffers del llamador y no tiene recursos externos.
    """
    left, right = int.from_bytes(block[:4], 'little'), int.from_bytes(block[4:], 'little')
    keys = (0x0f1e2d3c, 0x4b5a6978, 0x8796a5b4, 0xc3d2e1f0)
    def rol(value: int, n: int) -> int:
        # Una rotación mantiene los bits expulsados, a diferencia de un shift.
        return ((value << n) | (value >> (32 - n))) & 0xffffffff
    for key in reversed(keys) if decrypt else keys:
        value = left if decrypt else right
        f = ((rol(value, 5) + key) & 0xffffffff) ^ rol(value, 13)
        left, right = ((right ^ f) & 0xffffffff, left) if decrypt else (right, (left ^ f) & 0xffffffff)
    return left.to_bytes(4, 'little') + right.to_bytes(4, 'little')


@unittest.skipUnless(HAVE_ICARUS, 'requiere iverilog y vvp')
class FlushToolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Reserva un workspace externo por suite y caché de elaboraciones.

        Si se pidió evidencia persistente, exige un directorio nuevo: nunca
        sobrescribe pruebas anteriores. En modo normal TemporaryDirectory posee
        todo y tearDownClass lo libera. No ejecuta Git ni modifica producción.
        """
        cls.owner = contextlib.ExitStack()
        requested = os.environ.get('P28_EVIDENCE_DIR')
        if requested:
            cls.work = Path(requested).resolve()
            if cls.work == ROOT or ROOT in cls.work.parents:
                raise ValueError('la evidencia debe estar fuera del repositorio')
            cls.work.mkdir(parents=True, exist_ok=False)
        else:
            cls.work = Path(cls.owner.enter_context(tempfile.TemporaryDirectory(prefix='p28-tests-')))
        cls.compiled = {}
        cls.serial = 0
        cls.commands = []

    @classmethod
    def tearDownClass(cls):
        """Cierra recursos de la suite; los logs persistentes quedan al usuario."""
        cls.owner.close()

    def command(self, command, cwd, log, timeout=40):
        """Ejecuta argv sin shell; registra salida, código y tiempo de pared.

        Retorna CompletedProcess incluso con error para que el caso compruebe
        la causa esperada. Timeout es error de infraestructura, nunca un negativo
        detectado. Los archivos pertenecen al workspace externo de la suite.
        """
        start = time.monotonic()
        result = subprocess.run([str(x) for x in command], cwd=cwd, capture_output=True,
                                text=True, timeout=timeout, check=False)
        log.write_text(result.stdout + result.stderr)
        self.commands.append(dict(command=[str(x) for x in command], rc=result.returncode,
                                  seconds=round(time.monotonic()-start, 3), log=str(log)))
        (self.work / 'commands.json').write_text(json.dumps(self.commands, indent=2))
        return result

    def folder(self, label):
        """Crea un destino único para una ejecución; evita aceptar dumps previos."""
        type(self).serial += 1
        result = self.work / f'{self.serial:03d}-{label}'
        result.mkdir()
        return result

    def compile_tb(self, name, mode, text=None, label='normal'):
        """Elabora un banco real con modo comprobado, sin tocar su archivo fuente.

        El módulo raíz cfg aplica defparam y verifica el parámetro efectivo y las
        políticas públicas de L1-D. Una copia mutante se identifica por su texto,
        con oráculo original. Cachear el binario evita recompilaciones idénticas.
        Falla ante compilación no relacionada; jamás acredita un control negativo.
        """
        key = (name, mode, text)
        if key in self.compiled:
            return self.compiled[key]
        work = self.folder(f'compile-{name}-{mode}-{label}')
        source = ROOT / 'tests/rtl' / f'{name}.sv'
        if text is not None:
            source = work / f'{name}.sv'
            source.write_text(text)
        cfg = work / 'cfg.sv'
        policy = ''
        if mode == 2:
            policy = f'''
                if ({name}.DUT.g_mem_cache.HIER.L1D.WRITE_POLICY !== 1'b1 ||
                    {name}.DUT.g_mem_cache.HIER.L1D.INCL_POLICY !== 2'd2 ||
                    {name}.DUT.g_mem_cache.HIER.L1D.ALLOC_POLICY !== 1'b1 ||
                    {name}.DUT.g_mem_cache.HIER.L1D.REPL_POLICY !== 2'd0 ||
                    {name}.DUT.g_mem_cache.HIER.L1D.WB_DEPTH != 4 ||
                    {name}.DUT.g_mem_cache.HIER.L1D.N_MSHR != 2 ||
                    !{name}.DUT.g_mem_cache.HIER.L1D.L2_BUS_V2)
                    $fatal(1,"[FAIL] configuración EXCLUSIVA/WB/WA/LRU/WBUF4/MSHR2/v2");'''
        cfg.write_text(f'''module p28_cfg;
            defparam {name}.DUT.MEM_MODE={mode};
            initial begin #1;
                if ({name}.DUT.MEM_MODE!={mode}) $fatal(1,"[FAIL] modo efectivo");
                {policy}
                $display("[CONFIG_P28] banco={name} modo={mode}");
            end
        endmodule\n''')
        binary = work / 'sim.vvp'
        sources = [p for d in ('rtl', 'rtl-p2') for p in sorted((ROOT/d).glob('*.sv'))]
        args = [runner.tool('IVERILOG', 'iverilog'), '-g2012', '-Wall', '-Wno-timescale',
                '-I', ROOT, '-I', ROOT/'rtl', '-I', ROOT/'rtl-p2', '-I', ROOT/'tb',
                '-s', name, '-s', 'p28_cfg', '-o', binary, *sources, source, cfg]
        result = self.command(args, work, work/'compile.log')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.compiled[key] = binary
        return binary

    def simulate(self, binary, work, args=(), failure=None):
        """Ejecuta una simulación y exige éxito o una divergencia específica.

        Un negativo válido tiene código distinto de cero y el diagnóstico
        acordado, sin éxito nominal posterior. El log permite distinguir fallo
        de persistencia/handshake de un problema de sintaxis o infraestructura.
        """
        result = self.command([runner.tool('VVP', 'vvp'), '-n', binary, *args], work, work/'sim.log')
        output = result.stdout+result.stderr
        if failure is None:
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn('[FAIL]', output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn(failure, output)
        return output

    def runner_root(self, mode, mutant=None):
        """Prepara solo el adaptador temporal que necesita la API existente.

        El runner del issue9 selecciona el parámetro público al elaborar. Aquí
        la copia conserva el adaptador externo del #28 con sustitución verificada;
        la llamada a la API declara el mismo modo para verificarlo en el DUT;
        RTL y utilidades se enlazan en lectura. El assert dentro del banco prueba
        el modo elaborado incluso cuando el script invoca Icarus sin cfg externo.
        """
        work = self.folder(f'runner-root-{mode}')
        for d in ('rtl', 'rtl-p2', 'tb'):
            (work/d).symlink_to(ROOT/d, target_is_directory=True)
        (work/'tests/rtl').mkdir(parents=True)
        text = (ROOT/'tests/rtl/tb_assembled_program.sv').read_text()
        text = replace_once(text, '    parameter int MEM_MODE = 0',
                            f'    parameter int MEM_MODE = {mode}')
        text = replace_once(text, '    always #5 clk = ~clk;', f'''    initial begin #1;
            if(DUT.MEM_MODE!={mode}) $fatal(1,"[FAIL] modo efectivo runner");
            $display("[CONFIG_P28] runner modo={mode}");
        end
        always #5 clk = ~clk;''')
        if mutant:
            text = mutant(text)
        (work/'tests/rtl/tb_assembled_program.sv').write_text(text)
        return work

    def test_01_runner_modes_and_complete_memory(self):
        # Dos stores hit/miss conocidos y un load: después del corte los NOP
        # permiten mantenimiento. Los 16384 valores esperados se construyen con
        # cero inicial y los stores, sin leer caché. Detecta dumps prematuros y
        # registros desplazados por los flancos adicionales del flush.
        asm = 'sumai x4,x0,77 | nop | nop | nop\nnop\nnop\nnop | guardap x0,x4,256 | nop | nop\nnop | guardap x0,x4,260 | nop | nop\nnop | cargai x5,x0,260 | nop | nop\n'
        for mode in (0, 1, 2):
            with self.subTest(mode=mode):
                root = self.runner_root(mode)
                source = root/'input.asm'; source.write_text(asm)
                with mock.patch.object(runner, 'ROOT', root):
                    regs = runner.run_program(source, root/'out', {4:77, 5:77}, vcd=False, trace=True, mem_mode=mode)
                # Solo x4 y x5 deben cambiar; también comprobamos los otros
                # 30 registros para detectar escrituras ajenas al programa.
                self.assertEqual(regs, {r:77 if r in (4,5) else 0 for r in range(32)})
                words = [int(w, 16) for w in (root/'out/memory.txt').read_text().splitlines()]
                gold = [0]*16384; gold[64]=gold[65]=77
                self.assertEqual(words, gold)
                log = (root/'out/sim.log').read_text()
                self.assertIn(f'[CONFIG_P28] runner modo={mode}', log)
                self.assertIn(f'[FLUSH] fase=assembled modo={mode}', log)
                if mode<2:
                    self.assertIn('espera=0 salida=0', log)
                self.assertTrue((root/'out/trace.txt').is_file())

    def test_02_ce1108_fixture_modes(self):
        # El fixture original carga a=8,b=3,gp=0x4000. Usamos el mismo emisor
        # lineal/bundler y verificamos el mensaje original después de flush, sin
        # actualizar rutas ni compilar módulos externos reorganizados de CE1108.
        source = bundle_linear((ROOT/'examples/ce1108.linear').read_text())
        program = assemble_source(source)
        for mode in (0, 1, 2):
            with self.subTest(mode=mode):
                work = self.folder(f'ce1108-{mode}')
                mem = work/'program.mem'; mem.write_text(program.memory_text())
                output = self.simulate(self.compile_tb('tb_ce1108_program', mode), work,
                                       [f'+MEM={mem}', f'+BUNDLES={len(program.bundles)}'])
                self.assertIn('[PASS] expresión CE1108: (8 + 3) - 1 = 10', output)
                self.assertIn(f'[CONFIG_P28] banco=tb_ce1108_program modo={mode}', output)
                self.assertIn(f'[FLUSH] fase=ce1108 modo={mode}', output)

    def archivo(self, mode, data, only=False, text=None, failure=None):
        """Prepara imágenes externas y ejecuta el banco de archivo sin cambiarlo.

        data son los bytes de entrada; solo-descifrar recibe ciphertext. Devuelve
        memoria cifrada/descifrada y salida del proceso, con recursos conservados
        en work. Si failure identifica un negativo, exige código no cero y ese
        diagnóstico antes de retornar la salida, sin intentar aceptar dumps. El
        oráculo Feistel se construye en el caso, no desde el DUT.
        """
        work = self.folder(f'archivo-{mode}-{len(data)}-{only}')
        paths = []
        for name in ('cifrar', 'descifrar'):
            program = assemble_source((ROOT/f'examples/{name}_archivo.asm').read_text())
            p = work/f'{name}.mem'; p.write_text(program.memory_text()); paths.append(p)
        # $readmemh acepta rangos explícitos: inicialización independiente desde
        # 0x200, padding cero hasta ocho bytes y centinelas fuera del archivo.
        padded = data + bytes((-len(data))%8)
        words = [int.from_bytes(padded[j:j+4], 'little') for j in range(0,len(padded),4)]
        mem = work/'datos.mem'
        mem.write_text('@0080\n'+'\n'.join(f'{w:08x}' for w in words)+'\n@1000\n76543210\n@3fff\n89abcdef\n')
        args = [f'+CIFRAR={paths[0]}', f'+DESCIFRAR={paths[1]}', f'+DATOS={mem}', f'+BYTES={len(data)}']
        if only:args.append('+SOLO_DESCIFRAR')
        output = self.simulate(self.compile_tb('tb_archivo',mode,text),work,args,failure=failure)
        if failure is not None:
            return output
        def read_dump(name):
            # Los comentarios de $writememh no cambian los bytes del formato.
            tokens = re.sub(r'//[^\n]*', '', (work/name).read_text()).split()
            self.assertEqual(len(tokens), 16384)
            return b''.join(int(t,16).to_bytes(4,'little') for t in tokens)
        decrypted = read_dump('descifrado.mem')
        self.assertEqual(decrypted[0x4000:0x4004],bytes.fromhex('10325476'))
        self.assertEqual(decrypted[0xfffc:],bytes.fromhex('efcdab89'))
        return (None if only else read_dump('cifrado.mem')), decrypted, output

    def test_03_crypto_small_multiblock_and_only_decrypt(self):
        # Datos deterministas de 1,8,24 bytes cubren padding y varios bloques.
        # Cada modo debe producir el Feistel4 de referencia, conservar centinelas
        # y recuperar el texto. SOLO_DESCIFRAR se comprueba con ciphertext externo.
        for mode in (0,1,2):
            for size in (1,8,24):
                with self.subTest(mode=mode,size=size):
                    data = bytes((j*17+9)&255 for j in range(size))
                    padded = data + bytes((-size)%8)
                    expected = b''.join(feistel_block(padded[j:j+8]) for j in range(0,len(padded),8))
                    cipher, plain, output = self.archivo(mode,data)
                    self.assertEqual(cipher[512:512+len(expected)],expected)
                    self.assertEqual(plain[512:512+size],data)
                    self.assertIn(f'[FLUSH] fase=cifrado modo={mode}',output)
                    _, dec, output = self.archivo(mode,expected,only=True)
                    self.assertEqual(dec[512:512+len(padded)],padded)
                    self.assertIn('[PASS] tb_archivo:',output)

    def test_04_protocol_and_persistence(self):
        # Vacío, dirty hit, store MSHR, víctima en WBUF, repetición y reset.
        # El banco independiente prepara gold y confirma DMEM vieja antes del
        # flush, luego compara TODOS sus bytes. Mismo consumidor de handshake.
        work = self.folder('persistence')
        source = work/'tb_p28_persist.sv';source.write_text(persistence_bench())
        binary = self.compile_custom(source,'tb_p28_persist',work)
        output = self.simulate(binary,work)
        self.assertIn('[PASS] P28 persistencia completa',output)
        self.assertIn('[P28_PENDING] MSHR aceptado',output)
        self.assertIn('[P28_PENDING] write buffer',output)

    def compile_custom(self, source, name, work):
        """Compila un arnés temporal del test; exige compilación válida antes
        de considerar aserciones de persistencia o protocolo como evidencia."""
        binary=work/'sim.vvp'
        sources=[p for d in ('rtl','rtl-p2') for p in sorted((ROOT/d).glob('*.sv'))]
        result=self.command([runner.tool('IVERILOG','iverilog'),'-g2012','-I',ROOT,'-I',ROOT/'rtl','-I',ROOT/'rtl-p2',
                             '-I',ROOT/'tb','-s',name,'-o',binary,*sources,source],work,work/'compile.log')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        return binary

    def test_05_protocol_delayed_timeout_and_unknown(self):
        # Un productor diagnóstico retiene done durante300 flancos. Después del
        # handshake debe volver a0. No es una L2: prueba sincronización/timeout
        # del consumidor real con respuestas controladas, incluida X y Z. También
        # forzamos done retenido o desconocido al soltar req: la segunda espera
        # debe fallar, sin aceptar persistencia como permiso para reiniciar.
        for kind,failure in [('late',None),('never','vaciado de caché no completado'),
                             ('x','flush_done desconocido'),('z','flush_done desconocido'),
                             ('stuck','retorno de vaciado inválido'),
                             ('return-x','retorno de vaciado inválido')]:
            with self.subTest(kind=kind):
                work=self.folder('protocol-'+kind);src=work/'tb_p28_protocol.sv'
                src.write_text(protocol_bench(kind))
                out=self.simulate(self.compile_custom(src,'tb_p28_protocol',work),work,failure=failure)
                if kind=='late':self.assertIn('[PASS] P28 respuesta tardía',out)

    def test_06_negative_persistence_mutations(self):
        # Cada mutación conserva gold y el productor. Omitir flush, leer antes,
        # soltar req entre flancos, resetear antes o solo drenar cuatro avances
        # debe romper memoria o handshake, nunca sintaxis ni el oráculo. Omitir usa
        # un comentario de bloque: la comparación que sigue en la misma línea
        # debe seguir ejecutándose; comentarla invalidaría el control negativo.
        mutations = {
            # Sin solicitud, la comparación conservada debe encontrar dirty
            # y MSHR que aún no alcanzaron DMEM, contra el mismo gold.
            'omit': ('flush_cache("dirty-mshr");', '/* solicitud omitida; la comparación se conserva */'),
            # Leer antes de done viola persistencia incluso si luego se vacía;
            # compare_memory debe fallar antes de esa corrección tardía.
            'early-read': ('flush_cache("dirty-mshr");', 'compare_memory(); flush_cache("dirty-mshr");'),
            # Reset elimina estado dirty: el flush posterior no puede recuperar
            # esos datos; compare_memory los exige sin cambiar la expectativa.
            'early-reset': ('flush_cache("dirty-mshr");', 'reset=1; @(posedge clk); #1; reset=0; flush_cache("dirty-mshr");'),
            # Cuatro flancos drenan pipeline, pero no una caché WB exclusiva.
            # La misma comparación exige las palabras que siguen en L1-D.
            'pipeline-only': ('flush_cache("dirty-mshr");', 'repeat(4) @(posedge clk); #1;'),
            # Ningún flanco acepta este pulso: done no debe llegar. Se exige
            # el timeout del consumidor, no el watchdog global del arnés.
            'short-request': ("#1; flush_req=1'b1; #1;", "#1; flush_req=1'b1; #1; flush_req=0; #1;"),
        }
        for name,(old,new) in mutations.items():
            with self.subTest(mutation=name):
                work=self.folder('negative-'+name);src=work/'tb_p28_persist.sv'
                src.write_text(replace_once(persistence_bench(),old,new))
                failure='vaciado de caché no completado' if name=='short-request' else 'P28 memoria persistente'
                out=self.simulate(self.compile_custom(src,'tb_p28_persist',work),work,failure=failure)
                self.assertNotIn('[PASS] P28 persistencia completa',out)

    def test_07_runner_rejects_stale_missing_success_and_failed_process(self):
        # Preparamos dumps viejos que serían formalmente válidos. Un simulador
        # diagnóstico omite marcadores, falla aun imprimiéndolos o no produce
        # dumps nuevos. run_program debe rechazarlo y retirar los dumps; no
        # se altera la expectativa ni se considera ausencia de ejecutable éxito.
        for kind in ('empty','ok-without-flush','failed-with-success','success-without-dumps'):
            with self.subTest(kind=kind):
                work=self.folder('runner-negative-'+kind);source=work/'input.asm';source.write_text('nop\n')
                out=work/'out';out.mkdir()
                (out/'registers.txt').write_text(''.join(f'x{r} 00000000\n' for r in range(32)))
                (out/'memory.txt').write_text('00000000\n'*16384)
                fake=work/'simulator';msg='[OK] programa ejecutado: 1 bundles; 32 registros definidos'
                content='#!/usr/bin/env python3\n'
                if kind != 'success-without-dumps':
                    # Estos tres productores sí crean dumps nuevos válidos. Así
                    # cada rechazo depende del marcador/código incorrecto y no
                    # puede aprobar accidentalmente solo porque faltan archivos.
                    content += ("from pathlib import Path\nimport sys\n"
                                "args=dict(a[1:].split('=',1) for a in sys.argv[1:] if a.startswith('+') and '=' in a)\n"
                                "Path(args['REGDUMP']).write_text(''.join(f'x{r} 00000000\\n' for r in range(32)))\n"
                                "Path(args['MEMDUMP']).write_text('00000000\\n'*16384)\n")
                if kind!='empty':content+=f'print({msg!r})\n'
                if kind in ('failed-with-success','success-without-dumps'):
                    content+="print('[FLUSH] fase=assembled modo=0 espera=0 salida=0')\n"
                content+=f'raise SystemExit({1 if kind=="failed-with-success" else 0})\n'
                fake.write_text(content);fake.chmod(0o700)
                reason = ('falló simulator' if kind=='failed-with-success' else
                          'simulación sin dumps nuevos' if kind=='success-without-dumps' else
                          'simulación sin confirmación de vaciado')
                with mock.patch.dict(os.environ,{'VVP':str(fake)}),self.assertRaisesRegex(runner.SimulationError,reason):
                    runner.run_program(source,out,vcd=False)
                self.assertFalse((out/'memory.txt').exists())
                self.assertFalse((out/'registers.txt').exists())

    def test_08_running_program_is_not_a_quiescent_cut(self):
        # El bucle sigue guardando después del presupuesto. En modo2 el scan
        # necesita avanzar clk: el consumidor debe rechazar nuevos efectos, sin
        # introducir un halt ni afirmar una captura arquitectónica coherente.
        root=self.runner_root(2);source=root/'active.asm'
        source.write_text('sumai x4,x0,7 | nop | nop | nop\nnop\nnop\nloop: nop | guardap x0,x4,256 | sye x0,loop | nop\n')
        with mock.patch.object(runner,'ROOT',root),self.assertRaisesRegex(runner.SimulationError,'no quiescente'):
            runner.run_program(source,root/'out',vcd=False,cycles=12,mem_mode=2)
        self.assertFalse((root/'out/memory.txt').exists())

    def test_09_reset_before_encryption_persistence(self):
        # Se reinicia la caché ANTES del flush entre los dos programas: el dump
        # del cifrado perdería datos y el PC vuelve al programa. El banco real
        # debe rechazar sus nuevos efectos durante mantenimiento antes de crear
        # cifrado.mem. La mutación early-reset de persistencia contrasta además
        # la pérdida contra gold sin CPU, sin depender de este diagnóstico.
        text=(ROOT/'tests/rtl/tb_archivo.sv').read_text()
        text=replace_once(text,'flush_cache("cifrado");',
                          'reset=1; @(posedge clk); #1; reset=0; flush_cache("cifrado");')
        output = self.archivo(2,bytes(range(24)),text=text,
                              failure='[FAIL] programa no quiescente durante vaciado fase=cifrado')
        self.assertNotIn('[PASS] tb_archivo:',output)

    def test_10_ce1108_without_final_store_fails(self):
        # Una imagen NOP no ejecuta el fixture esperado. El presupuesto avanza,
        # pero la ausencia del store observable impide usar DMEM antigua como fin.
        work=self.folder('ce1108-no-finish');mem=work/'nop.mem';mem.write_text('0'*32+'\n')
        self.simulate(self.compile_tb('tb_ce1108_program',2),work,
                      [f'+MEM={mem}','+BUNDLES=1'],failure='no se observó store final')


def protocol_bench(kind):
    """Devuelve un productor diagnóstico y la tarea original del banco.

    No usa caché: controla done para aislar respuesta tardía, inactiva y X/Z.
    La única adaptación de la tarea es la constante de modo que imprime el log.
    La espera máxima pertenece al consumidor y debe producir su propio fallo.
    """
    task=replace_once(flush_task(),'DUT.MEM_MODE','2')
    done = {
        'late': 'flush_req && age>=300', 'never': "1'b0",
        'x': "1'bx", 'z': "1'bz",
        'stuck': 'age>=1',
        'return-x': "age>=1 ? (flush_req ? 1'b1 : 1'bx) : 1'b0",
    }[kind]
    # Los productores de salida incorrecta retienen age al bajar req; así el
    # defecto ocurre DESPUÉS de un done válido y ejercita el retorno a reposo.
    age_process = 'if(flush_req) age<=age+1;' if kind in ('stuck','return-x') else 'if(flush_req) age<=age+1; else age<=0;'
    return f'''`timescale 1ns/1ps
module tb_p28_protocol;
 logic clk=0,flush_req=0; wire flush_done={done};
 integer age=0,flush_limit={400 if kind=='late' else 4};
 always #5 clk=~clk;
 // age cuenta flancos de solicitud; el consumidor se observa POST-NBA.
 always @(posedge clk) {age_process}
 // No hay CPU en este productor diagnóstico: no existen efectos que vigilar.
 task automatic check_flush_quiescence(input string phase); begin end endtask
 {task}
 initial begin #1; flush_cache("diagnostico");
  if(age<300) $fatal(1,"[FAIL] respuesta tardía no ejercitada");
  $display("[PASS] P28 respuesta tardía"); $finish; end
 initial begin #10000; $fatal(1,"[FAIL] watchdog diagnóstico"); end
endmodule
'''


def persistence_bench():
    """Arnés de jerarquía real con referencia de65536 bytes preparada por stores.

    Copia la tarea física de flush; el chequeo de reposo se adapta a los puertos
    de este manejador sin CPU. No consulta privados de caché para obtener gold.
    Las expectativas se construyen antes de operar y se contrastan antes/después
    del vaciado y después de reset. Todo el texto se compila solo en temporales.
    """
    task=replace_once(flush_task(),'DUT.MEM_MODE','2')
    return '''`timescale 1ns/1ps
module tb_p28_persist;
 // Driver externo: re/we son demandas CPU, mwe es mantenimiento real a DMEM.
 // gold contiene todas las palabras esperadas; nunca se rellena desde caché.
 logic clk=0,reset=1,re=0,we=0,re_b=0,we_b=0,flush_req=0;
 logic [31:0] addr=0,data=0,addr_b=0,data_b=0; logic [3:0] be=15;
 wire [31:0] q,qb,ma,md,mq;wire [3:0] mb;wire stall,flush_done,mwe;
 integer flush_limit=1000,allocs=0;logic [31:0] gold[0:16383];
 always #5 clk=~clk;
 mem_hierarchy HIER(.clk(clk),.reset(reset),.re(re),.we(we),.be(be),.addr(addr),.wdata(data),.rdata(q),
  .re_b(re_b),.we_b(we_b),.addr_b(addr_b),.wdata_b(data_b),.rdata_b(qb),.stall(stall),
  .flush_req(flush_req),.flush_done(flush_done),.m_we(mwe),.m_be(mb),.m_addr(ma),.m_wdata(md),.m_rdata(mq));
 memory DMEM(.clk(clk),.we(mwe),.be(mb),.addr(ma),.wdata(md),.rdata(mq));
 // Confirmamos aceptación real de store miss antes de iniciar el flush.
 // El contador de eventos no supone que DMEM ya contiene su dato.
 always @(posedge clk) if(!reset&&HIER.L1D.ev_mshr_alloc) allocs++;
 task automatic check_flush_quiescence(input string phase);
  if({re,we,re_b,we_b}!==0) $fatal(1,"[FAIL] manejador activo durante flush %s",phase);
 endtask
''' + task + '''
 // Emite una demanda estable desde POST-NBA hasta el flanco de aceptación.
 // Recibe tipo/dirección/dato; un load debe coincidir con gold, un store lo
 // actualiza solo al aceptarse. El límite evita ocultar un handshake roto.
 task automatic access(input bit load,input logic [31:0] a,d);
  integer n;begin re=load;we=!load;addr=a;data=d;n=0;
   @(negedge clk);while(stall&&n<200)begin n++;@(negedge clk);end
   if(stall) $fatal(1,"[FAIL] acceso no completado");
   if(load&&q!==gold[a>>2]) $fatal(1,"[FAIL] dato de lectura");
   @(posedge clk);#1;if(!load)gold[a>>2]=d;re=0;we=0;
  end endtask
 // Recorre 16384 palabras: detecta pérdida y corrupción fuera de los stores.
 // Se invoca con el driver inactivo y después de done, salvo en mutaciones
 // que deliberadamente violan esa precondición sin modificar esta aserción.
 task automatic compare_memory;
  for(integer j=0;j<16384;j++) if(DMEM.mem[j]!==gold[j])
   $fatal(1,"[FAIL] P28 memoria persistente palabra=%0d esperado=%h observado=%h",j,gold[j],DMEM.mem[j]);
 endtask
 initial begin
  #1;for(integer j=0;j<16384;j++)begin gold[j]=32'h12340000^j;DMEM.mem[j]=gold[j];end
  if(HIER.L1D.INCL_POLICY!=2||HIER.L1D.WRITE_POLICY!=1||HIER.L1D.N_MSHR!=2)
   $fatal(1,"[FAIL] política real");
  repeat(2)@(negedge clk);reset=0;
  // Sin líneas sucias también debe cerrarse el protocolo. Luego preparamos
  // un dirty hit y un miss de store aceptado mientras su llenado sigue activo.
  flush_cache("empty");compare_memory();
  access(1,32'h08a0,0);access(0,32'h08a0,32'habcdef01);
  access(0,32'h2040,32'h98765432);
  if(allocs<1||DMEM.mem[32'h08a0>>2]===gold[32'h08a0>>2]||DMEM.mem[32'h2040>>2]===gold[32'h2040>>2])
   $fatal(1,"[FAIL] no se ejercitó dirty/MSHR con DMEM vieja");
  $display("[P28_PENDING] MSHR aceptado, DMEM desactualizada");
  flush_cache("dirty-mshr");compare_memory();
  // Repetir no altera datos. Reset posterior solo elimina estado de caché:
  // DMEM debe conservar exactamente los efectos que ya confirmó el primer flush.
  flush_cache("repeat");compare_memory();
  @(negedge clk);reset=1;repeat(2)@(negedge clk);reset=0;compare_memory();
  // A, B y C comparten conjunto: el tercer acceso expulsa la víctima sucia A.
  // Pedimos flush con la escritura todavía presentada al nivel inferior.
  access(1,32'h08a0,0);access(0,32'h08a0,32'hface1234);
  access(1,32'h10a0,0);access(1,32'h18a0,0);
  if(!(HIER.l2_req&&HIER.l2_we)) $fatal(1,"[FAIL] víctima no pendiente en bus");
  $display("[P28_PENDING] write buffer con víctima sucia");
  flush_cache("victim");compare_memory();
  // Puerto B del árbitro: lectura seguida por escritura de palabra conocida.
  // El dato ce1234fa corresponde a rotar face1234 ocho bits a la izquierda;
  // no se obtiene leyendo la salida del DUT para construir la expectativa.
  addr_b=32'h08a0;data_b=32'hce1234fa;re_b=1;we_b=1;
  begin integer n;n=0;@(negedge clk);while(stall&&n<200)begin n++;@(negedge clk);end
   if(stall)$fatal(1,"[FAIL] puertoB no termina");@(posedge clk);#1;end
  re_b=0;we_b=0;gold[32'h08a0>>2]=32'hce1234fa;
  flush_cache("port-b");compare_memory();
  // Solo hay éxito si todas las comparaciones completas y los handshakes pasan.
  $display("[PASS] P28 persistencia completa");$finish;
 end
 initial begin #100000; $fatal(1,"[FAIL] watchdog persistencia");end
endmodule
'''


if __name__ == '__main__':
    unittest.main()
