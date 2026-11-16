# Benchmark stride del issue #29, para el runner real de memoria.
# Entrada: GPR y los 65536 bytes de DMEM en cero; solo ISA original, slot LSU 1.
# Salidas: 32 palabras con valores 1..32, x5=32, x6=1056 y x7=1.
# Población: 32 guardap y 64 cargai; cada palabra es alineada, sin accesos por byte.
# Dependencias: assembler vigente, N+3, top y flush del #28 mediante el runner.
# El código de preparación es idéntico en longitud para comparar los patrones.
# No mide tiempo puro de memoria: incluye ALU, NOP y el arranque de cada dirección.
# Detecta pérdida, reordenamiento de stores, cargas falsas y daños fuera del arreglo.
# Direcciones 2048*i, i=0..31: conjunto=(direccion//32)%64=0 en todas.
# Son 32 etiquetas distintas para dos vías; los conflictos se contrastan con ejecución real.
# Última palabra en 63488, dentro de DMEM; 128 bytes útiles, extensión hasta 63492.
# Direcciones por pasada: 0x0000,0x0800,0x1000,0x1800,0x2000,0x2800,0x3000,0x3800,0x4000,0x4800,0x5000,0x5800,0x6000,0x6800,0x7000,0x7800,0x8000,0x8800,0x9000,0x9800,0xa000,0xa800,0xb000,0xb800,0xc000,0xc800,0xd000,0xd800,0xe000,0xe800,0xf000,0xf800

# Fase 1: inicializa las 32 palabras sin precargar DMEM desde el banco.
# Escritura 1: M[0x0000]=1; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,1 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 2: M[0x0800]=2; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,2 | nop | nop | nop
sumai x4,x0,2 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 3: M[0x1000]=3; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,4 | nop | nop | nop
sumai x4,x0,3 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 4: M[0x1800]=4; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,6 | nop | nop | nop
sumai x4,x0,4 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 5: M[0x2000]=5; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,8 | nop | nop | nop
sumai x4,x0,5 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 6: M[0x2800]=6; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,10 | nop | nop | nop
sumai x4,x0,6 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 7: M[0x3000]=7; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,12 | nop | nop | nop
sumai x4,x0,7 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 8: M[0x3800]=8; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,14 | nop | nop | nop
sumai x4,x0,8 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 9: M[0x4000]=9; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,16 | nop | nop | nop
sumai x4,x0,9 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 10: M[0x4800]=10; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,18 | nop | nop | nop
sumai x4,x0,10 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 11: M[0x5000]=11; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,20 | nop | nop | nop
sumai x4,x0,11 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 12: M[0x5800]=12; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,22 | nop | nop | nop
sumai x4,x0,12 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 13: M[0x6000]=13; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,24 | nop | nop | nop
sumai x4,x0,13 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 14: M[0x6800]=14; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,26 | nop | nop | nop
sumai x4,x0,14 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 15: M[0x7000]=15; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,28 | nop | nop | nop
sumai x4,x0,15 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 16: M[0x7800]=16; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,30 | nop | nop | nop
sumai x4,x0,16 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 17: M[0x8000]=17; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,32 | nop | nop | nop
sumai x4,x0,17 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 18: M[0x8800]=18; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,34 | nop | nop | nop
sumai x4,x0,18 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 19: M[0x9000]=19; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,36 | nop | nop | nop
sumai x4,x0,19 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 20: M[0x9800]=20; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,38 | nop | nop | nop
sumai x4,x0,20 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 21: M[0xa000]=21; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,40 | nop | nop | nop
sumai x4,x0,21 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 22: M[0xa800]=22; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,42 | nop | nop | nop
sumai x4,x0,22 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 23: M[0xb000]=23; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,44 | nop | nop | nop
sumai x4,x0,23 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 24: M[0xb800]=24; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,46 | nop | nop | nop
sumai x4,x0,24 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 25: M[0xc000]=25; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,48 | nop | nop | nop
sumai x4,x0,25 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 26: M[0xc800]=26; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,50 | nop | nop | nop
sumai x4,x0,26 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 27: M[0xd000]=27; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,52 | nop | nop | nop
sumai x4,x0,27 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 28: M[0xd800]=28; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,54 | nop | nop | nop
sumai x4,x0,28 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 29: M[0xe000]=29; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,56 | nop | nop | nop
sumai x4,x0,29 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 30: M[0xe800]=30; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,58 | nop | nop | nop
sumai x4,x0,30 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 31: M[0xf000]=31; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,60 | nop | nop | nop
sumai x4,x0,31 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 32: M[0xf800]=32; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,62 | nop | nop | nop
sumai x4,x0,32 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop

