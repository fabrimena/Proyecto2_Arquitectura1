/*
================================================================================
 Testbench de la caché L2 con la política de inclusión NINE
================================================================================
 Descripción:
 ------------------------------------------------------------------------------
 Este archivo solo fija las macros del cuerpo compartido y lo incluye. Todo el
 estímulo y todas las comprobaciones están en tb-p2/tb_l2_cache_body.svh, que
 también usa tb-p2/tb_l2_cache.sv con la política EXCLUSIVE.

 Con NINE (no inclusiva) la L2 guarda su propia copia de la línea: después de
 un fallo de lectura la L2 se queda con la línea y el siguiente acceso a la
 misma dirección ACIERTA en la L2 (8 ciclos) en vez de volver a fallar. Esa es
 exactamente la diferencia observable entre las dos políticas, y es la que
 comprueba este testbench.

 La línea que el eviction buffer reenvía se guarda SUCIA: si se guardara
 limpia, al desalojarla se perderían los datos. El cuerpo lo comprueba
 llenando el conjunto 0x30 y verificando que la línea reenviada baja al nivel
 inferior con el bit sucio.

 Uso: make tb_l2_cache_nine
================================================================================
*/

`define L2_TB_MODULE tb_l2_cache_nine
`define L2_TB_NAME   "tb_l2_cache_nine"
`define L2_TB_INCL   INCL_NINE

`include "tb_l2_cache_body.svh"
