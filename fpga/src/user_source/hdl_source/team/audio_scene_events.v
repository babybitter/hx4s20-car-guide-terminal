// Events reflect applied state or a published transaction, never UART ACK alone.
module audio_scene_events(
 input wire clk,rst,assets_ready,display_ready,page_commit,prompt_open,
 input wire [6:0] page,title,input wire [2:0] cue,
 input wire auto_active,story_active,story_auto,effect_mode,
 input wire [2:0] filter,input wire [1:0] transition,input wire [7:0] story_config,
 input wire [15:0] sequence_version,subtitle_version,
 input wire [3:0] error_code,
 output reg event_valid,output reg [4:0] event_id,output reg [1:0] event_priority,
 input wire [1:0] zoom_mode
);
 reg ready_d,display_d,auto_d,story_d,story_auto_d,mode_d;
 reg [2:0] filter_d;reg [1:0] transition_d;reg [7:0] config_d;
 reg [15:0] seq_d,sub_d;reg [3:0] error_d;
 reg [1:0] zoom_d;
 task emit;
  input [4:0] id;input [1:0] rank;
  begin event_valid<=1;event_id<=id;event_priority<=rank;end
 endtask
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   ready_d<=0;display_d<=0;auto_d<=0;story_d<=0;story_auto_d<=0;mode_d<=0;
   filter_d<=0;transition_d<=0;config_d<=0;seq_d<=0;sub_d<=0;error_d<=0;
   event_valid<=0;event_id<=0;event_priority<=0;zoom_d<=0;
  end else begin
   ready_d<=assets_ready;display_d<=display_ready;auto_d<=auto_active;
   story_d<=story_active;story_auto_d<=story_auto;mode_d<=effect_mode;
   filter_d<=filter;transition_d<=transition;config_d<=story_config;
   seq_d<=sequence_version;sub_d<=subtitle_version;error_d<=error_code;event_valid<=0;zoom_d<=zoom_mode;
   if(assets_ready)begin
    if(prompt_open)emit(page==7?5'd24:5'd25,3);
    else if(!ready_d)emit(0,2);
    else if(display_ready && !display_d)emit(1,2);
    else if(error_code!=0 && error_code!=4'hc && error_code!=error_d)emit(23,2);
    else if(story_active!=story_d)emit(story_active?5'd12:5'd15,2);
    else if(story_active && story_auto!=story_auto_d)emit(story_auto?5'd14:5'd13,2);
    else if(page_commit && cue!=4 && title<8)emit(5'd2+title[4:0],1);
    else if(!story_active && auto_active!=auto_d)emit(auto_active?5'd11:5'd10,0);
    else if(effect_mode!=mode_d)emit(effect_mode?5'd17:5'd16,0);
    else if(zoom_mode!=zoom_d)emit(zoom_mode==2?5'd22:zoom_mode==1?5'd20:5'd21,0);
    else if(filter!=filter_d)emit(18,0);
    else if(transition!=transition_d || story_config[1:0]!=config_d[1:0])emit(19,0);
    else if(sequence_version!=seq_d || subtitle_version!=sub_d)emit(22,0);
   end
  end
 end
endmodule
