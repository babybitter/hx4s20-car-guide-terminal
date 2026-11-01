
module car_terminal_top(
    input                       clk,
    input                       rst_n,
    input                       key_next_n,
    input                       key_auto_n,
    input                       key_prompt_n,
    input [1:0]                 period_sw,
    input uart_rx, effect_mode_sw, mute_sw,
    output uart_tx,

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
wire vendor_init_done,refresh_request,refresh_read_block,refresh_write_block;
wire refresh_fault;
wire [3:0] refresh_fault_code,refresh_debt;
reg [2:0] refresh_fault_pixel,refresh_fault_sd;

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
wire [23:0] effect_rgb;
wire effect_hs,effect_vs,effect_de;
reg uart_seen;
wire osd_hs;
wire osd_vs;
wire osd_de;
wire        display_valid;
wire        display_active;
wire        media_ready_sd;
wire        media_ready_pixel;
wire [7:0]  logical_count_sd;
wire [7:0]  logical_count_pixel;
wire [3:0]  valid_mask_sd;

wire [3:0]  state_code;
wire [3:0]  error_code;
wire [7:0]  status_upper_digit;
wire [7:0]  status_lower_digit;

wire        write_fifo_full;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
reg         write_ack_meta;
reg         write_ack_sd;
reg [2:0]   raster_fault_sd;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [6:0]  display_page;
wire [1:0] display_slot,cache_slot;
wire cache_req,cache_ack,cache_error;
wire [6:0] cache_id;
wire        page_commit;
wire [15:0] event_seq;
wire        auto_active;
wire basic_auto,story_active,story_auto,scene_valid,scene_accept;
wire [39:0] scene_word;
wire [31:0] sequence_status,status_config;
wire seq_begin,seq_write,seq_commit;
wire [3:0] seq_index;
wire [39:0] seq_word;
wire [4:0] seq_count;
wire [6:0] display_title;
wire [1:0] source_a,source_b,render_mode,legacy_style;
wire [8:0] render_alpha;
wire [9:0] render_shift;
wire legacy_active,scene_prompt,story_frame_good,raster_blank,raster_frame;
wire raster_fault,raster_underrun,story_read_lock,writer_busy;
wire [2:0] raster_fault_code,cue_id;
wire [7:0] story_config;
wire [4:0] transition_recoveries;
wire card_initialized_sd,directory_ready_sd;
wire preload_complete_sd;
reg [2:0] preload_complete_sync;
wire [31:0] metric_init,metric_directory,metric_preload,metric_firstframe,metric_cache;
reg playback_blank;
wire        frame_boundary=playback_blank;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;


// HDMI 1.4b 音频发射相关
reg         audio_valid;
wire        sample_tick;
wire signed [23:0] tone_left,tone_right,stream_pcm;
wire use_stream_pcm,music_active,fallback_allowed;
wire [314:0] spectrum_heights;
wire spectrum_silence,spectrum_valid,spectrum_overflow,spectrum_overrun,spectrum_heights_ready;
wire spectrum_invalid=spectrum_overflow || spectrum_overrun;
wire [23:0] spectrum_rgb;
wire spectrum_hs,spectrum_vs,spectrum_de;
wire effect_wave_hit;
wire [79:0] audio_status;
wire audio_loaded_sd,audio_write_mode,audio_writer_abort;
wire [3:0] audio_load_fault;
wire [31:0] audio_expected_bytes,audio_expected_crc;
wire [20:0] audio_write_words;
reg [2:0] audio_abort_sync;
reg vertical_blank;
wire video_read_grant,audio_read_grant,combined_read_lock;
wire video_read_en,audio_read_en,video_return,audio_return,audio_demand,audio_read_lock;
wire [20:0] video_read_addr,audio_read_addr;
wire [23:0] audio_left_data;
wire signed [23:0] audio_left_raw, audio_right_raw;
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

// S45: TF100MHz, MEM50MHz; SDRAM50MHz delayed8.5ns, PIX25MHz unchanged.
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

wire rst_serial;
clock_reset_mgr u_reset (
    .clk_ref(clk), .clk_sd(sd_card_clk),
    .clk_mem(ext_mem_clk), .clk_pixel(video_clk),
    .rst_n(rst_n), .sys_locked(sys_locked),
    .video_locked(video_locked),
    .rst_sd(rst_sd), .rst_mem(rst_mem), .rst_pixel(rst_video),
    .clk_serial(hdmi_5x_clk), .rst_serial(rst_serial)
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
wire [1:0] extra_switches;
key_switch_ctrl #(.CLK_HZ(25000000),.DEBOUNCE_MS(20)) u_extra_switches (
 .clk(video_clk),.rst(rst_video),.key_next_n(1'b1),.key_auto_n(1'b1),.key_prompt_n(1'b1),
 .period_sw({mute_sw,effect_mode_sw}),.period_sel(extra_switches),
 .next_pulse(),.auto_pulse(),.prompt_pulse(),.period_changed());
wire serial_command_valid;
wire [7:0] serial_command, serial_value;
wire menu_command_valid;
wire [7:0] menu_command,menu_value;
wire command_valid=serial_command_valid || menu_command_valid;
wire [7:0] command=serial_command_valid?serial_command:menu_command;
wire [7:0] command_value=serial_command_valid?serial_value:menu_value;
wire [3:0] menu_selection;wire [2:0] menu_edit_value;
reg [2:0] menu_applied_value;
wire [1:0] zoom_setting;
wire half_layout_frame;
wire [23:0] demo_rgb;wire demo_hs,demo_vs,demo_de,boot_active;
reg [2:0] init_ui_sync,dir_ui_sync;
wire [3:0] boot_progress=preload_complete_sync[2]?4'd4:dir_ui_sync[2]?4'd3:init_ui_sync[2]?4'd2:4'd0;
wire [319:0] serial_text, subtitle;
wire [5:0] serial_text_length, subtitle_length;
wire control_next, control_auto, control_prompt, control_tone, control_select;
wire [6:0] control_index;
wire [1:0] control_period, brightness, contrast, transition_style;
wire control_period_changed, effects_enabled, waveform_enabled;
wire [2:0] filter_mode, volume;
wire [2:0] opacity_level;
wire [79:0] sub_status;
wire sub_begin,sub_write,sub_commit,sub_abort,bitmap_active;
wire [15:0] sub_tag,sub_crc;
wire [5:0] sub_len0,sub_len1;
wire [6:0] sub_index;
wire [127:0] sub_chunk;
wire [23:0] subtitle_rgb;
wire subtitle_hs,subtitle_vs,subtitle_de;
wire [3:0] transition_level;
wire [3:0] error_pixel;
wire blank_tick = raster_blank;
wire [3:0] public_error=refresh_fault_pixel[2]?4'hd:(raster_fault?4'hc:error_pixel);
assign auto_active=story_active?story_auto:basic_auto;
assign status_config={transition_recoveries,opacity_level,raster_underrun,extra_switches[0],extra_switches[1],story_active,story_config[3:0],
                      control_period,waveform_enabled,effects_enabled,volume,transition_style,
                      filter_mode,contrast,brightness};
always @(posedge video_clk or posedge rst_video) begin
 if(rst_video) begin playback_blank<=0;uart_seen<=0;end
 else begin
  playback_blank<=blank_tick;
  if(serial_command_valid) uart_seen<=1;
 end
end
media_status_bridge u_media_status (
 .pixel_clk(video_clk),.pixel_rst(rst_video),.ready_sd(media_ready_sd),
 .fault_sd(state_code==4'he),.count_sd(logical_count_sd),.error_sd(error_code),
 .ready_pixel(media_ready_pixel),.count_pixel(logical_count_pixel),.error_pixel(error_pixel));
terminal_uart_v2 #(.CLK_HZ(25000000),.BAUD(115200),.AUDIO_STATUS_ENABLE(1),.HALF_ZOOM_ENABLE(1)) u_serial (
 .clk(video_clk),.rst(rst_video),.uart_rx(uart_rx),.uart_tx(uart_tx),
 .status_page(display_page),.status_count(logical_count_pixel),
 .status_auto(auto_active),.status_ready(display_valid),.status_error(public_error),
 .status_period(control_period),.cmd_valid(serial_command_valid),.cmd(serial_command),
 .value(serial_value),.text_data(serial_text),.text_length(serial_text_length),
 .status_config(status_config),.event_seq(event_seq),.sd_init_ms(metric_init),.dir_ms(metric_directory),
 .preload_ms(metric_preload),.firstframe_ms(metric_firstframe),.cache_ms(metric_cache),.sequence_status(sequence_status),
 .seq_begin(seq_begin),.seq_write(seq_write),.seq_commit(seq_commit),.seq_index(seq_index),.seq_word(seq_word),.seq_count(seq_count),
 .sub_status(sub_status),.sub_begin(sub_begin),.sub_write(sub_write),.sub_commit(sub_commit),.sub_abort(sub_abort),
 .sub_tag(sub_tag),.sub_crc(sub_crc),.sub_len0(sub_len0),.sub_len1(sub_len1),.sub_index(sub_index),.sub_chunk(sub_chunk),
 .audio_status(audio_status));
// UART owns a retained, validated pending S packet; controls owns the displayed
// text bank. Avoid a third 320-bit copy while retaining blank-time publication.
terminal_controls #(.HELD_TEXT_INPUT(1)) u_controls (
 .clk(video_clk),.rst(rst_video),.blank_tick(blank_tick),
 .next_key(key_next_pulse && !extra_switches[0]),.auto_key(key_auto_pulse && !extra_switches[0]),.prompt_key(key_prompt_pulse && !extra_switches[0]),
 .local_period(period_sel),.local_period_changed(period_changed),
 .mode_sw(extra_switches[0]),.mute_sw(extra_switches[1]),
 .command_valid(command_valid),.command(command),.value(command_value),
 .command_text(serial_text),.command_text_length(serial_text_length),
 .next_pulse(control_next),.auto_pulse(control_auto),.prompt_pulse(control_prompt),
 .tone_pulse(control_tone),.select_pulse(control_select),.select_index(control_index),
 .period_sel(control_period),.period_changed(control_period_changed),
 .brightness(brightness),.contrast(contrast),.transition_style(transition_style),
 .filter_mode(filter_mode),.volume(volume),.effects_enabled(effects_enabled),
 .waveform_enabled(waveform_enabled),.opacity_level(opacity_level),.subtitle(subtitle),.subtitle_length(subtitle_length));

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        prompt_latch <= 1'b0;
        prompt_pending <= 1'b0;
        prompt_open_event <= 1'b0;
    end else begin
        prompt_open_event <= 1'b0;
        if (control_prompt)
            prompt_pending <= 1'b1;
        if (frame_boundary && prompt_pending) begin
            prompt_latch <= ~prompt_latch;
            prompt_pending <= 1'b0;
            if (!prompt_latch)
                prompt_open_event <= 1'b1;
        end
        if(scene_prompt)begin prompt_latch<=1;prompt_pending<=0;if(!prompt_latch)prompt_open_event<=1;end
    end
