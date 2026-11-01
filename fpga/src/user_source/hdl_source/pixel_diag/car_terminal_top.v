
module car_terminal_top(
    input                       clk,
    input                       rst_n,
    input                       key_next_n,
    input                       key_auto_n,
    input                       key_prompt_n,
    input [1:0]                 period_sw,

    output [5:0]                seg_sel,
    output [7:0]                seg_data,
    output [3:0]                status_led,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [20:0] FRAME_PIXELS = 21'd307200;
parameter [20:0] BUF0_ADDR = 21'd0;
parameter [20:0] BUF1_ADDR = 21'd307200;
parameter [20:0] BUF2_ADDR = 21'd614400;
parameter [20:0] BUF3_ADDR = 21'd921600;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] osd_rgb;
wire osd_hs;
wire osd_vs;
wire osd_de;
wire        display_valid;
reg         display_active;
reg         video_prepared;
wire        media_ready_sd;
reg         media_ready_meta;
reg         media_ready_pixel;
wire [2:0]  valid_count_sd;
wire [3:0]  valid_mask_sd;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_raw;
wire        video_read_req_ack;
reg         video_ack_meta;
reg         video_ack_pixel;
wire        video_read_en;
wire        video_read_en_raw;
wire        video_fifo_empty;
wire        video_underflow_seen;
wire [31:0] video_read_data;
wire        write_fifo_full;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
reg         write_ack_meta;
reg         write_ack_sd;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire        page_request;
wire [1:0]  page_target;
wire [1:0]  display_page;
wire        page_commit;
wire [15:0] event_seq;
wire        auto_active;
reg         vs_prev;
reg         de_prev;
reg         frame_arm;
reg         frame_boundary;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;
wire key_next_pulse;
wire key_auto_pulse;
wire key_prompt_pulse;
wire [1:0] period_sel;
wire period_changed;
reg prompt_latch;
reg prompt_pending;
reg prompt_open_event;

wire sys_locked;
wire video_locked;
wire rst_sd;
wire rst_mem;
wire rst_video;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0),
    .locked     (sys_locked)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0),
    .locked     (video_locked)
);

clock_reset_mgr u_reset (
    .clk_ref(clk), .clk_sd(sd_card_clk),
    .clk_mem(ext_mem_clk), .clk_pixel(video_clk),
    .rst_n(rst_n), .sys_locked(sys_locked),
    .video_locked(video_locked),
    .rst_sd(rst_sd), .rst_mem(rst_mem), .rst_pixel(rst_video)
);

key_switch_ctrl #(
    .CLK_HZ(25000000),
    .DEBOUNCE_MS(20)
) u_keys (
    .clk(video_clk),
    .rst(rst_video),
    .key_next_n(key_next_n),
    .key_auto_n(key_auto_n),
    .key_prompt_n(key_prompt_n),
    .period_sw(period_sw),
    .next_pulse(key_next_pulse),
    .auto_pulse(key_auto_pulse),
    .prompt_pulse(key_prompt_pulse),
    .period_sel(period_sel),
    .period_changed(period_changed)
);
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        prompt_latch <= 1'b0;
        prompt_pending <= 1'b0;
        prompt_open_event <= 1'b0;
    end else begin
        prompt_open_event <= 1'b0;
        if (key_prompt_pulse)
            prompt_pending <= 1'b1;
        if (frame_boundary && prompt_pending) begin
            prompt_latch <= ~prompt_latch;
            prompt_pending <= 1'b0;
            if (!prompt_latch)
                prompt_open_event <= 1'b1;
        end
    end
end
assign status_led = {prompt_latch, period_sel[0], auto_active,
                     video_underflow_seen};
assign display_valid = display_active;
assign video_read_req = media_ready_pixel && video_read_req_raw;
assign video_read_en = display_active && video_read_en_raw;
assign disp_buf_idx = page_request ? page_target : display_page;

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        media_ready_meta <= 1'b0;
        media_ready_pixel <= 1'b0;
        video_ack_meta <= 1'b0;
        video_ack_pixel <= 1'b0;
        video_prepared <= 1'b0;
        display_active <= 1'b0;
        vs_prev <= 1'b0;
        de_prev <= 1'b0;
        frame_arm <= 1'b0;
        frame_boundary <= 1'b0;
    end else begin
        media_ready_meta <= media_ready_sd;
        media_ready_pixel <= media_ready_meta;
        video_ack_meta <= video_read_req_ack;
        video_ack_pixel <= video_ack_meta;
        if (!media_ready_pixel) begin
            video_prepared <= 1'b0;
            display_active <= 1'b0;
        end else begin
            if (video_ack_pixel)
                video_prepared <= 1'b1;
            if (frame_boundary && video_prepared)
                display_active <= 1'b1;
        end
        vs_prev <= vs_0;
        de_prev <= de_0;
        frame_boundary <= 1'b0;
        if (vs_0 != vs_prev)
            frame_arm <= 1'b1;
        if (de_0 && !de_prev && frame_arm) begin
            frame_boundary <= 1'b1;
            frame_arm <= 1'b0;
        end
    end
