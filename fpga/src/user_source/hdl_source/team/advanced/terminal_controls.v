// Pixel-domain control arbitration. Configuration is published only in blanking.
module terminal_controls #(parameter integer HELD_TEXT_INPUT=0) (
 input wire clk, rst, blank_tick,
 input wire next_key, auto_key, prompt_key,
 input wire [1:0] local_period,
 input wire local_period_changed,
 input wire mode_sw, mute_sw,
 input wire command_valid,
 input wire [7:0] command, value,
 input wire [319:0] command_text,
 input wire [5:0] command_text_length,
 output wire next_pulse, auto_pulse, prompt_pulse, tone_pulse, select_pulse,
 output wire [6:0] select_index,
 output reg [1:0] period_sel,
 output reg period_changed,
 output reg [1:0] brightness, contrast, transition_style,
 output reg [2:0] filter_mode, volume,
 output reg [2:0] opacity_level,
 output reg effects_enabled, waveform_enabled,
 output reg [319:0] subtitle,
 output reg [5:0] subtitle_length
);
 reg [1:0] pending_period, pending_brightness, pending_contrast, pending_style;
 reg [2:0] pending_filter, pending_volume;
 reg [2:0] pending_opacity;
 reg pending_effects, pending_waveform;
 reg [319:0] pending_text;
 reg [5:0] pending_length;
 wire remote_event = command_valid && !(next_key || auto_key || prompt_key);
 assign next_pulse = (!mode_sw && next_key) || (remote_event && command == "N");
 assign auto_pulse = (!mode_sw && auto_key) || (remote_event && command == "A");
 assign prompt_pulse = (!mode_sw && prompt_key) || (remote_event && command == "M");
 assign tone_pulse = remote_event && command == "P";
 assign select_pulse = remote_event && command == "I" && value < 8'd128;
 assign select_index = value[6:0];
 always @(posedge clk or posedge rst) begin
  if (rst) begin
   // Match key_switch_ctrl's reset snapshot. A stable physical 01 generates
   // no change pulse; other positions publish after debounce as before.
   pending_period<=2'b01; period_sel<=2'b01; period_changed<=0;
   pending_brightness<=1; pending_contrast<=1; pending_style<=0;
   pending_filter<=0; pending_volume<=4; pending_effects<=0; pending_waveform<=0;
   pending_opacity<=1; opacity_level<=1;
   pending_text<=0; pending_length<=0;
   brightness<=1; contrast<=1; transition_style<=0; filter_mode<=0;
   volume<=4; effects_enabled<=0; waveform_enabled<=0; subtitle<=0; subtitle_length<=0;
  end else begin
   period_changed<=0;
   if (command_valid) case(command)
    "B": pending_brightness<=value[1:0];
    "C": pending_contrast<=value[1:0];
    "F": pending_filter<=value[2:0];
    "T": pending_style<=value[1:0];
    "V": pending_volume<=value[2:0];
    "W": pending_waveform<=value[0];
    "Y": if(value<=4) pending_opacity<=value[2:0];
    "E": pending_effects<=value[0];
    "R": pending_period<=value[1:0];
    "S": begin pending_text<=command_text; pending_length<=command_text_length; end
    default: begin end
   endcase
   if(local_period_changed) pending_period<=local_period;
   if(mode_sw && next_key) pending_filter <= pending_filter==5 ? 0 : pending_filter+1'b1;
   if(mode_sw && prompt_key) pending_style<=pending_style+1'b1;
   if(mode_sw && auto_key) pending_effects<=~pending_effects;
   if(blank_tick) begin
    period_sel<=pending_period;
    period_changed<=period_sel!=pending_period;
    brightness<=pending_brightness; contrast<=pending_contrast;
    filter_mode<=pending_filter; transition_style<=pending_style;
    effects_enabled<=pending_effects; waveform_enabled<=pending_waveform;
    opacity_level<=pending_opacity;
    // terminal_uart_v2 already retains a complete validated S packet until
    // the next S. In that integration, reuse that pending bank and keep only
    // this displayed bank. A coincident S waits for the following blank.
    if(!HELD_TEXT_INPUT || !(command_valid && command=="S")) begin
     subtitle<=HELD_TEXT_INPUT?command_text:pending_text;
     subtitle_length<=HELD_TEXT_INPUT?command_text_length:pending_length;
    end
   end
   // Muting is independent of video blanking; PCM consumer samples this level.
   volume<=mute_sw ? 3'd0 : pending_volume;
  end
 end
endmodule
