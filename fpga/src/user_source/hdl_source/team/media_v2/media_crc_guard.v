// IEEE CRC32 over BGR pixel bytes. Completion is deliberately registered:
// source_done edge N captures the final accepted byte; N+1 checks registered
// CRC/count; N+2 publishes guarded_done. Never bypass the CRC register with take.
module media_crc_guard (
 input wire clk,rst,read_req,read_ready,input wire [6:0] read_id,
 input wire [31:0] read_offset,read_length,
 input wire data_valid,data_ready,input wire [7:0] data,
 input wire source_done,source_error,
 output reg guarded_done,output wire guarded_error,output wire [31:0] actual_crc,
 output wire crc_failed
);
 localparam [1:0] IDLE=0,RECEIVE=1,CHECK=2,PUBLISH=3;
 reg [1:0] state;
 reg active,failed_latch,source_fault,request_overlap;
 reg [31:0] crc;reg [19:0] count;reg [6:0] id;
 // Private receive enable is true exactly in an active pixel RECEIVE phase.
 // It is set on request acceptance, so the very first RECEIVE edge can take.
 reg pixel_receive;
 reg count_exact,count_saturated;
 wire accept_request=(state==IDLE) && read_req && read_ready;
 wire pixel_take=pixel_receive && data_valid && data_ready;
 wire expected_valid;wire [31:0] expected_crc;
 // The request ID is latched before RECEIVE. Pipeline the ROM result during
 // RECEIVE so CHECK sees the correct descriptor even when source_done arrives
 // on its first RECEIVE edge. Completion latency and cancellation are unchanged.
 reg expected_valid_q;reg [31:0] expected_crc_q;
 function [31:0] update_crc;
  input [31:0] c0;input [7:0] v;integer i;reg [31:0] c;
  begin c=c0^{24'd0,v};for(i=0;i<8;i=i+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;update_crc=c;end
 endfunction
 // Diagnostic CRC contains only bytes accepted at earlier clock edges. The
 // comparison below therefore has NO combinational dependency on FIFO ready.
 assign actual_crc=~crc;
 assign crc_failed=failed_latch;
 // Preserve raw source-error passthrough and retain transient source errors
 // until the delayed completion. Source faults must not masquerade as CRC faults.
 assign guarded_error=source_error || source_fault || failed_latch;
 assets_expected_crc u_expected(.id(id),.valid(expected_valid),.crc(expected_crc));
 always @(posedge clk)begin
  expected_valid_q<=expected_valid;expected_crc_q<=expected_crc;
 end
 // Keep payload storage controls local; descriptor length decode only feeds
 // pixel_receive/active, never the CRC/count clear or data-update mux.
 always @(posedge clk or posedge rst)begin
  if(rst)pixel_receive<=0;
  else if(accept_request)pixel_receive<=read_offset==54 && read_length==921600;
  else if(source_done)pixel_receive<=0;
 end
 always @(posedge clk or posedge rst)begin
  if(rst)crc<=32'hffffffff;
  else if(accept_request)crc<=32'hffffffff;
  else if(pixel_take)crc<=update_crc(crc,data);
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin count<=0;count_exact<=0;count_saturated<=0;end
  else if(accept_request)begin count<=0;count_exact<=0;count_saturated<=0;end
  else if(pixel_take && !count_saturated)begin
   count<=count+1'b1;
   // Predicates describe the count AFTER this accepted byte. In particular,
   // the final byte/done coincidence updates count_exact before CHECK.
   count_exact<=count==20'd921599;
   count_saturated<=count==20'd921600;
  end
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;active<=0;id<=0;
   failed_latch<=0;source_fault<=0;request_overlap<=0;guarded_done<=0;
  end
  else begin
   guarded_done<=0;
   if(state!=IDLE)begin
    if(source_error)source_fault<=1;
    if(read_req && read_ready)request_overlap<=1;
   end
   case(state)
    IDLE:if(read_req && read_ready)begin
     state<=RECEIVE;active<=read_offset==54 && read_length==921600;
     id<=read_id;
     failed_latch<=0;source_fault<=0;request_overlap<=0;
    end
    RECEIVE:begin
     if(source_done)state<=CHECK;
    end
    CHECK:begin
     // The last-byte/done coincidence was fully captured in RECEIVE. Header
     // reads bypass CRC/length policy, but retain source-error completion.
     failed_latch<=request_overlap || (read_req && read_ready) ||
       (active && !source_fault && !source_error &&
        (!expected_valid_q || actual_crc!=expected_crc_q || !count_exact));
     state<=PUBLISH;
    end
    PUBLISH:begin
     // An illegal overlapping request cannot replace the pending descriptor or
     // turn its reply into success. Normal cache clients wait for guarded_done.
     if(read_req && read_ready)failed_latch<=1;
     guarded_done<=1;state<=IDLE;active<=0;
    end
    default:begin state<=IDLE;failed_latch<=1;end
   endcase
  end
 end
endmodule
