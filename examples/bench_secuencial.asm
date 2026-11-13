# Benchmark secuencial del issue #29, para el runner real de memoria.
# Entrada: GPR y los 65536 bytes de DMEM en cero; solo ISA original, slot LSU 1.
# Salidas: 32 palabras con valores 1..32, x5=32, x6=1056 y x7=1.
# Población: 32 guardap y 64 cargai; cada palabra es alineada, sin accesos por byte.
# Dependencias: assembler vigente, N+3, top y flush del #28 mediante el runner.
# El código de preparación es idéntico en longitud para comparar los patrones.
# No mide tiempo puro de memoria: incluye ALU, NOP y el arranque de cada dirección.
# Detecta pérdida, reordenamiento de stores, cargas falsas y daños fuera del arreglo.
# Direcciones 4*i, i=0..31: 128 bytes, cuatro líneas de 32 B y ocho palabras por línea.
# Las dos pasadas de lectura reutilizan las mismas cuatro líneas; no se presupone un conteo de hits.
# Direcciones por pasada: 0x0000,0x0004,0x0008,0x000c,0x0010,0x0014,0x0018,0x001c,0x0020,0x0024,0x0028,0x002c,0x0030,0x0034,0x0038,0x003c,0x0040,0x0044,0x0048,0x004c,0x0050,0x0054,0x0058,0x005c,0x0060,0x0064,0x0068,0x006c,0x0070,0x0074,0x0078,0x007c

