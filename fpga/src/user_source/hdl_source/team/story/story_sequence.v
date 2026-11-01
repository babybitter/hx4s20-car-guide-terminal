// Sixteen-entry, double-buffered recipe store. Upload ACKs are only transport
// acknowledgements; status version changes only after a validated blank commit.
module story_sequence #(parameter integer CLK_HZ=25000000,DEFAULT_DWELL_MS=5000)(
 input wire clk,rst,blank_tick,media_ready,prompt_active,input wire [7:0] valid_count,
 input wire begin_upload,write_entry,commit_upload,
 input wire [3:0] upload_index,input wire [39:0] upload_word,input wire [4:0] upload_count,
 input wire command_valid,input wire [7:0] command,value,
 input wire manual_select,auto_toggle,
 input wire scene_accept,page_commit,
 output wire scene_valid,output reg [39:0] scene_word,
 output reg active,output reg auto_enabled,output wire [31:0] status
);
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
 reg [39:0] recipe[0:31];integer i;
 function [39:0] initial_word;
  input integer n;
  reg [39:0] w;
  begin
   w=0;w[6:0]=n;w[13:7]=n;w[29:14]=DEFAULT_DWELL_MS;
   w[32:30]=(n%3)+5;w[35:33]=n%4;w[36]=(n==7);initial_word=w;
  end
 endfunction
 initial begin for(i=0;i<32;i=i+1)recipe[i]=initial_word(i%8);end
 reg bank,upload_open,publish_pending;
 reg [15:0] valid_entries,version;
 reg [4:0] count,pending_count;
 reg [7:0] error;
 reg boot_busy;reg [2:0] boot_index;
 reg [3:0] index;
 // S27: physical addrb[5] is RTL index[1], despite packed launch name [2].
 wire recipe_index1_hold;
 EG_LOGIC_BUF hold_recipe_index1(.i(index[1]),.o(recipe_index1_hold));
 reg request_pending,waiting;reg [1:0] settle;
 reg [COUNTER_WIDTH-1:0] divider;reg [15:0] elapsed,dwell;
 wire ms_tick=divider==CLK_HZ/1000-1;
 wire [15:0] needed=upload_count==16?16'hffff:(16'hffff>>(16-upload_count));
 assign scene_valid=active && auto_enabled && media_ready && request_pending && settle==0 && !boot_busy &&
                    !publish_pending && !manual_select && !prompt_active;
 // [31:16] version,[15:8] error,[7:3] count,[2] bank,[1] upload,[0] active.
 assign status={version,error,count,bank,upload_open,active};
 always @(posedge clk)begin
  scene_word<=recipe[{bank,index[3:2],recipe_index1_hold,index[0]}];
  // BRAM initial values reload on FPGA configuration, not on KEY1. Explicitly
  // restore bank0's eight presets over eight clocks after every runtime reset.
  if(!rst && boot_busy)recipe[{2'b00,boot_index}]<=initial_word(boot_index);
  else if(!rst && write_entry && upload_open && !publish_pending)recipe[{!bank,upload_index}]<=upload_word;
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   bank<=0;upload_open<=0;publish_pending<=0;valid_entries<=0;version<=0;count<=8;pending_count<=8;error<=0;
   index<=0;request_pending<=0;waiting<=0;active<=0;auto_enabled<=0;divider<=0;elapsed<=0;dwell<=DEFAULT_DWELL_MS;settle<=2;
   boot_busy<=1;boot_index<=0;
  end else begin
   divider<=ms_tick?0:divider+1'b1;if(settle!=0)settle<=settle-1'b1;
   if(boot_busy)begin
    if(boot_index==7)boot_busy<=0;else boot_index<=boot_index+1'b1;
   end
   if(version==0 && media_ready && valid_count!=0 && valid_count<count)count<=valid_count[4:0];
   if(begin_upload)begin
    if(boot_busy)error<=3;
    else begin upload_open<=1;publish_pending<=0;valid_entries<=0;error<=0;end
   end
   if(write_entry)begin
    if(boot_busy)error<=3;
    else if(upload_open && !publish_pending)valid_entries[upload_index]<=1;
    else error<=1;
   end
   if(commit_upload)begin
    if(boot_busy)error<=3;
    else if(!upload_open || publish_pending)error<=1;
    else if(upload_count==0 || upload_count>16 || (valid_entries & needed)!=needed)error<=2;
    else begin publish_pending<=1;pending_count<=upload_count;end
   end
   if(blank_tick && publish_pending && !waiting)begin
    bank<=!bank;count<=pending_count;version<=version+1'b1;upload_open<=0;publish_pending<=0;error<=0;
    index<=0;request_pending<=active;elapsed<=0;settle<=2;
   end
   if(active && auto_toggle)begin auto_enabled<=!auto_enabled;elapsed<=0;end
   if(scene_valid && scene_accept)begin request_pending<=0;waiting<=1;dwell<=scene_word[29:14];end
   if(active && waiting && page_commit)begin
    waiting<=0;elapsed<=0;index<={1'b0,index}+1>=count?0:index+1'b1;settle<=2;
   end else if(active && !waiting && !request_pending)begin
    if(prompt_active || !auto_enabled)elapsed<=0;
    else if(ms_tick)begin
     if(elapsed>=dwell-1'b1)begin elapsed<=0;request_pending<=1;end
     else elapsed<=elapsed+1'b1;
    end
   end
   if(command_valid && command=="G")begin
    active<=value[0];auto_enabled<=value[0];index<=0;request_pending<=value[0];waiting<=0;elapsed<=0;settle<=2;
   end
   if(manual_select)begin active<=0;auto_enabled<=0;request_pending<=0;waiting<=0;elapsed<=0;end
  end
 end
endmodule
