// Cache target is protected through the complete transition. Logical identity,
// title, cue and prompt publish once in blanking, after complete target loading.
module story_playback #(
 parameter integer CLK_HZ=25000000,
 parameter integer MAX_BAD_FRAMES=8,
 parameter HALF_ZOOM_ENABLE=0,DEMO_PERIODS=0
)(
 input wire clk,rst,media_ready,fault,input wire [7:0] valid_count,
 input wire next_pulse,auto_pulse,select_pulse,input wire [6:0] select_index,
 input wire [1:0] period_sel,input wire period_changed,prompt_active,blank_tick,frame_good,
 input wire effects_enabled,input wire [1:0] transition_style,
 input wire command_valid,input wire [7:0] command,value,
 input wire story_active,scene_valid,input wire [39:0] scene_word,output wire scene_accept,
 output reg auto_enabled,output reg [6:0] display_page,display_title,
 output reg [1:0] display_slot,source_a,source_b,render_mode,
 output reg [8:0] alpha,output wire [9:0] shift,
 output reg [3:0] transition_level,output reg [1:0] legacy_style,output wire legacy_active,
 output reg page_commit,prompt_event,output reg [2:0] cue_id,output reg [15:0] event_seq,
 output reg cache_req,output reg [6:0] cache_id,
 input wire cache_ack,cache_error,input wire [1:0] cache_slot,
 output wire [7:0] config_status,
 output reg [4:0] recovery_count,
 output wire [1:0] zoom_setting
);
 localparam IDLE=0,LOAD=1,START=2,TRANS=3,OUT=4,IN=5,RELEASE=6;
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
 reg [2:0] state;
 reg [COUNTER_WIDTH-1:0] divider;reg [15:0] elapsed;
 reg queued;reg [6:0] queued_id,target_id,target_title;
 reg [1:0] target_slot;
 reg [2:0] target_effect,target_cue;reg target_prompt;
 reg [1:0] selected_effect,pending_effect,zoom,pending_zoom;reg duration64,pending_duration;
 assign zoom_setting=zoom;
 reg [8:0] step;
 // A failed scanout frame must not hold the cache transaction forever.
 // The destination is already a complete validated cache image in these states.
 // After a bounded consecutive miss interval, finish with a direct blank-time
 // switch to that image, restoring single-source bandwidth and manual service.
 localparam integer BAD_WIDTH=(MAX_BAD_FRAMES<2)?1:$clog2(MAX_BAD_FRAMES);
 reg [BAD_WIDTH-1:0] bad_frames;
 wire waiting_frame=(state==START || state==TRANS || state==OUT || state==IN);
 wire recover_frame=blank_tick && waiting_frame && !frame_good &&
                    bad_frames==MAX_BAD_FRAMES-1;
 wire ms_tick=divider==CLK_HZ/1000-1;
 wire [15:0] period_ms=DEMO_PERIODS ? (period_sel==0?1500:period_sel==1?3000:period_sel==2?5000:8000) :
                                    (period_sel==0?2000:period_sel==1?5000:period_sel==2?10000:15000);
 wire due=auto_enabled && !story_active && state==IDLE && !prompt_active && !auto_pulse && !period_changed && ms_tick && elapsed==period_ms-1;
 wire [6:0] basis=state==IDLE?display_page:target_id;
 wire [6:0] following=({1'b0,basis}+8'd1>=valid_count)?0:basis+1'b1;
 wire [18:0] distance=alpha*(render_mode==2?19'd480:19'd640);
 assign shift=distance[17:8];
 assign legacy_active=(state==OUT || state==IN) && target_effect>=1 && target_effect<=4;
 // Preserve H's legacy bit: any zoom active. AQ carries the exact zoom mode.
 assign config_status={4'd0,duration64,(zoom!=0),selected_effect};
 assign scene_accept=state==IDLE && !queued && !cache_ack && media_ready && !fault &&
                     scene_valid && {1'b0,scene_word[6:0]}<valid_count;
 task commit_target;
  begin
   display_page<=target_id;display_title<=target_title;display_slot<=target_slot;
   source_a<=target_slot;source_b<=target_slot;render_mode<=zoom?3:0;alpha<=0;
   page_commit<=1;prompt_event<=target_prompt;cue_id<=target_cue;event_seq<=event_seq+1'b1;
   cache_req<=0;elapsed<=0;
  end
 endtask
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;divider<=0;elapsed<=0;queued<=0;queued_id<=0;target_id<=0;target_title<=0;target_slot<=0;
   target_effect<=0;target_cue<=0;target_prompt<=0;selected_effect<=0;pending_effect<=0;
   zoom<=0;pending_zoom<=0;duration64<=0;pending_duration<=0;step<=8;
   auto_enabled<=0;display_page<=0;display_title<=0;display_slot<=0;source_a<=0;source_b<=0;render_mode<=0;
   alpha<=0;transition_level<=15;legacy_style<=0;page_commit<=0;prompt_event<=0;cue_id<=0;event_seq<=0;cache_req<=0;cache_id<=0;
   bad_frames<=0;recovery_count<=0;
  end else begin
   page_commit<=0;prompt_event<=0;divider<=ms_tick?0:divider+1'b1;
   if(!media_ready || fault || !waiting_frame) bad_frames<=0;
   else if(blank_tick) begin
    if(frame_good || recover_frame) bad_frames<=0;
    else bad_frames<=bad_frames+1'b1;
   end
   if(command_valid)case(command)
    "X":pending_effect<=value[1:0];
    "Z":if(HALF_ZOOM_ENABLE && value<=2)pending_zoom<=value[1:0];else pending_zoom<={1'b0,value[0]};
    "D":pending_duration<=value[0];
    default:begin end
   endcase
   if(blank_tick)begin
    selected_effect<=pending_effect;zoom<=pending_zoom;duration64<=pending_duration;
    if(state==IDLE || state==RELEASE)render_mode<=pending_zoom?3:0;
   end
   if(!media_ready)begin state<=IDLE;cache_req<=0;queued<=0;auto_enabled<=0;elapsed<=0;end
   else if(fault)begin
    state<=RELEASE;cache_req<=0;queued<=0;auto_enabled<=0;transition_level<=15;
    // Apply restoration only in blank so an already prefetched frame's source
    // descriptors never change in active video.
    if(blank_tick)begin source_a<=display_slot;source_b<=display_slot;render_mode<=zoom?3:0;alpha<=0;end
   end else begin
    if(story_active)begin auto_enabled<=0;elapsed<=0;end
    else if(auto_pulse)begin auto_enabled<=!auto_enabled;elapsed<=0;end
    else if(period_changed || prompt_active || state!=IDLE)elapsed<=0;
    else if(auto_enabled && ms_tick)elapsed<=due?0:elapsed+1'b1;
    if(recover_frame)begin
     // IN has already published its page/cue at black level. Do not publish
     // a second event while recovering the fade-in part of the same change.
     if(state!=IN)commit_target;
     else begin source_a<=display_slot;source_b<=display_slot;render_mode<=zoom?3:0;alpha<=0;cache_req<=0;end
     transition_level<=15;state<=RELEASE;
     if(recovery_count!=31)recovery_count<=recovery_count+1'b1;
    end else case(state)
     IDLE:begin
      if(scene_accept)begin
       target_id<=scene_word[6:0];target_title<=scene_word[13:7];target_effect<=scene_word[32:30];
       target_cue<=scene_word[35:33];target_prompt<=scene_word[36];
       cache_id<=scene_word[6:0];cache_req<=1;state<=LOAD;
      end else if(queued && !cache_ack)begin
       queued<=0;
       if(queued_id!=display_page && {1'b0,queued_id}<valid_count)begin
        target_id<=queued_id;target_title<=queued_id;target_cue<={1'b0,queued_id[1:0]};target_prompt<=0;
        target_effect<=selected_effect!=0?3'd4+selected_effect:(effects_enabled?3'd1+transition_style:0);
        cache_id<=queued_id;cache_req<=1;state<=LOAD;
       end
      end
     end
     LOAD:if(cache_ack)begin
      if(cache_error)begin cache_req<=0;state<=RELEASE;end
      else begin target_slot<=cache_slot;state<=START;end
     end
     START:if(blank_tick && frame_good)begin
      source_a<=display_slot;source_b<=target_slot;alpha<=0;step<=duration64?4:8;
      if(target_effect>=5)begin render_mode<=target_effect-5;state<=TRANS;end
      else if(target_effect!=0)begin legacy_style<=target_effect-1'b1;state<=OUT;end
      else begin commit_target;state<=RELEASE;end
     end
     TRANS:if(blank_tick && frame_good)begin
      if(alpha+step>=256)begin commit_target;state<=RELEASE;end
      else alpha<=alpha+step;
     end
     OUT:if(blank_tick && frame_good)begin
      if(transition_level==0)begin commit_target;state<=IN;end
      else transition_level<=transition_level-1'b1;
     end
     IN:if(blank_tick && frame_good)begin
      if(transition_level==14)begin transition_level<=15;state<=RELEASE;end
      else transition_level<=transition_level+1'b1;
     end
     RELEASE:if(!cache_ack)state<=IDLE;
     default:state<=IDLE;
    endcase
    if(due && valid_count>1)begin queued<=1;queued_id<=following;end
    if(next_pulse && valid_count>1)begin queued<=1;queued_id<=following;end
    if(select_pulse && {1'b0,select_index}<valid_count)begin queued<=1;queued_id<=select_index;end
   end
  end
 end
endmodule
