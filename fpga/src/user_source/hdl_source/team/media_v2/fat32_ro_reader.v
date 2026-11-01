`timescale 1ns/1ps
// Standalone, single-clock FAT32 read-only catalogue and byte-range reader.
// See docs/media-v2-contract.md. No SD pins, frame slots or contiguous-LBA API.
module fat32_ro_reader #(
    parameter integer PROJECT_NAMES_ONLY = 0,
    parameter integer ACK_TIMEOUT_CYCLES = 25000000,
    parameter integer SECTOR_TIMEOUT_CYCLES = 100000000,
    parameter integer STREAM_TIMEOUT_CYCLES = 25000000,
    parameter integer MAX_ROOT_CLUSTERS = 4096,
    parameter integer MAX_FILE_CLUSTERS = 1048576,
    parameter integer MAX_DIR_ENTRIES = 65536,
    parameter integer AUDIO_FILE_ENABLE = 0
) (
    input wire clk, input wire rst,
    input wire mount_req, output wire mount_ready,
    input wire [31:0] card_sector_count,
    output reg mount_done, output reg mounted,
    output reg [7:0] file_count,
    input wire [6:0] catalog_id,
    output wire catalog_valid,
    output wire [87:0] catalog_name,
    output wire [31:0] catalog_cluster, output wire [31:0] catalog_size,
    input wire read_req, output wire read_ready,
    input wire [6:0] read_id,
    input wire [31:0] read_offset, input wire [31:0] read_length,
    output reg read_done, output reg [31:0] bytes_read,
    output wire out_valid, input wire out_ready,
    output wire [7:0] out_data, output wire out_last,
    output reg [31:0] out_offset,
    output reg error, output reg [7:0] error_code,
    output reg io_fault,
    output wire sector_req, input wire sector_ready,
    output reg [31:0] sector_lba,
    input wire sector_byte_valid, input wire [7:0] sector_byte,
    input wire sector_done, input wire sector_error,
    // Optional sidecar; sampled only with read_req && read_ready.
    input wire read_audio,
    output wire audio_present, output wire [31:0] audio_size,
    output wire audio_invalid
);
    localparam [5:0] IDLE=0, IO_REQ=1, IO_WAIT=2, BOOT0=3, PART=4,
        BPB=5, CH_REQ=6, CH_EVAL=7, ROOT_START=8, DIR_REQ=9,
        DIR_ENTRY=10, INSERT=11, DIR_NEXT=12, DIR_FAT=13,
        MOUNT_OK=14, READ_START=15, SEEK=16, SEEK_FAT=17,
        DATA_REQ=18, STREAM=19, DATA_FAT=20, READ_OK=21,
        RAM_WAIT=22, FAT_START=23, FAT_COLLECT=24, DIR_START=25,
        DIR_COLLECT=26, CAT_WAIT=27, INS_SHIFT=28, INS_WRITE=29,
        READ_META=30, STREAM_PRIME=31, PROFILE_CHECK=32,
        BPB_META=33, BPB_SUB=34, BPB_SHIFT=35, BPB_LIMITS=36,
        BPB_CHECK=37, BPB_PUBLISH=38,
        CAT_SAMPLE=39, INS_DECIDE=40, READ_RANGE=41, READ_LENGTH=42,
        READ_VALIDATE=43, DIR_SAMPLE=44, DIR_DECODE=45,
        IO_DRAIN=46, IO_FINISH=47, PART_SUM=48, PART_CHECK=49,
        PART_APPLY=50, CH_ISSUE=51, CH_CLASSIFY=52, CH_APPLY=53,
        ADDR_SUB=54, ADDR_SHIFT=55, ADDR_BASE=56, ADDR_REQUEST=57, FAIL_ILLEGAL=58,
        FAT_CLASSIFY=59, READ_EXPECT_SHIFT=60, READ_EXPECT_LAUNCH=61, FAIL_RESPONSE=62,
        DIR_VALIDATE=63;
    localparam [7:0] E_ACK=1, E_SECTOR_TIMEOUT=2, E_LENGTH=3, E_IO=4,
        E_MBR=5, E_BPB=6, E_CLUSTER=7, E_LOOP=8, E_CHAIN_LENGTH=9,
        E_LIMIT=10, E_CATALOG_FULL=11, E_RANGE=12, E_STREAM_TIMEOUT=13,
        E_DUPLICATE=14;
    // One hot removes the shared high-fanout binary state decode. Every
    // assignment below writes exactly one bit; return selectors are 6-bit tags.
    reg [63:0] state;
    reg [5:0] io_return, chain_return;
    reg file_operation;
    // Audio metadata never enters the BMP catalogue RAM or its count.
    reg audio_found, audio_rejected, saved_audio;
    reg [31:0] audio_cluster, audio_size_q;
    assign audio_present = AUDIO_FILE_ENABLE && mounted && audio_found;
    assign audio_invalid = AUDIO_FILE_ENABLE && mounted && audio_rejected;
    assign audio_size = audio_present ? audio_size_q : 32'd0;
    // True synchronous memories, with no resets on RAM or RAM output registers.
    (* ram_style = "block" *) reg [7:0] sector_mem [0:511];
    reg [8:0] ram_addr;
    reg [7:0] ram_q;
    reg [5:0] ram_return, fat_return, cat_return;
    reg [8:0] fat_byte_addr;
    reg [1:0] fat_byte_index;
    reg [31:0] fat_word;
    reg fat_eoc_q, fat_cluster_ok_q, fat_hops_last_q, fat_hops_more_q;
    reg [31:0] read_size_minus_one_q, read_cluster_count_q;
    reg [7:0] pending_error_code;
    reg [4:0] dir_byte;
    reg [7:0] entry_first, entry_attr;
    reg [31:0] entry_cluster_raw, entry_size;
    reg entry_cluster_size_ok_q;
    reg [87:0] entry_name;
    reg entry_name_ok, space_seen;
    // The project profile accepts only NNN.BMP (space-padded 8.3 names).
    // Store nine BCD name bits, 28 masked cluster bits, and all 32 size bits.
    // Generic mode keeps all eleven name bytes. Logical RAM views and their
    // synchronous latency remain identical; never reset the inferred RAM.
    localparam integer CATALOG_BITS = PROJECT_NAMES_ONLY ? 69 : 152;
    (* ram_style = "block" *) reg [CATALOG_BITS-1:0] catalog [0:127];
    reg [6:0] cat_addr, cat_tag, saved_id;
    reg cat_valid_q;
    reg [CATALOG_BITS-1:0] cat_raw_q, cat_external_raw_q;
    wire [151:0] cat_q, cat_external_q;
    // Keep the synchronous BRAM outputs unreset. Internal consumers wait an
    // extra clock for this fabric register; the public catalog port is unchanged.
    reg [151:0] cat_pipe_q;
    reg insert_equal_q, insert_greater_q;
    reg [32:0] read_available_q;
    reg read_id_ok_q, read_length_ok_q;
    reg [7:0] dir_data_q, dir_upper_q;
    reg dir_space_q, dir_legal_q;
    reg [31:0] saved_length;
    reg [7:0] profile_index;
    reg [23:0] profile_expected;
    wire cat_we = state[INS_SHIFT] || state[INS_WRITE];
    wire [6:0] cat_port_addr = cat_we ? insert_pos[6:0] : cat_addr;
    wire [151:0] cat_write_data = state[INS_SHIFT] ? cat_pipe_q : candidate;
    wire [CATALOG_BITS-1:0] cat_packed_write;
    generate
        if (PROJECT_NAMES_ONLY) begin : compact_catalog
            assign cat_packed_write = {cat_write_data[144],cat_write_data[139:136],
                cat_write_data[131:128],cat_write_data[59:0]};
            assign cat_q = {7'b0011000,cat_raw_q[68],4'h3,cat_raw_q[67:64],4'h3,cat_raw_q[63:60],64'h2020202020424d50,4'b0,cat_raw_q[59:0]};
            assign cat_external_q = {7'b0011000,cat_external_raw_q[68],4'h3,cat_external_raw_q[67:64],4'h3,cat_external_raw_q[63:60],64'h2020202020424d50,4'b0,cat_external_raw_q[59:0]};
        end else begin : generic_catalog
            assign cat_packed_write = cat_write_data;
            assign cat_q = cat_raw_q;
            assign cat_external_q = cat_external_raw_q;
        end
    endgenerate
    wire receive_byte = !rst && sector_byte_valid && !sector_error && sector_count<512 &&
        (state[IO_WAIT] || (state[IO_REQ] && sector_ready));
    always @(posedge clk) begin
        if(receive_byte) sector_mem[sector_count[8:0]] <= sector_byte;
        ram_q <= sector_mem[ram_addr];
    end
    always @(posedge clk) begin
        if(cat_we && !rst) catalog[cat_port_addr] <= cat_packed_write;
        cat_raw_q <= catalog[cat_port_addr];
    end
    always @(posedge clk) cat_external_raw_q <= catalog[catalog_id];
    always @(posedge clk) begin
        cat_pipe_q <= cat_q;
        dir_data_q <= ram_q;
        dir_upper_q <= upper(dir_data_q);
        dir_space_q <= dir_data_q==8'h20;
        dir_legal_q <= legal_char(upper(dir_data_q));
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin cat_tag<=0; cat_valid_q<=0; end
        else begin cat_tag<=catalog_id; cat_valid_q<=mounted && {1'b0,catalog_id}<file_count; end
    end
    // BPB/MBR scalar fields are assembled only while receiving boot sectors.
    reg boot_e9, boot_eb, boot2_ok;
    reg [7:0] bpb_spc, bpb_nfats;
    reg [1:0] boot_signature_ok, bpb_bps_ok, bpb_root_entries_zero;
    reg [15:0] bpb_reserved;
    reg [1:0] bpb_total16_zero, bpb_fat16_zero, bpb_version_zero;
    reg [15:0] ext_flags;
    reg [31:0] bpb_total, bpb_fat_size, bpb_root_raw;
    reg mbr_type_ok[0:3], mbr_status_ok[0:3];
    reg [31:0] mbr_base[0:3], mbr_size[0:3];
    // Accepted boot-byte event -> local index/data -> registered scalar CEs
    // -> scalar bytes. IO_DRAIN/IO_FINISH drain both stages before BOOT0/BPB.
    // Consecutive valid bytes are accepted every clock; no ready is added.
    reg boot_capture_valid;
    reg [9:0] boot_capture_index;
    reg [7:0] boot_capture_byte, boot_scalar_byte;
    reg [31:0] boot_scalar_ce;
    reg [39:0] mbr_scalar_ce;
    always @(posedge clk) begin
        boot_capture_index<=sector_count;
        boot_capture_byte<=sector_byte;
        boot_scalar_byte<=boot_capture_byte;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin boot_capture_valid<=0;boot_scalar_ce<=0;mbr_scalar_ce<=0;end
        else begin
            boot_capture_valid<=receive_byte && (io_return==BOOT0 || io_return==BPB);
            boot_scalar_ce<=0;mbr_scalar_ce<=0;
            if(boot_capture_valid) begin
                case(boot_capture_index)
                    10'd0: boot_scalar_ce[0]<=1;
                    10'd2: boot_scalar_ce[1]<=1;
                    10'd11: boot_scalar_ce[2]<=1;
                    10'd12: boot_scalar_ce[3]<=1;
                    10'd13: boot_scalar_ce[4]<=1;
                    10'd14: boot_scalar_ce[5]<=1;
                    10'd15: boot_scalar_ce[6]<=1;
                    10'd16: boot_scalar_ce[7]<=1;
                    10'd17: boot_scalar_ce[8]<=1;
                    10'd18: boot_scalar_ce[9]<=1;
                    10'd19: boot_scalar_ce[10]<=1;
                    10'd20: boot_scalar_ce[11]<=1;
                    10'd22: boot_scalar_ce[12]<=1;
                    10'd23: boot_scalar_ce[13]<=1;
                    10'd32: boot_scalar_ce[14]<=1;
                    10'd33: boot_scalar_ce[15]<=1;
                    10'd34: boot_scalar_ce[16]<=1;
                    10'd35: boot_scalar_ce[17]<=1;
                    10'd36: boot_scalar_ce[18]<=1;
                    10'd37: boot_scalar_ce[19]<=1;
                    10'd38: boot_scalar_ce[20]<=1;
                    10'd39: boot_scalar_ce[21]<=1;
                    10'd40: boot_scalar_ce[22]<=1;
                    10'd41: boot_scalar_ce[23]<=1;
                    10'd42: boot_scalar_ce[24]<=1;
                    10'd43: boot_scalar_ce[25]<=1;
                    10'd44: boot_scalar_ce[26]<=1;
                    10'd45: boot_scalar_ce[27]<=1;
                    10'd46: boot_scalar_ce[28]<=1;
                    10'd47: boot_scalar_ce[29]<=1;
                    10'd510: boot_scalar_ce[30]<=1;
                    10'd511: boot_scalar_ce[31]<=1;
                    default: ;
                endcase
                case(boot_capture_index)
                    10'd446: mbr_scalar_ce[0]<=1;
                    10'd450: mbr_scalar_ce[1]<=1;
                    10'd454: mbr_scalar_ce[2]<=1;
                    10'd455: mbr_scalar_ce[3]<=1;
                    10'd456: mbr_scalar_ce[4]<=1;
                    10'd457: mbr_scalar_ce[5]<=1;
                    10'd458: mbr_scalar_ce[6]<=1;
                    10'd459: mbr_scalar_ce[7]<=1;
                    10'd460: mbr_scalar_ce[8]<=1;
                    10'd461: mbr_scalar_ce[9]<=1;
                    10'd462: mbr_scalar_ce[10]<=1;
                    10'd466: mbr_scalar_ce[11]<=1;
                    10'd470: mbr_scalar_ce[12]<=1;
                    10'd471: mbr_scalar_ce[13]<=1;
                    10'd472: mbr_scalar_ce[14]<=1;
                    10'd473: mbr_scalar_ce[15]<=1;
                    10'd474: mbr_scalar_ce[16]<=1;
                    10'd475: mbr_scalar_ce[17]<=1;
                    10'd476: mbr_scalar_ce[18]<=1;
                    10'd477: mbr_scalar_ce[19]<=1;
                    10'd478: mbr_scalar_ce[20]<=1;
                    10'd482: mbr_scalar_ce[21]<=1;
                    10'd486: mbr_scalar_ce[22]<=1;
                    10'd487: mbr_scalar_ce[23]<=1;
                    10'd488: mbr_scalar_ce[24]<=1;
                    10'd489: mbr_scalar_ce[25]<=1;
                    10'd490: mbr_scalar_ce[26]<=1;
                    10'd491: mbr_scalar_ce[27]<=1;
                    10'd492: mbr_scalar_ce[28]<=1;
                    10'd493: mbr_scalar_ce[29]<=1;
                    10'd494: mbr_scalar_ce[30]<=1;
                    10'd498: mbr_scalar_ce[31]<=1;
                    10'd502: mbr_scalar_ce[32]<=1;
                    10'd503: mbr_scalar_ce[33]<=1;
                    10'd504: mbr_scalar_ce[34]<=1;
                    10'd505: mbr_scalar_ce[35]<=1;
                    10'd506: mbr_scalar_ce[36]<=1;
                    10'd507: mbr_scalar_ce[37]<=1;
                    10'd508: mbr_scalar_ce[38]<=1;
                    10'd509: mbr_scalar_ce[39]<=1;
                    default: ;
                endcase
            end
        end
    end
    always @(posedge clk) begin
        if(boot_scalar_ce[0]) begin
            boot_e9<=boot_scalar_byte==8'he9; boot_eb<=boot_scalar_byte==8'heb;
        end
        if(boot_scalar_ce[1]) boot2_ok<=boot_scalar_byte==8'h90;
        if(boot_scalar_ce[2]) bpb_bps_ok[0]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[3]) bpb_bps_ok[1]<=boot_scalar_byte==8'h02;
        if(boot_scalar_ce[4]) bpb_spc<=boot_scalar_byte;
        if(boot_scalar_ce[5]) bpb_reserved[7:0]<=boot_scalar_byte;
        if(boot_scalar_ce[6]) bpb_reserved[15:8]<=boot_scalar_byte;
        if(boot_scalar_ce[7]) bpb_nfats<=boot_scalar_byte;
        if(boot_scalar_ce[8]) bpb_root_entries_zero[0]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[9]) bpb_root_entries_zero[1]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[10]) bpb_total16_zero[0]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[11]) bpb_total16_zero[1]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[12]) bpb_fat16_zero[0]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[13]) bpb_fat16_zero[1]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[14]) bpb_total[7:0]<=boot_scalar_byte;
        if(boot_scalar_ce[15]) bpb_total[15:8]<=boot_scalar_byte;
        if(boot_scalar_ce[16]) bpb_total[23:16]<=boot_scalar_byte;
        if(boot_scalar_ce[17]) bpb_total[31:24]<=boot_scalar_byte;
        if(boot_scalar_ce[18]) bpb_fat_size[7:0]<=boot_scalar_byte;
        if(boot_scalar_ce[19]) bpb_fat_size[15:8]<=boot_scalar_byte;
        if(boot_scalar_ce[20]) bpb_fat_size[23:16]<=boot_scalar_byte;
        if(boot_scalar_ce[21]) bpb_fat_size[31:24]<=boot_scalar_byte;
        if(boot_scalar_ce[22]) ext_flags[7:0]<=boot_scalar_byte;
        if(boot_scalar_ce[23]) ext_flags[15:8]<=boot_scalar_byte;
        if(boot_scalar_ce[24]) bpb_version_zero[0]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[25]) bpb_version_zero[1]<=boot_scalar_byte==8'h00;
        if(boot_scalar_ce[26]) bpb_root_raw[7:0]<=boot_scalar_byte;
        if(boot_scalar_ce[27]) bpb_root_raw[15:8]<=boot_scalar_byte;
        if(boot_scalar_ce[28]) bpb_root_raw[23:16]<=boot_scalar_byte;
        if(boot_scalar_ce[29]) bpb_root_raw[31:24]<=boot_scalar_byte;
        if(boot_scalar_ce[30]) boot_signature_ok[0]<=boot_scalar_byte==8'h55;
        if(boot_scalar_ce[31]) boot_signature_ok[1]<=boot_scalar_byte==8'haa;
        if(mbr_scalar_ce[0]) mbr_status_ok[0]<=boot_scalar_byte==8'h00 || boot_scalar_byte==8'h80;
        if(mbr_scalar_ce[1]) mbr_type_ok[0]<=boot_scalar_byte==8'h0b || boot_scalar_byte==8'h0c;
        if(mbr_scalar_ce[2]) mbr_base[0][7:0]<=boot_scalar_byte;
        if(mbr_scalar_ce[3]) mbr_base[0][15:8]<=boot_scalar_byte;
        if(mbr_scalar_ce[4]) mbr_base[0][23:16]<=boot_scalar_byte;
        if(mbr_scalar_ce[5]) mbr_base[0][31:24]<=boot_scalar_byte;
        if(mbr_scalar_ce[6]) mbr_size[0][7:0]<=boot_scalar_byte;
        if(mbr_scalar_ce[7]) mbr_size[0][15:8]<=boot_scalar_byte;
        if(mbr_scalar_ce[8]) mbr_size[0][23:16]<=boot_scalar_byte;
        if(mbr_scalar_ce[9]) mbr_size[0][31:24]<=boot_scalar_byte;
        if(mbr_scalar_ce[10]) mbr_status_ok[1]<=boot_scalar_byte==8'h00 || boot_scalar_byte==8'h80;
        if(mbr_scalar_ce[11]) mbr_type_ok[1]<=boot_scalar_byte==8'h0b || boot_scalar_byte==8'h0c;
        if(mbr_scalar_ce[12]) mbr_base[1][7:0]<=boot_scalar_byte;
        if(mbr_scalar_ce[13]) mbr_base[1][15:8]<=boot_scalar_byte;
        if(mbr_scalar_ce[14]) mbr_base[1][23:16]<=boot_scalar_byte;
        if(mbr_scalar_ce[15]) mbr_base[1][31:24]<=boot_scalar_byte;
        if(mbr_scalar_ce[16]) mbr_size[1][7:0]<=boot_scalar_byte;
        if(mbr_scalar_ce[17]) mbr_size[1][15:8]<=boot_scalar_byte;
        if(mbr_scalar_ce[18]) mbr_size[1][23:16]<=boot_scalar_byte;
        if(mbr_scalar_ce[19]) mbr_size[1][31:24]<=boot_scalar_byte;
        if(mbr_scalar_ce[20]) mbr_status_ok[2]<=boot_scalar_byte==8'h00 || boot_scalar_byte==8'h80;
        if(mbr_scalar_ce[21]) mbr_type_ok[2]<=boot_scalar_byte==8'h0b || boot_scalar_byte==8'h0c;
        if(mbr_scalar_ce[22]) mbr_base[2][7:0]<=boot_scalar_byte;
        if(mbr_scalar_ce[23]) mbr_base[2][15:8]<=boot_scalar_byte;
        if(mbr_scalar_ce[24]) mbr_base[2][23:16]<=boot_scalar_byte;
        if(mbr_scalar_ce[25]) mbr_base[2][31:24]<=boot_scalar_byte;
        if(mbr_scalar_ce[26]) mbr_size[2][7:0]<=boot_scalar_byte;
        if(mbr_scalar_ce[27]) mbr_size[2][15:8]<=boot_scalar_byte;
        if(mbr_scalar_ce[28]) mbr_size[2][23:16]<=boot_scalar_byte;
        if(mbr_scalar_ce[29]) mbr_size[2][31:24]<=boot_scalar_byte;
        if(mbr_scalar_ce[30]) mbr_status_ok[3]<=boot_scalar_byte==8'h00 || boot_scalar_byte==8'h80;
        if(mbr_scalar_ce[31]) mbr_type_ok[3]<=boot_scalar_byte==8'h0b || boot_scalar_byte==8'h0c;
        if(mbr_scalar_ce[32]) mbr_base[3][7:0]<=boot_scalar_byte;
        if(mbr_scalar_ce[33]) mbr_base[3][15:8]<=boot_scalar_byte;
        if(mbr_scalar_ce[34]) mbr_base[3][23:16]<=boot_scalar_byte;
        if(mbr_scalar_ce[35]) mbr_base[3][31:24]<=boot_scalar_byte;
        if(mbr_scalar_ce[36]) mbr_size[3][7:0]<=boot_scalar_byte;
        if(mbr_scalar_ce[37]) mbr_size[3][15:8]<=boot_scalar_byte;
        if(mbr_scalar_ce[38]) mbr_size[3][23:16]<=boot_scalar_byte;
        if(mbr_scalar_ce[39]) mbr_size[3][31:24]<=boot_scalar_byte;
    end
    reg [151:0] candidate;
    reg [7:0] insert_pos;
    reg [9:0] sector_count;
    // Exact current-count predicates, updated with the counter itself. This
    // cuts wide count decoding out of the same-cycle transport-failure cone.
    reg sector_last_q, sector_full_q; // count == 511, count == 512
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
reg [((ACK_TIMEOUT_CYCLES>1 && SECTOR_TIMEOUT_CYCLES>1) ?
        bounded_timeout_width((ACK_TIMEOUT_CYCLES>SECTOR_TIMEOUT_CYCLES ?
            ACK_TIMEOUT_CYCLES:SECTOR_TIMEOUT_CYCLES),1):32)-1:0] io_timer;
    reg [bounded_timeout_width(STREAM_TIMEOUT_CYCLES,0)-1:0] stream_timer;
    reg [31:0] capacity, volume_base, partition_size;
    reg [31:0] fat_base, data_base, cluster_max, root_cluster;
    reg [7:0] spc;
    reg [7:0] spc_shift_weight;
    reg [2:0] part_index;
    reg [31:0] part_base_q, part_size_q;
    reg [32:0] part_end_q;
    reg part_type_ok_q, part_status_ok_q, part_bounds_ok_q;
    reg chain_request_ok_q, chain_limit_ok_q;
    reg chain_eoc_q, chain_value_ok_q, chain_loop_q, chain_length_ok_q;
    reg chain_power_hit_q;
    reg [31:0] chain_distance_next_q;
    reg [31:0] cluster_offset_q, cluster_lba_q;
    reg [31:0] chain_current, chain_anchor, chain_power, chain_distance;
    reg [31:0] chain_seen, chain_limit, chain_expected, root_chain_count;
    reg [31:0] current_cluster, dir_entries, hops_left;
    reg [7:0] cluster_sector;
    reg [3:0] dir_slot;
    reg [31:0] selected_cluster, selected_size, saved_offset, remaining;
    reg [22:0] skip_clusters;
    // Immutable offset quotient for this read. READ_START precedes every SEEK;
    // skip_clusters is a different, decrementing walk counter. No reset is
    // needed on this private datapath: reset abandons the transaction.
    reg [22:0] seek_quotient_q;
    always @(posedge clk)
        if(state[READ_START]) seek_quotient_q <= file_cluster_quotient;
    reg [8:0] data_ptr;

    // One arithmetic dependency per clock, not a timing exception. These
    // private results are published only after all validation flags pass.
    reg bpb_probe, bpb_fields_ok, bpb_bounds_ok, bpb_meta_ok;
    reg bpb_cluster_range_ok;
    // Register the independent checks separately on the original BPB_CHECK
    // edge. Their conjunction is consumed on the original BPB_PUBLISH edge.
    reg bpb_header_ok_q, bpb_fat_capacity_ok_q, bpb_root_ok_q;
    wire bpb_geometry_ok = bpb_header_ok_q && bpb_fat_capacity_ok_q && bpb_root_ok_q;
    reg [7:0] bpb_shift_weight;
    reg [32:0] bpb_fats_q, bpb_end_q;
    reg [33:0] bpb_meta_q;
    reg [31:0] bpb_data_sectors_q, bpb_clusters_q;
    reg [31:0] bpb_fat_base_q, bpb_data_base_q;
    reg [27:0] bpb_cluster_max_q;
    reg [28:0] bpb_required_entries_q;

    // Shared combinational shift, consumed only in the named one-hot states.
    // The full four-bit amounts and 32-bit operands preserve overflow/truncation.
    wire [31:0] shift_left_input, shift_result, shift_left_result;
    genvar shift_bit;
    generate for(shift_bit=0;shift_bit<32;shift_bit=shift_bit+1) begin : reverse_shift_bits
        assign shift_left_input[shift_bit]=cluster_offset_q[31-shift_bit];
        assign shift_left_result[shift_bit]=shift_result[31-shift_bit];
    end endgenerate
    wire [31:0] shift_operand =
        ({32{state[BPB_SHIFT]}} & bpb_data_sectors_q) |
        ({32{state[READ_START]}} & {9'd0,saved_offset[31:9]}) |
        ({32{state[READ_EXPECT_SHIFT]}} & {9'd0,read_size_minus_one_q[31:9]}) |
        ({32{state[ADDR_SHIFT]}} & shift_left_input);
    // Store the decoded weight on the original geometry capture edges.
    // log_spc yields 0..7 even for invalid BPBs (default 0); no new cycle.
    wire [7:0] selected_shift_weight=state[BPB_SHIFT] ? bpb_shift_weight : spc_shift_weight;
    // Exact unsigned 32-bit shift by 0..15 using two 16x16 DSP products.
    // A single-bit weight means overlap bits cannot generate carries.
    wire [15:0] shift_weight = {selected_shift_weight,8'd0};
    (* dsp_style = "yes" *) wire [31:0] shift_lo_product;
    (* dsp_style = "yes" *) wire [31:0] shift_hi_product;
    assign shift_lo_product = shift_operand[15:0] * shift_weight;
    assign shift_hi_product = shift_operand[31:16] * shift_weight;
    assign shift_result = {shift_hi_product[30:15],
                          (shift_hi_product[14:0] | shift_lo_product[30:16]),
                          shift_lo_product[15]};
    wire [22:0] file_cluster_quotient=shift_result[22:0];

    // Keep each cluster predicate local to its consuming register. A shared
    // state-selected operand puts unrelated state bits ahead of the complete
    // range comparison; direct calls preserve the original capture edges.
    wire [31:0] volume_addend =
        ({32{state[BPB]}} & bpb_total) |
        ({32{state[BPB_META]}} & {16'd0,bpb_reserved}) |
        ({32{state[BPB_SUB]}} & bpb_meta_q[31:0]);
    wire [32:0] volume_sum={1'b0,volume_base}+{1'b0,volume_addend};
    wire [31:0] fat_address_cluster=state[CH_ISSUE] ? chain_current : current_cluster;
    wire [31:0] fat_address_sum=fat_base+(fat_address_cluster >> 7);

    // Share the variable one-hot return decode, without recoding any state
    // or return tag. Each destination consumes it only on its original edge.
    wire [5:0] selected_return =
        ({6{state[IO_FINISH]}} & io_return) |
        ({6{state[CH_APPLY]}} & chain_return) |
        ({6{state[RAM_WAIT]}} & (ram_return==DIR_COLLECT ? DIR_SAMPLE : ram_return)) |
        ({6{state[CAT_SAMPLE]}} & cat_return) |
        ({6{state[FAT_CLASSIFY]}} & fat_return);
    wire [63:0] decoded_return=64'd1 << selected_return;

    function [7:0] decode_shift_weight;
        input [7:0] value;
        begin
            case(value)
                1:decode_shift_weight=8'h80; 2:decode_shift_weight=8'h40;
                4:decode_shift_weight=8'h20; 8:decode_shift_weight=8'h10;
                16:decode_shift_weight=8'h08; 32:decode_shift_weight=8'h04;
                64:decode_shift_weight=8'h02; 128:decode_shift_weight=8'h01;
                default:decode_shift_weight=8'h80;
            endcase
        end
    endfunction
    function cluster_ok;
        input [31:0] c;
        begin cluster_ok = c >= 2 && c <= cluster_max && c < 32'h0ffffff0; end
    endfunction
    function [7:0] upper;
        input [7:0] c;
        begin upper = (c >= "a" && c <= "z") ? c - 8'd32 : c; end
    endfunction
    // ASCII 8.3 catalogue policy: base 1..8 legal characters then spaces.
    function legal_char;
        input [7:0] c;
        begin
            legal_char = (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") ||
                c=="!" || c=="#" || c=="$" || c=="%" || c=="&" || c==8'h27 ||
                c=="(" || c==")" || c=="-" || c=="@" || c=="^" || c=="_" ||
                c=="`" || c=="{" || c=="}" || c=="~";
        end
    endfunction
    wire signature = (&boot_signature_ok);
    wire boot_jump = boot_e9 || (boot_eb && boot2_ok);
    wire [31:0] bpb_root = bpb_root_raw & 32'h0fffffff;
    wire [31:0] part_base=mbr_base[part_index[1:0]];
    wire [31:0] part_size=mbr_size[part_index[1:0]];
    wire [31:0] fat_value=fat_word & 32'h0fffffff;
    wire [31:0] next_value=fat_value;
    wire [31:0] entry_cluster=entry_cluster_raw & 32'h0fffffff;
    wire project_name_ok = entry_name[63:24]==40'h2020202020 &&
        entry_name[87:80]>="0" && entry_name[87:80]<="9" &&
        entry_name[79:72]>="0" && entry_name[79:72]<="9" &&
        entry_name[71:64]>="0" && entry_name[71:64]<="9" &&
        entry_name[87:64]>=24'h303031 && entry_name[87:64]<=24'h313238;
    wire entry_bmp=entry_name_ok && entry_name[23:0]==24'h424d50 &&
        entry_first!=8'he5 && (entry_attr & 8'hd8)==0 &&
        (!PROJECT_NAMES_ONLY || project_name_ok);

    // Match the complete normalized 8.3 short name, with the same regular
    // file attribute policy as BMP. LFN/subdirectory/volume/deleted skip.
    wire entry_audio = AUDIO_FILE_ENABLE && entry_name_ok &&
        entry_name==88'h415544494f20202042494e &&
        entry_first!=8'he5 && (entry_attr & 8'hd8)==0;

    // S10: precompute decisions while the existing RAM/sector pipelines run.
    // DIR_NEXT/STREAM consume sector_more_q only after cluster_sector and SPC
    // have been stable through a sector fetch. PROFILE_CHECK follows CAT_WAIT
    // and CAT_SAMPLE after every index/count change. entry_bmp is final at
    // directory byte 11; DIR_ENTRY follows byte 31. No extra interface cycles.
    // Nine-bit unsigned sums preserve +1 at 8'hff instead of wrapping to zero.
    reg sector_more_q, profile_last_q, entry_bmp_q, entry_audio_q;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            sector_more_q<=0; profile_last_q<=0; entry_bmp_q<=0; entry_audio_q<=0;
        end else begin
            sector_more_q<=({1'b0,cluster_sector}+9'd1)<{1'b0,spc};
            profile_last_q<=({1'b0,profile_index}+9'd1)=={1'b0,file_count};
            entry_bmp_q<=entry_bmp; entry_audio_q<=entry_audio;
        end
    end

    // S12: remaining changes on READ_LENGTH or an accepted STREAM byte.
    // A subsequent valid STREAM follows existing RAM/address/sector waits;
    // refresh this predicate there, without adding an external wait cycle.
    // During backpressure remaining is constant. Gate out_last with out_valid
    // so the stale snapshot immediately after acceptance is never observable.
    reg remaining_last_q;
    always @(posedge clk or posedge rst) begin
        if(rst) remaining_last_q<=0;
        else remaining_last_q<=(remaining==32'd1);
    end

    // S13: CAT_SAMPLE has a fresh synchronous cat_q, but cat_pipe_q is only
    // updated on that edge. Compare cat_q here so PROFILE_CHECK consumes the
    // predicate for the SAME word as cat_pipe_q, without another state/cycle.
    reg profile_match_q;
    reg [23:0] profile_next_q;
    always @(posedge clk or posedge rst) begin
        if(rst) begin profile_match_q<=0;profile_next_q<=24'h303032;end
        else begin
            profile_match_q<=cat_q[151:128]==profile_expected;
            profile_next_q[7:0]<=profile_expected[7:0]==8'h39 ? 8'h30 : profile_expected[7:0]+8'd1;
            profile_next_q[15:8]<=profile_expected[7:0]!=8'h39 ? profile_expected[15:8] :
                (profile_expected[15:8]==8'h39 ? 8'h30 : profile_expected[15:8]+8'd1);
            profile_next_q[23:16]<=(profile_expected[15:0]==16'h3939) ?
                profile_expected[23:16]+8'd1 : profile_expected[23:16];
        end
    end
    // A local enable, independent of unrelated STREAM/failure decisions.
    always @(posedge clk or posedge rst) begin
        if(rst) profile_expected<=24'h303031;
        else if(state[MOUNT_OK] && PROJECT_NAMES_ONLY && file_count!=0)
            profile_expected<=24'h303031;
        else if(state[PROFILE_CHECK] && profile_match_q && !profile_last_q)
            profile_expected<=profile_next_q;
    end

    // io_timer is private to IO_REQ/IO_WAIT. Every get_sector call originates
    // outside them, so resetting elsewhere preserves its value at every use.
    // Register the predicate for the next timer value; explicit wrap handling
    // preserves the original unsigned >= comparison, including threshold 0/1.
    localparam [31:0] ACK_LAST=ACK_TIMEOUT_CYCLES-1;
    localparam [31:0] SECTOR_LAST=SECTOR_TIMEOUT_CYCLES-1;
    wire io_timer_increment=state[IO_WAIT] || (state[IO_REQ] && !sector_ready);
    reg io_ack_expired_q, io_sector_expired_q;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            io_timer<=0;io_ack_expired_q<=(ACK_LAST==0);io_sector_expired_q<=(SECTOR_LAST==0);
        end else begin
            io_timer<=io_timer_increment ? io_timer+32'd1 : 32'd0;
            io_ack_expired_q<=(ACK_LAST==0) || (io_timer_increment && io_timer!=32'hffffffff &&
                io_timer>=ACK_LAST-32'd1);
            io_sector_expired_q<=(SECTOR_LAST==0) || (io_timer_increment && io_timer!=32'hffffffff &&
                io_timer>=SECTOR_LAST-32'd1);
        end
    end

    // Only FAT_START/FAT_COLLECT consume this private pointer. Prepare it in
    // all possible calling states, without their out_ready/branch CE cone.
    // A rejected/non-FAT call may refresh it, but cannot publish or consume it.
    always @(posedge clk or posedge rst) begin
        if(rst) fat_byte_addr<=0;
        else if(state[CH_ISSUE]) fat_byte_addr<={chain_current[6:0],2'b00};
        else if(state[DIR_NEXT] || state[SEEK] || state[STREAM])
            fat_byte_addr<={current_cluster[6:0],2'b00};
        else if(state[FAT_COLLECT] && fat_byte_index!=3) fat_byte_addr<=fat_byte_addr+9'd1;
    end

    assign mount_ready = state[IDLE] && !io_fault;
    assign read_ready = state[IDLE] && mounted && !mount_req && !io_fault;
    assign sector_req = state[IO_REQ];
    assign catalog_valid = mounted && cat_valid_q && cat_tag==catalog_id;
    assign catalog_name = catalog_valid ? cat_external_q[151:64] : 88'd0;
    assign catalog_cluster = catalog_valid ? cat_external_q[63:32] : 32'd0;
    assign catalog_size = catalog_valid ? cat_external_q[31:0] : 32'd0;
    assign out_valid = state[STREAM];
    assign out_data = ram_q;
    assign out_last = out_valid && remaining_last_q;

    task finish_failure;
        input [7:0] code;
        begin
            error<=1; error_code<=code; state<=(64'd1 << (IDLE));
            if(file_operation) read_done<=1;
            else begin mount_done<=1; mounted<=0; file_count<=0; end
            if(code<=E_IO) begin io_fault<=1; mounted<=0; file_count<=0; end
        end
    endtask
    task fail;
        input [7:0] code;
        begin
            // Keep transport/stream cancellation and done/error simultaneous.
            // Metadata/chain failures have no active output beat: publish them
            // on a separate clock to cut classification from global CEs.
            if(code<=E_IO || code==E_STREAM_TIMEOUT) finish_failure(code);
            else begin pending_error_code<=code;state<=(64'd1 << FAIL_RESPONSE);end
        end
    endtask
    task get_sector;
        input [31:0] lba;
        input [5:0] return_state;
        begin
            sector_lba<=lba; io_return<=return_state;
            sector_count<=0; sector_last_q<=0; sector_full_q<=0; state<=(64'd1 << (IO_REQ));
        end
    endtask
    task get_byte;
        input [8:0] address;
        input [5:0] return_state;
        begin ram_addr<=address;ram_return<=return_state;state<=(64'd1 << (RAM_WAIT));end
    endtask
    task get_fat;
        input [31:0] cluster;
        input [5:0] return_state;
        begin
            fat_return<=return_state;
            get_sector(fat_address_sum,FAT_START);
        end
    endtask
    task check_chain;
        input [31:0] first;
        input [31:0] limit;
        input [31:0] expected;
        input [5:0] return_state;
        begin
            chain_current<=first; chain_anchor<=first; chain_power<=1;
            chain_distance<=0; chain_seen<=1; chain_limit<=limit;
            chain_expected<=expected; chain_return<=return_state; state<=(64'd1 << (CH_REQ));
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=(64'd1 << (IDLE)); io_return<=IDLE; chain_return<=IDLE; file_operation<=0;
            mount_done<=0; read_done<=0; mounted<=0; file_count<=0;
            audio_found<=0;audio_rejected<=0;audio_cluster<=0;audio_size_q<=0;saved_audio<=0;
            error<=0; error_code<=0; io_fault<=0; bytes_read<=0; out_offset<=0;
            sector_lba<=0; sector_count<=0; sector_last_q<=0; sector_full_q<=0; stream_timer<=0;
            capacity<=0; volume_base<=0; partition_size<=0; fat_base<=0;
            data_base<=0; cluster_max<=0; root_cluster<=0; spc<=0; spc_shift_weight<=8'h80;
            part_index<=0; chain_current<=0; chain_anchor<=0; chain_power<=0;
            chain_distance<=0; chain_seen<=0; chain_limit<=0; chain_expected<=0;
            root_chain_count<=0; current_cluster<=0; dir_entries<=0; hops_left<=0;
            cluster_sector<=0; dir_slot<=0; selected_cluster<=0; selected_size<=0;
            saved_offset<=0; remaining<=0; skip_clusters<=0; data_ptr<=0;
            candidate<=0; insert_pos<=0;ram_addr<=0;ram_return<=IDLE;
            fat_return<=IDLE;fat_byte_index<=0;fat_word<=0;
            fat_eoc_q<=0;fat_cluster_ok_q<=0;fat_hops_last_q<=0;fat_hops_more_q<=0;
            read_size_minus_one_q<=0;read_cluster_count_q<=0;pending_error_code<=0;
            dir_byte<=0;entry_first<=0;entry_attr<=0;entry_cluster_raw<=0;
            entry_size<=0;entry_name<=0;entry_name_ok<=0;space_seen<=0;
            entry_cluster_size_ok_q<=0;
            cat_addr<=0;cat_return<=IDLE;saved_id<=0;saved_length<=0;
            profile_index<=0;
            insert_equal_q<=0;insert_greater_q<=0;read_available_q<=0;
            read_id_ok_q<=0;read_length_ok_q<=0;
            bpb_probe<=0; bpb_fields_ok<=0; bpb_bounds_ok<=0; bpb_meta_ok<=0;
            bpb_cluster_range_ok<=0; bpb_header_ok_q<=0; bpb_fat_capacity_ok_q<=0; bpb_root_ok_q<=0; bpb_shift_weight<=8'h80;
            bpb_fats_q<=0; bpb_end_q<=0; bpb_meta_q<=0;
            bpb_data_sectors_q<=0; bpb_clusters_q<=0;
            bpb_fat_base_q<=0; bpb_data_base_q<=0;
            bpb_cluster_max_q<=0; bpb_required_entries_q<=0;
            part_base_q<=0;part_size_q<=0;part_end_q<=0;
            part_type_ok_q<=0;part_status_ok_q<=0;part_bounds_ok_q<=0;
            chain_request_ok_q<=0;chain_limit_ok_q<=0;chain_eoc_q<=0;
            chain_value_ok_q<=0;chain_loop_q<=0;chain_length_ok_q<=0;
            chain_power_hit_q<=0;chain_distance_next_q<=0;
            cluster_offset_q<=0;cluster_lba_q<=0;
        end else begin
            mount_done<=0; read_done<=0;
            // Every valid branch supplies a next-state bit, including the
            // three wait states below. Do not infer one shared state-bank CE.
            state<=0;
            case(1'b1) // synthesis parallel_case
                state[IDLE]: begin
                    state<=(64'd1 << IDLE);
                    if(mount_req && mount_ready) begin
                        file_operation<=0; mounted<=0; file_count<=0;
                        audio_found<=0;audio_rejected<=0;audio_cluster<=0;audio_size_q<=0;
                        error<=0; error_code<=0; capacity<=card_sector_count;
                        volume_base<=0; partition_size<=card_sector_count;
                        if(card_sector_count==0) begin
                            error<=1; error_code<=E_MBR; mount_done<=1;
                        end else get_sector(0,BOOT0);
                    end else if(read_req && read_ready) begin
                        file_operation<=1; error<=0; error_code<=0; bytes_read<=0;
                        out_offset<=read_offset; saved_offset<=read_offset;
                        saved_id<=read_id;saved_length<=read_length;
                        // Constant zero masks an unconnected/X input when disabled.
                        saved_audio<=AUDIO_FILE_ENABLE && read_audio;
                        cat_addr<=read_id;cat_return<=READ_META;state<=(64'd1 << (CAT_WAIT));
                    end
                end
                state[IO_REQ],state[IO_WAIT]: begin
                    state<=state[IO_REQ] ? (64'd1 << IO_REQ) : (64'd1 << IO_WAIT);
                    if(state[IO_REQ] && !sector_ready) begin
                        if(io_ack_expired_q) fail(E_ACK);
                    end else begin
                        if(state[IO_REQ]) begin state<=(64'd1 << (IO_WAIT)); end
                        if(sector_error) fail(E_IO);
                        else if(sector_byte_valid && sector_full_q) fail(E_LENGTH);
                        else begin
                            if(sector_byte_valid) begin
                                sector_count<=sector_count+1;
                                sector_last_q<=sector_count==10'd510;
                                sector_full_q<=sector_last_q;
                            end
                            if(sector_done) begin
                                if((sector_byte_valid && sector_last_q) ||
                                   (!sector_byte_valid && sector_full_q)) state<=(64'd1 << (IO_DRAIN));
                                else fail(E_LENGTH);
                            end else if(state[IO_WAIT] && io_sector_expired_q)
                                fail(E_SECTOR_TIMEOUT);
                        end
                    end
                end
                state[IO_DRAIN]: state<=(64'd1 << (IO_FINISH));
                state[IO_FINISH]: state<=decoded_return;
                state[BOOT0]: begin
                    if(!signature || capacity==0) fail(E_MBR);
                    else begin bpb_probe<=1; state<=(64'd1 << (BPB)); end
                end
                state[PART]: begin
                    part_base_q<=part_base;part_size_q<=part_size;
                    part_type_ok_q<=mbr_type_ok[part_index[1:0]];
                    part_status_ok_q<=mbr_status_ok[part_index[1:0]];
                    state<=(64'd1 << (PART_SUM));
                end
                state[PART_SUM]: begin
                    // Sum of two unsigned 32-bit fields needs exactly 33 bits.
                    // Keep carry through the capacity check before publishing.
                    part_end_q<={1'b0,part_base_q}+{1'b0,part_size_q};
                    state<=(64'd1 << (PART_CHECK));
                end
                state[PART_CHECK]: begin
                    part_bounds_ok_q<=part_status_ok_q && part_base_q!=0 && part_size_q!=0 &&
                        part_end_q<={1'b0,capacity};
                    state<=(64'd1 << (PART_APPLY));
                end
                state[PART_APPLY]: begin
                    if(part_type_ok_q) begin
                        if(!part_bounds_ok_q) fail(E_MBR);
                        else begin
                            volume_base<=part_base_q; partition_size<=part_size_q;
                            bpb_probe<=0;
                            get_sector(part_base_q,BPB);
                        end
                    end else if(part_index==3) fail(boot_jump ? E_BPB : E_MBR);
                    else begin part_index<=part_index+1;state<=(64'd1 << (PART));end
                end
                state[BPB]: begin
                    bpb_fields_ok <= signature && boot_jump && (&bpb_bps_ok) &&
                        bpb_spc!=0 && (bpb_spc & (bpb_spc-8'd1))==0 && bpb_reserved!=0 &&
                        (bpb_nfats==1 || bpb_nfats==2) && (&bpb_root_entries_zero) && (&bpb_total16_zero) &&
                        (&bpb_fat16_zero) && (&bpb_version_zero) && bpb_fat_size!=0 &&
                        (!ext_flags[7] || {4'd0,ext_flags[3:0]}<bpb_nfats);
                    bpb_shift_weight<=decode_shift_weight(bpb_spc);
                    // 2 * FATSz32 needs 33 bits; volume base + total also does.
                    bpb_fats_q<=bpb_nfats==2 ? {bpb_fat_size,1'b0} : {1'b0,bpb_fat_size};
                    bpb_end_q<=volume_sum;
                    state<=(64'd1 << (BPB_META));
                end
                state[BPB_META]: begin
                    // Adding reserved sectors to the 33-bit FAT span can carry
                    // into bit 33. Keep it until the strict meta < total check.
                    bpb_meta_q<={1'b0,bpb_fats_q}+{18'd0,bpb_reserved};
                    bpb_bounds_ok<=bpb_end_q<={1'b0,capacity} && bpb_total<=partition_size;
                    bpb_fat_base_q<=volume_sum[31:0];
                    state<=(64'd1 << (BPB_SUB));
                end
                state[BPB_SUB]: begin
                    bpb_meta_ok<=bpb_meta_q<{2'd0,bpb_total};
                    // Low-word arithmetic is usable only with meta_ok. A
                    // borrow or a high meta bit always rejects the transaction.
                    bpb_data_sectors_q<=bpb_total-bpb_meta_q[31:0];
                    bpb_data_base_q<=volume_sum[31:0];
                    bpb_fat_base_q<=bpb_fat_base_q+
                        (ext_flags[7] && ext_flags[3:0]==1 ? bpb_fat_size : 32'd0);
                    state<=(64'd1 << (BPB_SHIFT));
                end
                state[BPB_SHIFT]: begin
                    bpb_clusters_q<=shift_result;
                    state<=(64'd1 << (BPB_LIMITS));
                end
                state[BPB_LIMITS]: begin
                    bpb_cluster_range_ok<=bpb_clusters_q>=32'd65525 && bpb_clusters_q<=32'h0fffffee;
                    // Truncation is guarded by the independently registered
                    // range check; valid clusters+1/+2 cannot wrap these widths.
                    bpb_cluster_max_q<=bpb_clusters_q[27:0]+28'd1;
                    bpb_required_entries_q<={1'b0,bpb_clusters_q[27:0]}+29'd2;
                    state<=(64'd1 << (BPB_CHECK));
                end
                state[BPB_CHECK]: begin
                    bpb_header_ok_q<=bpb_fields_ok && bpb_bounds_ok && bpb_meta_ok && bpb_cluster_range_ok;
                    bpb_fat_capacity_ok_q<={bpb_fat_size,7'd0}>={10'd0,bpb_required_entries_q};
                    bpb_root_ok_q<=bpb_root>=2 && bpb_root<={4'd0,bpb_cluster_max_q};
                    state<=(64'd1 << (BPB_PUBLISH));
                end
                state[BPB_PUBLISH]: begin
                    if(!bpb_geometry_ok) begin
                        // LBA0 can be an MBR even when it has a FAT-like jump.
                        if(bpb_probe) begin part_index<=0; state<=(64'd1 << (PART)); end
                        else fail(E_BPB);
                    end
                    else begin
                        // Bounds guarantee base <= fat/data address < end <=
                        // capacity <= 2^32-1 before publishing 32-bit addresses.
                        spc<=bpb_spc; spc_shift_weight<=bpb_shift_weight;
                        fat_base<=bpb_fat_base_q; data_base<=bpb_data_base_q;
                        cluster_max<={4'd0,bpb_cluster_max_q}; root_cluster<=bpb_root;
                        check_chain(bpb_root,MAX_ROOT_CLUSTERS,0,ROOT_START);
                    end
                end
                state[CH_REQ]: begin
                    chain_request_ok_q<=cluster_ok(chain_current);
                    // Published geometry guarantees cluster_max>=65526;
                    // seen <= max-1 is the same unsigned comparison as seen<max.
                    chain_limit_ok_q<=chain_seen<=chain_limit && chain_seen<cluster_max;
                    state<=(64'd1 << (CH_ISSUE));
                end
                state[CH_ISSUE]: begin
                    if(!chain_request_ok_q) fail(E_CLUSTER);
                    else if(!chain_limit_ok_q) fail(E_LIMIT);
                    else get_fat(chain_current,CH_EVAL);
                end
                state[CH_EVAL]: begin
                    chain_eoc_q<=fat_eoc_q;
                    chain_value_ok_q<=fat_cluster_ok_q;
                    chain_loop_q<=fat_value==chain_anchor;
                    chain_length_ok_q<=chain_expected==0 || chain_seen==chain_expected;
                    chain_distance_next_q<=chain_distance+32'd1;
                    state<=(64'd1 << (CH_CLASSIFY));
                end
                state[CH_CLASSIFY]: begin
                    chain_power_hit_q<=chain_distance_next_q==chain_power;
                    state<=(64'd1 << (CH_APPLY));
                end
                state[CH_APPLY]: begin
                    if(chain_eoc_q) begin
                        if(!chain_length_ok_q) fail(E_CHAIN_LENGTH);
                        else begin root_chain_count<=chain_seen; state<=decoded_return; end
                    end else if(!chain_value_ok_q) fail(E_CLUSTER);
                    else if(chain_loop_q) fail(E_LOOP);
                    else begin
                        // Brent cycle detection: constant storage, no visited-list truncation.
                        if(chain_power_hit_q) begin
                            chain_anchor<=fat_value; chain_power<=chain_power<<1; chain_distance<=0;
                        end else chain_distance<=chain_distance_next_q;
                        chain_current<=fat_value; chain_seen<=chain_seen+1; state<=(64'd1 << (CH_REQ));
                    end
                end
                state[ROOT_START]: begin
                    current_cluster<=root_cluster; cluster_sector<=0; dir_entries<=0;
                    hops_left<=root_chain_count; state<=(64'd1 << (DIR_REQ));
                end
                state[DIR_REQ]: begin dir_slot<=0;io_return<=DIR_START;state<=(64'd1 << (ADDR_SUB));end
                state[ADDR_SUB]: begin cluster_offset_q<=current_cluster-32'd2;state<=(64'd1 << (ADDR_SHIFT));end
                state[ADDR_SHIFT]: begin cluster_offset_q<=shift_left_result;state<=(64'd1 << (ADDR_BASE));end
                state[ADDR_BASE]: begin cluster_lba_q<=data_base+cluster_offset_q;state<=(64'd1 << (ADDR_REQUEST));end
                state[ADDR_REQUEST]: get_sector(cluster_lba_q+{24'd0,cluster_sector},io_return);
                state[DIR_VALIDATE]: begin
                    // Byte 31 was committed on the preceding DIR_COLLECT edge.
                    // Classify the complete size and masked cluster before any
                    // directory decision fans out into shared control enables.
                    entry_cluster_size_ok_q <= (entry_size!=0 && cluster_ok(entry_cluster)) ||
                        (entry_size==0 && entry_cluster==0);
                    state<=(64'd1 << DIR_ENTRY);
                end
                state[DIR_ENTRY]: begin
                    if(entry_first==0) state<=(64'd1 << (MOUNT_OK));
                    else if(dir_entries>=MAX_DIR_ENTRIES) fail(E_LIMIT);
                    else if(entry_audio_q) begin
                        // Optional asset: ambiguous/bad metadata disables audio
                        // for this mount, but never blocks BMP catalogue scan.
                        if(audio_rejected || audio_found || !entry_cluster_size_ok_q) begin
                            audio_found<=0;audio_rejected<=1;audio_cluster<=0;audio_size_q<=0;
                        end else begin
                            audio_found<=1;audio_cluster<=entry_cluster;audio_size_q<=entry_size;
                        end
                        state<=(64'd1 << DIR_NEXT);
                    end else if(entry_bmp_q) begin
                        if(!entry_cluster_size_ok_q) fail(E_CLUSTER);
                        else if(file_count==128) fail(PROJECT_NAMES_ONLY ? E_RANGE : E_CATALOG_FULL);
                        else begin
                            candidate<={entry_name,entry_cluster,entry_size};
                            insert_pos<=file_count;
                            if(file_count==0) state<=(64'd1 << (INS_WRITE));
                            else begin cat_addr<=file_count-1;cat_return<=INSERT;state<=(64'd1 << (CAT_WAIT));end
                        end
                    end else state<=(64'd1 << (DIR_NEXT));
                end
                state[INSERT]: begin
                    insert_equal_q<=PROJECT_NAMES_ONLY ?
                        cat_pipe_q[151:128]==candidate[151:128] :
                        cat_pipe_q[151:64]==candidate[151:64];
                    insert_greater_q<=PROJECT_NAMES_ONLY ?
                        cat_pipe_q[151:128]>candidate[151:128] :
                        cat_pipe_q[151:64]>candidate[151:64];
                    state<=(64'd1 << (INS_DECIDE));
                end
                state[INS_DECIDE]: begin
                    if(insert_equal_q) fail(PROJECT_NAMES_ONLY ? E_RANGE : E_DUPLICATE);
                    else if(insert_greater_q) state<=(64'd1 << (INS_SHIFT));
                    else state<=(64'd1 << (INS_WRITE));
                end
                state[INS_SHIFT]: begin
                    insert_pos<=insert_pos-1;
                    if(insert_pos==1) state<=(64'd1 << (INS_WRITE));
                    else begin cat_addr<=insert_pos-2;cat_return<=INSERT;state<=(64'd1 << (CAT_WAIT));end
                end
                state[INS_WRITE]: begin file_count<=file_count+1;state<=(64'd1 << (DIR_NEXT));end
                state[DIR_NEXT]: begin
                    dir_entries<=dir_entries+1;
                    if(dir_slot!=15) begin dir_slot<=dir_slot+1; state<=(64'd1 << (DIR_START)); end
                    else if(sector_more_q) begin cluster_sector<=cluster_sector+1; state<=(64'd1 << (DIR_REQ)); end
                    else get_fat(current_cluster,DIR_FAT);
                end
                state[DIR_FAT]: begin
                    if(fat_eoc_q && fat_hops_last_q) state<=(64'd1 << (MOUNT_OK));
                    else if(!fat_cluster_ok_q || !fat_hops_more_q) fail(E_CHAIN_LENGTH);
                    else begin
                        current_cluster<=next_value; hops_left<=hops_left-1;
                        cluster_sector<=0; state<=(64'd1 << (DIR_REQ));
                    end
                end
                state[MOUNT_OK]: begin
                    if(PROJECT_NAMES_ONLY && file_count!=0) begin
                        profile_index<=0;
                        cat_addr<=0;cat_return<=PROFILE_CHECK;state<=(64'd1 << (CAT_WAIT));
                    end else begin mounted<=1;mount_done<=1;state<=(64'd1 << (IDLE));end
                end
                state[PROFILE_CHECK]: begin
                    if(!profile_match_q) fail(E_RANGE);
                    else if(profile_last_q) begin mounted<=1;mount_done<=1;state<=(64'd1 << (IDLE));end
                    else begin
                        profile_index<=profile_index+1;cat_addr<=profile_index+1;
                        cat_return<=PROFILE_CHECK;state<=(64'd1 << (CAT_WAIT));
                    end
                end
                state[READ_START]: begin
                    if(error) begin read_done<=1; state<=(64'd1 << (IDLE)); end
                    else if(selected_size==0) state<=(64'd1 << (READ_OK));
                    else begin
                        read_size_minus_one_q<=selected_size-32'd1;
                        state<=(64'd1 << READ_EXPECT_SHIFT);
                    end
                    current_cluster<=selected_cluster;
                    skip_clusters<={9'd0,file_cluster_quotient};
                    cluster_sector<=(saved_offset>>9) & (spc-1);
                    data_ptr<=saved_offset[8:0];
                end
                state[READ_EXPECT_SHIFT]: begin
                    read_cluster_count_q<={9'd0,file_cluster_quotient};
                    state<=(64'd1 << READ_EXPECT_LAUNCH);
                end
                state[READ_EXPECT_LAUNCH]: begin
                    // Nonempty 32-bit size and validated SPC>=1 bound this
                    // quotient to 0x007fffff; +1 cannot overflow 32 bits.
                    check_chain(selected_cluster,MAX_FILE_CLUSTERS,read_cluster_count_q+32'd1,SEEK);
                end
                state[SEEK]: begin
                    hops_left<=root_chain_count-{9'd0,seek_quotient_q};
                    if(remaining==0) state<=(64'd1 << (READ_OK));
                    else if(skip_clusters==0) state<=(64'd1 << (DATA_REQ));
                    else get_fat(current_cluster,SEEK_FAT);
                end
                state[SEEK_FAT]: begin
                    if(!fat_cluster_ok_q) fail(E_CHAIN_LENGTH);
                    else begin current_cluster<=next_value; skip_clusters<=skip_clusters-1; state<=(64'd1 << (SEEK)); end
                end
                state[DATA_REQ]: begin
                    stream_timer<=0;
                    io_return<=STREAM_PRIME;state<=(64'd1 << (ADDR_SUB));
                end
                state[STREAM]: begin
                    state<=(64'd1 << STREAM);
                    if(out_ready) begin
                        stream_timer<=0; remaining<=remaining-1; bytes_read<=bytes_read+1;
                        out_offset<=out_offset+1;
                        if(remaining_last_q) state<=(64'd1 << (READ_OK));
                        else if(data_ptr==511) begin
                            data_ptr<=0;
                            if(sector_more_q) begin cluster_sector<=cluster_sector+1; state<=(64'd1 << (DATA_REQ)); end
                            else get_fat(current_cluster,DATA_FAT);
                        end else begin data_ptr<=data_ptr+1;get_byte(data_ptr+1,STREAM);end
                    end else if(stream_timer>=STREAM_TIMEOUT_CYCLES-1) fail(E_STREAM_TIMEOUT);
                    else stream_timer<=stream_timer+1;
                end
                state[DATA_FAT]: begin
                    if(!fat_cluster_ok_q || !fat_hops_more_q) fail(E_CHAIN_LENGTH);
                    else begin
                        current_cluster<=next_value; hops_left<=hops_left-1;
                        cluster_sector<=0; state<=(64'd1 << (DATA_REQ));
                    end
                end
                state[RAM_WAIT]: state<=decoded_return;
                state[DIR_SAMPLE]: state<=(64'd1 << (DIR_DECODE));
                state[DIR_DECODE]: state<=(64'd1 << (DIR_COLLECT));
                state[CAT_WAIT]: state<=(64'd1 << (CAT_SAMPLE));
                state[CAT_SAMPLE]: state<=decoded_return;
                state[FAT_START]: begin fat_word<=0;fat_byte_index<=0;get_byte(fat_byte_addr,FAT_COLLECT);end
                state[FAT_COLLECT]: begin
                    fat_word<={ram_q,fat_word[31:8]};
                    if(fat_byte_index==3) state<=(64'd1 << FAT_CLASSIFY);
                    else begin
                        fat_byte_index<=fat_byte_index+1;
                        get_byte(fat_byte_addr+1,FAT_COLLECT);
                    end
                end
                state[FAT_CLASSIFY]: begin
                    // Last byte is already in fat_word. All raw FAT-value
                    // consumers see classification from this registered cut.
                    fat_eoc_q<=fat_value>=32'h0ffffff8;
                    fat_cluster_ok_q<=cluster_ok(fat_value);
                    fat_hops_last_q<=hops_left==1;
                    fat_hops_more_q<=hops_left>1;
                    state<=decoded_return;
                end
                state[DIR_START]: begin
                    dir_byte<=0;entry_name<=0;entry_name_ok<=1;space_seen<=0;
                    entry_cluster_raw<=0;entry_size<=0;get_byte({dir_slot,5'd0},DIR_COLLECT);
                end
                state[DIR_COLLECT]: begin
                    if(dir_byte==0) begin
                        entry_first<=dir_data_q;
                        if(dir_space_q) entry_name_ok<=0;
                    end
                    if(dir_byte<11) entry_name<={entry_name[79:0],dir_upper_q};
                    if(dir_byte<8) begin
                        if(dir_space_q) space_seen<=1;
                        else if(space_seen || !dir_legal_q) entry_name_ok<=0;
                    end
                    case(dir_byte)
                        11:entry_attr<=dir_data_q;
                        20:entry_cluster_raw[23:16]<=dir_data_q;
                        21:entry_cluster_raw[31:24]<=dir_data_q;
                        26:entry_cluster_raw[7:0]<=dir_data_q;
                        27:entry_cluster_raw[15:8]<=dir_data_q;
                        28:entry_size[7:0]<=dir_data_q;
                        29:entry_size[15:8]<=dir_data_q;
                        30:entry_size[23:16]<=dir_data_q;
                        31:entry_size[31:24]<=dir_data_q;
                        default: ;
                    endcase
                    if(dir_byte==31) state<=(64'd1 << (DIR_VALIDATE));
                    else begin dir_byte<=dir_byte+1;get_byte({dir_slot,dir_byte}+9'd1,DIR_COLLECT);end
                end
                state[READ_META]: begin
                    selected_cluster<=saved_audio ? audio_cluster : cat_pipe_q[63:32];
                    selected_size<=saved_audio ? audio_size_q : cat_pipe_q[31:0];
                    state<=(64'd1 << (READ_RANGE));
                end
                state[READ_RANGE]: begin
                    // Bit 32 retains unsigned borrow. The low-word result is
                    // private and is never streamed when offset exceeds size.
                    read_available_q<={1'b0,selected_size}-{1'b0,saved_offset};
                    read_id_ok_q<=saved_audio ? audio_found : ({1'b0,saved_id}<file_count);
                    state<=(64'd1 << (READ_LENGTH));
                end
                state[READ_LENGTH]: begin
                    read_length_ok_q<=saved_length==0 || saved_length<=read_available_q[31:0];
                    remaining<=saved_length==0 ? read_available_q[31:0] : saved_length;
                    state<=(64'd1 << (READ_VALIDATE));
                end
                state[READ_VALIDATE]: begin
                    if(!read_id_ok_q || read_available_q[32] || !read_length_ok_q) fail(E_RANGE);
                    else state<=(64'd1 << (READ_START));
                end
                state[STREAM_PRIME]: get_byte(data_ptr,STREAM);
                state[READ_OK]: begin read_done<=1; state<=(64'd1 << (IDLE)); end
                // Separate illegal-state decode from public error/completion fanout.
                state[FAIL_ILLEGAL]: fail(E_LIMIT);
                state[FAIL_RESPONSE]: finish_failure(pending_error_code);
                default: state<=(64'd1 << (FAIL_ILLEGAL));
            endcase
        end
    end
endmodule


