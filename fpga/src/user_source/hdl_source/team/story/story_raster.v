// Free-running 640x480 raster with two owned line banks. All descriptors are
// captured in vertical blank, and stay immutable for the complete active frame.
module story_raster #(parameter HALF_ZOOM_ENABLE=0)(
 input wire pixel_clk,mem_clk,rst,enable,
 input wire [1:0] slot_a,slot_b,mode,
 input wire [8:0] alpha,input wire [9:0] shift,
 input wire read_grant,vendor_wr_busy,vendor_wr_en,refresh_block,Sdr_init_done,Sdr_busy,
 output wire read_lock,App_rd_en,output wire [20:0] App_rd_addr,
 input wire Sdr_rd_en,input wire [31:0] Sdr_rd_dout,
 output wire blank_tick,frame_boundary,
 output wire hs,vs,de,output wire [23:0] rgb,
 output reg frame_good,display_ready,output reg underrun_sticky,
 output wire fault_pixel,output wire [2:0] fault_code_mem,
 input wire half_zoom,output wire half_layout_frame
);
 reg [1:0] reset_pixel;
 always @(posedge pixel_clk or posedge rst)
  if(rst)reset_pixel<=2'b11;else reset_pixel<={reset_pixel[0],1'b0};
 wire rst_p=reset_pixel[1];
 reg [9:0] h;reg [9:0] v;
 wire raw_hs=h>=96,raw_vs=v>=2;
 wire raw_de=h>=144 && h<784 && v>=35 && v<515;
 wire [9:0] x=h-144;
 wire [8:0] y=v-35;
 assign blank_tick=h==0 && v==2;
 assign frame_boundary=h==144 && v==35;
 reg [3:0] hs_d,vs_d,de_d;
 assign hs=hs_d[3];assign vs=vs_d[3];assign de=de_d[3];
 reg [1:0] frame_a,frame_b,frame_mode;
 reg frame_half;
 assign half_layout_frame=frame_half;
 wire image_pixel=!frame_half || (x>=160 && x<480 && y>=72 && y<312);
 reg [8:0] frame_alpha;reg [9:0] frame_shift;
 reg [15:0] tag;reg active,seen_pixel,bad_frame;
 reg [9:0] next_row;
 wire [1:0] owned,ready,done;
 reg [1:0] release_pending;
 wire release_bank=release_pending[0]?1'b0:1'b1;
 wire release_valid=|release_pending;
 wire release_ready;
 wire job_bank=next_row[0];
 wire [9:0] limit_row=v<35?10'd1:(v<515?{1'b0,y}+10'd1:10'd479);
 wire job_valid=active && next_row<(frame_half?312:480) && next_row<=limit_row &&
     !owned[job_bank] && !release_pending[job_bank];
 wire job_ready;
 wire [8:0] job_ya,job_yb;wire [1:0] job_sources;
 story_coordinates #(.HALF_ZOOM_ENABLE(HALF_ZOOM_ENABLE)) row_coordinates(.x(frame_half?10'd160:10'd0),.y(next_row[8:0]),.mode(frame_mode),
  .alpha(frame_alpha),.shift(frame_shift),.zoom_x(9'd160),.zoom_y(8'd120),
  .valid(),.need(),.row_sources(job_sources),.x_a(),.x_b(),.y_a(job_ya),.y_b(job_yb),.half_zoom(frame_half));
 wire out_valid,out_good,underrun;
 wire [23:0] engine_rgb;
 assign rgb=out_valid && out_good?engine_rgb:24'd0;
 story_effect_engine #(.HALF_ZOOM_ENABLE(HALF_ZOOM_ENABLE)) engine(.mem_clk(mem_clk),.pixel_clk(pixel_clk),.rst(rst),
  .read_grant(read_grant),.vendor_wr_busy(vendor_wr_busy),.vendor_wr_en(vendor_wr_en),
  .refresh_block(refresh_block),.Sdr_init_done(Sdr_init_done),.Sdr_busy(Sdr_busy),
  .read_demand(),.read_lock(read_lock),.App_rd_en(App_rd_en),.App_rd_addr(App_rd_addr),
  .Sdr_rd_en(Sdr_rd_en),.Sdr_rd_dout(Sdr_rd_dout),.fault_mem(),
  .fault_pixel(fault_pixel),.fault_code_mem(fault_code_mem),
  .job_valid(job_valid),.job_ready(job_ready),.job_bank(job_bank),
  .job_slot_a(frame_a),.job_slot_b(frame_b),.job_y_a(job_ya),.job_y_b(job_yb),
  .job_sources(job_sources),.job_tag(tag),.job_reject(),.job_done(done),
  .bank_owned(owned),.line_ready(ready),.release_valid(release_valid),
  .release_bank(release_bank),.release_ready(release_ready),
  .pixel_valid(raw_de && active && image_pixel),.pixel_bank(y[0]),.pixel_tag(tag),
  .slot_a(frame_a),.slot_b(frame_b),.mode(frame_mode),.alpha(frame_alpha),
  .shift(frame_shift),.pixel_x(x),.pixel_y(y),.zoom_x(9'd160),.zoom_y(8'd120),
  .out_valid(out_valid),.out_good(out_good),.underrun(underrun),.rgb(engine_rgb),.provenance(),.half_zoom(frame_half));
 always @(posedge pixel_clk or posedge rst_p)begin
  if(rst_p)begin
   h<=0;v<=0;hs_d<=15;vs_d<=15;de_d<=0;
   frame_a<=0;frame_b<=0;frame_mode<=0;frame_alpha<=0;frame_shift<=0;frame_half<=0;
   tag<=0;active<=0;next_row<=480;release_pending<=0;
   frame_good<=0;display_ready<=0;underrun_sticky<=0;seen_pixel<=0;bad_frame<=0;
  end else begin
   if(h==799)begin h<=0;v<=v==524?0:v+1'b1;end else h<=h+1'b1;
   hs_d<={hs_d[2:0],raw_hs};vs_d<={vs_d[2:0],raw_vs};de_d<={de_d[2:0],raw_de};
   if(release_valid && release_ready)release_pending[release_bank]<=0;
   if(job_valid && job_ready)next_row<=next_row+1'b1;
   // Release only after the final pixel has cleared all four pipeline edges.
   if(h==792 && v>=35 && v<515 && (!frame_half || (y>=72 && y<312)))release_pending[y[0]]<=1;
   if(raw_de && active)seen_pixel<=1;
   if(underrun && active)begin bad_frame<=1;underrun_sticky<=1;end
   if(blank_tick)begin
    frame_good<=seen_pixel && !bad_frame && !fault_pixel;
    if(seen_pixel && !bad_frame && !fault_pixel)display_ready<=1;
    seen_pixel<=0;bad_frame<=0;active<=0;next_row<=480;
    release_pending<=owned;
   end
   // Playback/configuration registers update on blank_tick; sample four clocks
   // later, before issuing row jobs, not on the same nonblocking-update edge.
   if(h==4 && v==2)begin
    frame_a<=slot_a;frame_b<=slot_b;frame_mode<=mode;frame_alpha<=alpha;frame_shift<=shift;
    frame_half<=HALF_ZOOM_ENABLE && half_zoom && mode==3;
    tag<=tag+1'b1;next_row<=(HALF_ZOOM_ENABLE && half_zoom && mode==3)?72:0;active<=enable && !fault_pixel;
   end
  end
 end
endmodule
