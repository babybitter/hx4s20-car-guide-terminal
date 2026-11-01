// Pixel-domain speech/music arbitration. Assets are prepared offline, never TTS
// computation in the FPGA. Four bounded queues prevent unbounded stale speech.
module audio_scene_scheduler #(
 parameter integer IDLE_MS=3000, CONFIG_MS=1500, SAMPLES_PER_MS=48,
 parameter integer FADE_TICKS=24
)(
 input wire clk,rst,sample_tick,assets_ready,muted,
 input wire [1:0] mode,
 input wire event_valid,input wire [4:0] event_id,input wire [1:0] event_priority,
 output wire [6:0] rom_addr,input wire [15:0] rom_data,
 output reg player_start,player_stop,
 output reg [20:0] clip_offset_words,clip_samples,resume_samples,
 output reg loop_enable,input wire player_ready,player_busy,player_done,player_fault,
 input wire [20:0] player_position,input wire signed [15:0] player_pcm,
 output wire signed [23:0] pcm,
 output wire music_active,pending,output wire [7:0] current_clip,
 output reg [15:0] event_sequence
);
 localparam IDLE=0,OFF_WAIT=1,OFF_GET=2,OFF_HIGH_WAIT=3,OFF_HIGH_GET=4,
            COUNT_WAIT=5,COUNT_GET=6,COUNT_HIGH_WAIT=7,COUNT_HIGH_GET=8,
            START=9,RUN=10,FADE=11,STOP=12,WAIT_STOP=13;
 reg [3:0] state;
 reg [3:0] queued;
 reg [4:0] ids[0:3];
 reg [4:0] selected;
 reg [1:0] priority_now;
 reg is_music;reg [1:0] field;reg [15:0] rom_low;
 reg [20:0] music_position;
 reg music_saved;
 reg [15:0] idle_ms,config_ms;
 reg [7:0] sample_div,fade_div;
 reg [4:0] gain;
 wire ms_tick=sample_tick && sample_div==SAMPLES_PER_MS-1;
 wire speech_allowed=assets_ready && mode[0] && !muted && !player_fault;
 wire music_allowed=assets_ready && mode[1] && !muted && !player_fault;
 wire config_ready=queued[0] && config_ms>=CONFIG_MS;
 wire have_speech=queued[3] || queued[2] || queued[1] || config_ready;
 wire [1:0] pick=queued[3]?3:queued[2]?2:queued[1]?1:0;
 wire interrupt_speech=(queued[3] && priority_now<3) ||
                       (queued[2] && priority_now<2) ||
                       (queued[1] && priority_now<=1);
 wire need_stop=(is_music?!music_allowed:!speech_allowed) ||
                (speech_allowed && (is_music?have_speech:interrupt_speech));
 wire signed [21:0] scaled=$signed(player_pcm)*$signed({1'b0,gain});
 // 16-bit source -> 24-bit HDMI; gain/16 then <<8, with no overflow.
 assign pcm={scaled[19:0],4'b0};
 assign rom_addr={selected,field};
 assign music_active=is_music && player_busy;
 assign current_clip=player_busy?{3'd0,selected}:8'hff;
 assign pending=|queued;
 integer k;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;queued<=0;for(k=0;k<4;k=k+1)ids[k]<=0;
   selected<=0;priority_now<=0;is_music<=0;field<=0;rom_low<=0;
   music_position<=0;music_saved<=0;idle_ms<=0;config_ms<=CONFIG_MS;
   sample_div<=0;fade_div<=0;gain<=0;event_sequence<=0;
   player_start<=0;player_stop<=0;clip_offset_words<=0;clip_samples<=0;resume_samples<=0;loop_enable<=0;
  end else begin
   player_start<=0;player_stop<=0;
   if(sample_tick)sample_div<=ms_tick?0:sample_div+1'b1;
   if(ms_tick)begin
    if(idle_ms<IDLE_MS)idle_ms<=idle_ms+1'b1;
    if(config_ms<CONFIG_MS)config_ms<=config_ms+1'b1;
   end
   // Fully muted announcements are deliberately discarded, not replayed later.
   if(!speech_allowed)queued<=0;
   if(!music_allowed && !is_music)idle_ms<=0;
   case(state)
    IDLE:begin
     gain<=0;fade_div<=0;
     if(speech_allowed && have_speech)begin
      selected<=ids[pick];priority_now<=pick;queued[pick]<=0;
      is_music<=0;loop_enable<=0;resume_samples<=0;field<=0;state<=OFF_WAIT;
      idle_ms<=0;if(pick==0)config_ms<=0;
     end else if(music_allowed && idle_ms>=IDLE_MS)begin
      selected<=31;priority_now<=0;is_music<=1;loop_enable<=1;
      resume_samples<=music_saved?music_position:0;field<=0;state<=OFF_WAIT;
     end
    end
    OFF_WAIT:state<=OFF_GET;
    OFF_GET:begin rom_low<=rom_data;field<=1;state<=OFF_HIGH_WAIT;end
    OFF_HIGH_WAIT:state<=OFF_HIGH_GET;
    OFF_HIGH_GET:begin clip_offset_words<={rom_data[6:0],rom_low[15:2]};field<=2;state<=COUNT_WAIT;end
    COUNT_WAIT:state<=COUNT_GET;
    COUNT_GET:begin rom_low<=rom_data;field<=3;state<=COUNT_HIGH_WAIT;end
    COUNT_HIGH_WAIT:state<=COUNT_HIGH_GET;
    COUNT_HIGH_GET:begin clip_samples<={rom_data[4:0],rom_low};state<=START;end
    START:begin
     if(is_music?!music_allowed:!speech_allowed)state<=IDLE;
     else if(player_ready)begin player_start<=1;state<=RUN;end
    end
    RUN:begin
     if(player_done)begin
      state<=IDLE;gain<=0;
      if(!is_music && music_saved)idle_ms<=IDLE_MS;
     end else if(need_stop)begin state<=FADE;fade_div<=0;end
     else if(sample_tick && gain<16)begin
      if(fade_div==FADE_TICKS-1)begin fade_div<=0;gain<=gain+1'b1;end
      else fade_div<=fade_div+1'b1;
     end
    end
    FADE:begin
     if(gain==0 || player_done)state<=STOP;
     else if(sample_tick)begin
      if(fade_div==FADE_TICKS-1)begin fade_div<=0;gain<=gain-1'b1;end
      else fade_div<=fade_div+1'b1;
     end
    end
    STOP:begin
     if(is_music)begin music_position<=player_position;music_saved<=1;end
     player_stop<=1;gain<=0;state<=WAIT_STOP;
    end
    WAIT_STOP:if(!player_stop && player_ready && !player_busy)begin
     state<=IDLE;if(music_saved)idle_ms<=IDLE_MS;
    end
    default:state<=IDLE;
   endcase
   // Newest same-priority event replaces queued speech. Executed last so a new
   // event arriving on a dequeue edge is retained (no nonblocking-write loss).
   if(event_valid && speech_allowed)begin
    ids[event_priority]<=event_id;queued[event_priority]<=1;
    event_sequence<=event_sequence+1'b1;idle_ms<=0;
   end
  end
 end
endmodule
