/* Valida perf_memory con aceptaciones, ocupación y fallos del controlador real.
 * mem_hold es el estímulo público de memoria trabada. El scoreboard observa
 * PRE, incluye el reintento en busy y no duplica la aceptación original. */
`timescale 1ns/1ps
module tb_perf_ram_faults;
logic clk=0,reset=1,req=0,we=0,hold_mem=0,en=1;
wire ready,error_out,accept,write_accept,busy,tout,err;
wire mc,mwe;wire [13:0]ma;wire [31:0]md;
wire [5:0][63:0] counts;
logic [63:0] gold[0:5];integer checks=0;
always #5 clk=~clk;
mem_controller MC(.clk(clk),.reset(reset),.ram_req(req),.ram_we(we),.ram_addr(32'd256),
 .ram_wline(256'd0),.ram_ready(ready),.ram_rline(),.mem_error(error_out),
 .req_accept(accept),.req_we_accepted(write_accept),.transfer_busy(busy),
 .timeout_event(tout),.error_event(err),.mem_hold(hold_mem),.clk_mem(mc),
 .mem_word_addr(ma),.mem_word_wdata(md),.mem_word_we(mwe),.mem_word_rdata(32'h12345678));
perf_memory P(.clk(clk),.reset(reset),.clear(1'b0),.measure_enable(en),
 .req_accept(accept),.req_we(write_accept),.transfer_busy(busy),
 .timeout_event(tout),.error_event(err),.read_accesses(counts[0]),
 .write_accesses(counts[1]),.transfer_cycles(counts[2]),.total_cycles(counts[3]),
 .timeout_count(counts[4]),.error_count(counts[5]));
always @(posedge clk)begin
 if(reset)for(integer k=0;k<6;k++)gold[k]=0;
 else if(en)begin
  if(accept)if(write_accept)gold[1]++;else gold[0]++;
  if(busy)gold[2]++;
  gold[3]++;if(tout)gold[4]++;if(err)gold[5]++;
 end
 #1;
 for(integer k=0;k<6;k++)if(counts[k]!==gold[k])$fatal(1,"[FAIL] RAM real %0d",k);
 checks++;
end
initial begin
 repeat(3)@(negedge clk);reset=0;
 // Una escritura normal, seguida de solicitud de lectura sin respuesta.
 @(negedge clk);req=1;we=1;
 wait(ready);@(negedge clk);req=0;we=0;
 repeat(4)@(negedge clk);hold_mem=1;req=1;
 wait(error_out);@(negedge clk);req=0;
 repeat(3)@(negedge clk);
 if(counts[0]!==1||counts[1]!==1||counts[4]!==2||counts[5]!==1)
  $fatal(1,"[FAIL] retry/timeout/error no corresponden a una petición");
 if(counts[2]>counts[3])$fatal(1,"[FAIL] utilización imposible");
 $display("[PASS] tb_perf_ram_faults: %0d flancos contrastados, 2 aceptaciones, 2 timeout, 1 error",checks);$finish;
end
initial begin #100000;$fatal(1,"[FAIL] watchdog RAM");end
endmodule
