// Reuses the official FIFO and write scheduler without changing SDRAM timings.
// A row-read owns the command interface until every accepted word returns.
module story_frame_writer #(parameter AUDIO_WRITE_ENABLE=0)(
 input wire rst,mem_clk,write_clk,Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,read_lock,
 input wire write_req,write_en,input wire [31:0] write_data,input wire [1:0] write_slot,
 output wire write_req_ack,write_finish,write_fifo_full,writer_busy,
 output wire App_wr_en,output wire [20:0] App_wr_addr,
 output wire [31:0] App_wr_din,output wire [3:0] App_wr_dm,
 input wire audio_mode,input wire [20:0] audio_words
);
 wire fifo_reset;wire [8:0] used,used_write;wire fifo_full_raw;
 // rst is generated in MEM (including the audio-abort mailbox). Assert in
 // both domains immediately, but release source-side state on write_clk.
 (* preserve *) reg [1:0] write_reset_pipe;
 always @(posedge write_clk or posedge rst)begin
  if(rst)write_reset_pipe<=2'b11;
  else write_reset_pipe<={write_reset_pipe[0],1'b0};
 end
 wire write_reset=write_reset_pipe[1];
 // Capture one bundled descriptor on the first source-clock request edge.
 // The held request crosses the scheduler's existing three-stage sync only
 // after this snapshot. Keep the bundle fixed until the next transaction.
 reg request_held,audio_mode_held;
 reg [1:0] slot_held;
 reg [20:0] words_held;
 always @(posedge write_clk or posedge write_reset)begin
  if(write_reset)begin request_held<=0;audio_mode_held<=0;slot_held<=0;words_held<=0;end
  else begin
   request_held<=write_req;
   if(write_req && !request_held)begin
    audio_mode_held<=AUDIO_WRITE_ENABLE && audio_mode;
    slot_held<=write_slot;words_held<=audio_words;
   end
  end
 end
 // Only base address 0 bypasses the scheduler's descriptor registers. Bring
 // its audio selector into MEM first. The existing three-stage request reaches
 // S_ACK after this two-stage path has settled; no scheduler wait is added.
 (* preserve *) reg audio_base_meta,audio_base_mem;
 always @(posedge mem_clk or posedge rst)begin
  if(rst)begin audio_base_meta<=0;audio_base_mem<=0;end
  else begin audio_base_meta<=audio_mode_held;audio_base_mem<=audio_base_meta;end
 end
 // fifo_reset is a held MEM-domain ACK/clear level. The producer already waits
 // for ACK-low before supplying data. Synchronize this additional full guard;
 // it may conservatively delay release but does not delay the actual FIFO reset.
 (* preserve *) reg fifo_clear_meta,fifo_clear_sd;
 always @(posedge write_clk or posedge write_reset)begin
  if(write_reset)begin fifo_clear_meta<=1;fifo_clear_sd<=1;end
  else begin fifo_clear_meta<=fifo_reset;fifo_clear_sd<=fifo_clear_meta;end
 end
 reg full_to_source;
 // The producer can enqueue at most one word per write clock. Stop at the
 // previous clock's occupancy >=510, reserving the one word needed while the
 // full indication is registered. Synchronized read progress can only make
 // this estimate conservative. This cuts raw FIFO pointer subtraction from
 // the upstream cache/CRC/FAT ready and counter-enable paths.
 always @(posedge write_clk or posedge write_reset)begin
  if(write_reset)full_to_source<=1;
  else if(fifo_clear_sd)full_to_source<=1;
  else full_to_source<=fifo_full_raw || used_write>=9'd510;
 end
 assign write_fifo_full=full_to_source;
 reg [8:0] used_mem;
 // Cut FIFO pointer subtraction from the scheduler's remaining-length sum.
 // There is exactly one reader. While CHECK_FIFO waits, occupancy can only
 // grow; the one-cycle-old value is conservative. After a burst, the vendor
 // scheduler spends BURST/END cycles without reads before CHECK_FIFO resumes,
 // so this snapshot has caught up before the next burst decision. A FIFO clear
 // invalidates the snapshot too. The exact count (not a threshold bit) is kept
 // because the scheduler also tests the final partial/remaining burst length.
 always @(posedge mem_clk or posedge rst) begin
  if(rst) used_mem<=0;
  else if(fifo_reset) used_mem<=0;
  else used_mem<=used;
 end
 assign App_wr_dm=0;
 // Global/abort reset must invalidate the entire FIFO, including a short
 // prefix which never reached a burst. The IP synchronizes release per port.
 (* keep *) wire fifo_async_reset = rst || fifo_reset;
 wfifo_32_32_512 fifo(.clkr(mem_clk),.clkw(write_clk),.rst(fifo_async_reset),
  .we(write_en),.re(App_wr_en),.di(write_data),.empty_flag(),.full_flag(fifo_full_raw),
  .wrusedw(used_write),.rdusedw(used),.dout(App_wr_din));
 frame_fifo_write #(.MEM_DATA_BITS(32),.ADDR_BITS(21),.BURST_BITS(9),.BURST_SIZE(256),
  .WRITE_V_FLIP(1),.RUNTIME_LINEAR_MODE(AUDIO_WRITE_ENABLE),.FRAME_WIDTH(640),.FRAME_HEIGHT(480)) writer(
  .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(Sdr_init_done),.Sdr_init_ref_vld(Sdr_init_ref_vld),
  .Sdr_busy(Sdr_busy),.App_rd_busy(read_lock),.O_wr_busy(writer_busy),
  .App_wr_en(App_wr_en),.App_wr_addr(App_wr_addr),.write_req(request_held),
  .write_req_ack(write_req_ack),.write_finish(write_finish),
  .write_addr_0((AUDIO_WRITE_ENABLE && audio_base_mem)?21'd1228800:21'd0),
  .write_addr_1(21'd307200),.write_addr_2(21'd614400),.write_addr_3(21'd921600),
  .write_addr_index((AUDIO_WRITE_ENABLE && audio_mode_held)?2'd0:slot_held),
  .write_len((AUDIO_WRITE_ENABLE && audio_mode_held)?words_held:21'd307200),
  .linear_mode(AUDIO_WRITE_ENABLE && audio_mode_held),.fifo_aclr(fifo_reset),.rdusedw({1'b0,used_mem}));
endmodule
