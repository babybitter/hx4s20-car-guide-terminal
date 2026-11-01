// New standalone team RTL. Interface/address/packing provenance is documented
// in docs/test-results/story-model.md. Does not instantiate or replace SDRAM IP.
module story_dual_source #(
    parameter integer MAX_INFLIGHT=32,
    parameter integer WATCHDOG_CYCLES=100000
)(
    input wire mem_clk, pixel_clk, rst,
    // One App_rd_en edge is one ACCEPTED 32-bit WORD address, not a burst.
    // Grant is supplied by an external arbiter, never inferred as an IP ACK.
    input wire read_grant, vendor_wr_busy, vendor_wr_en, refresh_block,
    input wire Sdr_init_done, Sdr_busy,
    output wire read_demand, read_lock,
    output wire App_rd_en, output wire [20:0] App_rd_addr,
    input wire Sdr_rd_en, input wire [31:0] Sdr_rd_dout,
    output reg fault_mem, output reg [2:0] fault_code_mem,
    output wire fault_pixel,
    // Pixel-domain mailbox: a bank remains owned until explicit release.
    input wire job_valid, output wire job_ready, input wire job_bank,
    input wire [1:0] job_slot_a, job_slot_b,
    input wire [8:0] job_y_a, job_y_b,
    input wire [1:0] job_sources, input wire [15:0] job_tag,
    output reg job_reject, output reg [1:0] job_done,
    output reg [1:0] bank_owned, output reg [1:0] line_ready,
    input wire release_valid, input wire release_bank, output wire release_ready,
    // One sample/cycle, fixed latency: output one edge after sample capture.
    input wire sample_valid, sample_bank,
    input wire [15:0] sample_tag,
    input wire [1:0] sample_slot_a, sample_slot_b, sample_need,
    input wire [9:0] sample_x_a, sample_x_b, sample_x,
    input wire [8:0] sample_y_a, sample_y_b, sample_y, sample_alpha,
    output reg out_valid, out_good,
    output reg [23:0] rgb_a, rgb_b,
    output reg [1:0] out_need, output reg [8:0] out_alpha,
    output reg [95:0] out_provenance
);
    // Common reset asserts asynchronously; each domain releases on its own
    // two-clock pipeline. The top may combine independent PLL-domain resets.
    reg [1:0] reset_mem,reset_pixel;
    always @(posedge mem_clk or posedge rst)
        if(rst)reset_mem<=2'b11;else reset_mem<={reset_mem[0],1'b0};
    always @(posedge pixel_clk or posedge rst)
        if(rst)reset_pixel<=2'b11;else reset_pixel<={reset_pixel[0],1'b0};
    wire rst_m=reset_mem[1],rst_p=reset_pixel[1];
    // Only the request toggle is synchronized. Descriptor is held unchanged
    // from job acceptance until completion AND release (bundled-data mailbox).
    reg [1:0] req_toggle, done_toggle, done_ok;
    // S27: delay only the input of the first pixel-domain synchronizer.
    wire done_toggle1_hold;
    EG_LOGIC_BUF hold_done_toggle1(.i(done_toggle[1]),.o(done_toggle1_hold));
    // S42: bit zero previously appeared in a physical hold violation.
    wire done_toggle0_hold;
    EG_LOGIC_BUF hold_done_toggle0(.i(done_toggle[0]),.o(done_toggle0_hold));
    reg [1:0] req_meta, req_sync, done_meta, done_sync;
    reg [1:0] pending;
    reg fault_meta, fault_sync;
    // S43: place the observed short MEM-to-PIX fault branch before routing.
    wire fault_mem_pixel_hold;
    EG_LOGIC_BUF hold_fault_mem_pixel(.i(fault_mem),.o(fault_mem_pixel_hold));
    reg [1:0] slot_a_box [0:1], slot_b_box [0:1], sources_box [0:1];
    reg [8:0] y_a_box [0:1], y_b_box [0:1];
    reg [15:0] tag_box [0:1];
    reg sample_d, good_d, bank_d;
    reg [1:0] need_d;
    reg [8:0] alpha_d;
    reg [95:0] provenance_d;
    wire descriptor_ok=(job_sources!=0) &&
        (!job_sources[0] || job_y_a<480) && (!job_sources[1] || job_y_b<480);
    assign fault_pixel=fault_sync;
    assign job_ready=!bank_owned[job_bank] && !fault_sync && !rst_p;
    assign release_ready=bank_owned[release_bank] && !pending[release_bank] &&
        !(sample_valid && sample_bank==release_bank) &&
        !(sample_d && bank_d==release_bank);
    wire sample_ok=line_ready[sample_bank] && !fault_sync &&
        (sample_tag==tag_box[sample_bank]) && (sample_need!=0) &&
        ((sample_need & sources_box[sample_bank])==sample_need) &&
        (!sample_need[0] || ((sample_x_a<640) &&
            (sample_y_a==y_a_box[sample_bank]) && (sample_slot_a==slot_a_box[sample_bank]))) &&
        (!sample_need[1] || ((sample_x_b<640) &&
            (sample_y_b==y_b_box[sample_bank]) && (sample_slot_b==slot_b_box[sample_bank])));
    wire ram_read=sample_valid && sample_ok && !rst_p;
    wire [23:0] a0, a1, b0, b1;
    integer p;
    always @(posedge pixel_clk or posedge rst_p) begin
        if (rst_p) begin
            req_toggle<=0; done_meta<=0; done_sync<=0; pending<=0;
            fault_meta<=0; fault_sync<=0; bank_owned<=0; line_ready<=0;
            job_done<=0; job_reject<=0;
            sample_d<=0; good_d<=0; bank_d<=0; need_d<=0; alpha_d<=0; provenance_d<=0;
            out_valid<=0; out_good<=0; rgb_a<=0; rgb_b<=0;
            out_need<=0; out_alpha<=0; out_provenance<=0;
            for (p=0;p<2;p=p+1) begin
                slot_a_box[p]<=0; slot_b_box[p]<=0; sources_box[p]<=0;
                y_a_box[p]<=0; y_b_box[p]<=0; tag_box[p]<=0;
            end
        end else begin
            done_meta<={done_toggle1_hold,done_toggle0_hold}; done_sync<=done_meta;
            fault_meta<=fault_mem_pixel_hold; fault_sync<=fault_meta;
            job_done<=0; job_reject<=0;
            for (p=0;p<2;p=p+1) begin
                if (pending[p] && done_sync[p]==req_toggle[p]) begin
                    pending[p]<=0; job_done[p]<=1;
                    line_ready[p]<=done_ok[p] && !fault_sync;
                end
            end
            if (fault_sync) line_ready<=0;
            if (release_valid && release_ready) begin
                bank_owned[release_bank]<=0; line_ready[release_bank]<=0;
            end
            if (job_valid && job_ready) begin
                if (!descriptor_ok) job_reject<=1;
                else begin
                    bank_owned[job_bank]<=1; pending[job_bank]<=1; line_ready[job_bank]<=0;
                    slot_a_box[job_bank]<=job_slot_a; slot_b_box[job_bank]<=job_slot_b;
                    y_a_box[job_bank]<=job_y_a; y_b_box[job_bank]<=job_y_b;
                    sources_box[job_bank]<=job_sources; tag_box[job_bank]<=job_tag;
                    req_toggle[job_bank]<=!req_toggle[job_bank];
                end
            end
            sample_d<=sample_valid; good_d<=sample_ok; bank_d<=sample_bank;
            need_d<=sample_need; alpha_d<=sample_alpha;
            provenance_d<={sample_tag,sample_need,slot_a_box[sample_bank],slot_b_box[sample_bank],
                y_a_box[sample_bank],y_b_box[sample_bank],sample_x_a,sample_x_b,
                sample_x,sample_y,sample_bank,16'd0};
            out_valid<=sample_d;
            out_good<=sample_d && good_d && !fault_sync;
            rgb_a<=(sample_d && good_d && need_d[0] && !fault_sync) ? (bank_d ? a1:a0):24'd0;
            rgb_b<=(sample_d && good_d && need_d[1] && !fault_sync) ? (bank_d ? b1:b0):24'd0;
            out_need<=need_d; out_alpha<=alpha_d; out_provenance<=provenance_d;
        end
    end

    reg active, active_bank, source_b, prefer_bank;
    reg [1:0] active_sources, active_slot_a, active_slot_b;
    reg [8:0] active_y_a, active_y_b;
    localparam integer CREDIT_WIDTH=(MAX_INFLIGHT<2)?1:$clog2(MAX_INFLIGHT+1);
    localparam integer WATCHDOG_WIDTH=(WATCHDOG_CYCLES<2)?1:$clog2(WATCHDOG_CYCLES);
    reg [9:0] issued, returned;
    // S27: only ram_b1 write-address bit9; counters and other RAMs stay direct.
    wire returned9_b1_hold;
    EG_LOGIC_BUF hold_returned9_b1(.i(returned[9]),.o(returned9_b1_hold));
    reg [CREDIT_WIDTH-1:0] outstanding;
    reg [WATCHDOG_WIDTH-1:0] idle_cycles;
    // Registered predicates describe the CURRENT counters, not a delayed
    // admission decision. External grant/refresh/write pins gate this edge.
    reg issue_open, issued_any, credit_nonzero, credit_room, last_return;
    reg watchdog_last;
    wire pending0=req_sync[0]!=done_toggle[0];
    wire pending1=req_sync[1]!=done_toggle[1];
    wire pick_bank=(pending0 && pending1) ? prefer_bank : pending1;
    function [20:0] slot_base;
        input [1:0] slot;
        begin
            case (slot)
                0: slot_base=21'd0;
                1: slot_base=21'd307200;
                2: slot_base=21'd614400;
                default: slot_base=21'd921600;
            endcase
        end
    endfunction
    wire [20:0] row_offset=source_b ? ({12'd0,active_y_b}*21'd640) : ({12'd0,active_y_a}*21'd640);
    assign App_rd_addr=slot_base(source_b ? active_slot_b:active_slot_a)+row_offset+issued;
    assign read_demand=active && issue_open && !fault_mem;
    assign read_lock=active || credit_nonzero;
    // Sdr_busy reports the controller's active operation, NOT per-word ready.
    // Gating every word with it breaks pipelined reads into four-word groups.
    // The official word interface pipelines App_rd_en while busy is asserted.
    // Keep arbitration, initialization, refresh, writer exclusion and credit.
    // See docs/test-results/transition-recovery-s17.md for exported-net evidence.
    assign App_rd_en=read_demand && read_grant && Sdr_init_done &&
        !refresh_block && !vendor_wr_busy && !vendor_wr_en && credit_room;
    // active has asynchronous reset and only rises after a synchronized job.
    // A second combinational rst_m gate is redundant and used to put reset's
    // fanout through App_rd_en/return_ok into fault_mem's synchronous D path.
    wire return_ok=Sdr_rd_en && active && (credit_nonzero || App_rd_en) && !fault_mem;
    // A live source has at most 640 accepted requests; the last return retires
    // it on this edge. No accepted return can address beyond 639.
    wire memory_write=return_ok;
    wire unexpected_return=Sdr_rd_en && (!active || (!credit_nonzero && !App_rd_en));
    wire init_lost=active && issued_any && !Sdr_init_done;
    wire progress=App_rd_en || return_ok;
    wire timeout_now=active && watchdog_last && !progress;
    wire load_job=!active && !fault_mem && !unexpected_return && (pending0 || pending1);
    wire transfer_run=active && !fault_mem && !unexpected_return && !init_lost;
    wire next_source=transfer_run && return_ok && last_return && !source_b && active_sources[1];
    story_line_ram ram_a0(.mem_clk(mem_clk),.wr_en(memory_write && !source_b && !active_bank),
        .wr_x(returned),.wr_rgb(Sdr_rd_dout[31:8]),.pixel_clk(pixel_clk),
        .rd_en(ram_read && !sample_bank && sample_need[0]),.rd_x(sample_x_a),.rd_rgb(a0));
    story_line_ram ram_a1(.mem_clk(mem_clk),.wr_en(memory_write && !source_b && active_bank),
        .wr_x(returned),.wr_rgb(Sdr_rd_dout[31:8]),.pixel_clk(pixel_clk),
        .rd_en(ram_read && sample_bank && sample_need[0]),.rd_x(sample_x_a),.rd_rgb(a1));
    story_line_ram ram_b0(.mem_clk(mem_clk),.wr_en(memory_write && source_b && !active_bank),
        .wr_x(returned),.wr_rgb(Sdr_rd_dout[31:8]),.pixel_clk(pixel_clk),
        .rd_en(ram_read && !sample_bank && sample_need[1]),.rd_x(sample_x_b),.rd_rgb(b0));
    story_line_ram ram_b1(.mem_clk(mem_clk),.wr_en(memory_write && source_b && active_bank),
        .wr_x({returned9_b1_hold,returned[8:0]}),.wr_rgb(Sdr_rd_dout[31:8]),.pixel_clk(pixel_clk),
        .rd_en(ram_read && sample_bank && sample_need[1]),.rd_x(sample_x_b),.rd_rgb(b1));

    // Payload/counters are initialized before active can admit a transfer.
    // They need no asynchronous reset: ownership/readiness and the small
    // control predicates above invalidate them across coordinated reset.
    always @(posedge mem_clk) begin
        if (load_job) begin
            active_bank<=pick_bank;
            active_sources<=sources_box[pick_bank];
            active_slot_a<=slot_a_box[pick_bank]; active_slot_b<=slot_b_box[pick_bank];
            active_y_a<=y_a_box[pick_bank]; active_y_b<=y_b_box[pick_bank];
        end
        if (load_job || next_source) begin
            issued<=0; returned<=0; outstanding<=0;
        end else if (transfer_run) begin
            case ({App_rd_en,return_ok})
                2'b10: outstanding<=outstanding+1'b1;
                2'b01: outstanding<=outstanding-1'b1;
                default: begin end
            endcase
            if (App_rd_en) issued<=issued+1'b1;
            if (return_ok) returned<=returned+1'b1;
        end
        if (!active || fault_mem || progress) idle_cycles<=0;
        else if (transfer_run && !watchdog_last) idle_cycles<=idle_cycles+1'b1;
    end

    // Decode one cycle before expiry, in parallel with incrementing the
    // bounded counter. The fault FSM sees a one-bit flag, not a 32-bit adder
    // and terminal decode. Progress on the exact deadline still wins.
    always @(posedge mem_clk or posedge rst_m) begin
        if (rst_m) watchdog_last<=(WATCHDOG_CYCLES==1);
        else if (!active || fault_mem || progress) watchdog_last<=(WATCHDOG_CYCLES==1);
        else if (transfer_run && !watchdog_last)
            watchdog_last<=(idle_cycles==WATCHDOG_CYCLES-2);
    end
    always @(posedge mem_clk or posedge rst_m) begin
        if (rst_m) begin fault_mem<=0; fault_code_mem<=0; end
        else if (!fault_mem) begin
            if (unexpected_return) begin fault_mem<=1; fault_code_mem<=2; end
            else if (init_lost) begin fault_mem<=1; fault_code_mem<=3; end
            else if (timeout_now) begin fault_mem<=1; fault_code_mem<=1; end
        end
    end

    always @(posedge mem_clk or posedge rst_m) begin
        if (rst_m) begin
            req_meta<=0; req_sync<=0; done_toggle<=0; done_ok<=0;
            active<=0; source_b<=0; prefer_bank<=0;
            issue_open<=0; issued_any<=0; credit_nonzero<=0; credit_room<=1; last_return<=0;
        end else begin
            req_meta<=req_toggle; req_sync<=req_meta;
            if (fault_mem) begin
                // Untagged late returns cannot safely be assigned to a new job.
                // Quarantine until a coordinated controller + both-domain reset.
                active<=0; done_ok<=0; done_toggle<=req_sync;
            end else if (unexpected_return || init_lost) begin
                // The fault register above latches on THIS edge. Freeze the
                // in-flight ledger; never recycle untagged returns after it.
            end else if (!active) begin
                if (pending0 || pending1) begin
                    active<=1; prefer_bank<=!pick_bank;
                    source_b<=!sources_box[pick_bank][0];
                    issue_open<=1; issued_any<=0; credit_nonzero<=0; credit_room<=1; last_return<=0;
                    done_ok[pick_bank]<=0;
                end
            end else begin
                case ({App_rd_en,return_ok})
                    2'b10: begin
                        credit_nonzero<=1;
                        credit_room<=(outstanding<MAX_INFLIGHT-1);
                    end
                    2'b01: begin credit_nonzero<=(outstanding!=1); credit_room<=1; end
                    default: begin end
                endcase
                if (App_rd_en) begin issued_any<=1; issue_open<=(issued!=639); end
                if (return_ok) begin
                    last_return<=(returned==638);
                    if (last_return) begin
                        if (!source_b && active_sources[1]) begin
                            source_b<=1;
                            issue_open<=1; issued_any<=0; credit_nonzero<=0; credit_room<=1; last_return<=0;
                        end else begin
                            active<=0; done_ok[active_bank]<=1;
                            done_toggle[active_bank]<=req_sync[active_bank];
                        end
                    end
                end
            end
        end
    end
endmodule
