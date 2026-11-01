// Samples are taken from the actual post-volume HDMI PCM, not an animation.
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
 input wire [23:0] left_wave_color,right_wave_color
);
 // The existing subtitle band starts at y=380 (glyphs at y=387).
 // Keep the entire 64-row scope immediately above that band.
 reg layout;
 reg [23:0] frame_left_color,frame_right_color;
 wire [23:0] left_color=DYNAMIC_COLOR?frame_left_color:24'h57E0BD;
 wire [23:0] right_color=DYNAMIC_COLOR?frame_right_color:24'hFFAF72;
 wire [9:0] wave_top=layout?10'd260:10'd316, wave_bottom=layout?10'd308:10'd380;
 wire signed [10:0] wave_center=layout?11'sd284:11'sd348;
 // Each clipped displacement is in [-24,24], exactly representable in 6 bits.
 (* ram_style = "block" *) reg [11:0] samples [0:127];
 reg [6:0] wr;
 reg [7:0] filled;
 // 48 kHz PCM / 6 = 8 kHz scope samples: the 1 kHz prompt has eight
 // points per period instead of aliasing to DC at the old 1 kHz scope rate.
 reg [2:0] sample_div;
 reg [5:0] meter_div;
 reg [23:0] peak_left,peak_right;
 reg [3:0] level_left,level_right;
 wire [23:0] magnitude_left=audio_left[23] ? -audio_left : audio_left;
 wire [23:0] magnitude_right=audio_right[23] ? -audio_right : audio_right;
 wire [23:0] next_peak_left=magnitude_left>peak_left ? magnitude_left : peak_left;
 wire [23:0] next_peak_right=magnitude_right>peak_right ? magnitude_right : peak_right;
 reg [9:0] x,y;
 reg de_d,vs_d,frame_arm;
 wire [9:0] px=!de_d?0:x+1'b1;
 wire [9:0] py=!de_d && frame_arm?0:!de_d?y+1'b1:y;
 wire [9:0] left_start=layout?10'd168:10'd16,right_start=layout?10'd328:10'd320;
 wire [9:0] box_width=layout?10'd128:10'd256;
 wire [9:0] left_end=layout?10'd296:10'd272,right_end=layout?10'd456:10'd576;
 wire left_box=px>=left_start && px<left_end;
 wire right_box=px>=right_start && px<right_end;
 wire box=(left_box||right_box) && py>=wave_top && py<wave_bottom;
 wire [9:0] column=left_box?px-left_start:px-right_start;
 wire [6:0] index=layout?column[6:0]:column[7:1];
 // Prefetch one active pixel ahead. Blanking always prepares index0; the
 // first scope pixel is x16, so every visible scope access is warmed up.
 // Forward same-edge writes to preserve the old asynchronous-memory view.
 wire [9:0] next_px=I_de ? px+10'd1 : 10'd0;
 wire next_left=next_px>=left_start && next_px<left_end;
 wire next_right=next_px>=right_start && next_px<right_end;
 wire [9:0] next_column=next_left?next_px-left_start:next_px-right_start;
 wire [6:0] next_index=I_de?(layout?next_column[6:0]:next_column[7:1]):7'd0;
 wire capture_enable=!LOCAL_ENABLES || enable;
 wire read_enable=!LOCAL_ENABLES || (enable && I_de && (next_left || next_right) && py>=wave_top && py<wave_bottom);
 wire write_sample=audio_valid && sample_div==5 && capture_enable;
 wire [11:0] sample_input={scaled(audio_left),scaled(audio_right)};
 reg [11:0] sample_read,forward_sample;
 reg forward_valid;
 always @(posedge clk) begin
  if(read_enable)sample_read<=samples[next_index];
  if(!rst && write_sample)samples[wr]<=sample_input;
  if(write_sample)forward_sample<=sample_input;
 end
 always @(posedge clk or posedge rst)
  if(rst)forward_valid<=0;
  else forward_valid<=read_enable && write_sample && wr==next_index;
 wire [11:0] current_sample=forward_valid?forward_sample:sample_read;
 wire signed [5:0] sample_y=left_box?$signed(current_sample[11:6]):$signed(current_sample[5:0]);
 wire signed [5:0] draw_sample=layout?(sample_y>>>1):sample_y;
 // modulo-64 is exact within the guarded 64/48-row scopes; no screen-wide subtractor.
 wire [5:0] relative_y=py[5:0]-(layout?6'd4:6'd60);
 wire signed [6:0] point_row=(layout?7'sd24:7'sd32)-draw_sample;
 wire left_meter=layout?(px>=300 && px<304):(px>=276 && px<284);
 wire right_meter=layout?(px>=460 && px<464):(px>=580 && px<588);
 wire [3:0] meter_level=left_meter?level_left:level_right;
 wire [6:0] meter_height=layout?{2'd0,meter_level,1'b0}:{1'b0,meter_level,2'b00};
 wire [23:0] base_rgb=layout && py>=48 && py<380 &&
     (px<160 || px>=480 || py<72 || py>=312)?24'h081E2A:I_rgb;
 // Exact per-channel integer mix, with one final truncation to 8 bits.
 // Shifts/additions only; constants below let synthesis fold the tint terms.
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
 wire [23:0] background_rgb={
  mix_channel(base_rgb[23:16],8'h09,opacity_level),
  mix_channel(base_rgb[15:8],8'h2D,opacity_level),
  mix_channel(base_rgb[7:0],8'h37,opacity_level)};
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
   wr<=0;filled<=0;sample_div<=0;meter_div<=0;x<=0;y<=0;de_d<=0;vs_d<=0;frame_arm<=0;
   peak_left<=0;peak_right<=0;level_left<=0;level_right<=0;layout<=0;
   frame_left_color<=24'h57E0BD;frame_right_color<=24'hFFAF72;
   O_rgb<=0;O_hs<=0;O_vs<=0;O_de<=0;
  end else begin
   O_rgb<=base_rgb;O_hs<=I_hs;O_vs<=I_vs;O_de<=I_de;
   de_d<=I_de;vs_d<=I_vs;
   if(vs_d!=I_vs) frame_arm<=1;
   if(I_de) begin
    x<=px;y<=py;
    if(!de_d)begin
     frame_arm<=0;
     if(frame_arm)begin
      layout<=ADAPTIVE_LAYOUT && half_layout;
      frame_left_color<=left_wave_color;frame_right_color<=right_wave_color;
     end
    end
   end
   if(!capture_enable)begin
    wr<=0;filled<=0;sample_div<=0;meter_div<=0;peak_left<=0;peak_right<=0;level_left<=0;level_right<=0;
   end else if(audio_valid) begin
    peak_left<=next_peak_left;peak_right<=next_peak_right;
    if(sample_div==5) begin
     sample_div<=0;wr<=wr+1'b1;
     if(filled<128) filled<=filled+1'b1;
    end else sample_div<=sample_div+1'b1;
    // Keep the actual PCM peak window at 48 samples (1 ms).
    if(meter_div==47) begin
     meter_div<=0;
     level_left<=|next_peak_left[23:19]?4'd15:next_peak_left[18:15];
     level_right<=|next_peak_right[23:19]?4'd15:next_peak_right[18:15];
     peak_left<=0;peak_right<=0;
    end else meter_div<=meter_div+1'b1;
   end
   if(enable && I_de && box) begin
    O_rgb<=background_rgb;
    if(py==wave_center) O_rgb<=24'h37616A;
    if({1'b0,index}<filled && $signed({1'b0,relative_y})==point_row)
     O_rgb<=left_box?left_color:right_color;
   end
   if(enable && I_de && (left_meter||right_meter) && py>=wave_top && py<wave_bottom)
    O_rgb<=py>=wave_bottom-meter_height ? (left_meter?left_color:right_color):background_rgb;
  end
 end
endmodule
