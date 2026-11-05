# Organización interna (microarquitectura) — Proyecto Grupal 1

> Curso: CE4301 – Arquitectura de Computadores I, II Semestre 2026  
> Profesor: Dr.-Ing. Jeferson González Gómez  
> Entrega: Implementación Funcional (Entrega 2, 14 de octubre de 2026)  
> Equipo: Dylan Guerrero González, José García Izaguirre, Javier Hernández Castillo, Alejandro Vásquez Oviedo, Fabricio Mena Mejia

Cómo se implementa en SystemVerilog la ISA de [`isa.md`](isa.md): diagrama de bloques, pipeline,
dispatch de los slots, unidades funcionales y sus conexiones. El detalle de cada componente está en
[`simulation.md`](simulation.md).

## Diagrama de bloques

![Diagrama de bloques del procesador](../img/diagrama_organizacion.png)

Las barras grises son los registros de segmentación. Las 4 unidades de EX reciben sus operandos de
ID/EX y trabajan en paralelo en el mismo ciclo. El conector 1 es la redirección del PC (salto tomado
o excepción) con el vaciado de IF/ID e ID/EX, y el 2 es el permiso que ESTADO da al decodificador
cripto.

## Pipeline

Cuatro etapas, *Fetch → Decode/Dispatch → Execute → Writeback*, con tres registros de segmentación
(`pipeline_if_id`, `pipeline_id_ex` y `pipeline_ex_wb`). Cada bundle de 128 bits avanza completo y
entra uno nuevo por ciclo. No hay etapa MEM: la memoria de datos se accede en EX.

| Etapa | Qué hace |
|:---|:---|
| IF | El PC (alineado a 16 bytes, `0x0000` después del reset) lee la memoria de instrucciones de forma combinacional; IF/ID guarda el bundle y su PC. El PC avanza 16 bytes por ciclo, salvo un salto tomado o una excepción |
| ID | `dispatch` separa los 4 slots y cada decodificador fijo los decodifica en paralelo (slot 0 ALU, 1 LSU, 2 BRU, 3 CRIPTO). `TIPO = 0000000` es NOP y no invoca a la unidad. Se leen los operandos del banco (8 puertos, 2 por slot) y `decoder_crypto` valida los permisos contra ESTADO. Todo se guarda en ID/EX |
| EX | ALU, LSU, BRU y unidad criptográfica operan a la vez sobre los operandos de ID/EX. La LSU accede a la memoria de datos por el puerto A; `vcr` y `camcon`, por el puerto B. La BRU resuelve los saltos. La bóveda se escribe al final de EX |
| WB | `wb` junta los resultados (hasta 5: ALU, LSU, BRU y el par de la cripto) y los escribe en el banco en el flanco al final de la etapa. ESTADO se actualiza aquí |

La ALU llega a WB por `pipeline_ex_wb`; la LSU, la BRU y la cripto registran su resultado
internamente, con la misma latencia.

**Bóveda escrita en EX.** La bóveda se escribe al final de EX, como la memoria de datos, y no en WB.
Es seguro porque un bundle que llega a EX ya no se puede anular: los saltos y la excepción se
resuelven en EX y solo anulan los bundles de IF e ID, o al propio bundle con la excepción, que
entonces no escribe. La ventaja es que las instrucciones que leen la bóveda (la ronda Feistel, y
`vcr` y `camcon` con la contraseña) también están en EX: una llave cargada con `ell` en el bundle N se
puede usar desde el N+1 (en WB sería desde el N+2), y no hace falta llevar los 64 bits de la llave por
el registro EX/WB.

**Ejemplo.** Desde el ciclo 4 hay un bundle distinto en cada etapa:

| Ciclo | IF | ID | EX | WB |
|---|---|---|---|---|
| 1 | B0 | | | |
| 2 | B1 | B0 | | |
| 3 | B2 | B1 | B0 | |
| 4 | B3 | B2 | B1 | B0 |
| 5 | B4 | B3 | B2 | B1 |

