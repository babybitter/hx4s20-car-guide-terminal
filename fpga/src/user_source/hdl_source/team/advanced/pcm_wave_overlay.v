`timescale 1ns/1ps
// Actual post-volume stereo PCM. One shared scope, ONE video register.
module pcm_wave_overlay #(parameter ADAPTIVE_LAYOUT=0,LOCAL_ENABLES=0,DYNAMIC_COLOR=0)(
 input wire clk,rst,enable,
 // Background opacity: 0/25/50/75/100 percent. Invalid/X/Z -> 25%.
 input wire [2:0] opacity_level,
 input wire [23:0] I_rgb,
 input wire I_hs,I_vs,I_de,audio_valid,
 input wire signed [23:0] audio_left,audio_right,
 output reg [23:0] O_rgb,
 output reg O_hs,O_vs,O_de,
 input wire half_layout,
 input wire [23:0] left_wave_color,right_wave_color,
 // Same pixel/clock as O_rgb; only captured PCM traces, never the panel.
 output reg O_wave_hit
);
 reg layout;
 reg [23:0] frame_left_color,frame_right_color;
 // Small dynamic tint: L grey-white, R cyan-white, above the rainbow.
 wire [23:0] left_color=DYNAMIC_COLOR ?
  {3'b111,frame_left_color[23:19],3'b111,frame_left_color[15:11],3'b111,frame_left_color[7:3]} : 24'hE8EEF4;
 wire [23:0] right_color=DYNAMIC_COLOR ?
  {3'b100,frame_right_color[23:19],3'b111,frame_right_color[15:11],3'b111,frame_right_color[7:3]} : 24'h9DECF5;
 // Preserve the existing 128x12 single-read/single-write block RAM.
 // Fixed addresses retain circular sweep history; BOTH channels always use
 // the same address. No second buffer, memory reset loop or extra RAM port.
 (* ram_style = "block" *) reg [11:0] samples [0:127];
 reg [6:0] wr;
 reg [7:0] filled;
 // 48 kHz / 6 = 8 kHz scope history (16 ms, 128 samples).
 reg [2:0] sample_div;
 reg [9:0] x,y;
 reg de_d,vs_d,frame_arm;
 wire [9:0] px=!de_d ? 10'd0 : x+10'd1;
 wire [9:0] py=!de_d ? (frame_arm ? 10'd0 : y+10'd1) : y;
 wire [9:0] panel_left=layout ? 10'd192 : 10'd160;
 wire [9:0] panel_right=layout ? 10'd448 : 10'd480;
 wire in_x=px>=panel_left && px<panel_right;
 wire box=in_x && py>=10'd344 && py<10'd400;
 // Exact mapping without multiply/divide: normal index=floor(2*column/5),
 // repeating over 3+2 pixels; half index=floor(column/2). All 128 addresses.
 reg [6:0] index;
 reg [2:0] phase;
 wire advance=layout ? phase==3'd1 : (phase==3'd2 || phase==3'd4);
 wire [9:0] next_px=I_de ? px+10'd1 : 10'd0;
 wire next_in_x=next_px>=panel_left && next_px<panel_right;
 wire [6:0] next_index=in_x ? index+{6'd0,advance} : 7'd0;
 wire capture_enable=!LOCAL_ENABLES || enable;
 wire read_enable=!LOCAL_ENABLES || (enable && I_de && next_in_x && py>=10'd344 && py<10'd400);
 wire write_sample=audio_valid && sample_div==3'd5 && capture_enable;
 wire [11:0] sample_input={scaled(audio_left),scaled(audio_right)};
 reg [11:0] sample_read,forward_sample;
 reg forward_valid;
 always @(posedge clk) begin
  // One active-pixel lookahead warms the RAM at panel_left-1.
  if(read_enable) sample_read<=samples[next_index];
  if(!rst && write_sample) samples[wr]<=sample_input;
  if(write_sample) forward_sample<=sample_input;
 end
 always @(posedge clk or posedge rst)
  if(rst) forward_valid<=0;
  else forward_valid<=read_enable && write_sample && wr==next_index;
 wire [11:0] current_sample=forward_valid ? forward_sample : sample_read;
 wire sample_valid={1'b0,index}<filled;
 // Previous PIXEL register joins adjacent samples at sample boundaries.
 // Invalid/line boundaries cannot draw phantom segments from unfilled RAM.
 reg [11:0] previous_sample;
 reg previous_valid;
 wire [5:0] relative_y=py[5:0]-6'd24;
 wire signed [6:0] left_row=7'sd28-$signed({current_sample[11],current_sample[11:6]});
 wire signed [6:0] right_row=7'sd28-$signed({current_sample[5],current_sample[5:0]});
 wire signed [6:0] previous_left_row=7'sd28-$signed({previous_sample[11],previous_sample[11:6]});
 wire signed [6:0] previous_right_row=7'sd28-$signed({previous_sample[5],previous_sample[5:0]});
 wire [6:0] left_low=previous_valid && previous_left_row<left_row ? previous_left_row : left_row;
 wire [6:0] left_high=previous_valid && previous_left_row>left_row ? previous_left_row : left_row;
 wire [6:0] right_low=previous_valid && previous_right_row<right_row ? previous_right_row : right_row;
 wire [6:0] right_high=previous_valid && previous_right_row>right_row ? previous_right_row : right_row;
 wire left_hit=sample_valid && {1'b0,relative_y}>=left_low && {1'b0,relative_y}<=left_high;
 wire right_hit=sample_valid && {1'b0,relative_y}>=right_low && {1'b0,relative_y}<=right_high;
 function [7:0] mix_channel;
  input [7:0] base,tint;
  input [2:0] level;
  reg [8:0] pair_sum;
  reg [7:0] heavier;
  reg [9:0] weighted;
  begin
   pair_sum={1'b0,base}+{1'b0,tint};
   case(level)
    3'd3: heavier=tint;
    default: heavier=base;
   endcase
   weighted={1'b0,pair_sum}+{1'b0,heavier,1'b0};
   case(level)
    3'd0: mix_channel=base;
    3'd2: mix_channel=pair_sum[8:1];
    3'd4: mix_channel=tint;
    default: mix_channel=weighted[9:2];
   endcase
  end
 endfunction
 // Exactly one dark-background mix; spectrum tints only occupied bars.
 wire [23:0] background_rgb={
  mix_channel(I_rgb[23:16],8'h09,opacity_level),
  mix_channel(I_rgb[15:8],8'h2D,opacity_level),
  mix_channel(I_rgb[7:0],8'h37,opacity_level)};
 function [5:0] scaled;
  input signed [23:0] s;
  reg signed [23:0] v;
  begin
   v=s>>>15;
   if(v>24) scaled=6'd24;
   else if(v< -24) scaled=-6'sd24;
   else scaled=v[5:0];
  end
 endfunction
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   wr<=0;filled<=0;sample_div<=0;x<=0;y<=0;de_d<=0;vs_d<=0;frame_arm<=1;
   layout<=0;index<=0;phase<=0;previous_sample<=0;previous_valid<=0;
   frame_left_color<=24'hE8EEF4;frame_right_color<=24'h9DECF5;
   O_rgb<=0;O_hs<=0;O_vs<=0;O_de<=0;O_wave_hit<=0;
  end else begin
   O_rgb<=I_rgb;O_hs<=I_hs;O_vs<=I_vs;O_de<=I_de;O_wave_hit<=0;
   de_d<=I_de;vs_d<=I_vs;
   if(vs_d!=I_vs) frame_arm<=1;
   if(I_de) begin
    x<=px;y<=py;
    if(!de_d) begin
     frame_arm<=0;
     if(frame_arm) begin
      layout<=ADAPTIVE_LAYOUT && half_layout;
      frame_left_color<=left_wave_color;frame_right_color<=right_wave_color;
     end
    end
   end
   if(!I_de || !in_x) begin index<=0;phase<=0;end
   else begin
    if(advance) index<=index+7'd1;
    if(layout ? phase==3'd1 : phase==3'd4) phase<=0;
    else phase<=phase+3'd1;
   end
   previous_valid<=I_de && box && sample_valid;
   if(I_de && box) previous_sample<=current_sample;
   if(!capture_enable) begin wr<=0;filled<=0;sample_div<=0;end
   else if(audio_valid) begin
    if(sample_div==3'd5) begin
     sample_div<=0;wr<=wr+7'd1;
     if(filled<8'd128) filled<=filled+8'd1;
    end else sample_div<=sample_div+3'd1;
   end
   if(enable && I_de && box) begin
    O_rgb<=background_rgb;
    O_wave_hit<=left_hit || right_hit;
    if(left_hit && right_hit) O_rgb<=24'hF2FAFF;
    else if(left_hit) O_rgb<=left_color;
    else if(right_hit) O_rgb<=right_color;
   end
  end
 end
endmodule