end

playback_fsm u_playback (
    .clk(video_clk), .rst(rst_video),
    .media_ready(media_ready_pixel),
    .valid_count(valid_count_sd),
    .next_pulse(key_next_pulse), .auto_pulse(key_auto_pulse),
    .period_sel(period_sel), .period_changed(period_changed),
    .prompt_active(prompt_latch),
    .frame_boundary(frame_boundary), .page_ready(video_ack_pixel),
    .auto_enabled(auto_active), .page_req(page_request),
    .page_target(page_target), .display_page(display_page),
    .page_commit(page_commit), .event_seq(event_seq)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// The vendor write ack is a held level until request drops; synchronize it
// before the SD-domain loader consumes the four-phase handshake.
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        write_ack_meta <= 1'b0;
        write_ack_sd <= 1'b0;
    end else begin
        write_ack_meta <= sd_card_write_req_ack;
        write_ack_sd <= write_ack_meta;
    end
end

// Four physical-sector BMP candidates are fully loaded before playback.
tf_four_frame_loader u_media (
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .state_code        (state_code),
    .write_finish_toggle(frame_write_toggle_mem),
    .write_slot        (write_buf_idx),
    .write_fifo_full   (write_fifo_full),
    .media_ready       (media_ready_sd),
    .valid_count       (valid_count_sd),
    .valid_mask        (valid_mask_sd),
    .write_req         (sd_card_write_req),
    .write_req_ack     (write_ack_sd),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_req          (video_read_req_raw),
    .read_req_ack      (video_ack_pixel),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_en           (video_read_en_raw),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid ? vout_data_raw : 24'd0;

osd_compositor u_osd (
    .clk(video_clk), .rst(rst_video),
    .I_rgb(vout_data), .I_hs(hs), .I_vs(vs), .I_de(de),
    .page_id(display_page), .auto_enabled(auto_active),
    .prompt_active(prompt_latch),
    .O_rgb(osd_rgb), .O_hs(osd_hs), .O_vs(osd_vs), .O_de(osd_de)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),
    .read_fifo_empty   (video_fifo_empty),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_fifo_full   (write_fifo_full)
);

pixel_underflow_monitor u_pixel_underflow_monitor (
    .clk(video_clk),
    .rst(rst_video),
    .display_active(display_active),
    .frame_boundary(frame_boundary),
    .pixel_read(video_read_en),
    .fifo_empty(video_fifo_empty),
    .underflow_seen(video_underflow_seen)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// Audio samples and page commit are both in the pixel clock domain.
page_audio_cue u_page_audio_cue (
    .clk(video_clk),
    .rst(rst_video),
    .page_commit(page_commit),
    .page_id(display_page),
    .prompt_open_event(prompt_open_event),
    .test_tone_enable(1'b0),
    .audio_valid(audio_valid),
    .audio_left(audio_left_data),
    .audio_right(audio_right_data),
    .cue_busy()
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (osd_vs),
    .I_de          (osd_de),
    .I_rgb         (osd_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_video),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

module pixel_underflow_monitor (
    input wire clk,
    input wire rst,
    input wire display_active,
    input wire frame_boundary,
    input wire pixel_read,
    input wire fifo_empty,
    output reg underflow_seen
);
    reg armed;
    reg [1:0] settle_frames;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            armed <= 1'b0;
            settle_frames <= 2'd0;
            underflow_seen <= 1'b0;
        end else if (!display_active) begin
            armed <= 1'b0;
            settle_frames <= 2'd0;
            underflow_seen <= 1'b0;
        end else begin
            if (!armed && frame_boundary) begin
                if (settle_frames == 2'd1)
                    armed <= 1'b1;
                else
                    settle_frames <= settle_frames + 1'b1;
            end
            if (armed && pixel_read && fifo_empty)
                underflow_seen <= 1'b1;
        end
    end
endmodule
