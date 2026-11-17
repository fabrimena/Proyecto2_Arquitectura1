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


def temporal_metrics(l2, ram, available):
    """Valida cohortes y deriva medias sin sumar niveles solapados.

    Recibe listas de 14/22 unsigned y disponibilidad REAL+modo2+PERF. Devuelve
    poblaciones, tiempos y diagnósticos sin efectos ni mutación. ValueError
    rechaza protocolo, asociación rota, cohortes imposibles y wrap observable.
    None expresa población vacía. Las tasas L2 son de lecturas completas;
    las tasas globales de clasificación permanecen en el esquema anterior.
    RAM no tiene hits/misses de caché: esas tasas no son aplicables.
    """
    if (not isinstance(l2, list) or len(l2) != 14 or
            not isinstance(ram, list) or len(ram) != 22 or
            any(type(v) is not int or not 0 <= v < 1 << 64 for v in l2 + ram)):
        raise ValueError('forma/ancho temporal inválido')
    if not available and any(l2 + ram):
        raise ValueError('latencia activa sin jerarquía real instrumentada')
    if l2[6] or ram[13]:
        raise ValueError('protocolo temporal con errores; asociación inválida')
    nh, nm, sh, sm = l2[:4]
    if (sh < nh or sm < nm or (not nh and sh) or (not nm and sm) or
            l2[4] != sh + sm - nh - nm or l2[12] != nh + nm + l2[5] or
            l2[9] != l2[12] + l2[7] or l2[13] > l2[7] or
            l2[10] < l2[11] or l2[10] - l2[11] > l2[8] or
            l2[8] - (l2[10] - l2[11]) > l2[7]):
        raise ValueError('población/tiempo L2 incompatible')
    nr, nw, sr, sw = ram[:4]
    if (sr < nr or sw < nw or (not nr and sr) or (not nw and sw) or
            ram[4] != sr + sw - nr - nw or ram[6] < ram[5] or
            (not ram[5] and ram[6]) or
            ram[17] != nr + nw + ram[5] + ram[7] + ram[8] or
            ram[16] != ram[17] + ram[14] or ram[14] not in (0, 1) or
            ram[15] > ram[14] or ram[19] not in (0, 1) or
            ram[9] != ram[11] or ram[11] > nr + nw or
            ram[10] != 2 * ram[5] or ram[12] != ram[5]):
        raise ValueError('población/tiempo/reintento RAM incompatible')
    if ((ram[17] and (ram[18] == 0 or ram[21] - ram[20] != ram[18])) or
            (not ram[17] and any(ram[18:]))):
        raise ValueError('fechas de transacción RAM incompatibles')
    n = nh + nm
    return dict(available=bool(available), unit='ciclos clk entre flancos PRE',
                population='aceptadas y completadas sin flancos deshabilitados',
                l2=dict(accesses=n, hits=nh, misses=nm, service_cycles=sh + sm,
                        hit_service_cycles=sh, miss_service_cycles=sm,
                        wait_cycles=l2[4], hit_rate=ratio(nh,n), miss_rate=ratio(nm,n),
                        hit_mean_cycles=ratio(sh,nh), miss_mean_cycles=ratio(sm,nm),
                        amat_cycles=ratio(sh+sm,n), excluded=l2[5], pending=l2[7],
                        pending_ineligible=l2[13], pending_classifications=l2[8],
                        accepted_reads=l2[9], accepted_writes=l2[10],
                        classified_posted_writes=l2[11], write_amat_cycles=None),
                ram=dict(accesses=nr+nw, reads=nr, writes=nw, service_cycles=sr+sw,
                         read_service_cycles=sr, write_service_cycles=sw,
                         read_mean_cycles=ratio(sr,nr), write_mean_cycles=ratio(sw,nw),
                         mean_cycles=ratio(sr+sw,nr+nw), wait_cycles=ram[4],
                         failures=ram[5], failure_service_cycles=ram[6],
                         failure_mean_cycles=ratio(ram[6],ram[5]),
                         excluded_successes=ram[7], excluded_failures=ram[8],
                         success_timeouts=ram[9], failure_timeouts=ram[10],
                         success_retries=ram[11], failure_retries=ram[12],
                         pending=ram[14], pending_eligible=ram[15],
                         accepted=ram[16], finished=ram[17],
                         last_latency=ram[18], last_write=ram[19],
                         last_accept_tick=ram[20], last_finish_tick=ram[21],
                         hit_rate=None, miss_rate=None),
                hierarchical_sum_cycles=None)


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
    result = dict(vliw=v, stages=stages, l1=l1, k1b=latency, classes=classes,l2=l2,ram=ram,
                ipc=ratio(v[2],v[0]), cpi=ratio(v[0],v[2]),
                l1_hit_rate=ratio(h1,a1),l1_miss_rate=ratio(a1-h1,a1),
                l2_hit_rate=ratio(h2,a2),l2_miss_rate=ratio(a2-h2,a2),
                l1_observed_service=ratio(latency[1],latency[0]),
                ram_accesses=ram[0]+ram[1], ram_utilization=ratio(ram[2],ram[3]))
    # Extensión optativa: los logs históricos conservan exactamente su objeto.
    # Una extensión incompleta/malformada nunca se degrada a formato histórico.
    if any(line.startswith(('[PERF_L2_LATENCY]', '[PERF_RAM_LATENCY]'))
           for line in output.splitlines()):
        lt=vector('PERF_L2_LATENCY',14); rt=vector('PERF_RAM_LATENCY',22)
        # RAM es serial: duraciones de cohortes completas no se solapan y caben
        # en sus flancos medidos. L2 sí admite solapamiento: NO se aplica allí
        # esta cota. Clasificados/aceptados son cotas, nunca denominadores nuevos.
        if (rt[2]+rt[3]+rt[6]>v[0] or rt[0]>ram[0] or rt[1]>ram[1] or
                lt[0]>l2[0] or lt[1]>l2[1]):
            raise ValueError('cohorte temporal fuera de ventana/población pública')
        result.update(temporal_schema=1, l2_latency=lt, ram_latency=rt,
                      temporal=temporal_metrics(lt,rt,mode==2 and not cfg['L2_MODEL'] and cfg['PERF_ENABLE']))
    return result
