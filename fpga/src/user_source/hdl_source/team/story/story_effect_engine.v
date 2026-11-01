// Standalone composition. The caller prefetches row jobs and owns raster timing.
// Required row descriptors can be obtained from story_coordinates at that y.
module story_effect_engine #(
    parameter integer MAX_INFLIGHT=32,
    parameter integer WATCHDOG_CYCLES=100000,
    parameter HALF_ZOOM_ENABLE=0
)(
    input wire mem_clk, pixel_clk, rst,
    input wire read_grant, vendor_wr_busy, vendor_wr_en, refresh_block,
    input wire Sdr_init_done, Sdr_busy,
    output wire read_demand, read_lock,
    output wire App_rd_en, output wire [20:0] App_rd_addr,
    input wire Sdr_rd_en, input wire [31:0] Sdr_rd_dout,
    output wire fault_mem, fault_pixel, output wire [2:0] fault_code_mem,
    input wire job_valid, output wire job_ready, input wire job_bank,
    input wire [1:0] job_slot_a, job_slot_b,
    input wire [8:0] job_y_a, job_y_b,
    input wire [1:0] job_sources, input wire [15:0] job_tag,
    output wire job_reject, output wire [1:0] job_done, bank_owned, line_ready,
    input wire release_valid, release_bank, output wire release_ready,
    input wire pixel_valid, pixel_bank,
    input wire [15:0] pixel_tag,
    input wire [1:0] slot_a, slot_b, mode,
    input wire [8:0] alpha,
    input wire [9:0] shift, pixel_x,
    input wire [8:0] pixel_y, zoom_x,
    input wire [7:0] zoom_y,
    output wire out_valid, out_good, underrun,
    output wire [23:0] rgb, output wire [95:0] provenance,
    input wire half_zoom
);
    reg [1:0] mixer_reset;
    always @(posedge pixel_clk or posedge rst)
        if(rst)mixer_reset<=2'b11;else mixer_reset<={mixer_reset[0],1'b0};
    wire coord_ok;
    wire [1:0] need, row_sources;
    wire [9:0] x_a,x_b;
    wire [8:0] y_a,y_b;
    wire fetched_valid, fetched_good;
    wire [23:0] fetched_a, fetched_b;
    wire [1:0] fetched_need;
    wire [8:0] fetched_alpha;
    wire [95:0] fetched_provenance;
    story_coordinates #(.HALF_ZOOM_ENABLE(HALF_ZOOM_ENABLE)) coordinates(.x(pixel_x),.y(pixel_y),.mode(mode),.alpha(alpha),
        .shift(shift),.zoom_x(zoom_x),.zoom_y(zoom_y),.valid(coord_ok),.need(need),
        .row_sources(row_sources),.x_a(x_a),.x_b(x_b),.y_a(y_a),.y_b(y_b),.half_zoom(half_zoom));
    story_dual_source #(.MAX_INFLIGHT(MAX_INFLIGHT),.WATCHDOG_CYCLES(WATCHDOG_CYCLES)) fetch(
        .mem_clk(mem_clk),.pixel_clk(pixel_clk),.rst(rst),.read_grant(read_grant),
        .vendor_wr_busy(vendor_wr_busy),.vendor_wr_en(vendor_wr_en),.refresh_block(refresh_block),
        .Sdr_init_done(Sdr_init_done),.Sdr_busy(Sdr_busy),.read_demand(read_demand),.read_lock(read_lock),
        .App_rd_en(App_rd_en),.App_rd_addr(App_rd_addr),.Sdr_rd_en(Sdr_rd_en),.Sdr_rd_dout(Sdr_rd_dout),
        .fault_mem(fault_mem),.fault_code_mem(fault_code_mem),.fault_pixel(fault_pixel),
        .job_valid(job_valid),.job_ready(job_ready),.job_bank(job_bank),
        .job_slot_a(job_slot_a),.job_slot_b(job_slot_b),.job_y_a(job_y_a),.job_y_b(job_y_b),
        .job_sources(job_sources),.job_tag(job_tag),.job_reject(job_reject),.job_done(job_done),
        .bank_owned(bank_owned),.line_ready(line_ready),.release_valid(release_valid),
        .release_bank(release_bank),.release_ready(release_ready),
        .sample_valid(pixel_valid),.sample_bank(pixel_bank),.sample_tag(pixel_tag),
        .sample_slot_a(slot_a),.sample_slot_b(slot_b),.sample_need(need),
        .sample_x_a(x_a),.sample_x_b(x_b),.sample_y_a(y_a),.sample_y_b(y_b),
        .sample_x(pixel_x),.sample_y(pixel_y),.sample_alpha(alpha),
        .out_valid(fetched_valid),.out_good(fetched_good),.rgb_a(fetched_a),.rgb_b(fetched_b),
        .out_need(fetched_need),.out_alpha(fetched_alpha),.out_provenance(fetched_provenance));
    story_pixel_mixer mixer(.clk(pixel_clk),.rst(mixer_reset[1]),.in_valid(fetched_valid),.in_good(fetched_good),
        .need(fetched_need),.alpha(fetched_alpha),.rgb_a(fetched_a),.rgb_b(fetched_b),
        .provenance(fetched_provenance),.out_valid(out_valid),.out_good(out_good),.underrun(underrun),
        .rgb(rgb),.out_provenance(provenance));
endmodule
