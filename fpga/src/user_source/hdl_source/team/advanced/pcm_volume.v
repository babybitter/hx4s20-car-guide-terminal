// Signed PCM attenuation. Explicit cases avoid unsigned ternary shift promotion.
module pcm_volume (
 input wire [2:0] volume,
 input wire signed [23:0] left_in, right_in,
 output reg signed [23:0] left_out, right_out
);
 always @* begin
  case(volume)
   1: begin left_out=left_in >>> 3; right_out=right_in >>> 3; end
   2: begin left_out=left_in >>> 2; right_out=right_in >>> 2; end
   3: begin left_out=left_in >>> 1; right_out=right_in >>> 1; end
   4: begin left_out=left_in; right_out=right_in; end
   default: begin left_out=0; right_out=0; end
  endcase
 end
endmodule
