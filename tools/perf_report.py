"""Contratos de configuración y métricas exportadas por el banco RTL.

Entradas: parámetros enteros de elaboración y marcadores POST-NBA. Salidas:
configuración normalizada y cocientes con población explícita. No ejecuta RTL,
no escribe archivos y no altera estado. ValueError identifica formatos, políticas
prohibidas e identidades imposibles; run_program lo traduce a SimulationError.
Las ventanas parciales son válidas: una petición pendiente no se convierte en
acceso completado. Un denominador cero produce None, nunca un cero inventado.
"""
from __future__ import annotations
import re

DEFAULTS = dict(L2_MODEL=0, MEM_DIV=4, PERF_ENABLE=1, ROM_SYNC=1, WRITE_POLICY=1,
                ALLOC_POLICY=1, INCL_POLICY=2, L1_REPL_POLICY=0, L2_REPL_POLICY=0,
                N_MSHR=2, WB_DEPTH=4, EB_DEPTH=4, STALL_CYCLES=3)


def configuration(values=None):
    """Completa parámetros sin mutar el diccionario; rechaza truncamientos RTL.

    La asignación depende de la política de escritura si no se indicó. Se
    verifica antes de compilar: un valor fuera de bits no puede normalizarse
    silenciosamente al llegar a un parámetro logic del hardware.
    """
    if values is not None and not isinstance(values, dict):
        raise ValueError('configuración requiere objeto')
    values = values or {}
    if set(values)-set(DEFAULTS):
        raise ValueError('configuración desconocida: '+str(set(values)-set(DEFAULTS)))
    cfg = DEFAULTS | values
    if 'ALLOC_POLICY' not in values:
        cfg['ALLOC_POLICY'] = cfg['WRITE_POLICY']
    ranges = dict(L2_MODEL=(0,1), MEM_DIV=(2,3,4,5), PERF_ENABLE=(0,1), ROM_SYNC=(0,1),
                  WRITE_POLICY=(0,1), ALLOC_POLICY=(0,1), INCL_POLICY=(1,2),
                  L1_REPL_POLICY=(0,1,2), L2_REPL_POLICY=(0,1), N_MSHR=range(1,5),
                  WB_DEPTH=range(2,9), EB_DEPTH=range(4,17), STALL_CYCLES=range(1,1001))
    for k,v in cfg.items():
        if type(v) is not int or v not in ranges[k]:
            raise ValueError('configuración fuera de contrato: '+k)
    if cfg['INCL_POLICY']==2 and (not cfg['WRITE_POLICY'] or not cfg['ALLOC_POLICY']):
        raise ValueError('política prohibida: exclusiva requiere WB+WA')
    return cfg


def ratio(numerator, denominator):
    """Cociente externo; None identifica ausencia de población, incluido IPC 0/0."""
    return numerator/denominator if denominator else None


def metrics(output, mode, cfg):
    """Lee cada vector único y comprueba invariantes sin usar arreglos privados.

    Las longitudes pertenecen al esquema de observación 2. El orden de eventos
    L1/K1-B y L2 se documenta en performance-analysis. Se conserva el vector
    original para auditoría; las tasas usan accesos clasificados del mismo nivel.
    """
    def vector(name, count):
        """Extrae un único vector decimal de longitud y ancho exactos; rechaza ausencia, duplicados o X/Z sin modificar archivos."""
        lines = [s for s in output.splitlines() if s.startswith('['+name+']')]
        if len(lines)!=1 or not re.fullmatch(r'\['+name+r'\](?: [0-9]+){'+str(count)+'}',lines[0]):
            raise ValueError('marcador '+name+' ausente, duplicado o mal formado')
        values=list(map(int,lines[0].split()[1:]))
        if any(v>=1<<64 for v in values):
            raise ValueError('contador fuera de 64 bits: '+name)
        return values
    v=vector('PERF_VLIW',5)
    stages=[vector('PERF_STAGE'+str(k),4) for k in range(4)]
    l1=vector('PERF_L1',19); l2=vector('PERF_L2',10); ram=vector('PERF_RAM',6)
    latency=vector('PERF_K1B',6)
    classes=[vector('PERF_CLASS'+str(k),3) for k in range(4)]
    if v[1]>v[0] or v[2]>4*v[1] or v[3]+v[4]>v[0]:
        raise ValueError('contadores VLIW incompatibles')
    if any(s[0]+s[1]!=v[0] or s[2]!=v[3] or s[3]>min(s[0],s[2]) for s in stages):
        raise ValueError('contadores por etapa incompatibles')
    if latency[1]!=latency[0]+latency[2] or any(c[1]!=c[0]+c[2] for c in classes):
        raise ValueError('contadores K1B incompatibles')
    if any(sum(c[k] for c in classes)!=latency[k] for k in range(3)):
        raise ValueError('poblaciones K1B incompatibles')
    if ram[2]>ram[3] or (mode==2 and not cfg['L2_MODEL'] and ram[3]!=v[0]):
        raise ValueError('contadores RAM/ventana incompatibles')
    if (mode!=2 or cfg['L2_MODEL']) and any(l2+ram):
        raise ValueError('eventos de jerarquía real inexistente')
    if mode!=2 and any(l1+latency):
        raise ValueError('eventos de L1 inexistente')
    if not cfg['PERF_ENABLE'] and any(v+l1+l2+ram+latency+sum(stages,[])+sum(classes,[])):
        raise ValueError('contadores activos con PERF_ENABLE=0')
    h1=l1[0]+l1[2]; a1=sum(l1[:4]); h2=l2[0]+l2[2]; a2=sum(l2[:4])
    return dict(vliw=v, stages=stages, l1=l1, k1b=latency, classes=classes,l2=l2,ram=ram,
                ipc=ratio(v[2],v[0]), cpi=ratio(v[0],v[2]),
                l1_hit_rate=ratio(h1,a1),l1_miss_rate=ratio(a1-h1,a1),
                l2_hit_rate=ratio(h2,a2),l2_miss_rate=ratio(a2-h2,a2),
                l1_observed_service=ratio(latency[1],latency[0]),
                ram_accesses=ram[0]+ram[1], ram_utilization=ratio(ram[2],ram[3]))
