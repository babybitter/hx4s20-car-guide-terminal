// s08 candidate: effect=3, wave=1, RGB/timing total=4 registered stages.
// Chinese safety OSD is applied by the caller after this chain.
module terminal_video_chain #(parameter ADAPTIVE_LAYOUT=0,LOCAL_ENABLES=0,DYNAMIC_COLOR=0)(
 input wire clk,rst,effects_enabled,waveform_enabled,
 // Actual E only: effects_enabled may also contain legacy_active.
 input wire waveform_auto_enabled,
 input wire [2:0] opacity_level,
 input wire [23:0] I_rgb,
 input wire I_hs,I_vs,I_de,
 input wire [6:0] page_id,
 input wire [1:0] brightness,contrast,transition_style,
 input wire [2:0] filter_mode,volume,
 input wire [3:0] transition_level,
 input wire auto_enabled,media_ready,uart_seen,
 input wire [3:0] error_code,
 input wire [319:0] subtitle,
 input wire [5:0] subtitle_length,
 input wire audio_valid,
 input wire signed [23:0] audio_left,audio_right,
 output wire [23:0] O_rgb,
 output wire O_hs,O_vs,O_de,
 input wire half_layout,
 input wire [1:0] zoom_setting,
 input wire [23:0] left_wave_color,right_wave_color
);
 reg [2:0] hs_delay,vs_delay,de_delay;
 wire [23:0] effect_rgb;
 always @(posedge clk or posedge rst) begin
  if(rst) begin hs_delay<=0;vs_delay<=0;de_delay<=0;end
  else begin
   hs_delay<={hs_delay[1:0],I_hs};vs_delay<={vs_delay[1:0],I_vs};de_delay<={de_delay[1:0],I_de};
  end
 end
 advanced_video_overlay #(.HALF_ZOOM_ENABLE(ADAPTIVE_LAYOUT)) u_effect (
  .video_clk(clk),.rst(rst),.enable(effects_enabled),.hs(I_hs),.vs(I_vs),.de(I_de),
  .rgb_in(I_rgb),.image_index(page_id),.auto_play(auto_enabled),.zoom_2x(1'b0),
  .audio_ready(media_ready),.brightness_level(brightness),.contrast_level(contrast),
  .filter_mode(filter_mode),.transition_style(transition_style),.transition_level(transition_level),
  .uart_seen(uart_seen),.stability_alert(error_code!=0),.stability_error_count(error_code),
  .audio_level({1'b0,volume}),.scroll_text(subtitle),.scroll_text_len(subtitle_length),.rgb_out(effect_rgb),.zoom_setting(zoom_setting));
 pcm_wave_overlay #(.ADAPTIVE_LAYOUT(ADAPTIVE_LAYOUT),.LOCAL_ENABLES(LOCAL_ENABLES),.DYNAMIC_COLOR(DYNAMIC_COLOR)) u_wave (
  .clk(clk),.rst(rst),.enable(waveform_auto_enabled || waveform_enabled),
  .opacity_level(opacity_level),.I_rgb(effect_rgb),
  .I_hs(hs_delay[2]),.I_vs(vs_delay[2]),.I_de(de_delay[2]),.audio_valid(audio_valid),
  .audio_left(audio_left),.audio_right(audio_right),.O_rgb(O_rgb),.O_hs(O_hs),.O_vs(O_vs),.O_de(O_de),.half_layout(half_layout),
  .left_wave_color(left_wave_color),.right_wave_color(right_wave_color));
endmodule
