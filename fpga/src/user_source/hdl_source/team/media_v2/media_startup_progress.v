// Startup visibility is independent of background preload completion. A slot
// becomes visible only after the loader's CRC/count/write-finish commit.
module media_startup_progress #(parameter EARLY_FIRST_FRAME=1)(
 input wire clk,rst,initialized,mounted,slot0_valid,fault,
 input wire [7:0] logical_count,input wire preload_done,loader_ready,
 output reg display_ready,preload_ready
);
 always @(posedge clk or posedge rst)begin
  if(rst)begin display_ready<=0;preload_ready<=0;end
  else if(!fault)begin
   if(preload_done && loader_ready && initialized && mounted)begin
    preload_ready<=1;display_ready<=1;
   end else if(EARLY_FIRST_FRAME && initialized && mounted && slot0_valid && logical_count!=0)
    display_ready<=1;
  end
  // Once a correct frame was published, a later media fault must not blank it.
  // Read/SDRAM failures remain a separate raster fault, not hidden here.
 end
endmodule
