module catalog_media_system #(parameter EARLY_FIRST_FRAME=1)(
 input wire clk,rst,pixel_clk,pixel_rst,
 input wire cache_req,input wire [6:0] cache_id,
 input wire display_valid,input wire [1:0] display_slot,
 output wire cache_ack,cache_error,output wire [1:0] cache_slot,
 output wire media_ready,preload_complete,output wire [7:0] logical_count,output wire [3:0] valid_mask,
 output wire [3:0] state_code,error_code,
 output wire card_initialized,directory_ready,
 input wire write_finish_toggle,write_fifo_full,write_req_ack,
 output wire [1:0] write_slot,output wire write_req,write_en,output wire [31:0] write_data,
 output wire SD_nCS,SD_DCLK,SD_MOSI,input wire SD_MISO,
 input wire [31:0] audio_expected_bytes,audio_expected_crc,
 output wire audio_loaded,output wire [3:0] audio_fault,
 output wire audio_write_mode,audio_writer_abort,output wire [20:0] audio_write_words
);
 wire sector_req,sector_ready,sector_valid,sector_done,sector_error,initialized;
 wire [31:0] sector_lba,capacity;wire [7:0] sector_data,sd_fault;
 wire mounted,mount_ready,mount_done,fs_error,io_fault;wire [7:0] file_count,fs_error_code;
 reg mount_started,start_started;
 wire [6:0] catalog_id,read_id;wire catalog_valid;wire [31:0] catalog_size;
 wire read_req,read_ready,read_done,out_valid,out_ready,out_last;
 wire [31:0] read_offset,read_length,out_offset;wire [7:0] out_data;
 wire audio_present,audio_done,audio_read_req,audio_out_ready,audio_write_req,audio_write_en;
 wire [31:0] audio_size,audio_read_length,audio_write_data;
 wire [3:0] audio_progress;
 wire fs_read_req,fs_read_ready,fs_read_done,fs_out_valid,fs_out_ready;
 wire image_write_req,image_write_en;wire [31:0] image_write_data;wire [1:0] image_write_slot;
 reg image_fs_started;
 wire guarded_done,guarded_error,crc_failed;
 wire start_ready,preload_done,loader_ready,loader_error;
 wire [7:0] loader_error_code,source_error_code;
 wire request_sd,ack_sd,page_done;wire [6:0] id_sd;
 wire [1:0] result_slot,protected_display_slot,protected_target_slot;
 wire protect_display,protect_target;
 wire fatal_error=sd_fault!=0 || io_fault || (fs_error && image_fs_started) || crc_failed || (loader_error && !loader_ready);
 assign card_initialized=initialized;
 assign directory_ready=mounted;
 assign state_code=fatal_error?4'he:!initialized?4'd0:!mounted?4'd2:!preload_complete?4'd3:4'd4;
 // E8=file system; E9=cache/BMP; EA=SD protocol/CRC/capacity. Detail wires retained for models.
 assign error_code=sd_fault!=0?4'ha:crc_failed?4'hb:(fs_error && image_fs_started)||io_fault?4'h8:loader_error?4'h9:4'd0;
 assign audio_write_mode=!audio_done;
 assign fs_read_req=audio_write_mode?audio_read_req:read_req;
 assign read_ready=fs_read_ready && !audio_write_mode;
 assign read_done=fs_read_done && !audio_write_mode;
 assign out_valid=fs_out_valid && !audio_write_mode;
 assign fs_out_ready=audio_write_mode?audio_out_ready:out_ready;
 assign write_req=audio_write_mode?audio_write_req:image_write_req;
 assign write_en=audio_write_mode?audio_write_en:image_write_en;
 assign write_data=audio_write_mode?audio_write_data:image_write_data;
 assign write_slot=audio_write_mode?2'd0:image_write_slot;
 always @(posedge clk or posedge rst)begin
  if(rst)begin mount_started<=0;start_started<=0;image_fs_started<=0;end
  else begin
   if(initialized && !mount_started && mount_ready)mount_started<=1;
   if(mounted && audio_done && !start_started && start_ready)start_started<=1;
   if(read_req && read_ready)image_fs_started<=1;
  end
 end
 media_startup_progress #(.EARLY_FIRST_FRAME(EARLY_FIRST_FRAME)) u_startup_progress(
  .clk(clk),.rst(rst),.initialized(initialized),.mounted(mounted),.slot0_valid(valid_mask[0]),
  .fault(fatal_error),.logical_count(logical_count),.preload_done(preload_done),.loader_ready(loader_ready),
  .display_ready(media_ready),.preload_ready(preload_complete));
 sd_sector_adapter u_sd(.clk(clk),.rst(rst),.sector_req(sector_req),.sector_ready(sector_ready),
  .sector_lba(sector_lba),.sector_byte_valid(sector_valid),.sector_byte(sector_data),
  .sector_done(sector_done),.sector_error(sector_error),.initialized(initialized),
  .card_sector_count(capacity),.fault_code(sd_fault),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO));
 audio_asset_loader u_audio_load(.clk(clk),.rst(rst),.mounted(mounted),.audio_present(audio_present),
  .audio_size(audio_size),.expected_bytes(audio_expected_bytes),.expected_crc(audio_expected_crc),
  .owns_fs(),.done(audio_done),.loaded(audio_loaded),.fault(audio_fault),
  .read_req(audio_read_req),.read_ready(fs_read_ready),.read_length(audio_read_length),
  .read_done(fs_read_done),.fs_error(fs_error),.out_valid(fs_out_valid),.out_last(out_last),
  .out_ready(audio_out_ready),.out_data(out_data),.out_offset(out_offset),
  .write_req(audio_write_req),.write_req_ack(write_req_ack),.write_fifo_full(write_fifo_full),
  .write_finish_toggle(write_finish_toggle),.write_en(audio_write_en),.write_data(audio_write_data),
  .write_words(audio_write_words),.writer_abort(audio_writer_abort),.progress(audio_progress));
 fat32_ro_reader #(.SECTOR_TIMEOUT_CYCLES(100000000),.PROJECT_NAMES_ONLY(1),.AUDIO_FILE_ENABLE(1)) u_fs(
  .clk(clk),.rst(rst),.mount_req(initialized && !mount_started),.mount_ready(mount_ready),
  .card_sector_count(capacity),.mount_done(mount_done),.mounted(mounted),.file_count(file_count),
  .catalog_id(catalog_id),.catalog_valid(catalog_valid),.catalog_name(),.catalog_cluster(),.catalog_size(catalog_size),
  .audio_present(audio_present),.audio_size(audio_size),.read_audio(audio_write_mode),
  .read_req(fs_read_req),.read_ready(fs_read_ready),.read_id(read_id),
  .read_offset(audio_write_mode?32'd0:read_offset),.read_length(audio_write_mode?audio_read_length:read_length),
  .read_done(fs_read_done),.bytes_read(),.out_valid(fs_out_valid),.out_ready(fs_out_ready),.out_data(out_data),.out_last(out_last),
  .out_offset(out_offset),.error(fs_error),.error_code(fs_error_code),.io_fault(io_fault),
  .sector_req(sector_req),.sector_ready(sector_ready),.sector_lba(sector_lba),
  .sector_byte_valid(sector_valid),.sector_byte(sector_data),.sector_done(sector_done),.sector_error(sector_error));
 media_crc_guard u_crc(
  .clk(clk),.rst(rst),.read_req(read_req),.read_ready(read_ready),.read_id(read_id),.read_offset(read_offset),.read_length(read_length),
  .data_valid(out_valid),.data_ready(out_ready),.data(out_data),.source_done(read_done),.source_error(fs_error && image_fs_started),
  .guarded_done(guarded_done),.guarded_error(guarded_error),.actual_crc(),.crc_failed(crc_failed));
 catalog_mailbox u_mailbox(
  .pixel_clk(pixel_clk),.pixel_rst(pixel_rst),.sd_clk(clk),.sd_rst(rst),
  .request_pixel(cache_req),.id_pixel(cache_id),.display_valid_pixel(display_valid),.display_slot_pixel(display_slot),
  .ack_pixel(cache_ack),.error_pixel(cache_error),.slot_pixel(cache_slot),
  .request_sd(request_sd),.id_sd(id_sd),.ack_sd(ack_sd),.done_sd(page_done),.error_sd(loader_error),
  .result_slot_sd(result_slot),.protect_display(protect_display),.display_slot_sd(protected_display_slot),
  .protect_target(protect_target),.target_slot_sd(protected_target_slot));
 catalog_frame_loader u_cache(
  .clk(clk),.rst(rst),.start_req(mounted && audio_done && !start_started),.start_ready(start_ready),.preload_done(preload_done),
  .ready(loader_ready),.error(loader_error),.error_code(loader_error_code),.source_error_code(source_error_code),
  .logical_count(logical_count),.page_req(request_sd),.page_ready(),.page_id(id_sd),.page_done(page_done),.page_ack(ack_sd),
  .result_id(),.result_slot(result_slot),.display_valid(protect_display),.display_slot(protected_display_slot),
  .target_valid(protect_target),.target_slot(protected_target_slot),.loading(),.write_slot(image_write_slot),
  .slot_valid(valid_mask),.slot_ids(),.fs_mounted(mounted),.fs_file_count(file_count),
  .fs_catalog_id(catalog_id),.fs_catalog_valid(catalog_valid),.fs_catalog_size(catalog_size),
  .fs_read_req(read_req),.fs_read_ready(read_ready),.fs_read_id(read_id),.fs_read_offset(read_offset),.fs_read_length(read_length),
  .fs_read_done(guarded_done),.fs_error(guarded_error),.fs_error_code(crc_failed?8'h31:fs_error_code),.fs_out_valid(out_valid),.fs_out_ready(out_ready),
  .fs_out_data(out_data),.fs_out_offset(out_offset),.fs_out_last(out_last),
  .write_req(image_write_req),.write_req_ack(write_req_ack && !audio_write_mode),.write_en(image_write_en),.write_data(image_write_data),
  .write_fifo_full(write_fifo_full),.write_finish_toggle(write_finish_toggle));
endmodule