end
assign status_led = {prompt_latch, control_period[0], auto_active, display_valid};
assign display_valid = display_active;

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        preload_complete_sync <= 0;
        init_ui_sync<=0;dir_ui_sync<=0;
    end else begin
        preload_complete_sync <= {preload_complete_sync[1:0],preload_complete_sd};
        init_ui_sync<={init_ui_sync[1:0],card_initialized_sd};dir_ui_sync<={dir_ui_sync[1:0],directory_ready_sd};
    end
end

terminal_demo_menu u_menu(.pixelclk(video_clk),.rst(rst_video),.blank_tick(blank_tick),.menu_mode(extra_switches[0]),
 .key_next(key_next_pulse),.key_prompt(key_prompt_pulse),.key_auto(key_auto_pulse),.serial_busy(serial_command_valid),
 .applied_filter(filter_mode),.applied_t(transition_style),.applied_x(story_config[1:0]),.applied_z(zoom_setting),
 .applied_l(audio_status[51:50]),.applied_r(control_period),.applied_g(story_active),.applied_e(effects_enabled),
 .applied_y(opacity_level),.cmd_valid(menu_command_valid),.cmd(menu_command),.value(menu_value),
 .selection(menu_selection),.edit_value(menu_edit_value));
always @*case(menu_selection)
 0:menu_applied_value=filter_mode;
 1:menu_applied_value={1'b0,transition_style};
 2:menu_applied_value={1'b0,story_config[1:0]};
 3:menu_applied_value={1'b0,zoom_setting};
 4:menu_applied_value={1'b0,audio_status[51:50]};
 5:menu_applied_value={1'b0,control_period};
 6:menu_applied_value={2'b0,story_active};
 7:menu_applied_value={2'b0,effects_enabled};
 8:menu_applied_value=opacity_level;
 default:menu_applied_value=0;
endcase
story_sequence #(.DEFAULT_DWELL_MS(3000)) u_sequence (
 .clk(video_clk),.rst(rst_video),.blank_tick(playback_blank),.media_ready(display_valid),.valid_count(logical_count_pixel),
 .prompt_active(prompt_latch),.begin_upload(seq_begin),.write_entry(seq_write),.commit_upload(seq_commit),
 .upload_index(seq_index),.upload_word(seq_word),.upload_count(seq_count),
 .command_valid(command_valid),.command(command),.value(command_value),
 .manual_select(control_next || control_select),.auto_toggle(control_auto),
 .scene_accept(scene_accept),.page_commit(page_commit),.scene_valid(scene_valid),.scene_word(scene_word),
 .active(story_active),.auto_enabled(story_auto),.status(sequence_status));
story_playback #(.HALF_ZOOM_ENABLE(1),.DEMO_PERIODS(1)) u_playback (
    .clk(video_clk), .rst(rst_video),
    // Do not let an early raw I command capture display_valid=0 in the cache
    // mailbox and evict slot0 before the first displayed frame is protected.
    .media_ready(display_valid),
    .valid_count(logical_count_pixel),.fault(public_error!=0),
    .next_pulse(control_next), .auto_pulse(control_auto),
    .select_pulse(control_select),.select_index(control_index),
    .blank_tick(playback_blank),.frame_good(story_frame_good),.effects_enabled(effects_enabled),
    .transition_style(transition_style),.transition_level(transition_level),
    .period_sel(control_period), .period_changed(control_period_changed),
    .prompt_active(prompt_latch),
    .auto_enabled(basic_auto),.display_page(display_page),.display_slot(display_slot),.display_title(display_title),
    .source_a(source_a),.source_b(source_b),.render_mode(render_mode),.alpha(render_alpha),.shift(render_shift),
    .legacy_style(legacy_style),.legacy_active(legacy_active),.prompt_event(scene_prompt),.cue_id(cue_id),
    .command_valid(command_valid),.command(command),.value(command_value),
    .story_active(story_active),.scene_valid(scene_valid),.scene_word(scene_word),.scene_accept(scene_accept),
    .config_status(story_config),
    .zoom_setting(zoom_setting),
    .recovery_count(transition_recoveries),
    .page_commit(page_commit), .event_seq(event_seq),
    .cache_req(cache_req),.cache_id(cache_id),.cache_ack(cache_ack),.cache_error(cache_error),.cache_slot(cache_slot)
);
terminal_metrics u_metrics(.clk(video_clk),.rst(rst_video),.card_initialized_sd(card_initialized_sd),
 .directory_ready_sd(directory_ready_sd),.media_ready(preload_complete_sync[2]),.display_ready(display_valid),
 .cache_req(cache_req),.cache_ack(cache_ack),.sd_init_ms(metric_init),.dir_ms(metric_directory),
 .preload_ms(metric_preload),.firstframe_ms(metric_firstframe),.cache_ms(metric_cache));

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
        raster_fault_sd <= 0;
        refresh_fault_sd <= 0;
    end else begin
        write_ack_meta <= sd_card_write_req_ack;
        write_ack_sd <= write_ack_meta;
        raster_fault_sd <= {raster_fault_sd[1:0],raster_fault};
        refresh_fault_sd <= {refresh_fault_sd[1:0],refresh_fault};
    end
end

// FAT32 logical catalogue and four protected cache slots; media_ready is held
// after initial commit so a later load error retains the protected current frame.
catalog_media_system u_media (
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .state_code        (state_code),
    .error_code        (error_code),
    .card_initialized(card_initialized_sd),.directory_ready(directory_ready_sd),
    .write_finish_toggle(frame_write_toggle_mem),
    .write_slot        (write_buf_idx),
    .write_fifo_full   (write_fifo_full),
    .media_ready       (media_ready_sd),
    .preload_complete  (preload_complete_sd),
    .logical_count     (logical_count_sd),
    .valid_mask        (valid_mask_sd),
    .audio_expected_bytes(audio_expected_bytes),.audio_expected_crc(audio_expected_crc),
    .audio_loaded(audio_loaded_sd),.audio_fault(audio_load_fault),.audio_write_mode(audio_write_mode),
    .audio_writer_abort(audio_writer_abort),.audio_write_words(audio_write_words),
    .write_req         (sd_card_write_req),
    .write_req_ack     (write_ack_sd),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .pixel_clk(video_clk),.pixel_rst(rst_video),.cache_req(cache_req),.cache_id(cache_id),
    .display_valid(display_valid),.display_slot(display_slot),
    .cache_ack(cache_ack),.cache_error(cache_error),.cache_slot(cache_slot),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

terminal_status_digits u_status_digits(
    .clk(sd_card_clk),.rst(rst_sd),.state_code(refresh_fault_sd[2]?4'he:state_code),
    .error_code(refresh_fault_sd[2]?4'hd:error_code),
    .raster_fault(raster_fault_sd[2] && !refresh_fault_sd[2]),
    .upper_digit(status_upper_digit),.lower_digit(status_lower_digit)
);

// Keep diagnostic digits in the loader domain; do not sample its status bus
// directly with the unrelated 50 MHz reference clock.
seg_scan #(.CLK_FREQ(100000000)) seg_scan_m0(
    .clk               (sd_card_clk),
    .rst_n             (~rst_sd),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        (status_upper_digit),
    .seg_data_5        (status_lower_digit)
);

// Dual-source scanout owns two ping-pong rows. Official SDRAM IP/timings remain.
story_raster #(.HALF_ZOOM_ENABLE(1)) u_raster(.pixel_clk(video_clk),.mem_clk(ext_mem_clk),.rst(rst_video || rst_mem),
 .enable(media_ready_pixel),.slot_a(source_a),.slot_b(source_b),.mode(render_mode),
 .alpha(render_alpha),.shift(render_shift),.read_grant(video_read_grant),
 .vendor_wr_busy(writer_busy),.vendor_wr_en(App_wr_en),.refresh_block(refresh_read_block),
 .Sdr_init_done(Sdr_init_done),.Sdr_busy(Sdr_busy),.read_lock(story_read_lock),
 .App_rd_en(video_read_en),.App_rd_addr(video_read_addr),.Sdr_rd_en(video_return),.Sdr_rd_dout(Sdr_rd_dout),
 .blank_tick(raster_blank),.frame_boundary(raster_frame),.hs(hs),.vs(vs),.de(de),.rgb(vout_data_raw),
 .frame_good(story_frame_good),.display_ready(display_active),.underrun_sticky(raster_underrun),
 .fault_pixel(raster_fault),.fault_code_mem(raster_fault_code),
 .half_zoom(zoom_setting==2),.half_layout_frame(half_layout_frame));

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid ? vout_data_raw : 24'd0;

terminal_video_chain #(.ADAPTIVE_LAYOUT(1),.LOCAL_ENABLES(1),.DYNAMIC_COLOR(0)) u_effect_chain (
    .clk(video_clk),.rst(rst_video),.effects_enabled(effects_enabled || legacy_active),.waveform_enabled(waveform_enabled),
    .waveform_auto_enabled(effects_enabled || music_active),.opacity_level(opacity_level),
    .I_rgb(vout_data),.I_hs(hs),.I_vs(vs),.I_de(de),.page_id(display_page),
    .brightness(brightness),.contrast(contrast),.transition_style(legacy_active?legacy_style:transition_style),
    .filter_mode(filter_mode),.volume(volume),.transition_level(transition_level),
    .auto_enabled(auto_active),.media_ready(media_ready_pixel),.uart_seen(uart_seen),.error_code(public_error),
    .subtitle(subtitle),.subtitle_length(bitmap_active?6'd0:subtitle_length),.audio_valid(audio_valid),
    .audio_left(audio_left_data),.audio_right(audio_right_data),
    .O_rgb(effect_rgb),.O_hs(effect_hs),.O_vs(effect_vs),.O_de(effect_de),.half_layout(half_layout_frame),.zoom_setting(zoom_setting),
    .left_wave_color(24'hE8EEF4),.right_wave_color(24'h9DECF5),.O_wave_hit(effect_wave_hit)
);

// 63 positive-frequency responses of ACTUAL post-volume PCM. Saturation/overrun
// suppresses the analysis display only; it cannot stop HDMI/audio or video.
audio_band_analyzer #(.ATOMIC_OUTPUT(0)) u_spectrum(.clk(video_clk),.rst(rst_video),.sample_tick(audio_valid),
 .pcm_postvolume(audio_left_data),.band_heights(spectrum_heights),.dominant_band(),
 .heights_ready(spectrum_heights_ready),
 .silence(spectrum_silence),.valid(spectrum_valid),.overflow_sticky(spectrum_overflow),.overrun_sticky(spectrum_overrun));
// Frequency colors live in the full rainbow spectrum. Fixed high-contrast
// stereo traces remain legible over every hue; no duplicate score/color ROM.
pcm_spectrum_overlay #(.GUARDED_HEIGHTS(1)) u_spectrum_overlay(.clk(video_clk),.rst(rst_video),
 .enable((effects_enabled || waveform_enabled || music_active) && !spectrum_invalid),.half_layout(half_layout_frame),
 .band_heights(spectrum_heights),.silence(spectrum_silence),.opacity(opacity_level),
 .heights_ready(spectrum_heights_ready),
 .I_rgb(effect_rgb),.I_hs(effect_hs),.I_vs(effect_vs),.I_de(effect_de),.I_wave_hit(effect_wave_hit),
 .O_rgb(spectrum_rgb),.O_hs(spectrum_hs),.O_vs(spectrum_vs),.O_de(spectrum_de));

// Two synchronized video registers; bitmap publication only in vertical blank.
// Safety OSD remains last, above both waveform and user subtitle.
subtitle_bitmap_overlay u_bitmap_subtitle (
    .clk(video_clk),.rst(rst_video),.blank_tick(blank_tick),.enable(effects_enabled),
    .legacy_select(serial_command_valid && serial_command=="S"),
    .sub_begin(sub_begin),.sub_write(sub_write),.sub_commit(sub_commit),.sub_abort(sub_abort),
    .sub_tag(sub_tag),.sub_crc(sub_crc),.sub_len0(sub_len0),.sub_len1(sub_len1),
    .sub_index(sub_index),.sub_chunk(sub_chunk),.sub_status(sub_status),.bitmap_active(bitmap_active),
    .I_rgb(spectrum_rgb),.I_hs(spectrum_hs),.I_vs(spectrum_vs),.I_de(spectrum_de),
    .O_rgb(subtitle_rgb),.O_hs(subtitle_hs),.O_vs(subtitle_vs),.O_de(subtitle_de)
);

osd_compositor #(.INDEPENDENT_TITLE(1),.USE_SYNC_FONT(1)) u_osd (
    .clk(video_clk), .rst(rst_video),
    .I_rgb(subtitle_rgb), .I_hs(subtitle_hs), .I_vs(subtitle_vs), .I_de(subtitle_de),
    .page_id(display_page),.title_id(display_title),.page_count(logical_count_pixel), .auto_enabled(auto_active),
    .prompt_active(prompt_latch),
    .O_rgb(osd_rgb), .O_hs(osd_hs), .O_vs(osd_vs), .O_de(osd_de)
);

terminal_boot_menu_overlay u_demo_ui(.pixelclk(video_clk),.rst(rst_video),.blank_tick(blank_tick),
 .I_rgb(osd_rgb),.I_hs(osd_hs),.I_vs(osd_vs),.I_de(osd_de),.page_id(display_page),
 .media_ready(media_ready_pixel),.boot_progress(boot_progress),.display_ready(display_valid),.fault_code(public_error),
 .menu_mode(extra_switches[0]),.menu_selection(menu_selection),.edit_value(menu_edit_value),.applied_value(menu_applied_value),
 .O_rgb(demo_rgb),.O_hs(demo_hs),.O_vs(demo_vs),.O_de(demo_de),.boot_active(boot_active));

always @(posedge ext_mem_clk or posedge rst_mem)begin
 if(rst_mem)audio_abort_sync<=0;
 else audio_abort_sync<={audio_abort_sync[1:0],audio_writer_abort};
end
always @(posedge video_clk or posedge rst_video)begin
 if(rst_video)begin vertical_blank<=1;audio_valid<=0;refresh_fault_pixel<=0;end
 else begin
  refresh_fault_pixel<={refresh_fault_pixel[1:0],refresh_fault};
  audio_valid<=sample_tick;
  if(raster_blank)vertical_blank<=1;
  else if(de)vertical_blank<=0;
 end
end
audio_memory_arbiter u_read_arbiter(.mem_clk(ext_mem_clk),.rst(rst_mem),.init_done(Sdr_init_done),
 .refresh_block(refresh_read_block),.controller_busy(Sdr_busy),.vertical_blank_pixel(vertical_blank),
 .writer_busy(writer_busy),.writer_en(App_wr_en),.video_lock(story_read_lock),.video_en(video_read_en),
 .video_addr(video_read_addr),.audio_demand(audio_demand),.audio_lock(audio_read_lock),
 .audio_en(audio_read_en),.audio_addr(audio_read_addr),.video_grant(video_read_grant),.audio_grant(audio_read_grant),
 .read_lock(combined_read_lock),.return_valid(Sdr_rd_en),.video_return(video_return),.audio_return(audio_return),
 .app_en(App_rd_en),.app_addr(App_rd_addr));
story_frame_writer #(.AUDIO_WRITE_ENABLE(1)) u_frame_writer(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem || audio_abort_sync[2]),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    // Only new-burst admission sees this block; never gate accepted App_wr_en.
    .read_lock(combined_read_lock || refresh_write_block),.writer_busy(writer_busy),
    .audio_mode(audio_write_mode),.audio_words(audio_write_words),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_slot        (write_buf_idx),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_fifo_full   (write_fifo_full)
);

sdram_refresh_guard u_refresh_guard(
 .clk(ext_mem_clk),.rst(rst_mem),.vendor_init_done(vendor_init_done),
 .vendor_ref_vld(Sdr_init_ref_vld),.vendor_busy(Sdr_busy),
 .app_rd_en(App_rd_en),.app_rd_low(App_rd_addr[1:0]),.app_wr_en(App_wr_en),
 .return_valid(Sdr_rd_en),.read_lock(combined_read_lock),.writer_busy(writer_busy),
 .app_ref_req(refresh_request),.init_done(Sdr_init_done),
 .read_block(refresh_read_block),.write_block(refresh_write_block),
 .fault(refresh_fault),.fault_code(refresh_fault_code),.refresh_debt(refresh_debt));

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .App_ref_req       (refresh_request),
    .Sdr_init_done     (vendor_init_done),
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
    .page_commit(page_commit && cue_id!=4),
    .page_id(cue_id[1:0]),
    .prompt_open_event(prompt_open_event | control_tone),
    .test_tone_enable(1'b0),
    .audio_valid(sample_tick),
    .audio_left(tone_left),
    .audio_right(tone_right),
    .cue_busy()
);

terminal_audio_engine #(.FEATURES(8'h1f)) u_audio_engine(.pixel_clk(video_clk),.mem_clk(ext_mem_clk),.rst_pixel(rst_video),.rst_mem(rst_mem),
 .sample_tick(sample_tick),.assets_ready_sd(audio_loaded_sd),.loader_fault_sd(audio_load_fault),.volume(volume),
 .command_valid(command_valid),.command(command),.value(command_value),
 .display_ready(display_valid),.page_commit(page_commit),.prompt_open(prompt_open_event | control_tone),
 .page(display_page),.title(display_title),.cue(cue_id),.auto_active(auto_active),.story_active(story_active),
 .story_auto(story_auto),.effect_mode(extra_switches[0]),.filter(filter_mode),.transition(transition_style),.story_config(story_config),
 .sequence_version(sequence_status[31:16]),.subtitle_version(sub_status[31:16]),.error_code(public_error),
 .expected_bytes(audio_expected_bytes),.expected_crc(audio_expected_crc),.pcm(stream_pcm),.use_pcm(use_stream_pcm),
 .music_active(music_active),.fallback_allowed(fallback_allowed),.audio_status(audio_status),.rd_demand(audio_demand),.rd_lock(audio_read_lock),.rd_grant(audio_read_grant),
 .position_samples(),
 .App_rd_en(audio_read_en),.App_rd_addr(audio_read_addr),.Sdr_rd_en(audio_return),.Sdr_rd_dout(Sdr_rd_dout),
 .Sdr_init_done(Sdr_init_done),.Sdr_init_ref_vld(refresh_read_block),.Sdr_busy(Sdr_busy),.zoom_setting(zoom_setting));
assign audio_left_raw=use_stream_pcm?stream_pcm:(fallback_allowed?tone_left:24'sd0);
assign audio_right_raw=use_stream_pcm?stream_pcm:(fallback_allowed?tone_right:24'sd0);

pcm_volume u_pcm_volume (
    .volume(volume), .left_in(audio_left_raw), .right_in(audio_right_raw),
    .left_out(audio_left_data), .right_out(audio_right_data)
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
    .I_vs          (demo_vs),
    .I_de          (demo_de),
    .I_rgb         (demo_rgb),
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
    .I_serial_rst       (rst_serial),
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
