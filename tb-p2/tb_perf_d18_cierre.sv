/* Integra medir/lcont/vaciarc con eventos reales, en cuatro modos de memoria.
 * El oráculo acumula eventos públicos PRE y contrasta captura EX y consumo WB.
 * El programa deja líneas sucias y cierra la ventana antes de leer contadores;
 * el mantenimiento persiste los datos sin reabrir la medición. */
`timescale 1ns/1ps
module perf_d18_env #(parameter MODE=2,MODEL=0)(output logic done=0);
logic clk=0,reset=1;
wire [9:0] ev;
wire accept,busy;
logic [63:0] g[0:12];
logic [31:0] reads[0:31];
integer issued=0,written=0,cycles=0,flushes=0;
// Calendario independiente: lo observado en ID vence dos avances después.
// La máscara procede de la tabla del programa, no del clasificador del DUT.
bit due_valid[0:4095],cancel_young=0;
integer due_ops[0:4095],advances=0;
always #5 clk=~clk;
top #(.MEM_MODE(MODE),.L2_MODEL(MODEL)) D(.clk(clk),.reset(reset),
 .flush_req(1'b0),.flush_done(),.debug_result(),.debug_rd(),.debug_write());
generate if(MODE==2&&!MODEL)begin:r
 assign ev=D.g_mem_cache.HIER.perf_l2_events;
 assign accept=D.g_mem_cache.HIER.mc_accept;
 assign busy=D.g_mem_cache.HIER.mc_busy;
end else begin:r
 assign ev=0;assign accept=0;assign busy=0;
end endgenerate
// Dos subconjuntos diferentes permiten detectar una suma intercambiada: misses
// clasificados L2 y aceptaciones de MC no usan req retenido como evento nuevo.
always @(posedge clk)begin
 if(reset)begin
  for(integer k=0;k<13;k++)g[k]=0;
  for(integer k=0;k<4096;k++)begin due_valid[k]=0;due_ops[k]=0;end
  advances=0;cancel_young=0;
 end
 else begin
  cycles++;
  if(D.id_ex_valid&&D.ex_cisa_valid&&D.ex_cisa_op==2&&D.core_en&&D.CACHE_ISA.issue_ready)begin
   integer sel;logic [63:0] value;
   sel=D.ex_cisa_sel[4:0];value=sel<=12?g[sel]:0;
   reads[D.ex_cisa_rd]=D.ex_cisa_sel[5]?value[63:32]:value[31:0];
   issued++;
   // El valor esperado usa PRE, antes de incrementar por este mismo flanco.
  end
  if(D.cisa_wb_we)begin
   if(D.cisa_wb_data!==reads[D.cisa_wb_rd])$fatal(1,"[FAIL] snapshot EX/WB D18 mode=%0d sel=%0d",MODE,D.ex_cisa_sel);
   written++;
  end
  if(D.perf_measure_eff)begin
   g[0]++;
   if(!D.core_en)g[3]++;
   if(D.core_en&&due_valid[advances])begin g[1]++;g[2]+=due_ops[advances];end
   if(ev[0])g[9]++;if(ev[2])g[9]++;
   if(ev[1])g[10]++;if(ev[3])g[10]++;
   if(accept)g[11]++;
   if(busy)g[12]++;
  end
  if(D.core_en)begin
   integer index;
   if(advances>=4093)$fatal(1,"[FAIL] límite de calendario D18");
   if(D.crypto_fault)due_valid[advances+1]=0;
   due_valid[advances+2]=D.id_valid&&!D.redirect&&!cancel_young;
   index=D.id_pc>>4;
   due_ops[advances+2]=(index==0||(index>=3&&index<=18)||index==24||index==25)?1:0;
   cancel_young=D.redirect;
   advances++;
  end
  if(D.cisa_flush_req&&D.flush_done)flushes++;
 end
 #1;
 if(!reset&&{D.perf_cycle_count,D.perf_bundle_count,D.perf_instruction_count,D.perf_memory_stall_count}
    !=={g[0],g[1],g[2],g[3]})$fatal(1,"[FAIL] retiro D18, ventana o duplicación durante congelamiento MODE=%0d",MODE);
 if(!reset)for(integer k=9;k<=12;k++)if(D.cisa_counters[k]!==g[k])$fatal(1,"[FAIL] selector fuente %0d",k);
end
// Las palabras se obtienen del ISA existente; cargas/stores no se identifican
// mediante escrituras al banco. Distancias explícitas conservan N+3.
function automatic [127:0] lsu(input [31:0] word);
 return {64'd0,word,32'd0};
endfunction
initial begin
 #1;
 for(integer k=0;k<1024;k++)D.IMEM.memory[k]=0;
 // sumai x4,x0,55 y stores a tres líneas. El segundo conjunto se reutiliza.
 D.IMEM.memory[0]={96'd0,32'h80002037};
 D.IMEM.memory[3]=lsu(32'h92002000); // guardap x0,x4,0
 D.IMEM.memory[4]=lsu(32'h92002020); // guardap x0,x4,32
 D.IMEM.memory[5]=lsu(32'h92002040); // guardap x0,x4,64
 D.IMEM.memory[6]=lsu(32'h9a000000); // vaciarc: drena L1 y L2 reales.
 D.IMEM.memory[7]=lsu(32'h9a200000); // medir 0: los selectores quedan estables.
 for(integer k=0;k<4;k++)begin
  D.IMEM.memory[8+k]=lsu(32'h9a400000|((10+k)<<11)|(9+k));
  D.IMEM.memory[12+k]=lsu(32'h9a400000|((14+k)<<11)|(41+k));
 end
 D.IMEM.memory[16]=lsu(32'h9a400000|(18<<11)|31); // Reservado devuelve cero.
 D.IMEM.memory[17]=lsu(32'h9a200001); // Reanuda sin borrar el acumulado.
 D.IMEM.memory[18]=lsu(32'h93002800); // cargai x5,x0,0
 // Salto final sin enlace y sin nuevos efectos durante el mantenimiento.
 D.IMEM.memory[24]={32'd0,32'h96000000,64'd0};
 D.IMEM.memory[25]=lsu(32'h9a200000); // Debe anularse por el salto, sin pausar.
 repeat(3)@(negedge clk);reset=0;
 wait(issued==9&&written==9);repeat(12)@(negedge clk);
 if(D.REGFILE.regs[4]!==55||D.REGFILE.regs[5]!==55)$fatal(1,"[FAIL] oraculo GPR D18");
 for(integer k=0;k<16384;k++)begin
  if(D.DMEM.mem[k]!==((k==0||k==8||k==16)?32'd55:32'd0))$fatal(1,"[FAIL] persistencia DMEM D18 %0d",k);
 end
 if(D.cisa_measure_enable!==1)$fatal(1,"[FAIL] medir anulado tuvo efecto");
 if(flushes==0)$fatal(1,"[FAIL] falta vaciarc");
 if(MODE==2&&!MODEL&&(g[10]==0||g[11]==0||g[12]==0))$fatal(1,"[FAIL] falta actividad L2/RAM");
 if(D.REGFILE.regs[18]!==0)$fatal(1,"[FAIL] reservado D18");
 $display("[PASS] D18 MODE=%0d MODEL=%0d: 9 lecturas EX/WB, 16384 words, medir y vaciarc",MODE,MODEL);done=1;
end
initial begin #5000000;$fatal(1,"[FAIL] watchdog D18 MODE=%0d issued=%0d written=%0d",MODE,issued,written);end
endmodule
module tb_perf_d18_cierre;
wire [3:0]done;
perf_d18_env #(.MODE(0))E0(done[0]);
perf_d18_env #(.MODE(1))E1(done[1]);
perf_d18_env E2(done[2]);
perf_d18_env #(.MODEL(1))E3(done[3]);
initial begin wait(&done);$display("[PASS] tb_perf_d18_cierre");$finish;end
endmodule
