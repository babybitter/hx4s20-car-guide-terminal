// Four-phase bundled-data mailbox. Pixel holds ID/display slot until ack drops.
// No background eviction: protection is updated before forwarding each request.
module catalog_mailbox (
 input wire pixel_clk,pixel_rst,sd_clk,sd_rst,
 input wire request_pixel,input wire [6:0] id_pixel,
 input wire display_valid_pixel,input wire [1:0] display_slot_pixel,
 output wire ack_pixel,error_pixel,output wire [1:0] slot_pixel,
 output reg request_sd,output reg [6:0] id_sd,
 input wire ack_sd,done_sd,error_sd,input wire [1:0] result_slot_sd,
 output reg protect_display,output reg [1:0] display_slot_sd,
 output reg protect_target,output reg [1:0] target_slot_sd
);
 reg [2:0] request_sync,ack_sync;
 reg response,failed;reg [1:0] result,state;
 localparam IDLE=0,SETUP=1,WAIT_RESULT=2,RELEASE=3;
 assign ack_pixel=ack_sync[2];
 assign error_pixel=ack_pixel && failed;
 assign slot_pixel=result;
 always @(posedge pixel_clk or posedge pixel_rst)begin
  if(pixel_rst)ack_sync<=0;else ack_sync<={ack_sync[1:0],response};
 end
 always @(posedge sd_clk or posedge sd_rst)begin
  if(sd_rst)begin
   request_sync<=0;response<=0;failed<=0;result<=0;state<=IDLE;
   request_sd<=0;id_sd<=0;protect_display<=0;display_slot_sd<=0;protect_target<=0;target_slot_sd<=0;
  end else begin
   request_sync<={request_sync[1:0],request_pixel};
   case(state)
    IDLE:if(request_sync[2])begin
     id_sd<=id_pixel;display_slot_sd<=display_slot_pixel;protect_display<=display_valid_pixel;
     protect_target<=0;failed<=0;state<=SETUP;
    end
    SETUP:begin request_sd<=1;state<=WAIT_RESULT;end
    WAIT_RESULT:begin
     if(!response && (ack_sd || (done_sd && error_sd)))begin
      result<=result_slot_sd;failed<=!ack_sd;response<=1;
      if(ack_sd)begin protect_target<=1;target_slot_sd<=result_slot_sd;end
     end
     if(response && !request_sync[2])begin request_sd<=0;response<=0;state<=RELEASE;end
    end
    RELEASE:if(!ack_sd && !request_sync[2])state<=IDLE;
   endcase
  end
 end
endmodule
