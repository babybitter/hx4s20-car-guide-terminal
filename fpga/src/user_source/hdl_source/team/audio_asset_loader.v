// Boot-only audio preload. Reuses the image write FIFO before image loading.
// AUDIO.BIN is a generated, length/CRC-bound 16 kHz G.711 mu-law sample pack.
module audio_asset_loader #(
 parameter integer CLK_HZ=100000000, TIMEOUT_MS=30000,
 parameter [31:0] MAX_BYTES=32'd2097152
)(
 input wire clk,rst,mounted,audio_present,
 input wire [31:0] audio_size,expected_bytes,expected_crc,
 output wire owns_fs,done,loaded,output reg [3:0] fault,
 output wire read_req,input wire read_ready,output wire [31:0] read_length,
 input wire read_done,fs_error,out_valid,out_last,
 output wire out_ready,input wire [7:0] out_data,input wire [31:0] out_offset,
 output wire write_req,input wire write_req_ack,write_fifo_full,write_finish_toggle,
 output reg write_en,output reg [31:0] write_data,
 output wire [20:0] write_words,output wire writer_abort,
 output wire [3:0] progress
);
 localparam [3:0] IDLE=0,ACK=1,CLEAR=2,REQUEST=3,STREAM=4,DRAIN=5,
                  ABORTING=6,RECOVER=7,FINISHED=8;
 localparam integer MS_DIV=CLK_HZ/1000;
 localparam integer TICK_W=MS_DIV<2?1:$clog2(MS_DIV);
 reg [3:0] state; reg [TICK_W-1:0] ticks;reg [14:0] elapsed_ms;
 reg [31:0] received,crc;reg [23:0] pack;
 // Only the first stage consumes the asynchronous MEM-domain toggle.
 // The request/ack handshake permits one outstanding writer transaction.
 (* preserve *) reg finish_meta,finish_sync;
 always @(posedge clk or posedge rst) begin
  if(rst)begin finish_meta<=0;finish_sync<=0;end
  else begin finish_meta<=write_finish_toggle;finish_sync<=finish_meta;end
 end
 reg finish_at_start,finish_seen,source_done,pack_good;
 reg [4:0] settle;
 wire ms_tick=ticks==MS_DIV-1;
 wire working=state!=IDLE && state!=FINISHED;
 wire accepted=out_valid && out_ready;
 wire last_expected=received==expected_bytes-1'b1;
 function [31:0] crc_byte;
  input [31:0] prior;input [7:0] data;reg [31:0] c;integer i;
  begin c=prior^{24'd0,data};for(i=0;i<8;i=i+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
 endfunction
 assign owns_fs=state!=FINISHED;
 assign done=state==FINISHED;
 assign loaded=done && fault==0 && pack_good;
 assign read_req=state==REQUEST;
 assign read_length=expected_bytes;
 assign out_ready=state==STREAM && !write_fifo_full && received<expected_bytes;
 assign write_req=state==ACK;
 assign write_words=expected_bytes[22:2];
 assign writer_abort=state==ABORTING;
 assign progress=state;
 task abort_audio;input [3:0] reason;begin fault<=reason;state<=ABORTING;settle<=0;pack_good<=0;end endtask
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=IDLE;ticks<=0;elapsed_ms<=0;fault<=0;received<=0;crc<=32'hffffffff;pack<=0;
   finish_at_start<=0;finish_seen<=0;source_done<=0;pack_good<=0;settle<=0;write_en<=0;write_data<=0;
  end else begin
   write_en<=0;
   if(working)begin
    if(ms_tick)begin ticks<=0;if(elapsed_ms<TIMEOUT_MS)elapsed_ms<=elapsed_ms+1'b1;end
    else ticks<=ticks+1'b1;
   end else begin ticks<=0;elapsed_ms<=0;end
   if((state==REQUEST || state==STREAM || state==DRAIN) &&
      finish_sync!=finish_at_start)finish_seen<=1;
   if(working && state!=ABORTING && state!=RECOVER && elapsed_ms>=TIMEOUT_MS)abort_audio(4'd5);
   else case(state)
    IDLE:if(mounted)begin
     if(!audio_present)begin fault<=1;state<=FINISHED;end
     else if(expected_bytes==0 || expected_bytes>MAX_BYTES || expected_bytes[8:0]!=0 || audio_size!=expected_bytes)begin
      fault<=2;state<=FINISHED;
     end else begin state<=ACK;end
    end
    ACK:if(write_req_ack)state<=CLEAR;
    CLEAR:if(!write_req_ack && !write_fifo_full)begin
     // ACK has returned low and FIFO clear has completed. A stale/reset
     // toggle has settled before this point; no payload can have been sent.
     // Arm here, not in IDLE before the synchronizer has acquired its level.
     finish_at_start<=finish_sync;finish_seen<=0;state<=REQUEST;
    end
    REQUEST:if(read_ready)begin state<=STREAM;received<=0;crc<=32'hffffffff;end
    STREAM:begin
     if(fs_error)abort_audio(4'd4);
     else begin
      if(accepted)begin
       if(out_offset!=received || out_last!=last_expected)abort_audio(4'd6);
       else begin
        received<=received+1'b1;crc<=crc_byte(crc,out_data);
        // Little-endian byte order in each SDRAM word, independent of BMP BGR.
        case(received[1:0])
         0:pack[7:0]<=out_data;
         1:pack[15:8]<=out_data;
         2:pack[23:16]<=out_data;
         3:begin write_data<={out_data,pack};write_en<=1;end
        endcase
        if(last_expected)begin pack_good<=(~crc_byte(crc,out_data))==expected_crc;state<=DRAIN;end
       end
      end
      if(read_done)begin
       source_done<=1;
       if(!(accepted && last_expected))abort_audio(4'd6);
      end
     end
    end
    DRAIN:begin
     if(fs_error)abort_audio(4'd4);
     else begin
      if(read_done)source_done<=1;
      if(source_done && (finish_seen || finish_sync!=finish_at_start))begin
       if(!pack_good)fault<=3;
       state<=FINISHED;
      end
     end
    end
    ABORTING:begin
     // 16 source clocks cover the two-stage MEM reset mailbox; hold producer idle.
     if(settle==15)begin state<=RECOVER;settle<=0;end else settle<=settle+1'b1;
    end
    RECOVER:begin
     // A cancelled stream must return to IDLE before its data may be routed to
     // the BMP loader. With ready held low, the FAT reader's own watchdog drains
     // or terminates the transaction. A lost mount remains a card-level error.
     if(settle==15)begin if(!mounted || (read_ready && !out_valid))state<=FINISHED;end
     else settle<=settle+1'b1;
    end
    default:begin end
   endcase
  end
 end
endmodule
