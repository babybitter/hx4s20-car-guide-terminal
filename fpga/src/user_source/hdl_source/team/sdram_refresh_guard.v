`timescale 1ns/1ps
// Admission guard for the legally exported Anlogic sdr_as_ram protocol.
// The controller MUST use self_refresh_open=0. No App_en/data/address is gated
// here. read_block goes to clients BEFORE they count acceptance; write_block
// only inhibits the scheduler's next burst admission. An admitted burst drains.
module sdram_refresh_guard #(
 parameter REF_INTERVAL_CYCLES=750, // S44: 15us at 50MHz, not a clock auto-detect
 parameter QUIESCE_LIMIT=512, SERVICE_LIMIT=64,
 parameter QUIET_CYCLES=4, COOLDOWN_CYCLES=6,
 parameter DEBT_BITS=4, CREDIT_BITS=10
)(input clk,rst,
 input vendor_init_done,vendor_ref_vld,vendor_busy,
 input app_rd_en,input [1:0] app_rd_low,input app_wr_en,return_valid,
 input read_lock,writer_busy,
 output app_ref_req,output init_done,output read_block,write_block,
 output reg fault,output reg [3:0] fault_code,
 output [DEBT_BITS-1:0] refresh_debt);
 function integer bits;input integer n;integer v;begin v=n-1;bits=0;while(v>0)begin bits=bits+1;v=v>>1;end if(bits<1)bits=1;end endfunction
 localparam BOOT=0,RUN=1,DRAIN=2,PULSE=3,WAIT_RISE=4,WAIT_FALL=5,COOL=6,FAILED=7;
 localparam TW=bits(REF_INTERVAL_CYCLES), WW=bits(QUIESCE_LIMIT+SERVICE_LIMIT+1);
 reg [2:0] state;
 reg ready,group_open,write_drain;
 reg [1:0] boot_remaining;
 reg [TW-1:0] timer;
 reg [WW-1:0] watchdog;
 reg [bits(QUIET_CYCLES+COOLDOWN_CYCLES+1)-1:0] settle;
 reg [DEBT_BITS-1:0] debt;
 reg [CREDIT_BITS-1:0] credit;
 wire tick=ready && timer==REF_INTERVAL_CYCLES-1;
 wire service_complete=state==WAIT_FALL && !vendor_ref_vld;
 wire retire=service_complete && ready;
 wire finish_group=state==DRAIN && group_open && read_lock;
 wire quiet=!vendor_busy && !vendor_ref_vld && !writer_busy &&
            !app_rd_en && !app_wr_en && !return_valid && credit==0 && !finish_group;
 assign refresh_debt=debt;
 assign init_done=ready && !fault;
 // The scheduler does not consult Sdr_busy between bursts. Prevent a NEW
 // burst while the preceding vendor transaction is still draining; never
 // feed this into the active burst's en/data path.
 assign write_block=state!=RUN || fault || !ready || vendor_ref_vld || vendor_busy;
 assign read_block=(!ready || fault || vendor_ref_vld || write_drain || (state!=RUN && !finish_group));
 // A held request produces consecutive ACK/REF commands. Exactly ONE cycle.
 assign app_ref_req=state==PULSE && !fault;
 task fail;input [3:0] code;begin fault<=1;fault_code<=code;state<=FAILED;end endtask
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=BOOT;ready<=0;group_open<=0;write_drain<=0;boot_remaining<=2;timer<=0;
   watchdog<=0;settle<=0;debt<=0;credit<=0;fault<=0;fault_code<=0;
  end else if(!fault) begin
   if(app_wr_en)write_drain<=1;
   else if(!vendor_busy)write_drain<=0;
   if(ready) begin if(tick)timer<=0;else timer<=timer+1'b1;end
   case({tick,retire})
    2'b10:if(&debt)fail(4'h1);else debt<=debt+1'b1;
    2'b01:if(debt==0)fail(4'h2);else debt<=debt-1'b1;
    default:begin end
   endcase
   case({app_rd_en,return_valid})
    2'b10:if(&credit)fail(4'h3);else credit<=credit+1'b1;
    2'b01:if(credit==0)fail(4'h4);else credit<=credit-1'b1;
    default:begin end
   endcase
   if(app_rd_en)group_open<=app_rd_low!=2'b11;
   else if(!read_lock)group_open<=0; // stopped owner drained/released its lock
   case(state)
    BOOT:if(vendor_init_done && !vendor_ref_vld)begin state<=DRAIN;watchdog<=0;settle<=0;end
    RUN:if(tick || debt!=0)begin state<=DRAIN;watchdog<=0;settle<=0;end
    DRAIN:begin
     watchdog<=watchdog+1'b1;
     if(watchdog==QUIESCE_LIMIT-1)fail(4'h5);
     else if(quiet)begin
      if(settle==QUIET_CYCLES-1)begin state<=PULSE;watchdog<=0;settle<=0;end
      else settle<=settle+1'b1;
     end else settle<=0;
    end
    PULSE:begin state<=WAIT_RISE;watchdog<=0;end
    WAIT_RISE:begin
     watchdog<=watchdog+1'b1;
     if(vendor_ref_vld)begin state<=WAIT_FALL;watchdog<=0;end
     else if(watchdog==SERVICE_LIMIT-1)fail(4'h6);
    end
    WAIT_FALL:begin
     watchdog<=watchdog+1'b1;
     if(!vendor_ref_vld)begin
      if(!ready)boot_remaining<=boot_remaining-1'b1;
      state<=COOL;settle<=0;watchdog<=0;
     end else if(watchdog==SERVICE_LIMIT-1)fail(4'h7);
    end
    COOL:begin
     // The vendor's internal pending bit clears after ref_vld falls. Retain
     // admission blocking through that pipeline, not just the visible fall.
     if(settle==COOLDOWN_CYCLES-1)begin
      settle<=0;
      if(!ready && boot_remaining==0)begin ready<=1;state<=RUN;timer<=0;end
      else if(!ready || debt!=0 || tick)begin state<=DRAIN;watchdog<=0;end
      else state<=RUN;
     end else settle<=settle+1'b1;
    end
    default:state<=FAILED;
   endcase
   // These checks diagnose an integration violation. They never discard an
   // already asserted App_en. Recovery is coordinated controller/client reset.
   if(app_rd_en && app_wr_en)fail(4'h8);
   if(app_rd_en && read_block)fail(4'h9);
   if((app_rd_en || app_wr_en) &&
      (state==PULSE || state==WAIT_RISE || state==WAIT_FALL || state==COOL || !ready))fail(4'ha);
   if(ready && !vendor_init_done)fail(4'hb);
  end
 end
endmodule
