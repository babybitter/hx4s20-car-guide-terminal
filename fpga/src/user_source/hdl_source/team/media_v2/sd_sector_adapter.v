// Read-only SDHC/SDXC SPI adapter; no write command or data path exists.
// Reuses the unchanged official spi_master. See docs/sd-sector-contract.md.
module sd_sector_adapter #(
 parameter integer INIT_TIMEOUT=500000000, SECTOR_TIMEOUT=10000000
)(
 input wire clk,rst,
 input wire sector_req, output wire sector_ready,
 input wire [31:0] sector_lba,
 output wire sector_byte_valid,output wire [7:0] sector_byte,
 output wire sector_done,sector_error,
 output wire initialized,output wire [31:0] card_sector_count,
 output wire [7:0] fault_code,
 output wire SD_nCS,SD_DCLK,SD_MOSI,input wire SD_MISO
);
 wire req,ack,cs;wire [7:0] tx,rx;wire [15:0] divider;
 sd_spi_byte_reader #(.INIT_TIMEOUT(INIT_TIMEOUT),.SECTOR_TIMEOUT(SECTOR_TIMEOUT)) u_reader (
  .clk(clk),.rst(rst),.sector_req(sector_req),.sector_ready(sector_ready),.sector_lba(sector_lba),
  .sector_byte_valid(sector_byte_valid),.sector_byte(sector_byte),.sector_done(sector_done),.sector_error(sector_error),
  .initialized(initialized),.card_sector_count(card_sector_count),.fault_code(fault_code),
  .byte_req(req),.byte_ack(ack),.byte_tx(tx),.byte_rx(rx),.spi_cs(cs),.spi_div(divider));
 spi_master u_spi(.sys_clk(clk),.rst(rst),.nCS(SD_nCS),.DCLK(SD_DCLK),.MOSI(SD_MOSI),.MISO(SD_MISO),
  .CPOL(1'b1),.CPHA(1'b1),.nCS_ctrl(cs),.clk_div(divider),.wr_req(req),.wr_ack(ack),.data_in(tx),.data_out(rx));
endmodule

