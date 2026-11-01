`timescale 1ns/1ps
// MEDIA-08 adapter. Connect fs_* to fat32_ro_reader, never to raw LBA logic.
// Strict 640x480 BGR24 BMP -> 307200 RGB0 words. See media-v2-contract.md.
module catalog_frame_loader #(
    parameter integer STALL_TIMEOUT_CYCLES = 500000000
) (
    input wire clk, input wire rst,
    input wire start_req, output wire start_ready, output reg preload_done,
    output reg ready, output reg error, output reg [7:0] error_code,
    output reg [7:0] source_error_code, output reg [7:0] logical_count,
    input wire page_req, output wire page_ready, input wire [6:0] page_id,
    output reg page_done, output wire page_ack,
    output reg [6:0] result_id, output reg [1:0] result_slot,
    input wire display_valid, input wire [1:0] display_slot,
    input wire target_valid, input wire [1:0] target_slot,
    output wire loading, output reg [1:0] write_slot,
    output reg [3:0] slot_valid,
    output wire [27:0] slot_ids,
    input wire fs_mounted, input wire [7:0] fs_file_count,
    output wire [6:0] fs_catalog_id,
    input wire fs_catalog_valid, input wire [31:0] fs_catalog_size,
    output wire fs_read_req, input wire fs_read_ready,
    output wire [6:0] fs_read_id,
    output wire [31:0] fs_read_offset, output wire [31:0] fs_read_length,
    input wire fs_read_done, input wire fs_error, input wire [7:0] fs_error_code,
    input wire fs_out_valid, output wire fs_out_ready,
    input wire [7:0] fs_out_data, input wire [31:0] fs_out_offset,
    input wire fs_out_last,
    output wire write_req, input wire write_req_ack,
    output wire write_en, output wire [31:0] write_data,
    input wire write_fifo_full, input wire write_finish_toggle
);
    localparam [4:0] OFF=0, SELECT=1, META=2, H_START=3, H_REQ=4,
        H_STREAM=5, H_VALIDATE=6, H_RESULT=7, W_REQ=8, W_ACK_LOW=9,
        P_REQ=10, P_STREAM=11, COMMIT=12, IDLE=13, FAILED=14, REPLY=15,
        H_COMPLETE=16,P_COMPLETE=17,SELECT_LOOKUP=18,META_CHECK=19;
    localparam [7:0] E_EMPTY=1, E_ID=2, E_META=3, E_HEADER=4, E_SOURCE=5,
        E_PROTOCOL=6, E_TIMEOUT=7, E_EARLY_FINISH=8, E_LOCK=9, E_UNMOUNT=10;
    localparam [31:0] FILE_BYTES=921654, PIXEL_BYTES=921600;
    // Explicit one-hot state bits cut shared binary state decode fanout.
    reg [19:0] state;
    reg state_changed_q, timeout_active_q;
    reg metadata_size_ok;
    reg [6:0] slot_page[0:3];
    reg [6:0] load_id;
    reg preloading, writer_active, drained, source_complete, last_seen;
    reg [2:0] preload_goal, preload_index;
    reg [9:0] header_bytes;
    reg [19:0] pixel_bytes;
    reg [18:0] pixels;
    reg [1:0] phase;
    reg [7:0] blue, green;
        // S34: preserve 32-bit behavior for exceptional effective integer limits.
    // inclusive=1 includes the increment on the timeout/exit edge (count=L).
    // No limit+1 arithmetic: INT_MAX must not overflow during width selection.
    function integer bounded_timeout_width;
        input integer limit;
        input integer inclusive;
        integer remaining;
        begin
            bounded_timeout_width=32;
            if(limit>1) begin
                bounded_timeout_width=0;
                for(remaining=inclusive ? limit : limit-1;
                    remaining>0;remaining=remaining>>1)
                    bounded_timeout_width=bounded_timeout_width+1;
            end
        end
    endfunction
reg [bounded_timeout_width(STALL_TIMEOUT_CYCLES,1)-1:0] stall_cycles;
    reg stall_expired,protocol_fault,finish_pending,finish_early;
    reg [19:0] expected_offset;
    reg header_closed,pixel_open,last_expected;
    reg [2:0] finish_sync;
    wire finish_pulse=finish_sync[2]^finish_sync[1];
    wire protected_slot=(display_valid && display_slot==write_slot) ||
        (target_valid && target_slot==write_slot);
    wire header_done, header_ok;
    reg victim_found, hit_found;
    reg [1:0] victim, hit;
    reg hit_found_q;
    reg [1:0] hit_q;
    integer i, reset_index;
    always @* begin
        victim_found=0;victim=0;hit_found=0;hit=0;
        // Prefer an invalid unprotected slot, then lowest-numbered victim.
        for(i=0;i<4;i=i+1) begin
            if(slot_valid[i] && slot_page[i]==load_id) begin hit_found=1;hit=i;end
            if(!victim_found && !slot_valid[i] &&
               !(display_valid && display_slot==i) && !(target_valid && target_slot==i)) begin
                victim_found=1;victim=i;
            end
        end
        if(!preloading && !victim_found)
            for(i=0;i<4;i=i+1)
                if(!victim_found && !(display_valid && display_slot==i) &&
                   !(target_valid && target_slot==i)) begin victim_found=1;victim=i;end
    end
    assign start_ready=state[OFF] && fs_mounted;
    assign page_ready=state[IDLE] && ready && fs_mounted;
    assign page_ack=state[REPLY] && !error && slot_valid[result_slot] &&
        slot_page[result_slot]==result_id;
    // One-hot classification has no shared next-state CE or held register.
    assign loading=(|state[12:2]) || state[H_COMPLETE] ||
        state[P_COMPLETE] || state[META_CHECK];
    assign slot_ids={slot_page[3],slot_page[2],slot_page[1],slot_page[0]};
    assign fs_catalog_id=load_id;
    assign fs_read_id=load_id;
    assign fs_read_req=state[H_REQ] || state[P_REQ];
    assign fs_read_offset=state[H_REQ] ? 32'd0 : 32'd54;
    assign fs_read_length=state[H_REQ] ? 32'd512 : PIXEL_BYTES;
    // FAILED drains any source response without writing. Recovery requires the
    // integrator to reset/cancel the reader and SDRAM writer as well as this FSM.
    wire stream_ready_unlocked=!protocol_fault && !finish_pending &&
        (state[H_STREAM] || (state[P_STREAM] && (phase!=2 || !write_fifo_full)));
    assign fs_out_ready=state[FAILED] ||
        (stream_ready_unlocked && (!state[P_STREAM] || !protected_slot));
    // A lock collision in P_STREAM/W_REQ already wins E_LOCK before timeout.
    // Only the private watchdog may observe unlocked progress on that fatal
    // edge; the real ready/request/write gates remain immediately protected.
    wire watchdog_take=fs_out_valid && (state[FAILED] || stream_ready_unlocked);
    wire take=fs_out_valid && fs_out_ready;
    assign write_req=state[W_REQ] && !protected_slot;
    assign write_en=state[P_STREAM] && take && phase==2 &&
        pixel_open && !protected_slot;
    assign write_data={fs_out_data,green,blue,8'h00};
    wire progress=state_changed_q || watchdog_take ||
        (fs_read_req && fs_read_ready) || (state[W_REQ] && write_req_ack) ||
        (state[W_ACK_LOW] && !write_req_ack) || fs_read_done ||
        (writer_active && (finish_pulse || finish_pending));
    wire timeout_now=(STALL_TIMEOUT_CYCLES<=1)?1'b1:stall_expired;
    // All fatal transitions disable this private watchdog. Its D equation
    // needs no error-priority mux and no set_state transition clock-enable.
    // The original FSM below still selects every error and public update.
    wire timeout_abort=((state[H_STREAM] || state[P_STREAM]) && fs_read_done && fs_error) ||
        (loading && protected_slot) || (timeout_active_q && !progress && timeout_now) ||
        (writer_active && !state[FAILED] && finish_pending && finish_early) ||
        (protocol_fault && !state[FAILED]);
    wire timeout_leave=(state[SELECT] && !preloading && hit_found_q) ||
        (state[META_CHECK] && !metadata_size_ok) ||
        (state[H_COMPLETE] && (header_bytes!=512 || !last_seen)) ||
        (state[H_RESULT] && header_done && !header_ok) ||
        (state[P_COMPLETE] && (pixel_bytes!=PIXEL_BYTES || pixels!=307200 || !last_seen)) ||
        (state[COMMIT] && source_complete && drained && pixels==307200 &&
         !(preloading && preload_index+1<preload_goal));
    wire timeout_enter=(state[OFF] && start_req && fs_file_count!=0 && fs_file_count<=128) ||
        (state[IDLE] && page_req && ready && {1'b0,page_id}<logical_count);
    // For every reachable one-hot state this is exactly the next-state class.
    // Unmount is factored at the final AND; OFF/IDLE entries also need mounted.
    wire next_timeout_active=fs_mounted && !timeout_abort && !timeout_leave &&
        ((|state[12:1]) || (|state[19:16]) || timeout_enter);
    always @(posedge clk or posedge rst) begin
        if(rst) timeout_active_q<=1'b0;
        else timeout_active_q<=next_timeout_active;
    end
    bmp_header_validator u_header (
        .clk(clk),.rst(rst),.start(state[H_START]),
        .byte_valid(state[H_STREAM] && take),.byte_index(header_bytes[8:0]),
        .byte_data(fs_out_data),.sector_done(state[H_VALIDATE]),
        .done(header_done),.accepted(header_ok)
    );
    // Every reachable set_state call is a transition, never a self-loop.
    // Avoid feeding the current state through a dynamic indexed test into
    // this pulse. A held state still clears it in the enclosing always block.
    task set_state;
        input [4:0] next_tag;
        begin
            state<=(20'd1 << next_tag);
            state_changed_q<=1'b1;
        end
    endtask
    task fatal_load;
        input [7:0] code;
        begin
            error<=1;error_code<=code;ready<=0;set_state(FAILED);
            if(writer_active) slot_valid[write_slot]<=0;
            if(preloading) preload_done<=1;else page_done<=1;
        end
    endtask
    // Private payload bookkeeping is not qualified by the global fatal
    // decoder. In a live transaction these are the same accepted-beat updates
    // as the FSM. If a fatal edge coincides with a beat/start, a private value
    // may change; that same edge enters FAILED, which has no exit except reset.
    // FAILED never consumes these values, never publishes a slot, and drains
    // via its original ready gate. All private state is reset before reuse.
    // Do not move blue/green here: write_data exposes them even when invalid.
    // Public ready/write/protection, fatal priority and watchdog stay unchanged.
    wire header_payload_start=state[META_CHECK] && metadata_size_ok;
    wire pixel_payload_start=state[H_RESULT] && header_done && header_ok;
    wire header_take=state[H_STREAM] && take;
    wire pixel_take=state[P_STREAM] && take;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            expected_offset<=0;header_bytes<=0;pixel_bytes<=0;pixels<=0;phase<=0;
            last_seen<=0;header_closed<=0;pixel_open<=0;last_expected<=0;
        end else begin
            if(state[H_START])expected_offset<=0;
            else if(state[P_REQ] && fs_read_ready)expected_offset<=54;
            else if(header_take || pixel_take)expected_offset<=expected_offset+1'b1;
            if(header_payload_start)header_bytes<=0;
            else if(header_take)header_bytes<=header_bytes+1'b1;
            if(pixel_payload_start)begin pixel_bytes<=0;pixels<=0;phase<=0;end
            else if(pixel_take)begin
                pixel_bytes<=pixel_bytes+1'b1;
                case(phase)
                    0:phase<=1;
                    1:phase<=2;
                    2:begin phase<=0;pixels<=pixels+1'b1;end
                    default:phase<=0;
                endcase
            end
            if(header_payload_start || pixel_payload_start)last_seen<=0;
            else if((header_take || pixel_take) && fs_out_last)last_seen<=1;
            if(state[H_START])header_closed<=0;
            else if(header_take && header_bytes==511)header_closed<=1;
            if(pixel_payload_start)pixel_open<=1;
            else if(pixel_take && pixel_bytes==PIXEL_BYTES-1)pixel_open<=0;
            if(state[H_START] || pixel_payload_start)last_expected<=0;
            else if((header_take && header_bytes==510) ||
                    (pixel_take && pixel_bytes==PIXEL_BYTES-2))last_expected<=1;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            set_state(OFF);state_changed_q<=0;preload_done<=0;page_done<=0;
            ready<=0;error<=0;error_code<=0;source_error_code<=0;logical_count<=0;
            result_id<=0;result_slot<=0;write_slot<=0;slot_valid<=0;
            for(reset_index=0;reset_index<4;reset_index=reset_index+1) slot_page[reset_index]<=0;
            load_id<=0;preloading<=0;writer_active<=0;drained<=0;source_complete<=0;
            preload_goal<=0;preload_index<=0;
            hit_found_q<=0;hit_q<=0;metadata_size_ok<=0;
            blue<=0;green<=0;
            stall_cycles<=0;finish_sync<=0;
            stall_expired<=0;protocol_fault<=0;finish_pending<=0;finish_early<=0;
        end else begin
            finish_sync<={finish_sync[1:0],write_finish_toggle};
            finish_pending<=writer_active && finish_pulse;
            // Count at the observed finish edge, BEFORE any coincident word.
            // A later counter update must never hide a premature finish.
            if(writer_active && finish_pulse)finish_early<=pixels!=307200;
            protocol_fault<=0;
            // Stop the accepted-byte protocol path at one local register.
            if(take && (state[H_STREAM] || state[P_STREAM]))begin
                protocol_fault<=fs_out_offset!={12'd0,expected_offset} || fs_out_last!=last_expected ||
                    (state[H_STREAM] ? header_closed:!pixel_open);
            end
            state_changed_q<=0;preload_done<=0;page_done<=0;
            if(progress || !timeout_active_q)begin
                stall_cycles<=0;stall_expired<=0;
            end else begin
                stall_cycles<=stall_cycles+1;
                stall_expired<=stall_cycles>=(STALL_TIMEOUT_CYCLES<=1?0:STALL_TIMEOUT_CYCLES-2);
            end
            if((state[H_STREAM] || state[P_STREAM]) && fs_read_done && fs_error) begin
                source_error_code<=fs_error_code;fatal_load(E_SOURCE);
            end else if(!state[OFF] && !state[FAILED] && !fs_mounted) fatal_load(E_UNMOUNT);
            else if(loading && protected_slot) fatal_load(E_LOCK);
            else if(timeout_active_q && !progress &&
                    timeout_now) fatal_load(E_TIMEOUT);
            else if(writer_active && !state[FAILED] && finish_pending && finish_early) fatal_load(E_EARLY_FINISH);
            else if(protocol_fault && !state[FAILED])fatal_load(E_PROTOCOL);
            else begin
                if(writer_active && finish_pending) drained<=1;
                case(1'b1) // synthesis parallel_case
                    state[OFF]: if(start_req && start_ready) begin
                        logical_count<=fs_file_count;preloading<=1;preload_index<=0;
                        preload_goal<=fs_file_count>=4 ? 3'd4 : fs_file_count[2:0];
                        load_id<=0;error<=0;error_code<=0;source_error_code<=0;
                        if(fs_file_count==0 || fs_file_count>128) begin
                            error<=1;error_code<=E_EMPTY;preload_done<=1;set_state(FAILED);
                        end else set_state(SELECT_LOOKUP);
                    end
                    state[IDLE]: if(page_req && page_ready) begin
                        error<=0;error_code<=0;source_error_code<=0;preloading<=0;
                        result_id<=page_id;load_id<=page_id;
                        if({1'b0,page_id}>=logical_count) begin
                            error<=1;error_code<=E_ID;page_done<=1;set_state(REPLY);
                        end else set_state(SELECT_LOOKUP);
                    end
                    state[SELECT_LOOKUP]: begin
                        // load_id and slot metadata are stable for this lookup.
                        // Victim/protected-slot decisions remain live in SELECT.
                        hit_found_q<=hit_found;hit_q<=hit;set_state(SELECT);
                    end
                    state[SELECT]: begin
                        if(!preloading && hit_found_q) begin
                            result_slot<=hit_q;page_done<=1;set_state(REPLY);
                        end else if(victim_found) begin
                            write_slot<=victim;result_slot<=victim;
                            writer_active<=0;drained<=0;source_complete<=0;
                            set_state(META);
                        end
                    end
                    state[META]: if(fs_catalog_valid) begin
                        // Snapshot the classification only for the current
                        // stable load_id. No RAM-size comparison reaches a
                        // header counter CE or fatal/public-state fanout.
                        metadata_size_ok<=fs_catalog_size==FILE_BYTES;
                        set_state(META_CHECK);
                    end
                    state[META_CHECK]: begin
                        if(!metadata_size_ok) fatal_load(E_META);
                        else set_state(H_START);
                    end
                    state[H_START]:set_state(H_REQ);
                    state[H_REQ]: if(fs_read_ready) set_state(H_STREAM);
                    state[H_STREAM]: begin
                        if(fs_read_done && fs_error) begin
                            source_error_code<=fs_error_code;fatal_load(E_SOURCE);
                        end else if(fs_read_done)set_state(H_COMPLETE);
                    end
                    state[H_COMPLETE]:if(header_bytes!=512 || !last_seen)fatal_load(E_PROTOCOL);else set_state(H_VALIDATE);
                    state[H_VALIDATE]: set_state(H_RESULT);
                    state[H_RESULT]: if(header_done) begin
                        if(!header_ok) fatal_load(E_HEADER);
                        else begin
                            slot_valid[write_slot]<=0;set_state(W_REQ);
                        end
                    end
                    state[W_REQ]: if(write_req_ack) begin writer_active<=1;set_state(W_ACK_LOW);end
                    state[W_ACK_LOW]: if(!write_req_ack) set_state(P_REQ);
                    state[P_REQ]: if(fs_read_ready)set_state(P_STREAM);
                    state[P_STREAM]: begin
                        if(take) begin
                            // These two bytes directly drive public write_data,
                            // even while write_en is low: retain fatal priority.
                            case(phase)
                                0:blue<=fs_out_data;
                                1:green<=fs_out_data;
                                default:begin end
                            endcase
                        end
                        if(fs_read_done && fs_error) begin
                            source_error_code<=fs_error_code;fatal_load(E_SOURCE);
                        end else if(fs_read_done)set_state(P_COMPLETE);
                    end
                    state[P_COMPLETE]:if(pixel_bytes!=PIXEL_BYTES || pixels!=307200 || !last_seen)fatal_load(E_PROTOCOL);
                        else begin source_complete<=1;set_state(COMMIT);end
                    state[COMMIT]: if(source_complete && drained && pixels==307200) begin
                        slot_valid[write_slot]<=1;slot_page[write_slot]<=load_id;writer_active<=0;
                        if(preloading && preload_index+1<preload_goal) begin
                            preload_index<=preload_index+1;load_id<=load_id+1;set_state(SELECT_LOOKUP);
                        end else begin
                            if(preloading) begin ready<=1;preload_done<=1;preloading<=0;end
                            else page_done<=1;
                            set_state(preloading ? IDLE : REPLY);
                        end
                    end
                    state[FAILED]: ;
                    state[REPLY]: if(!page_req) set_state(IDLE);
                    default: fatal_load(E_PROTOCOL);
                endcase
            end
        end
    end
endmodule
