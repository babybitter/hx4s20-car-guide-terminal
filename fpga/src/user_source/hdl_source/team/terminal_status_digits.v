// Two SD-clock stages isolate status decoding from the scan-output register.
// Uses the unchanged official hex decoder. A raster fault overrides to EC.
module terminal_status_digits(
 input wire clk,rst,
 input wire [3:0] state_code,error_code,
 input wire raster_fault,
 output reg [7:0] upper_digit,lower_digit
);
 reg [3:0] state_q,error_q;
 reg fault_q;
 wire [6:0] state_segments,error_segments;
 seg_decoder state_decoder(.bin_data(state_q),.seg_data(state_segments));
 seg_decoder error_decoder(.bin_data(error_q),.seg_data(error_segments));
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state_q<=0;error_q<=0;fault_q<=0;upper_digit<=8'hff;lower_digit<=8'hff;
  end else begin
   state_q<=raster_fault?4'he:state_code;
   error_q<=raster_fault?4'hc:error_code;
   fault_q<=raster_fault || state_code==4'he;
   upper_digit<=fault_q?{1'b1,state_segments}:8'hff;
   lower_digit<=fault_q?{1'b1,error_segments}:{1'b1,state_segments};
  end
 end
endmodule
