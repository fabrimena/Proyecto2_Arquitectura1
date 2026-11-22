/* Jerarquía real/modelo con instrumentación activa y ausente en paralelo.
 * El driver usa solo demandas públicas y una RAM inicial cero. Gold se prepara
 * por stores aceptados; el scoreboard suma los eventos públicos PRE de L2/MC.
 * Comprueba pausa durante peticiones, vaciado, políticas, pasividad y toda DMEM. */
`timescale 1ns/1ps
module perf_hier_env #(parameter int INCL=2,MODEL=0,DIV=4)(output logic done=0);
logic clk=0,reset=1,en=1,re=0,we=0,freq=0;
logic [31:0] addr=0,data=0;logic [3:0] be=15;
wire [1:0] stall,fd,mc,mwe;
wire [31:0] q[0:1],ma[0:1],md[0:1],mq[0:1];wire [3:0] mb[0:1];
wire [9:0][63:0] l2[0:1];wire [5:0][63:0] ram[0:1];
logic [31:0] gold[0:16383];
logic [63:0] gl2[0:9],gram[0:5];
integer checks=0,offers=0,accepts=0;
always #5 clk=~clk;
for(genvar p=0;p<2;p++)begin:g
 mem_hierarchy #(.INCL_POLICY(INCL),.L2_MODEL(MODEL),.MEM_DIV(DIV),.PERF_ENABLE(p==0)) H(
  .clk(clk),.reset(reset),.re(re),.we(we),.be(be),.addr(addr),.wdata(data),.rdata(q[p]),
  .re_b(1'b0),.we_b(1'b0),.addr_b(32'd0),.wdata_b(32'd0),.rdata_b(),.stall(stall[p]),
  .flush_req(freq),.flush_done(fd[p]),.m_clk(mc[p]),.m_we(mwe[p]),.m_be(mb[p]),
  .m_addr(ma[p]),.m_wdata(md[p]),.m_rdata(mq[p]),.perf_measure_enable(en),
  .perf_l1d_counts(),.perf_l2_counts(l2[p]),.perf_ram_counts(ram[p]));
 memory M(.clk(mc[p]),.we(mwe[p]),.be(mb[p]),.addr(ma[p]),.wdata(md[p]),.rdata(mq[p]),
  .we_b(1'b0),.addr_b(32'd0),.wdata_b(32'd0),.rdata_b());
end
// Las fuentes son puertos de observación explícitos de la jerarquía, nunca tags
// ni acumuladores del monitor. La aceptación MC se califica una vez por petición.
always @(posedge clk)begin
 if(reset)begin for(integer j=0;j<10;j++)gl2[j]=0;for(integer j=0;j<6;j++)gram[j]=0;end
 else begin
  if({stall[0],fd[0],mc[0],mwe[0],mb[0],ma[0],md[0],q[0]}!==
     {stall[1],fd[1],mc[1],mwe[1],mb[1],ma[1],md[1],q[1]})$fatal(1,"[FAIL] pasividad jerarquia");
  if(en&&!MODEL)begin
   for(integer j=0;j<10;j++)if(g[0].H.perf_l2_events[j])gl2[j]++;
   if(g[0].H.mc_accept)if(g[0].H.mc_write)gram[1]++;else gram[0]++;
   if(g[0].H.mc_busy)gram[2]++;
   gram[3]++;
   if(g[0].H.mc_timeout)gram[4]++;
   if(g[0].H.mc_error)gram[5]++;
  end
 end
 #1;
 for(integer j=0;j<10;j++)if(l2[0][j]!==gl2[j])$fatal(1,"[FAIL] L2 PRE/NBA %0d",j);
 for(integer j=0;j<6;j++)if(ram[0][j]!==gram[j])$fatal(1,"[FAIL] RAM PRE/NBA %0d",j);
 if(l2[1]!==0||ram[1]!==0)$fatal(1,"[FAIL] PERF_ENABLE cero");
 checks++;
end
// Demanda estable hasta aceptación. Cargas cotejan el dato conocido; stores
// actualizan gold mediante máscara por byte solo al avanzar el contrato CPU.
task automatic access(input bit load,input integer a,input logic [31:0] d,input logic [3:0] mask);
 integer n;
 @(negedge clk);re=load;we=!load;addr=a;data=d;be=mask;
 n=0;#1;
 while(stall[0]&&n<4000)begin @(negedge clk);n++;end
 if(stall[0])$fatal(1,"[FAIL] demanda pendiente");
 if(load&&(q[0]!==gold[a/4]||q[1]!==gold[a/4]))$fatal(1,"[FAIL] oraculo lectura %h",a);
 @(posedge clk);#2;
 if(!load)for(integer b=0;b<4;b++)if(mask[b])gold[a/4][b*8+:8]=d[b*8+:8];
 re=0;we=0;
endtask
// Espera confirmación y retorno, conservando la misma secuencia de relojes y
// controles de ambas instancias. Un timeout no equivale a persistencia.
task automatic flush;
 integer n;
 @(negedge clk);freq=1;n=0;
 while(!(&fd)&&n<20000)begin @(negedge clk);n++;end
 if(!(&fd))$fatal(1,"[FAIL] flush real");
 for(integer j=0;j<16384;j++)begin
  if(g[0].M.mem[j]!==gold[j]||g[1].M.mem[j]!==gold[j])$fatal(1,"[FAIL] DMEM completa %0d",j);
 end
 freq=0;repeat(3)@(negedge clk);
 if(fd!==0)$fatal(1,"[FAIL] retorno flush");
endtask
initial begin
 for(integer j=0;j<16384;j++)gold[j]=0;
 repeat(3)@(negedge clk);reset=0;
 // Tres líneas del mismo set fuerzan reemplazos; repetir lecturas ejerce L2.
 for(integer j=0;j<12;j++)access(0,j*2048,32'habc00000+j,15);
 access(0,0,32'h00007f00,2);
 // La ventana se interrumpe con demanda pendiente, sin detener su resolución.
 fork begin access(1,6144,0,15);end
      begin repeat(4)@(negedge clk);en=0;repeat(17)@(negedge clk);en=1;end
 join
 for(integer j=0;j<12;j++)access(1,j*2048,0,15);
 flush();
 if(!MODEL&&(ram[0][0]==0||ram[0][1]==0||l2[0][6]==0))$fatal(1,"[FAIL] cobertura RAM/flush");
 en=0;access(0,65532,32'h12345678,15);flush();en=1;
 access(1,65532,0,15);flush();
 $display("[PASS] jerarquia INCL=%0d MODEL=%0d DIV=%0d checks=%0d",INCL,MODEL,DIV,checks);done=1;
end
endmodule
module tb_perf_integracion_hierarquia;
wire [3:0] done;
perf_hier_env E0(.done(done[0]));
perf_hier_env #(.INCL(1)) E1(.done(done[1]));
perf_hier_env #(.DIV(2)) E2(.done(done[2]));
perf_hier_env #(.MODEL(1)) E3(.done(done[3]));
initial begin wait(&done);$display("[PASS] tb_perf_integracion_hierarquia: cuatro configuraciones, pasividad y oraculos completos");$finish;end
initial begin #20000000;$fatal(1,"[FAIL] watchdog jerarquia");end
endmodule
