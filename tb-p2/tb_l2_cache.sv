/*
================================================================================
 Testbench de la caché L2 con la política de inclusión EXCLUSIVE
================================================================================
 Descripción:
 ------------------------------------------------------------------------------
 Este archivo solo fija las macros del cuerpo compartido y lo incluye. Todo el
 estímulo y todas las comprobaciones están en tb-p2/tb_l2_cache_body.svh, que
 también usa tb-p2/tb_l2_cache_nine.sv con la política NINE.

 La diferencia entre las dos políticas NO está en el estímulo sino en las
 expectativas, y esas se deciden dentro del cuerpo con IS_EXCL. Duplicar el
 testbench entero para cambiar una constante sería una fuente de errores que
 no compensa.

 Uso: make tb_l2_cache
================================================================================
*/

`define L2_TB_MODULE tb_l2_cache
`define L2_TB_NAME   "tb_l2_cache"
`define L2_TB_INCL   INCL_EXCLUSIVE

`include "tb_l2_cache_body.svh"
