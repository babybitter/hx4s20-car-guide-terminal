// S19: prepared Chinese speech and background music, both from validated SDRAM.
module terminal_audio_engine #(parameter [7:0] FEATURES=8'h01)(
 input wire pixel_clk,mem_clk,rst_pixel,rst_mem,
 input wire sample_tick,assets_ready_sd,input wire [3:0] loader_fault_sd,
 input wire [2:0] volume,input wire command_valid,input wire [7:0] command,value,
 input wire display_ready,page_commit,prompt_open,input wire [6:0] page,title,
 input wire [2:0] cue,input wire auto_active,story_active,story_auto,effect_mode,
 input wire [2:0] filter,input wire [1:0] transition,input wire [7:0] story_config,
 input wire [15:0] sequence_version,subtitle_version,input wire [3:0] error_code,
 output wire [31:0] expected_bytes,expected_crc,
 output wire signed [23:0] pcm,output wire use_pcm,music_active,fallback_allowed,
 output wire [79:0] audio_status,
 output wire rd_demand,rd_lock,input wire rd_grant,
 output wire App_rd_en,output wire [20:0] App_rd_addr,
 input wire Sdr_rd_en,input wire [31:0] Sdr_rd_dout,
 input wire Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,
 input wire [1:0] zoom_setting,
 output wire [20:0] position_samples
);
 reg [2:0] assets_sync;reg [3:0] fault_meta,fault_sync;
 reg [1:0] mode;
 wire [6:0] rom_addr;wire [15:0] rom_data;
 wire event_valid;wire [4:0] event_id;wire [1:0] event_priority;
 wire start,stop,ready,busy,done,fault,loop_enable,pending;
 wire [20:0] offset,count,resume,position;wire [31:0] underflows;
 wire signed [15:0] pcm16;wire [7:0] clip;wire [15:0] event_sequence;
 always @(posedge pixel_clk or posedge rst_pixel)begin
  if(rst_pixel)begin assets_sync<=0;fault_meta<=0;fault_sync<=0;mode<=3;end
  else begin
   assets_sync<={assets_sync[1:0],assets_ready_sd};fault_meta<=loader_fault_sd;fault_sync<=fault_meta;
   if(command_valid && command=="L" && value<4)mode<=value[1:0];
  end
 end
 assign use_pcm=assets_sync[2] && !fault;
 assign fallback_allowed=mode[0];
 // This index stays with pcm16 through all three 48kHz repeats and loop wrap.
 // Keep the original progress position for resume and AQ compatibility.
 wire [7:0] flags={assets_sync[2],busy,music_active,volume==0,mode,pending,fault};
 wire [7:0] missing_ticks=(|underflows[31:8])?8'hff:underflows[7:0];
 assign audio_status={8'd1,FEATURES,clip,flags,fault_sync,zoom_setting,1'b0,fault,missing_ticks,event_sequence,position[19:4]};
 audio_asset_rom u_rom(.clk(pixel_clk),.addr(rom_addr),.q(rom_data),
  .package_bytes(expected_bytes),.package_crc32(expected_crc),.active_mask());
 audio_scene_events u_events(.clk(pixel_clk),.rst(rst_pixel),.assets_ready(assets_sync[2]),
  .display_ready(display_ready),.page_commit(page_commit),.prompt_open(prompt_open),.page(page),.title(title),.cue(cue),
  .auto_active(auto_active),.story_active(story_active),.story_auto(story_auto),.effect_mode(effect_mode),
  .filter(filter),.transition(transition),.story_config(story_config),
  .sequence_version(sequence_version),.subtitle_version(subtitle_version),.error_code(error_code),
  .event_valid(event_valid),.event_id(event_id),.event_priority(event_priority),.zoom_mode(zoom_setting));
 audio_scene_scheduler u_schedule(.clk(pixel_clk),.rst(rst_pixel),.sample_tick(sample_tick),
  .assets_ready(assets_sync[2]),.muted(volume==0 || error_code==4'hc),.mode(mode),
  .event_valid(event_valid),.event_id(event_id),.event_priority(event_priority),
  .rom_addr(rom_addr),.rom_data(rom_data),.player_start(start),.player_stop(stop),
  .clip_offset_words(offset),.clip_samples(count),.resume_samples(resume),.loop_enable(loop_enable),
  .player_ready(ready),.player_busy(busy),.player_done(done),.player_fault(fault),
  .player_position(position),.player_pcm(pcm16),.pcm(pcm),.music_active(music_active),.pending(pending),
  .current_clip(clip),.event_sequence(event_sequence));
 audio_stream_player u_player(.pixel_clk(pixel_clk),.mem_clk(mem_clk),.reset_n(!(rst_pixel || rst_mem)),
  .start(start),.stop(stop),.clip_offset_words(offset),.clip_samples(count),.resume_samples(resume),
  .loop_enable(loop_enable),.sample_tick(sample_tick),.ready(ready),.pcm16(pcm16),
  .busy(busy),.done(done),.position(position),.pcm_position(position_samples),.underflow_count(underflows),.fault(fault),
  .rd_demand(rd_demand),.rd_lock(rd_lock),.rd_grant(rd_grant),.App_rd_en(App_rd_en),.App_rd_addr(App_rd_addr),
  .Sdr_rd_en(Sdr_rd_en),.Sdr_rd_dout(Sdr_rd_dout),.Sdr_init_done(Sdr_init_done),.Sdr_init_ref_vld(Sdr_init_ref_vld),.Sdr_busy(Sdr_busy));
endmodule
