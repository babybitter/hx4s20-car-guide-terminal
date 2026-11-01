// Two read clients share the official untagged SDRAM return stream.
// Ownership only changes after a client's lock AND controller busy have cleared.
// Video always keeps an in-flight line; audio starts in vertical blank only.
module audio_memory_arbiter(
 input wire mem_clk,rst,init_done,refresh_block,controller_busy,
 input wire vertical_blank_pixel,writer_busy,writer_en,
 input wire video_lock,video_en,input wire [20:0] video_addr,
 input wire audio_demand,audio_lock,audio_en,input wire [20:0] audio_addr,
 output wire video_grant,audio_grant,read_lock,
 input wire return_valid,output wire video_return,audio_return,
 output wire app_en,output wire [20:0] app_addr
);
 reg [2:0] blank_sync;reg audio_owner,seen_lock;
 always @(posedge mem_clk or posedge rst)begin
  if(rst)begin blank_sync<=0;audio_owner<=0;seen_lock<=0;end
  else begin
   blank_sync<={blank_sync[1:0],vertical_blank_pixel};
   if(!audio_owner)begin
    if(audio_demand && blank_sync[2] && init_done && !refresh_block &&
      !video_lock && !video_en && !writer_busy && !writer_en && !controller_busy)begin audio_owner<=1;seen_lock<=audio_lock;end
   end else begin
    if(audio_lock)seen_lock<=1;
    // A request cancelled before its first lock has accepted no words. Allow
    // that empty reservation to retire too; an active client must retain lock
    // for all outstanding credits, including a stop/preemption drain.
    if((seen_lock || !audio_demand) && !audio_lock && !audio_en && !controller_busy && !return_valid)audio_owner<=0;
   end
  end
 end
 assign video_grant=!audio_owner && !writer_busy && !writer_en;
 assign audio_grant=audio_owner && !writer_busy && !writer_en;
 assign read_lock=video_lock || audio_owner;
 assign app_en=audio_owner?audio_en:video_en;
 assign app_addr=audio_owner?audio_addr:video_addr;
 assign video_return=return_valid && !audio_owner;
 assign audio_return=return_valid && audio_owner;
endmodule