# Fase 2: pasada de lectura 1; cada dato se suma a x6 después de dos NOP.
# Lectura 1 de pasada 1: espera 1 desde 0x0000; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 2 de pasada 1: espera 2 desde 0x0800; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 3 de pasada 1: espera 3 desde 0x1000; detecta desplazamientos y corrupción.
sumai x20,x0,4 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 4 de pasada 1: espera 4 desde 0x1800; detecta desplazamientos y corrupción.
sumai x20,x0,6 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 5 de pasada 1: espera 5 desde 0x2000; detecta desplazamientos y corrupción.
sumai x20,x0,8 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 6 de pasada 1: espera 6 desde 0x2800; detecta desplazamientos y corrupción.
sumai x20,x0,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 7 de pasada 1: espera 7 desde 0x3000; detecta desplazamientos y corrupción.
sumai x20,x0,12 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 8 de pasada 1: espera 8 desde 0x3800; detecta desplazamientos y corrupción.
sumai x20,x0,14 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 9 de pasada 1: espera 9 desde 0x4000; detecta desplazamientos y corrupción.
sumai x20,x0,16 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 10 de pasada 1: espera 10 desde 0x4800; detecta desplazamientos y corrupción.
sumai x20,x0,18 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 11 de pasada 1: espera 11 desde 0x5000; detecta desplazamientos y corrupción.
sumai x20,x0,20 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 12 de pasada 1: espera 12 desde 0x5800; detecta desplazamientos y corrupción.
sumai x20,x0,22 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 13 de pasada 1: espera 13 desde 0x6000; detecta desplazamientos y corrupción.
sumai x20,x0,24 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 14 de pasada 1: espera 14 desde 0x6800; detecta desplazamientos y corrupción.
sumai x20,x0,26 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 15 de pasada 1: espera 15 desde 0x7000; detecta desplazamientos y corrupción.
sumai x20,x0,28 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 16 de pasada 1: espera 16 desde 0x7800; detecta desplazamientos y corrupción.
sumai x20,x0,30 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 17 de pasada 1: espera 17 desde 0x8000; detecta desplazamientos y corrupción.
sumai x20,x0,32 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 18 de pasada 1: espera 18 desde 0x8800; detecta desplazamientos y corrupción.
sumai x20,x0,34 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 19 de pasada 1: espera 19 desde 0x9000; detecta desplazamientos y corrupción.
sumai x20,x0,36 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 20 de pasada 1: espera 20 desde 0x9800; detecta desplazamientos y corrupción.
sumai x20,x0,38 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 21 de pasada 1: espera 21 desde 0xa000; detecta desplazamientos y corrupción.
sumai x20,x0,40 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 22 de pasada 1: espera 22 desde 0xa800; detecta desplazamientos y corrupción.
sumai x20,x0,42 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 23 de pasada 1: espera 23 desde 0xb000; detecta desplazamientos y corrupción.
sumai x20,x0,44 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 24 de pasada 1: espera 24 desde 0xb800; detecta desplazamientos y corrupción.
sumai x20,x0,46 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 25 de pasada 1: espera 25 desde 0xc000; detecta desplazamientos y corrupción.
sumai x20,x0,48 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 26 de pasada 1: espera 26 desde 0xc800; detecta desplazamientos y corrupción.
sumai x20,x0,50 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 27 de pasada 1: espera 27 desde 0xd000; detecta desplazamientos y corrupción.
sumai x20,x0,52 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 28 de pasada 1: espera 28 desde 0xd800; detecta desplazamientos y corrupción.
sumai x20,x0,54 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 29 de pasada 1: espera 29 desde 0xe000; detecta desplazamientos y corrupción.
sumai x20,x0,56 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 30 de pasada 1: espera 30 desde 0xe800; detecta desplazamientos y corrupción.
sumai x20,x0,58 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 31 de pasada 1: espera 31 desde 0xf000; detecta desplazamientos y corrupción.
sumai x20,x0,60 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 32 de pasada 1: espera 32 desde 0xf800; detecta desplazamientos y corrupción.
sumai x20,x0,62 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop

