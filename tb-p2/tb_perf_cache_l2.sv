/* Oráculo independiente de los diez eventos: patrones dirigidos y LCG32.
 * Verifica reset prioritario, pausa, reanudación, consecutivos y oferta retenida.
 * Los valores esperados se actualizan desde estímulos PRE, nunca desde el DUT. */
`timescale 1ns/1ps
module tb_perf_cache_l2;
`include "tb_utils.svh"
logic clk=0,reset=1,measure_enable=1;
logic [9:0] ev=0;
wire [9:0][63:0] counts;
wire [63:0] rd,wr,hits,misses,total,fill,victim,flush,invalid,lr,lw;
logic [63:0] gold[0:9];
logic [31:0] seed=32'h26c2026;
always #5 clk=~clk;
perf_cache_l2 DUT(.clk(clk),.reset(reset),.measure_enable(measure_enable),
 .ev_l2_rd_hit(ev[0]),.ev_l2_rd_miss(ev[1]),.ev_l2_wr_hit(ev[2]),.ev_l2_wr_miss(ev[3]),
 .ev_l2_fill(ev[4]),.ev_l2_evict(ev[5]),.ev_l2_writeback(ev[6]),.ev_l2_invalid(ev[7]),
 .ev_l2_read_req(ev[8]),.ev_l2_write_req(ev[9]),.event_counts(counts),
 .read_accesses(rd),.write_accesses(wr),.total_hits(hits),.total_misses(misses),.total_accesses(total),
 .fill_events(fill),.replacement_evictions(victim),.flush_writebacks(flush),
 .exclusive_invalidations(invalid),.lower_read_requests(lr),.lower_write_offer_cycles(lw));
// Aplica controles fuera de flanco, actualiza gold PRE y observa después de NBA.
// Reset borra incluso durante pausa y con todos los eventos activos.
task automatic step(input bit rst,en,input logic [9:0] events);
 @(negedge clk);reset=rst;measure_enable=en;ev=events;
 @(posedge clk);
 for(integer j=0;j<10;j++) if(rst)gold[j]=0;else if(en&&events[j])gold[j]++;
 #1;
 for(integer j=0;j<10;j++)check_true("evento64",counts[j]===gold[j]);
 check_true("lecturas",rd===gold[0]+gold[1]);check_true("escrituras",wr===gold[2]+gold[3]);
 check_true("hits",hits===gold[0]+gold[2]);check_true("misses",misses===gold[1]+gold[3]);
 check_true("población",total===gold[0]+gold[1]+gold[2]+gold[3]);
 check_true("auxiliares separados",{fill,victim,flush,invalid,lr,lw}==={gold[4],gold[5],gold[6],gold[7],gold[8],gold[9]});
endtask
initial begin
 for(integer j=0;j<10;j++)gold[j]=0;
 step(1,0,'1);
 for(integer j=0;j<10;j++)begin step(0,1,10'b1<<j);step(0,1,10'b1<<j);end
 // Una oferta retenida cinco ciclos produce cinco ciclos, sin inventar aceptaciones.
 repeat(5)step(0,1,10'b1000000000);
 repeat(4)step(0,0,'1);
 step(0,1,'1);step(1,0,'1);step(0,1,'0);
 for(integer j=0;j<2000;j++)begin
  seed=1664525*seed+1013904223;
  step(j%173==0,seed[10],seed[9:0]);
 end
 // Precargas exclusivas del banco permiten comprobar acarreo y wrap sin
 // simular 2^64 ciclos. Se realizan con ventana cerrada, sin un puerto extra RTL.
 step(0,0,'0);
 @(negedge clk);
 for(integer j=0;j<10;j++)begin DUT.event_counts[j]=64'h00000000ffffffff;gold[j]=64'h00000000ffffffff;end
 step(0,1,'1); // Cada contador debe propagar el acarreo al bit 32.
 step(0,0,'1); // Pausar conserva también esos bits altos.
 @(negedge clk);
 for(integer j=0;j<10;j++)begin DUT.event_counts[j]=64'hffffffffffffffff;gold[j]=64'hffffffffffffffff;end
 step(0,1,'1); // Aritmética natural: máximo más uno produce cero.
 step(1,0,'1); // Reset mantiene su prioridad sobre pausa y eventos activos.
 tb_finish("tb_perf_cache_l2");
end
endmodule
