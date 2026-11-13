# Benchmark aleatorio del issue #29, para el runner real de memoria.
# Entrada: GPR y los 65536 bytes de DMEM en cero; solo ISA original, slot LSU 1.
# Salidas: 32 palabras con valores 1..32, x5=32, x6=1056 y x7=1.
# Población: 32 guardap y 64 cargai; cada palabra es alineada, sin accesos por byte.
# Dependencias: assembler vigente, N+3, top y flush del #28 mediante el runner.
# El código de preparación es idéntico en longitud para comparar los patrones.
# No mide tiempo puro de memoria: incluye ALU, NOP y el arranque de cada dirección.
# Detecta pérdida, reordenamiento de stores, cargas falsas y daños fuera del arreglo.
# Semilla 0x29c0de; Fisher-Yates de 128 líneas con LCG32 (1664525,1013904223).
# Se toman las primeras 32 líneas de la permutación; se accede solo a su primera palabra.
# Reduce localidad espacial: 32 líneas distintas, sin depender de random de Python.
# Direcciones por pasada: 0x0d00,0x00c0,0x0240,0x0c80,0x0980,0x04c0,0x0b00,0x0640,0x0580,0x01c0,0x0940,0x0ea0,0x0320,0x0e00,0x05c0,0x0f60,0x01e0,0x0f20,0x0100,0x0460,0x0380,0x0ec0,0x0300,0x0840,0x0b80,0x0880,0x0c00,0x0bc0,0x06c0,0x06e0,0x0040,0x0c40

# Fase 1: inicializa las 32 palabras sin precargar DMEM desde el banco.
# Escritura 1: M[0x0d00]=1; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,1 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,256 | nop | nop
# Escritura 2: M[0x00c0]=2; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,2 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,192 | nop | nop
# Escritura 3: M[0x0240]=3; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,3 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,576 | nop | nop
# Escritura 4: M[0x0c80]=4; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,4 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,128 | nop | nop
# Escritura 5: M[0x0980]=5; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,2 | nop | nop | nop
sumai x4,x0,5 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,384 | nop | nop
# Escritura 6: M[0x04c0]=6; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,1 | nop | nop | nop
sumai x4,x0,6 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,192 | nop | nop
# Escritura 7: M[0x0b00]=7; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,2 | nop | nop | nop
sumai x4,x0,7 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,768 | nop | nop
# Escritura 8: M[0x0640]=8; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,1 | nop | nop | nop
sumai x4,x0,8 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,576 | nop | nop
# Escritura 9: M[0x0580]=9; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,1 | nop | nop | nop
sumai x4,x0,9 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,384 | nop | nop
# Escritura 10: M[0x01c0]=10; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,10 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,448 | nop | nop
# Escritura 11: M[0x0940]=11; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,2 | nop | nop | nop
sumai x4,x0,11 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,320 | nop | nop
# Escritura 12: M[0x0ea0]=12; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,12 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,672 | nop | nop
# Escritura 13: M[0x0320]=13; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,13 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,800 | nop | nop
# Escritura 14: M[0x0e00]=14; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,14 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,512 | nop | nop
# Escritura 15: M[0x05c0]=15; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,1 | nop | nop | nop
sumai x4,x0,15 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,448 | nop | nop
# Escritura 16: M[0x0f60]=16; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,16 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,864 | nop | nop
# Escritura 17: M[0x01e0]=17; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,17 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,480 | nop | nop
# Escritura 18: M[0x0f20]=18; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,18 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,800 | nop | nop
# Escritura 19: M[0x0100]=19; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,19 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,256 | nop | nop
# Escritura 20: M[0x0460]=20; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,1 | nop | nop | nop
sumai x4,x0,20 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,96 | nop | nop
# Escritura 21: M[0x0380]=21; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,21 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,896 | nop | nop
# Escritura 22: M[0x0ec0]=22; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,22 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,704 | nop | nop
# Escritura 23: M[0x0300]=23; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,23 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,768 | nop | nop
# Escritura 24: M[0x0840]=24; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,2 | nop | nop | nop
sumai x4,x0,24 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,64 | nop | nop
# Escritura 25: M[0x0b80]=25; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,2 | nop | nop | nop
sumai x4,x0,25 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,896 | nop | nop
# Escritura 26: M[0x0880]=26; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,2 | nop | nop | nop
sumai x4,x0,26 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,128 | nop | nop
# Escritura 27: M[0x0c00]=27; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,27 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,0 | nop | nop
# Escritura 28: M[0x0bc0]=28; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,2 | nop | nop | nop
sumai x4,x0,28 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,960 | nop | nop
# Escritura 29: M[0x06c0]=29; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,1 | nop | nop | nop
sumai x4,x0,29 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,704 | nop | nop
# Escritura 30: M[0x06e0]=30; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,1 | nop | nop | nop
sumai x4,x0,30 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,736 | nop | nop
# Escritura 31: M[0x0040]=31; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,0 | nop | nop | nop
sumai x4,x0,31 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,64 | nop | nop
# Escritura 32: M[0x0c40]=32; x20 construye la base en dos pasos separados N+3.
sumai x20,x0,3 | nop | nop | nop
sumai x4,x0,32 | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | guardap x20,x4,64 | nop | nop