# Fase 3: pasada de lectura 2; cada dato se suma a x6 después de dos NOP.
# Lectura 1 de pasada 2: espera 1 desde 0x0000; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 2 de pasada 2: espera 2 desde 0x0800; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 3 de pasada 2: espera 3 desde 0x1000; detecta desplazamientos y corrupción.
sumai x20,x0,4 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 4 de pasada 2: espera 4 desde 0x1800; detecta desplazamientos y corrupción.
sumai x20,x0,6 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 5 de pasada 2: espera 5 desde 0x2000; detecta desplazamientos y corrupción.
sumai x20,x0,8 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 6 de pasada 2: espera 6 desde 0x2800; detecta desplazamientos y corrupción.
sumai x20,x0,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 7 de pasada 2: espera 7 desde 0x3000; detecta desplazamientos y corrupción.
sumai x20,x0,12 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 8 de pasada 2: espera 8 desde 0x3800; detecta desplazamientos y corrupción.
sumai x20,x0,14 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 9 de pasada 2: espera 9 desde 0x4000; detecta desplazamientos y corrupción.
sumai x20,x0,16 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 10 de pasada 2: espera 10 desde 0x4800; detecta desplazamientos y corrupción.
sumai x20,x0,18 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 11 de pasada 2: espera 11 desde 0x5000; detecta desplazamientos y corrupción.
sumai x20,x0,20 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 12 de pasada 2: espera 12 desde 0x5800; detecta desplazamientos y corrupción.
sumai x20,x0,22 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 13 de pasada 2: espera 13 desde 0x6000; detecta desplazamientos y corrupción.
sumai x20,x0,24 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 14 de pasada 2: espera 14 desde 0x6800; detecta desplazamientos y corrupción.
sumai x20,x0,26 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 15 de pasada 2: espera 15 desde 0x7000; detecta desplazamientos y corrupción.
sumai x20,x0,28 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 16 de pasada 2: espera 16 desde 0x7800; detecta desplazamientos y corrupción.
sumai x20,x0,30 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 17 de pasada 2: espera 17 desde 0x8000; detecta desplazamientos y corrupción.
sumai x20,x0,32 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 18 de pasada 2: espera 18 desde 0x8800; detecta desplazamientos y corrupción.
sumai x20,x0,34 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 19 de pasada 2: espera 19 desde 0x9000; detecta desplazamientos y corrupción.
sumai x20,x0,36 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 20 de pasada 2: espera 20 desde 0x9800; detecta desplazamientos y corrupción.
sumai x20,x0,38 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 21 de pasada 2: espera 21 desde 0xa000; detecta desplazamientos y corrupción.
sumai x20,x0,40 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 22 de pasada 2: espera 22 desde 0xa800; detecta desplazamientos y corrupción.
sumai x20,x0,42 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 23 de pasada 2: espera 23 desde 0xb000; detecta desplazamientos y corrupción.
sumai x20,x0,44 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 24 de pasada 2: espera 24 desde 0xb800; detecta desplazamientos y corrupción.
sumai x20,x0,46 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 25 de pasada 2: espera 25 desde 0xc000; detecta desplazamientos y corrupción.
sumai x20,x0,48 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 26 de pasada 2: espera 26 desde 0xc800; detecta desplazamientos y corrupción.
sumai x20,x0,50 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 27 de pasada 2: espera 27 desde 0xd000; detecta desplazamientos y corrupción.
sumai x20,x0,52 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 28 de pasada 2: espera 28 desde 0xd800; detecta desplazamientos y corrupción.
sumai x20,x0,54 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 29 de pasada 2: espera 29 desde 0xe000; detecta desplazamientos y corrupción.
sumai x20,x0,56 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 30 de pasada 2: espera 30 desde 0xe800; detecta desplazamientos y corrupción.
sumai x20,x0,58 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 31 de pasada 2: espera 31 desde 0xf000; detecta desplazamientos y corrupción.
sumai x20,x0,60 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 32 de pasada 2: espera 32 desde 0xf800; detecta desplazamientos y corrupción.
sumai x20,x0,62 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop

# x7 acredita llegada al final útil; dos NOP y el drenado de cuatro avances llevan todo a WB.
sumai x7,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
# Reposo útil permanente: sye a sí mismo sin enlace. El núcleo no termina ni escribe durante mantenimiento.
fin: nop | nop | sye x0,fin | nop