# Fase 1: inicializa las 32 palabras sin precargar DMEM desde el banco.
# Escritura 1: M[0x0000]=1; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,1 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 2: M[0x0004]=2; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,2 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,4 | nop | nop
# Escritura 3: M[0x0008]=3; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,3 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,8 | nop | nop
# Escritura 4: M[0x000c]=4; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,4 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,12 | nop | nop
# Escritura 5: M[0x0010]=5; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,5 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,16 | nop | nop
# Escritura 6: M[0x0014]=6; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,6 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,20 | nop | nop
# Escritura 7: M[0x0018]=7; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,7 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,24 | nop | nop
# Escritura 8: M[0x001c]=8; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,8 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,28 | nop | nop
# Escritura 9: M[0x0020]=9; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,9 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,32 | nop | nop
# Escritura 10: M[0x0024]=10; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,10 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,36 | nop | nop
# Escritura 11: M[0x0028]=11; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,11 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,40 | nop | nop
# Escritura 12: M[0x002c]=12; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,12 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,44 | nop | nop
# Escritura 13: M[0x0030]=13; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,13 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,48 | nop | nop
# Escritura 14: M[0x0034]=14; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,14 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,52 | nop | nop
# Escritura 15: M[0x0038]=15; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,15 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,56 | nop | nop
# Escritura 16: M[0x003c]=16; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,16 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,60 | nop | nop
# Escritura 17: M[0x0040]=17; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,17 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,64 | nop | nop
# Escritura 18: M[0x0044]=18; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,18 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,68 | nop | nop
# Escritura 19: M[0x0048]=19; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,19 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,72 | nop | nop
# Escritura 20: M[0x004c]=20; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,20 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,76 | nop | nop
# Escritura 21: M[0x0050]=21; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,21 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,80 | nop | nop
# Escritura 22: M[0x0054]=22; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,22 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,84 | nop | nop
# Escritura 23: M[0x0058]=23; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,23 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,88 | nop | nop
# Escritura 24: M[0x005c]=24; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,24 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,92 | nop | nop
# Escritura 25: M[0x0060]=25; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,25 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,96 | nop | nop
# Escritura 26: M[0x0064]=26; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,26 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,100 | nop | nop
# Escritura 27: M[0x0068]=27; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,27 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,104 | nop | nop
# Escritura 28: M[0x006c]=28; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,28 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,108 | nop | nop
# Escritura 29: M[0x0070]=29; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,29 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,112 | nop | nop
# Escritura 30: M[0x0074]=30; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,30 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,116 | nop | nop
# Escritura 31: M[0x0078]=31; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,31 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,120 | nop | nop
# Escritura 32: M[0x007c]=32; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,32 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,124 | nop | nop

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
# Lectura 2 de pasada 1: espera 2 desde 0x0004; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,4 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 3 de pasada 1: espera 3 desde 0x0008; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,8 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 4 de pasada 1: espera 4 desde 0x000c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,12 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 5 de pasada 1: espera 5 desde 0x0010; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,16 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 6 de pasada 1: espera 6 desde 0x0014; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,20 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 7 de pasada 1: espera 7 desde 0x0018; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,24 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 8 de pasada 1: espera 8 desde 0x001c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,28 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 9 de pasada 1: espera 9 desde 0x0020; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,32 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 10 de pasada 1: espera 10 desde 0x0024; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,36 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 11 de pasada 1: espera 11 desde 0x0028; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,40 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 12 de pasada 1: espera 12 desde 0x002c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,44 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 13 de pasada 1: espera 13 desde 0x0030; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,48 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 14 de pasada 1: espera 14 desde 0x0034; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,52 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 15 de pasada 1: espera 15 desde 0x0038; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,56 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 16 de pasada 1: espera 16 desde 0x003c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,60 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 17 de pasada 1: espera 17 desde 0x0040; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,64 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 18 de pasada 1: espera 18 desde 0x0044; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,68 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 19 de pasada 1: espera 19 desde 0x0048; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,72 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 20 de pasada 1: espera 20 desde 0x004c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,76 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 21 de pasada 1: espera 21 desde 0x0050; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,80 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 22 de pasada 1: espera 22 desde 0x0054; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,84 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 23 de pasada 1: espera 23 desde 0x0058; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,88 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 24 de pasada 1: espera 24 desde 0x005c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,92 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 25 de pasada 1: espera 25 desde 0x0060; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,96 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 26 de pasada 1: espera 26 desde 0x0064; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,100 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 27 de pasada 1: espera 27 desde 0x0068; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,104 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 28 de pasada 1: espera 28 desde 0x006c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,108 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 29 de pasada 1: espera 29 desde 0x0070; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,112 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 30 de pasada 1: espera 30 desde 0x0074; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,116 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 31 de pasada 1: espera 31 desde 0x0078; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,120 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 32 de pasada 1: espera 32 desde 0x007c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,124 | nop | nop
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
# Lectura 2 de pasada 2: espera 2 desde 0x0004; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,4 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 3 de pasada 2: espera 3 desde 0x0008; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,8 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 4 de pasada 2: espera 4 desde 0x000c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,12 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 5 de pasada 2: espera 5 desde 0x0010; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,16 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 6 de pasada 2: espera 6 desde 0x0014; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,20 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 7 de pasada 2: espera 7 desde 0x0018; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,24 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 8 de pasada 2: espera 8 desde 0x001c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,28 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 9 de pasada 2: espera 9 desde 0x0020; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,32 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 10 de pasada 2: espera 10 desde 0x0024; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,36 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 11 de pasada 2: espera 11 desde 0x0028; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,40 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 12 de pasada 2: espera 12 desde 0x002c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,44 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 13 de pasada 2: espera 13 desde 0x0030; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,48 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 14 de pasada 2: espera 14 desde 0x0034; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,52 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 15 de pasada 2: espera 15 desde 0x0038; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,56 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 16 de pasada 2: espera 16 desde 0x003c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,60 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 17 de pasada 2: espera 17 desde 0x0040; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,64 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 18 de pasada 2: espera 18 desde 0x0044; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,68 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 19 de pasada 2: espera 19 desde 0x0048; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,72 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 20 de pasada 2: espera 20 desde 0x004c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,76 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 21 de pasada 2: espera 21 desde 0x0050; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,80 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 22 de pasada 2: espera 22 desde 0x0054; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,84 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 23 de pasada 2: espera 23 desde 0x0058; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,88 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 24 de pasada 2: espera 24 desde 0x005c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,92 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 25 de pasada 2: espera 25 desde 0x0060; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,96 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 26 de pasada 2: espera 26 desde 0x0064; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,100 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 27 de pasada 2: espera 27 desde 0x0068; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,104 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 28 de pasada 2: espera 28 desde 0x006c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,108 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 29 de pasada 2: espera 29 desde 0x0070; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,112 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 30 de pasada 2: espera 30 desde 0x0074; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,116 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 31 de pasada 2: espera 31 desde 0x0078; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,120 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 32 de pasada 2: espera 32 desde 0x007c; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,124 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop

# x7 acredita llegada al final útil; dos NOP y el drenado de cuatro avances llevan todo a WB.
sumai x7,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
# Reposo útil permanente: sye a sí mismo sin enlace. El núcleo no termina ni escribe durante mantenimiento.
fin: nop | nop | sye x0,fin | nop