Si B1 es un salto tomado, en el ciclo 4 la BRU lo resuelve en EX: B2 y B3 (en ID e IF) se anulan y en
el ciclo 5 entra a IF el bundle destino. `tb_top` comprueba los 4 bundles a la vez.

## Riesgos y excepción de privilegio

- **Sin forwarding, scoreboarding ni stalls.** El banco no tiene bypass: el valor que escribe el
  bundle N se lee desde el N+3. La calendarización la hace el software, y `tools/assembler.py` rechaza
  los programas que no la cumplen.
- **Sin conflictos estructurales.** Cada slot tiene sus puertos del banco (2 de lectura; 1 de
  escritura, 2 para la cripto) y la memoria tiene un puerto para la LSU y otro para la cripto. Que dos
  unidades escriban el mismo registro es un error del software: `wb` lo señala con `conflict` y gana
  CRIPTO > BRU > LSU > ALU.
- **Saltos sin delay slots.** Un salto tomado anula los 2 bundles de IF e ID (2 ciclos de
  penalización); uno no tomado no cuesta nada.
- **Excepción de privilegio.** Si una instrucción cripto no tiene permiso (`fsl`, `fsli`, `ell` y
  `camcon` necesitan AUTH = 1; `setpwd`, INIT = 1), al llegar a EX se anula su bundle completo y los 2
  siguientes, y el PC salta a `TRAP_VECTOR` = `0x3FF0`, el último bundle de la memoria de
  instrucciones. `trap_pc` y `trap_count` guardan el PC culpable y la cantidad de excepciones (solo
  para observación). Como ESTADO se escribe en WB y se valida en ID, después de `vcr` la instrucción
  que necesita AUTH = 1 va 3 bundles después.

## Componentes

| Componente | Organización |
|:---|:---|
| Banco de registros | 32 × 32 bits, x0 = 0, 8 lecturas combinacionales y 5 escrituras, reset síncrono |
| Memoria de instrucciones | 1024 bundles de 128 bits (16 KB), lectura combinacional, carga con `$readmemh` (`+IMEM`); `0x3FF0` es `TRAP_VECTOR` |
| Memoria de datos | 64 KB, por byte, *little-endian*, lectura combinacional, escritura con byte enables, 2 puertos (A: LSU, B: cripto). Espacio separado de la memoria de instrucciones |
| Bóveda de llaves | 4 llaves de 128 bits (4 subllaves de 32) y la contraseña, dentro de `crypto_unit`. Solo la lee la ronda Feistel; no tiene camino a registros ni a memoria. El reset la borra |
| ESTADO | AUTH e INIT, dentro de `crypto_unit`; no lo lee ninguna instrucción |
| Parámetros | `rtl/isa_defs.sv`: `NUM_SLOTS`, `SLOT_W`, `BUNDLE_W`, `BUNDLE_BYTES`, `IMEM_BUNDLES`, `DMEM_BYTES` y `TRAP_VECTOR` |

## Módulos SystemVerilog

| Bloque | Archivos |
|---|---|
| IF | `rtl/pc_branch.sv`, `rtl/instruction_memory.sv`, `rtl/fetch.sv`, `rtl/pipeline_if_id.sv` |
| ID | `rtl/dispatch.sv`, `rtl/decoder_alu.sv`, `rtl/decoder_lsu.sv`, `rtl/decoder_bru.sv`, `rtl/decoder_crypto.sv`, `rtl/regfile.sv`, `rtl/pipeline_id_ex.sv` |
| EX | `rtl/alu.sv`, `rtl/lsu.sv`, `rtl/memory.sv`, `rtl/bru.sv`, `rtl/crypto_unit.sv`, `rtl/key_vault.sv` |
| WB | `rtl/pipeline_ex_wb.sv`, `rtl/wb.sv` |
| Integración | `rtl-p2/top.sv` (conexiones, flush y excepción) y `rtl/isa_defs.sv` (códigos y parámetros) |
| Pruebas | Un testbench por módulo en `tb/` (`pc_branch` e `instruction_memory` se prueban dentro de `top`) más `tb_top`, `tb_pipeline_integracion` y `tb_pipeline_cripto` sobre el procesador completo ([simulation.md](simulation.md), sección 13) |
