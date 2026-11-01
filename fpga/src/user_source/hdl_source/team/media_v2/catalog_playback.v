// Logical page IDs (0..127) are independent of the four physical SDRAM slots.
// A cache miss retains the current picture until the complete target is valid.
module catalog_playback #(parameter integer CLK_HZ=25000000)(
 input wire clk,rst,media_ready,fault,
 input wire [7:0] valid_count,
 input wire next_pulse,auto_pulse,select_pulse,input wire [6:0] select_index,
 input wire [1:0] period_sel,
 input wire period_changed,prompt_active,frame_boundary,blank_tick,page_ready,effects_enabled,
 output reg auto_enabled,page_req,
 output reg [1:0] page_target,display_slot,
 output reg [6:0] display_page,
 output reg page_commit,output reg [15:0] event_seq,output reg [3:0] transition_level,
 output reg cache_req,output reg [6:0] cache_id,
 input wire cache_ack,cache_error,input wire [1:0] cache_slot
);
 localparam IDLE=0,LOAD=1,OUT=2,WAIT_ACK=3,READY=4,IN=5,RELEASE=6;
 reg [2:0] state;
 reg [31:0] div_count;reg [15:0] elapsed;
 reg queued,ack_d,do_effect;reg [6:0] queued_id,target_id;
 wire tick=div_count==CLK_HZ/1000-1;
 wire [15:0] period_ms=period_sel==0?2000:period_sel==1?5000:period_sel==2?10000:15000;
 wire due=auto_enabled && tick && elapsed==period_ms-1 && !prompt_active &&
          !auto_pulse && !period_changed && state==IDLE;
 wire [6:0] basis=state==IDLE?display_page:target_id;
 wire [6:0] following=({1'b0,basis}+8'd1>=valid_count)?7'd0:basis+1'b1;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;div_count<=0;elapsed<=0;queued<=0;queued_id<=0;target_id<=0;ack_d<=0;do_effect<=0;
   auto_enabled<=0;page_req<=0;page_target<=0;display_slot<=0;display_page<=0;
   page_commit<=0;event_seq<=0;transition_level<=15;cache_req<=0;cache_id<=0;
  end else begin
   page_commit<=0;ack_d<=page_ready;div_count<=tick?0:div_count+1'b1;
   if(!media_ready)begin
    state<=IDLE;page_req<=0;cache_req<=0;queued<=0;auto_enabled<=0;elapsed<=0;transition_level<=15;
   end else if(fault)begin
    // The protected display slot is retained. Recovery is by full KEY1 reset.
    page_req<=0;cache_req<=0;queued<=0;auto_enabled<=0;state<=RELEASE;transition_level<=15;
   end else begin
    if(auto_pulse)begin auto_enabled<=!auto_enabled;elapsed<=0;end
    else if(period_changed || prompt_active || state!=IDLE)elapsed<=0;
    else if(auto_enabled && tick)elapsed<=due?0:elapsed+1'b1;
    case(state)
     IDLE:if(queued && !cache_ack)begin
      queued<=0;
      if(queued_id!=display_page && {1'b0,queued_id}<valid_count)begin
       target_id<=queued_id;cache_id<=queued_id;cache_req<=1;state<=LOAD;
      end
     end
     LOAD:if(cache_ack)begin
      if(cache_error)begin cache_req<=0;state<=RELEASE;end
      else begin
       page_target<=cache_slot;do_effect<=effects_enabled;
       if(effects_enabled)state<=OUT;
       else begin page_req<=1;state<=WAIT_ACK;end
      end
     end
     OUT:if(blank_tick)begin
      if(transition_level!=0)transition_level<=transition_level-1'b1;
      else begin page_req<=1;state<=WAIT_ACK;end
     end
     WAIT_ACK:if(page_ready && !ack_d)begin page_req<=0;state<=READY;end
     READY:if(frame_boundary)begin
      display_slot<=page_target;display_page<=target_id;page_commit<=1;event_seq<=event_seq+1'b1;
      elapsed<=0;cache_req<=0;state<=do_effect?IN:RELEASE;
     end
     IN:if(blank_tick)begin
      if(transition_level==14)begin transition_level<=15;state<=RELEASE;end
      else transition_level<=transition_level+1'b1;
     end
     RELEASE:if(!cache_ack)state<=IDLE;
     default:begin state<=IDLE;page_req<=0;cache_req<=0;transition_level<=15;end
    endcase
    if(due && valid_count>1)begin queued<=1;queued_id<=following;end
    if(next_pulse && valid_count>1)begin queued<=1;queued_id<=following;end
    if(select_pulse && {1'b0,select_index}<valid_count)begin queued<=1;queued_id<=select_index;end
   end
  end
 end
endmodule
