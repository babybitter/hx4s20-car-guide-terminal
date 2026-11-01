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
 // Layout inputs/parameters remain compatible; both modes share 608x56.
 reg shown_enable;
 reg [2:0] frame_opacity;
 reg [23:0] frame_left_color,frame_right_color;
 // Small dynamic tint: L grey-white, R cyan-white, above the rainbow.
 wire [23:0] left_color=DYNAMIC_COLOR ?
  {3'b111,frame_left_color[23:19],3'b111,frame_left_color[15:11],3'b111,frame_left_color[7:3]} : 24'hE8EEF4;
 wire [23:0] right_color=DYNAMIC_COLOR ?
  {3'b100,frame_right_color[23:19],3'b111,frame_right_color[15:11],3'b111,frame_right_color[7:3]} : 24'h9DECF5;
 // Two 152x12 snapshots use the unused depth of the SAME one 9K BRAM.
 // Each bank has a 256-word stride; only addresses 0..151 are populated.
 // Only the back bank is written; a complete capture waits for frame start.
 // No RAM reset loop, extra port, copy pass or read/write forwarding mux.
 (* ram_style = "block" *) reg [11:0] samples [0:511];
 reg display_bank,display_valid,capture_ready;
 reg [7:0] wr;
 // 48 kHz / 5 = 9.6 kHz scope history (15.83 ms, 152 samples).
 reg [2:0] sample_div;
 reg [9:0] x;
 reg [8:0] y; // Active raster has 480 rows; ten bits are unnecessary.
 reg de_d,vs_d,frame_arm;
 wire [9:0] px=!de_d ? 10'd0 : x+10'd1;
 wire [8:0] py=!de_d ? (frame_arm ? 9'd0 : y+9'd1) : y;
 wire snapshot=I_de && !de_d && frame_arm;
 wire [9:0] panel_left=10'd16;
 wire [9:0] panel_right=10'd624;
 wire in_x=px>=panel_left && px<panel_right;
 wire box=in_x && py>=9'd343 && py<9'd399;
 // 608 columns = 152 four-pixel segments. No divider or variable step.
 reg [7:0] index;
 reg [1:0] phase;
 wire advance=phase==2'd3;
 // Prefetch the two endpoints before x16, then fetch once per segment.
 // Clamp the last endpoint: never join sample151 to sample0.
 wire [7:0] endpoint_index=index>=8'd150 ? 8'd151 : index+8'd2;
 wire [7:0] read_index=px==10'd14 ? 8'd0 : (px==10'd15 ? 8'd1 : endpoint_index);
 wire capture_enable=!LOCAL_ENABLES || (snapshot ? enable : shown_enable);
 wire read_enable=I_de && py>=9'd343 && py<9'd399 &&
   (!LOCAL_ENABLES || shown_enable) && (px==10'd14 || px==10'd15 || (in_x && advance));
 wire write_sample=audio_valid && sample_div==3'd4 && capture_enable && !capture_ready;
 wire [11:0] raw_sample={scaled(audio_left),scaled(audio_right)};
 reg [11:0] history1,history2;
 reg history_valid;
 // Display-only causal [1,2,1]/4 FIR; replicate the first endpoint.
 // Arithmetic rounding keeps negative samples symmetric to within 1px.
 function [5:0] smooth;
  input signed [5:0] a,b,c;
  reg signed [7:0] total;
  begin
   total={{2{a[5]}},a}+{{1{b[5]}},b,1'b0}+{{2{c[5]}},c}+8'sd2;
   smooth=total>>>2;
  end
 endfunction
 wire [11:0] sample_input=history_valid ?
   {smooth(history2[11:6],history1[11:6],raw_sample[11:6]),
    smooth(history2[5:0],history1[5:0],raw_sample[5:0])} : raw_sample;
 reg [11:0] sample_read;
 always @(posedge clk) begin
  if(read_enable) sample_read<=samples[{display_bank,read_index}];
  if(!rst && write_sample) samples[{!display_bank,wr}]<=sample_input;
 end
 reg [11:0] segment_start;
 wire sample_valid=display_valid;
 // Exact quarter-step interpolation: ((4-t)*a+t*b+2)>>2.
 // Rows are 4..52; pair_sum<=104 and weighted<=210 cannot overflow.
 wire [5:0] start_row [0:1];
 wire [5:0] end_row [0:1];
 wire [5:0] interpolated_row [0:1];
 assign start_row[0]=6'd28-segment_start[11:6];
 assign start_row[1]=6'd28-segment_start[5:0];
 assign end_row[0]=6'd28-sample_read[11:6];
 assign end_row[1]=6'd28-sample_read[5:0];
 genvar channel;
 generate for(channel=0;channel<2;channel=channel+1) begin : g_line
  wire [6:0] pair_sum={1'b0,start_row[channel]}+{1'b0,end_row[channel]};
  wire [5:0] heavier=phase[1] ? end_row[channel] : start_row[channel];
  wire [7:0] weighted={1'b0,pair_sum}+{1'b0,heavier,1'b0}+8'd2;
  wire [6:0] midpoint=pair_sum+7'd1;
  assign interpolated_row[channel]=phase==0 ? start_row[channel] :
    phase==2 ? midpoint[6:1] : weighted[7:2];
 end endgenerate
 wire [5:0] left_row=interpolated_row[0];
 wire [5:0] right_row=interpolated_row[1];
 reg [5:0] previous_left_row,previous_right_row;
 reg previous_valid;
 wire [5:0] relative_y=py[5:0]-6'd23;
 // Test membership between the two rows without selecting min/max buses.
 wire left_hit=sample_valid && ((relative_y==left_row) || (previous_valid &&
   ((relative_y>=previous_left_row && relative_y<=left_row) ||
    (relative_y<=previous_left_row && relative_y>=left_row))));
 wire right_hit=sample_valid && ((relative_y==right_row) || (previous_valid &&
   ((relative_y>=previous_right_row && relative_y<=right_row) ||
    (relative_y<=previous_right_row && relative_y>=right_row))));
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
  mix_channel(I_rgb[23:16],8'h09,frame_opacity),
  mix_channel(I_rgb[15:8],8'h2D,frame_opacity),
  mix_channel(I_rgb[7:0],8'h37,frame_opacity)};
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
   wr<=0;sample_div<=0;display_bank<=0;display_valid<=0;capture_ready<=0;
   x<=0;y<=0;de_d<=0;vs_d<=0;frame_arm<=1;
   shown_enable<=0;frame_opacity<=1;index<=0;phase<=0;previous_valid<=0;
   history_valid<=0;
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
      shown_enable<=enable;frame_opacity<=opacity_level;
      frame_left_color<=left_wave_color;frame_right_color<=right_wave_color;
     end
    end
   end
   if(!I_de || !in_x) begin index<=0;phase<=0;end
   else begin
    if(advance) index<=index+8'd1;
    if(advance) phase<=0;
    else phase<=phase+2'd1;
   end
   previous_valid<=I_de && box && sample_valid;
   if(!capture_enable || (snapshot && capture_ready)) history_valid<=0;
   else if(write_sample) history_valid<=1;
   if(!capture_enable) begin wr<=0;capture_ready<=0;display_valid<=0;sample_div<=0;end
   else if(snapshot && capture_ready) begin
    display_bank<=!display_bank;display_valid<=1;capture_ready<=0;wr<=0;sample_div<=0;
   end else if(audio_valid && !capture_ready) begin
    if(sample_div==3'd4) begin
     sample_div<=0;
     if(wr==8'd151) capture_ready<=1;
     else wr<=wr+8'd1;
    end else sample_div<=sample_div+3'd1;
   end
   if(shown_enable && I_de && box) begin
    O_rgb<=background_rgb;
    O_wave_hit<=left_hit || right_hit;
    if(left_hit && right_hit) O_rgb<=24'hF2FAFF;
    else if(left_hit) O_rgb<=left_color;
    else if(right_hit) O_rgb<=right_color;
   end
  end
 end
 // Private sample/line history is overwritten before its validity flag can
 // expose it. Avoid reset multiplexers on data that need no reset value.
 always @(posedge clk) if(!rst) begin
  if(I_de && (px==15 || (box && advance))) segment_start<=sample_read;
  if(I_de && box) begin previous_left_row<=left_row;previous_right_row<=right_row;end
  if(write_sample) begin
   history1<=raw_sample;
   history2<=history_valid ? history1 : raw_sample;
  end
 end
endmodule
