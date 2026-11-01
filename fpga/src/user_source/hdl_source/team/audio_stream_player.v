`timescale 1ns/1ps
`default_nettype none

// Standalone candidate; see ../CONTRACT.md. No vendor IP or production edits.
module audio_stream_player #(
    parameter [20:0] AUDIO_BASE_WORDS = 21'd1228800,
    parameter [20:0] AUDIO_WORDS = 21'd524288,
    parameter integer MAX_CREDIT = 32
)(
    input wire pixel_clk, mem_clk, reset_n,
    input wire start, stop,
    input wire [20:0] clip_offset_words, clip_samples, resume_samples,
    input wire loop_enable, sample_tick,
    output wire ready,
    output reg signed [15:0] pcm16,
    output reg busy, done,
    output reg [20:0] position,
    // Source index associated with the held PCM, distinct from next-read progress.
    output reg [20:0] pcm_position,
    output reg [31:0] underflow_count,
    output wire fault,
    output wire rd_demand,
    output reg rd_lock,
    input wire rd_grant,
    output wire App_rd_en,
    output wire [20:0] App_rd_addr,
    input wire Sdr_rd_en,
    input wire [31:0] Sdr_rd_dout,
    input wire Sdr_init_done, Sdr_init_ref_vld, Sdr_busy
);
    // Common asynchronous assertion, independently synchronized deassertion.
    (* ASYNC_REG = "TRUE" *) reg [1:0] px_reset, mem_reset;
    always @(posedge pixel_clk or negedge reset_n)
        if (!reset_n) px_reset <= 2'b11;
        else px_reset <= {px_reset[0], 1'b0};
    always @(posedge mem_clk or negedge reset_n)
        if (!reset_n) mem_reset <= 2'b11;
        else mem_reset <= {mem_reset[0], 1'b0};
    wire prst = px_reset[1];
    wire mrst = mem_reset[1];

    // Bundled-data mailbox: payload is immutable until round-trip ACK.
    reg cmd_req, cmd_pending, cancel_pending;
    reg cmd_run, cmd_loop;
    reg [13:0] cmd_offset_block;
    reg [20:0] cmd_last;
    reg [11:0] cmd_resume_block;
    reg cmd_ack;
    (* ASYNC_REG = "TRUE" *) reg req_m1, req_m2, ack_p1, ack_p2;
    reg [1:0] published, consumed;
    // S27: delay only the first synchronizer input; keep pub_p1 -> pub_p2 direct.
    wire published1_hold;
    EG_LOGIC_BUF hold_published1(.i(published[1]),.o(published1_hold));
    // S41: place the bit-zero branch buffer before automatic hold repair.
    wire published0_hold;
    EG_LOGIC_BUF hold_published0(.i(published[0]),.o(published0_hold));
    (* ASYNC_REG = "TRUE" *) reg [1:0] pub_p1, pub_p2, con_m1, con_m2;
    reg mem_fault, pixel_fault;
    // S42: known short MEM-to-PIX branches participate in initial placement.
    wire cmd_ack_hold, mem_fault_hold;
    EG_LOGIC_BUF hold_cmd_ack(.i(cmd_ack),.o(cmd_ack_hold));
    EG_LOGIC_BUF hold_mem_fault(.i(mem_fault),.o(mem_fault_hold));
    (* ASYNC_REG = "TRUE" *) reg fault_p1, fault_p2;
    assign fault = pixel_fault | fault_p2;

    always @(posedge pixel_clk or posedge prst)
        if (prst) begin
            ack_p1 <= 0; ack_p2 <= 0;
            pub_p1 <= 0; pub_p2 <= 0;
            fault_p1 <= 0; fault_p2 <= 0;
        end else begin
            ack_p1 <= cmd_ack_hold; ack_p2 <= ack_p1;
            pub_p1 <= {published1_hold,published0_hold}; pub_p2 <= pub_p1;
            fault_p1 <= mem_fault_hold; fault_p2 <= fault_p1;
        end
    always @(posedge mem_clk or posedge mrst)
        if (mrst) begin
            req_m1 <= 0; req_m2 <= 0;
            con_m1 <= 0; con_m2 <= 0;
        end else begin
            req_m1 <= cmd_req; req_m2 <= req_m1;
            con_m1 <= consumed; con_m2 <= con_m1;
        end

    // Compare allocation in 512-byte blocks: no wide byte/word adders.
    // The parameter contract makes a valid relative range also an absolute one.
    wire [20:0] input_last_sample = clip_samples - 1'b1;
    wire [14:0] last_alloc_block = {1'b0, clip_offset_words[20:7]} +
                                   {3'b0, input_last_sample[20:9]};
    wire bad_command = (clip_offset_words[6:0] != 0) ||
                       (clip_offset_words[20:7] >= AUDIO_WORDS[20:7]) ||
                       ((clip_samples != 0) && (last_alloc_block >= {1'b0, AUDIO_WORDS[20:7]})) ||
                       (resume_samples > clip_samples);
    wire [20:0] normalized_resume = (loop_enable && resume_samples == clip_samples)
                                  ? 21'd0 : resume_samples;
    assign ready = !prst && !cmd_pending && !cancel_pending && !stop;

    reg playing, played_once, read_bank;
    reg [1:0] repeat_phase, warm;
    wire bank_available = (pub_p2[read_bank] != consumed[read_bank]);
    wire [7:0] ram_read_addr = {read_bank, position[8:2]};
    wire [31:0] ram_read_data;
    reg [7:0] ulaw_byte;
    always @* begin
        case (position[1:0])
            2'd0: ulaw_byte = ram_read_data[7:0];
            2'd1: ulaw_byte = ram_read_data[15:8];
            2'd2: ulaw_byte = ram_read_data[23:16];
            default: ulaw_byte = ram_read_data[31:24];
        endcase
    end
    wire signed [15:0] decoded;
    audio_ulaw_decode decode(.ulaw(ulaw_byte), .pcm(decoded));

    // All sample/position changes are in pixel_clk; sample_tick is an enable.
    always @(posedge pixel_clk or posedge prst) begin
        if (prst) begin
            cmd_req <= 0; cmd_pending <= 0; cancel_pending <= 0;
            cmd_run <= 0; cmd_loop <= 0;
            cmd_offset_block <= 0; cmd_last <= 0; cmd_resume_block <= 0;
            pcm16 <= 0; busy <= 0; done <= 0; position <= 0; pcm_position <= 0;
            underflow_count <= 0; pixel_fault <= 0;
            consumed <= 0; playing <= 0; played_once <= 0; read_bank <= 0;
            repeat_phase <= 0; warm <= 0;
        end else begin
            done <= 0;
            if (playing && bank_available) begin
                if (warm != 2'd3) warm <= warm + 1'b1;
            end else warm <= 0;

            if (stop) begin
                pcm16 <= 0; busy <= 0; playing <= 0; played_once <= 0;
                repeat_phase <= 0; warm <= 0;
                if (cmd_pending) begin
                    if (ack_p2 == cmd_req) begin
                        cancel_pending <= 0;
                        if (cmd_run) begin
                            cmd_run <= 0; cmd_req <= ~cmd_req;
                            consumed <= 0;
                        end else cmd_pending <= 0;
                    end else if (cmd_run) cancel_pending <= 1;
                end else if (playing || busy) begin
                    cmd_run <= 0; cmd_req <= ~cmd_req; cmd_pending <= 1;
                    consumed <= 0;
                end
            end else if (cmd_pending) begin
                pcm16 <= 0;
                if (ack_p2 == cmd_req) begin
                    if (cancel_pending) begin
                        cmd_run <= 0; cmd_req <= ~cmd_req; cancel_pending <= 0;
                        consumed <= 0;
                    end else begin
                        cmd_pending <= 0;
                        if (cmd_run) playing <= 1;
                        else if (busy) begin busy <= 0; done <= 1; end
                    end
                end
            end else if (start && ready) begin
                cmd_offset_block <= clip_offset_words[20:7];
                cmd_last <= input_last_sample;
                cmd_resume_block <= normalized_resume[20:9];
                cmd_loop <= loop_enable;
                cmd_run <= !bad_command && (clip_samples != 0) &&
                           (loop_enable || resume_samples != clip_samples);
                cmd_req <= ~cmd_req; cmd_pending <= 1;
                pcm16 <= 0; busy <= 1; playing <= 0; played_once <= 0;
                position <= normalized_resume;
                consumed <= 0; read_bank <= 0; repeat_phase <= 0; warm <= 0;
                if (bad_command) pixel_fault <= 1;
            end else if (sample_tick) begin
                if (!playing) pcm16 <= 0;
                else if ((repeat_phase == 0) && (!bank_available || warm != 3)) begin
                    pcm16 <= 0;
                    if (played_once && underflow_count != 32'hffffffff)
                        underflow_count <= underflow_count + 1'b1;
                end else begin
                    if (repeat_phase == 0) begin
                        pcm16 <= decoded; pcm_position <= position;
                        repeat_phase <= 1; played_once <= 1;
                    end else if (repeat_phase == 1) begin
                        repeat_phase <= 2;
                    end else begin
                        repeat_phase <= 0; warm <= 0;
                        if (position == cmd_last) begin
                            consumed[read_bank] <= pub_p2[read_bank];
                            read_bank <= ~read_bank;
                            if (cmd_loop) position <= 0;
                            else begin
                                position <= position + 1'b1; playing <= 0; busy <= 0; done <= 1;
                            end
                        end else begin
                            position <= position + 1'b1;
                            if (position[8:0] == 9'd511) begin
                                consumed[read_bank] <= pub_p2[read_bank];
                                read_bank <= ~read_bank;
                            end
                        end
                    end
                end
            end
        end
    end

    localparam [2:0] M_IDLE=0, M_WAIT=1, M_READ=2, M_RELEASE=3, M_DRAIN=4, M_APPLY=5,
                     M_REARM=6;
    reg [2:0] mstate;
    reg mem_active, mem_loop, write_bank;
    reg [13:0] base_block;
    reg [11:0] block_index, last_block;
    reg [7:0] issued;
    reg [6:0] received;
    reg [5:0] credit;
    wire new_command = req_m2 != cmd_ack;
    wire [13:0] command_base_block = AUDIO_BASE_WORDS[20:7] + cmd_offset_block;
    wire [13:0] fetch_block = base_block + {2'b00, block_index};
    assign App_rd_addr = {fetch_block, issued[6:0]};
    assign rd_demand = !mrst && !new_command &&
                       ((mstate == M_WAIT) || (mstate == M_READ) || (mstate == M_RELEASE));
    // busy is deliberately absent: it is NOT a per-word ready signal.
    assign App_rd_en = !mrst && !new_command && (mstate == M_READ) && rd_grant &&
                       Sdr_init_done && !Sdr_init_ref_vld && (issued < 8'd128) &&
                       (credit < MAX_CREDIT);
    wire valid_return = Sdr_rd_en && ((credit != 0) || App_rd_en);
    wire ram_write_en = !mrst && !new_command && (mstate == M_READ) && valid_return;
    audio_bank_ram banks(
        .write_clk(mem_clk), .write_en(ram_write_en),
        .write_addr({write_bank, received[6:0]}), .write_data(Sdr_rd_dout),
        .read_clk(pixel_clk), .read_addr(ram_read_addr), .read_data(ram_read_data)
    );

    always @(posedge mem_clk or posedge mrst) begin
        if (mrst) begin
            cmd_ack <= 0; published <= 0; mem_fault <= 0;
            mstate <= M_IDLE; mem_active <= 0; mem_loop <= 0; write_bank <= 0;
            base_block <= 0; block_index <= 0; last_block <= 0;
            issued <= 0; received <= 0; credit <= 0; rd_lock <= 0;
        end else begin
            if (App_rd_en != valid_return)
                credit <= credit + (App_rd_en ? 6'd1 : 6'd63);
            if (Sdr_rd_en && !valid_return) mem_fault <= 1;
            if (App_rd_en) issued <= issued + 1'b1;
            if (valid_return) received <= received + 1'b1;

            // Commands override publication, but never erase outstanding credit.
            if (new_command && mstate != M_DRAIN && mstate != M_APPLY && mstate != M_REARM) begin
                mstate <= M_DRAIN; mem_active <= 0;
            end else case (mstate)
                M_IDLE: if (mem_active && published[write_bank] == con_m2[write_bank]) begin
                    rd_lock <= 1; mstate <= M_WAIT;
                end
                M_WAIT: if (rd_grant && Sdr_init_done && !Sdr_init_ref_vld && !Sdr_busy) begin
                    rd_lock <= 1; issued <= 0; received <= 0; mstate <= M_READ;
                end
                M_READ: if (valid_return && received == 7'd127) begin
                    published[write_bank] <= ~published[write_bank];
                    write_bank <= ~write_bank;
                    if (block_index == last_block) begin
                        if (mem_loop) block_index <= 0;
                        else mem_active <= 0;
                    end else block_index <= block_index + 1'b1;
                    mstate <= M_RELEASE;
                end
                M_RELEASE: if (credit == 0 && !Sdr_busy && !Sdr_rd_en) begin
                    rd_lock <= 0; mstate <= M_REARM;
                end
                M_DRAIN: if (credit == 0 && !Sdr_busy && !Sdr_rd_en) begin
                    rd_lock <= 0; mstate <= M_REARM;
                end
                M_REARM: if (!rd_grant) begin
                    if (new_command) mstate <= M_APPLY;
                    else mstate <= M_IDLE;
                end
                M_APPLY: begin
                    published <= 0; write_bank <= 0;
                    issued <= 0; received <= 0;
                    base_block <= command_base_block;
                    block_index <= cmd_resume_block;
                    last_block <= cmd_last[20:9];
                    mem_loop <= cmd_loop; mem_active <= cmd_run;
                    cmd_ack <= req_m2; mstate <= M_IDLE;
                end
                default: mstate <= M_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_CREDIT < 1 || MAX_CREDIT > 32) $fatal(1, "MAX_CREDIT must be 1..32");
        if (AUDIO_BASE_WORDS[6:0] != 0 || AUDIO_WORDS[6:0] != 0 || AUDIO_WORDS == 0)
            $fatal(1, "audio base/capacity must be nonzero-capacity 128-word aligned");
        if ({1'b0,AUDIO_BASE_WORDS} + {1'b0,AUDIO_WORDS} > 22'd2097152)
            $fatal(1, "audio allocation exceeds 21-bit word address bus");
    end
`endif
endmodule

module audio_ulaw_decode(input wire [7:0] ulaw, output wire signed [15:0] pcm);
    wire [7:0] inv = ~ulaw;
    // G.711 output is divisible by four. Work in 14 bits, sharing the signed
    // bias adder: positive t-33, negative ~t+34 == 33-t.
    wire [13:0] biased = {8'd0,1'b1,inv[3:0],1'b1} << inv[6:4];
    wire [13:0] signed_base = biased ^ {14{inv[7]}};
    wire [13:0] scaled_pcm = signed_base + (inv[7] ? 14'd34 : 14'h3fdf);
    assign pcm = {scaled_pcm,2'b00};
endmodule

// One 8192-bit simple dual-port, dual-clock memory. No array reset or extra ROM.
module audio_bank_ram(
    input wire write_clk, write_en,
    input wire [7:0] write_addr,
    input wire [31:0] write_data,
    input wire read_clk,
    input wire [7:0] read_addr,
    output reg [31:0] read_data
);
    (* ram_style = "block", ramstyle = "block" *) reg [31:0] memory [0:255];
    always @(posedge write_clk) if (write_en) memory[write_addr] <= write_data;
    always @(posedge read_clk) read_data <= memory[read_addr];
endmodule
`default_nettype wire