module sd_spi_byte_reader #(
 parameter integer INIT_TIMEOUT=500000000, SECTOR_TIMEOUT=10000000,
 parameter integer POWERUP_CYCLES=100000, MAX_RETRIES=2
)(
 input wire clk,rst,
 input wire sector_req,output wire sector_ready,input wire [31:0] sector_lba,
 output reg sector_byte_valid,output reg [7:0] sector_byte,
 output reg sector_done,sector_error,
 output reg initialized,output reg [31:0] card_sector_count,
 output reg [7:0] fault_code,
 output wire byte_req,input wire byte_ack,output reg [7:0] byte_tx,input wire [7:0] byte_rx,
 output wire spi_cs,output wire [15:0] spi_div
);
 localparam POWER=0,CLOCKS=1,PRE=2,CMD=3,R1=4,TAIL=5,TOKEN=6,DATA=7,
            CRC_HI=8,CRC_LO=9,IDLE=10,DRAIN=11,FINISH=12,FAILED=13,RETRY=14,REQUEST=15;
 reg [3:0] state;
 reg [5:0] command;
 // Decode the fixed command kind at launch, before the command bytes and R1.
 // Keep the original six-bit number for the wire protocol. R1/error handling
 // consumes one-hot bits instead of decoding command through the retry CE.
 reg [6:0] command_kind;
 reg r1_allow_zero,r1_allow_one;
 reg [7:0] r1_error_code;
 localparam integer TIMER_LIMIT=(INIT_TIMEOUT>SECTOR_TIMEOUT) ?
          ((INIT_TIMEOUT>POWERUP_CYCLES)?INIT_TIMEOUT:POWERUP_CYCLES) :
          ((SECTOR_TIMEOUT>POWERUP_CYCLES)?SECTOR_TIMEOUT:POWERUP_CYCLES);
 localparam integer TIMER_BITS=(TIMER_LIMIT<2)?1:$clog2(TIMER_LIMIT+2);
 reg [31:0] argument,saved_lba;
 reg range_bad;
 reg [TIMER_BITS-1:0] timer;
 reg [7:0] command_crc;
 reg [9:0] count;
 reg count3,count5,count11,count15,count511;
 reg [1:0] gap,retries;
 reg [31:0] tail;
 reg [127:0] csd;
 reg [15:0] crc;
 reg hi_crc_matches;
 reg finish_error;
 reg init_expired,sector_expired;
 // One synchronous 512-byte RAM; no reset on RAM or its read register.
 (* ram_style = "block" *) reg [7:0] buffer [0:511];
 reg [7:0] buffer_q;
 // CRC_LO primes byte zero on the edge entering DRAIN. Each DRAIN edge
 // publishes the preceding read and prefetches the next byte, preserving
 // the original 512 consecutive valid clocks and completion timing.
 wire [8:0] buffer_read_addr=state==DRAIN ? count[8:0]+9'd1 : 9'd0;
 wire [32:0] capacity_wide=({11'd0,csd[69:48]}+33'd1)<<10;
 wire transfer_state=state==CLOCKS || state==PRE || state==CMD || state==R1 ||
                     state==TAIL || state==TOKEN || state==DATA || state==CRC_HI || state==CRC_LO;
 // Once a block passed CRC, publishing its buffered 512 bytes is atomic.
 // A transfer deadline may abort/retry only before any byte is released.
 // FINISH is excluded too: do not suppress the sole completion after byte511.
 wire sector_timeout_eligible=initialized && state!=IDLE && state!=FAILED &&
                              state!=DRAIN && state!=FINISH && state!=RETRY;
 assign byte_req=transfer_state && gap==0;
 assign spi_cs=state==POWER || state==CLOCKS || state==PRE || state==IDLE ||
               state==DRAIN || state==FINISH || state==FAILED || state==RETRY || state==REQUEST;
 assign spi_div=initialized ? 16'd0 : 16'd248;
 assign sector_ready=state==IDLE;
 function [15:0] crc16;
  input [15:0] initial_crc;input [7:0] data;
  reg [15:0] c;integer i;
  begin
   c=initial_crc ^ {data,8'd0};
   for(i=0;i<8;i=i+1)c=c[15]?(c<<1)^16'h1021:c<<1;
   crc16=c;
  end
 endfunction
 task start_cmd;
  input [5:0] number;input [31:0] arg;input [7:0] check;
  begin
   command<=number;argument<=arg;command_crc<=check;count<=0;state<=PRE;
   case(number)
    0:command_kind<=7'b0000001;
    8:command_kind<=7'b0000010;
    55:command_kind<=7'b0000100;
    41:command_kind<=7'b0001000;
    58:command_kind<=7'b0010000;
    9:command_kind<=7'b0100000;
    17:command_kind<=7'b1000000;
    default:command_kind<=0;
   endcase
   // R1 accepts only 00/01 for the supported commands. Register their policy
   // and error code here so all response failures share one short decision,
   // independent of the success-command branch and retry counter update.
   r1_allow_zero<=number==55 || number==41 || number==58 || number==9 || number==17;
   r1_allow_one<=number==0 || number==8 || number==55 || number==41;
   case(number)
    0:r1_error_code<=8'h22;8:r1_error_code<=8'h23;55:r1_error_code<=8'h24;
    41:r1_error_code<=8'h25;58:r1_error_code<=8'h26;
    9,17:r1_error_code<=8'h27;default:r1_error_code<=8'h28;
   endcase
  end
 endtask
 task fail;
  input [7:0] code;
  begin
   if(initialized && retries<MAX_RETRIES) begin
    // Separate the error/timeout decoder from the wide command argument CE.
    // RETRY keeps CS high and launches the saved request on the next edge.
    state<=RETRY;
   end else begin
    fault_code<=code;state<=FAILED;
    if(initialized) begin sector_done<=1;sector_error<=1;end
   end
  end
 endtask
 always @* begin
  byte_tx=8'hff;
  if(state==CMD)case(count)
   0:byte_tx={2'b01,command};1:byte_tx=argument[31:24];2:byte_tx=argument[23:16];
   3:byte_tx=argument[15:8];4:byte_tx=argument[7:0];5:byte_tx=command_crc;
   default:byte_tx=8'hff;
  endcase
 end
 // Payload registers may capture a byte on the edge which aborts a transfer.
 // Such a byte is discarded: no buffer is published before CRC success, and
 // TOKEN/TAIL reinitializes the accumulator before a new attempt. Keeping
 // these local enables independent of timeout/error decoding cuts a wide
 // control path without changing any observable byte/done transaction.
 always @(posedge clk or posedge rst) begin
  if(rst)begin tail<=0;csd<=0;crc<=0;hi_crc_matches<=0;end
  else if(byte_ack && gap==0)begin
   if(state==R1 && command_kind[1] && byte_rx==1)tail<=0;
   if(state==R1 && command_kind[4] && byte_rx==0)tail<=0;
   if(state==TAIL)tail<={tail[23:0],byte_rx};
   if(state==TOKEN && byte_rx==8'hfe)begin csd<=0;crc<=0;end
   if(state==DATA)begin
    crc<=crc16(crc,byte_rx);
    if(command_kind[5])csd<={csd[119:0],byte_rx};
   end
   // DATA has finished updating crc before CRC_HI is accepted. The CRC
   // accumulator stays stable through both check bytes, so compare its high
   // half here instead of feeding a full 16-bit comparison into CRC_LO's CE.
   // Every CRC_LO is preceded by this handshake, including CMD9 and retries.
   if(state==CRC_HI)hi_crc_matches<=byte_rx==crc[15:8];
  end
 end
 always @(posedge clk)begin
  buffer_q<=buffer[buffer_read_addr];
  if(byte_ack && gap==0 && state==DATA && !command_kind[5])
   buffer[count[8:0]]<=byte_rx;
 end
 always @(posedge clk or posedge rst)begin
  if(rst)timer<=0;
  else if(state==IDLE)timer<=0;
  // Original fail edge cleared timer, then RETRY advanced it once. Preserve
  // that exact command-attempt age while removing the fail decoder from CE.
  else if(state==RETRY)timer<=1;
  else if(state!=FAILED && !(&timer))timer<=timer+1'b1;
 end
 // These flags are consumed only at SPI byte acceptance. Every acceptance
 // inserts two gap clocks, so the flags catch up after count changes before
 // another byte can be accepted. DRAIN advances every clock and deliberately
 // keeps its direct count comparison instead of using these delayed flags.
 always @(posedge clk or posedge rst)begin
  if(rst)begin count3<=0;count5<=0;count11<=0;count15<=0;count511<=0;end
  else begin
   count3<=count==3;count5<=count==5;count11<=count==11;
   count15<=count==15;count511<=count==511;
  end
 end
 always @(posedge clk or posedge rst) begin
  if(rst)begin
   state<=POWER;command<=0;command_kind<=7'b0000001;argument<=0;command_crc<=8'h95;saved_lba<=0;
   r1_allow_zero<=0;r1_allow_one<=1;r1_error_code<=8'h22;
   count<=0;gap<=0;retries<=0;range_bad<=0;
   initialized<=0;card_sector_count<=0;fault_code<=0;finish_error<=0;
   init_expired<=0;sector_expired<=0;
   sector_byte_valid<=0;sector_byte<=0;sector_done<=0;sector_error<=0;
  end else begin
   sector_byte_valid<=0;sector_done<=0;sector_error<=0;
   if(gap!=0)gap<=gap-1'b1;
   if(byte_ack && byte_req)gap<=2;
   // Threshold comparison has its own register. The declared timeout may be
   // exceeded by at most one SD clock (10 ns), not another SPI transaction.
   // Retry/idle explicitly clear both flags so a previous attempt cannot
   // immediately time out a newly accepted request.
   if(state==IDLE || state==FAILED || state==RETRY)begin
    init_expired<=0;sector_expired<=0;
   end else begin
    init_expired<=!initialized && timer>=INIT_TIMEOUT-1;
    sector_expired<=sector_timeout_eligible && timer>=SECTOR_TIMEOUT-1;
   end
   if(state!=FAILED && ((!initialized && init_expired) ||
      (sector_timeout_eligible && sector_expired)))fail(8'h21);
   else case(state)
    POWER:if(timer>=POWERUP_CYCLES-1)begin state<=CLOCKS;count<=0;end
    // In these case arms transfer_state is already true. Use the local gap
    // enable; feeding the public multi-state byte_req decoder back into this
    // control cone needlessly lengthens the command/failure path.
    CLOCKS:if(byte_ack && gap==0)begin
     if(count11)start_cmd(0,0,8'h95);else count<=count+1'b1;
    end
    PRE:if(byte_ack && gap==0)begin state<=CMD;count<=0;end
    CMD:if(byte_ack && gap==0)begin
     if(count5)begin state<=R1;count<=0;end else count<=count+1'b1;
    end
    R1:if(byte_ack && gap==0)begin
     if(!byte_rx[7])begin
      if(!((byte_rx==0 && r1_allow_zero) || (byte_rx==1 && r1_allow_one)))fail(r1_error_code);
      else if(command_kind[0])start_cmd(8,32'h1aa,8'h87);
      else if(command_kind[1] || command_kind[4])begin state<=TAIL;count<=0;end
      else if(command_kind[2])start_cmd(41,32'h40000000,8'hff);
      else if(command_kind[3])begin
       if(byte_rx==0)start_cmd(58,0,8'hff);else start_cmd(55,0,8'hff);
      end else begin state<=TOKEN;count<=0;end // CMD9 or CMD17 by launch policy.
     end
     else if(count15)fail(8'h29);else count<=count+1'b1;
    end
    TAIL:if(byte_ack && gap==0)begin
     if(count3)begin
      if(command_kind[1])begin
       if({tail[23:0],byte_rx}==32'h000001aa)start_cmd(55,0,8'hff);else fail(8'h2a);
      end else begin
       // Only block-addressed, powered-up SDHC/SDXC. SDSC is explicitly rejected.
       if(tail[23:22]==2'b11)start_cmd(9,0,8'hff);else fail(8'h2b);
      end
     end else count<=count+1'b1;
    end
    TOKEN:if(byte_ack && gap==0)begin
     if(byte_rx==8'hfe)begin state<=DATA;count<=0;end
     else if(byte_rx!=8'hff)fail(8'h2c);
    end
    DATA:if(byte_ack && gap==0)begin
     if(command_kind[5]?count15:count511)state<=CRC_HI;else count<=count+1'b1;
    end
    CRC_HI:if(byte_ack && gap==0)state<=CRC_LO;
    CRC_LO:if(byte_ack && gap==0)begin
     if(!hi_crc_matches || byte_rx!=crc[7:0])fail(8'h2d);
     else if(command_kind[5])begin
      if(csd[127:126]!=1 || csd[83:80]!=9 || capacity_wide[32] || capacity_wide==0)fail(8'h2e);
      else begin initialized<=1;card_sector_count<=capacity_wide[31:0];state<=IDLE;end
     end else begin count<=0;state<=DRAIN;finish_error<=0;end
    end
    IDLE:begin
     retries<=0;
     if(sector_req)begin
      // Accept once at ready, then separate the 32-bit capacity comparison
      // from command/state enables. The requester may withdraw or change LBA
      // after this edge. REQUEST consumes only the captured request one clock
      // later; it issues no SPI byte and does not restart the request deadline.
      saved_lba<=sector_lba;range_bad<=sector_lba>=card_sector_count;state<=REQUEST;
     end
    end
    REQUEST:begin
     if(range_bad)begin finish_error<=1;fault_code<=8'h2f;state<=FINISH;end
     else start_cmd(17,saved_lba,8'hff);
    end
    DRAIN:begin
     sector_byte_valid<=1;sector_byte<=buffer_q;
     if(count==511)state<=FINISH;else count<=count+1'b1;
    end
    FINISH:begin sector_done<=1;sector_error<=finish_error;state<=IDLE;end
    // No byte handshake or deadline is consumed in RETRY, so advancing the
    // counter here preserves the visible transaction and retry limit.
    RETRY:begin retries<=retries+1'b1;start_cmd(17,saved_lba,8'hff);end
    FAILED:begin end
    default:fail(8'h30);
   endcase
  end
 end
endmodule
