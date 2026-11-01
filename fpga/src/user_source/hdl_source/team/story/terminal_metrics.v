// Pixel-domain timestamps; only held one-bit milestones cross from SD clock.
// FFFFFFFF = not measured, FFFF ms = saturated. No performance claim implied.
module terminal_metrics #(parameter integer CLK_HZ=25000000)(
 input wire clk,rst,card_initialized_sd,directory_ready_sd,media_ready,display_ready,cache_req,cache_ack,
 output wire [31:0] sd_init_ms,dir_ms,preload_ms,firstframe_ms,cache_ms
);
    // Preserve original 32-bit wrap for zero/one/negative/unknown limits.
    // For limit > 1, reset/terminal logic bounds count to [0, limit-1].
    function integer counter_width;
        input integer limit;
        integer remaining;
        begin
            counter_width=32;
            if(limit>1) begin
                counter_width=0;
                for(remaining=limit-1;remaining>0;remaining=remaining>>1)
                    counter_width=counter_width+1;
            end
        end
    endfunction
    localparam integer COUNTER_WIDTH=counter_width(CLK_HZ/1000);
 reg [2:0] init_sync,dir_sync;
 reg [COUNTER_WIDTH-1:0] divider;reg [31:0] now_ms,init_time,dir_time,cache_start;
 reg [15:0] init_value,dir_value,load_value,frame_value,cache_value;
 reg [4:0] valid;
 reg req_d,ack_d;
 function [15:0] saturated;
  input [31:0] elapsed;
  begin saturated=elapsed>65535?16'hffff:elapsed[15:0];end
 endfunction
 assign sd_init_ms=valid[0]?{16'd0,init_value}:32'hffffffff;
 assign dir_ms=valid[1]?{16'd0,dir_value}:32'hffffffff;
 assign preload_ms=valid[2]?{16'd0,load_value}:32'hffffffff;
 assign firstframe_ms=valid[3]?{16'd0,frame_value}:32'hffffffff;
 assign cache_ms=valid[4]?{16'd0,cache_value}:32'hffffffff;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   init_sync<=0;dir_sync<=0;divider<=0;now_ms<=0;init_time<=0;dir_time<=0;cache_start<=0;
   init_value<=0;dir_value<=0;load_value<=0;frame_value<=0;cache_value<=0;valid<=0;req_d<=0;ack_d<=0;
  end else begin
   init_sync<={init_sync[1:0],card_initialized_sd};dir_sync<={dir_sync[1:0],directory_ready_sd};
   req_d<=cache_req;ack_d<=cache_ack;
   if(divider==CLK_HZ/1000-1)begin divider<=0;now_ms<=now_ms+1'b1;end
   else divider<=divider+1'b1;
   if(init_sync[2] && !valid[0])begin valid[0]<=1;init_time<=now_ms;init_value<=saturated(now_ms);end
   if(dir_sync[2] && !valid[1])begin valid[1]<=1;dir_time<=now_ms;dir_value<=saturated(now_ms-init_time);end
   if(media_ready && !valid[2])begin valid[2]<=1;load_value<=saturated(now_ms-dir_time);end
   if(display_ready && !valid[3])begin valid[3]<=1;frame_value<=saturated(now_ms);end
   if(cache_req && !req_d)cache_start<=now_ms;
   if(cache_ack && !ack_d)begin valid[4]<=1;cache_value<=saturated(now_ms-cache_start);end
  end
 end
endmodule