# Fase 2: pasada de lectura 1; cada dato se suma a x6 después de dos NOP.
# Lectura 1 de pasada 1: espera 1 desde 0x0d00; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,256 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 2 de pasada 1: espera 2 desde 0x00c0; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,192 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 3 de pasada 1: espera 3 desde 0x0240; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,576 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 4 de pasada 1: espera 4 desde 0x0c80; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,128 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 5 de pasada 1: espera 5 desde 0x0980; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,384 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 6 de pasada 1: espera 6 desde 0x04c0; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,192 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 7 de pasada 1: espera 7 desde 0x0b00; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,768 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 8 de pasada 1: espera 8 desde 0x0640; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,576 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 9 de pasada 1: espera 9 desde 0x0580; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,384 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 10 de pasada 1: espera 10 desde 0x01c0; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,448 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 11 de pasada 1: espera 11 desde 0x0940; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,320 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 12 de pasada 1: espera 12 desde 0x0ea0; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,672 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 13 de pasada 1: espera 13 desde 0x0320; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,800 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 14 de pasada 1: espera 14 desde 0x0e00; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,512 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 15 de pasada 1: espera 15 desde 0x05c0; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,448 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 16 de pasada 1: espera 16 desde 0x0f60; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,864 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 17 de pasada 1: espera 17 desde 0x01e0; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,480 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 18 de pasada 1: espera 18 desde 0x0f20; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,800 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 19 de pasada 1: espera 19 desde 0x0100; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,256 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 20 de pasada 1: espera 20 desde 0x0460; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,96 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 21 de pasada 1: espera 21 desde 0x0380; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,896 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 22 de pasada 1: espera 22 desde 0x0ec0; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,704 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 23 de pasada 1: espera 23 desde 0x0300; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,768 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 24 de pasada 1: espera 24 desde 0x0840; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,64 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 25 de pasada 1: espera 25 desde 0x0b80; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,896 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 26 de pasada 1: espera 26 desde 0x0880; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,128 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 27 de pasada 1: espera 27 desde 0x0c00; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 28 de pasada 1: espera 28 desde 0x0bc0; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,960 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 29 de pasada 1: espera 29 desde 0x06c0; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,704 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 30 de pasada 1: espera 30 desde 0x06e0; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,736 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 31 de pasada 1: espera 31 desde 0x0040; detecta desplazamientos y corrupción.
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
# Lectura 32 de pasada 1: espera 32 desde 0x0c40; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,64 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop

# Fase 3: pasada de lectura 2; cada dato se suma a x6 después de dos NOP.
# Lectura 1 de pasada 2: espera 1 desde 0x0d00; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,256 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 2 de pasada 2: espera 2 desde 0x00c0; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,192 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 3 de pasada 2: espera 3 desde 0x0240; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,576 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 4 de pasada 2: espera 4 desde 0x0c80; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,128 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 5 de pasada 2: espera 5 desde 0x0980; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,384 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 6 de pasada 2: espera 6 desde 0x04c0; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,192 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 7 de pasada 2: espera 7 desde 0x0b00; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,768 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 8 de pasada 2: espera 8 desde 0x0640; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,576 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 9 de pasada 2: espera 9 desde 0x0580; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,384 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 10 de pasada 2: espera 10 desde 0x01c0; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,448 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 11 de pasada 2: espera 11 desde 0x0940; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,320 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 12 de pasada 2: espera 12 desde 0x0ea0; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,672 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 13 de pasada 2: espera 13 desde 0x0320; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,800 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 14 de pasada 2: espera 14 desde 0x0e00; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,512 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 15 de pasada 2: espera 15 desde 0x05c0; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,448 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 16 de pasada 2: espera 16 desde 0x0f60; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,864 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 17 de pasada 2: espera 17 desde 0x01e0; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,480 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 18 de pasada 2: espera 18 desde 0x0f20; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,800 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 19 de pasada 2: espera 19 desde 0x0100; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,256 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 20 de pasada 2: espera 20 desde 0x0460; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,96 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 21 de pasada 2: espera 21 desde 0x0380; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,896 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 22 de pasada 2: espera 22 desde 0x0ec0; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,704 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 23 de pasada 2: espera 23 desde 0x0300; detecta desplazamientos y corrupción.
sumai x20,x0,0 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,768 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 24 de pasada 2: espera 24 desde 0x0840; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,64 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 25 de pasada 2: espera 25 desde 0x0b80; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,896 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 26 de pasada 2: espera 26 desde 0x0880; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,128 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 27 de pasada 2: espera 27 desde 0x0c00; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,0 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 28 de pasada 2: espera 28 desde 0x0bc0; detecta desplazamientos y corrupción.
sumai x20,x0,2 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,960 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 29 de pasada 2: espera 29 desde 0x06c0; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,704 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 30 de pasada 2: espera 30 desde 0x06e0; detecta desplazamientos y corrupción.
sumai x20,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,736 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop
# Lectura 31 de pasada 2: espera 31 desde 0x0040; detecta desplazamientos y corrupción.
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
# Lectura 32 de pasada 2: espera 32 desde 0x0c40; detecta desplazamientos y corrupción.
sumai x20,x0,3 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
cizqi x20,x20,10 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
nop | cargai x5,x20,64 | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
suma x6,x6,x5 | nop | nop | nop

# x7 acredita llegada al final útil; dos NOP y el drenado de cuatro avances llevan todo a WB.
sumai x7,x0,1 | nop | nop | nop
nop | nop | nop | nop
nop | nop | nop | nop
# Reposo útil permanente: sye a sí mismo sin enlace. El núcleo no termina ni escribe durante mantenimiento.
fin: nop | nop | sye x0,fin | nop
