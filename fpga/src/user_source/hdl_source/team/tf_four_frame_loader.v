module tf_four_frame_loader #(
    parameter [31:0] SCAN_LAST_LBA = 32'd131071,
    parameter integer CLK_HZ = 100000000
) (
    input wire clk,
    input wire rst,
    input wire write_req_ack,
    input wire write_finish_toggle,
    input wire write_fifo_full,
    output wire write_req,
    output wire [1:0] write_slot,
    output wire write_en,
    output wire [31:0] write_data,
    output wire media_ready,
    output wire [2:0] valid_count,
    output wire [3:0] valid_mask,
    output reg [3:0] state_code,
    output reg [3:0] error_code,
    output wire SD_nCS,
    output wire SD_DCLK,
    output wire SD_MOSI,
    input wire SD_MISO
);
    localparam [3:0] S_INIT = 4'd0, S_SCAN_START = 4'd1,
        S_SCAN_WAIT = 4'd2, S_SCAN_EVAL = 4'd3, S_WRITE_REQ = 4'd4,
        S_WRITE_ACK_LOW = 4'd5, S_CONSUME = 4'd6,
        S_READ_NEXT = 4'd7, S_LOAD_WAIT = 4'd8,
        S_WAIT_FINISH = 4'd9, S_READY = 4'd10, S_ERROR = 4'd11;
    localparam [19:0] PIXEL_BYTES = 20'd921600;
    localparam [31:0] FILE_SECTORS = 32'd1801;
    localparam integer SECTOR_TIMEOUT = CLK_HZ / 4;
    localparam integer MS_DIVISOR = CLK_HZ / 1000;

    reg [3:0] state;
    reg [31:0] scan_lba;
    reg [31:0] current_lba;
    reg [8:0] sector_index;
    reg [9:0] sector_byte_count;
    reg [8:0] read_ptr;
    reg [19:0] bytes_left;
    reg [1:0] pixel_phase;
    reg [7:0] pixel_b;
    reg [7:0] pixel_g;
    reg [7:0] sector_buffer [0:511];
    reg header_start;
    reg slot_start;
    reg [31:0] idle_cycles;
    reg [31:0] ms_div;
    reg [15:0] scan_ms;
    reg [12:0] frame_ms;
    reg [2:0] finish_sync;
    wire finish_pulse = finish_sync[2] ^ finish_sync[1];
    wire sd_init_done;
    wire [7:0] sd_data;
    wire sd_data_valid;
    wire sd_end;
    wire header_done;
    wire header_ok;
    wire slot_busy;
    wire [1:0] slot_active;
    wire [3:0] slot_error_mask;
    wire slot_committed;
    wire slot_failed;
    wire sector_has_exact_bytes =
        (sector_byte_count == 10'd512 && !sd_data_valid) ||
        (sd_data_valid && sector_byte_count == 10'd511);
    wire consume = state == S_CONSUME && !write_fifo_full && bytes_left != 0;
    wire source_done = consume && bytes_left == 20'd1;
    wire sector_request = state == S_SCAN_WAIT || state == S_LOAD_WAIT;
    wire ms_tick = ms_div == MS_DIVISOR - 1;

    assign write_slot = slot_active;
    assign write_req = state == S_WRITE_REQ;
    assign write_en = consume && pixel_phase == 2'd2;
    assign write_data = {sector_buffer[read_ptr], pixel_g, pixel_b, 8'd0};
    assign media_ready = state == S_READY;

    sd_card_top u_sd (
        .clk(clk), .rst(rst),
        .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK),
        .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO),
        .sd_init_done(sd_init_done),
        .sd_sec_read(sector_request), .sd_sec_read_addr(current_lba),
        .sd_sec_read_data(sd_data),
        .sd_sec_read_data_valid(sd_data_valid),
        .sd_sec_read_end(sd_end),
        .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0),
        .sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(), .sd_sec_write_end()
    );

    bmp_header_validator u_header (
        .clk(clk), .rst(rst), .start(header_start),
        .byte_valid(sd_data_valid && state == S_SCAN_WAIT),
        .byte_index(sector_index), .byte_data(sd_data),
        .sector_done(sd_end && state == S_SCAN_WAIT),
        .done(header_done), .accepted(header_ok)
    );

    frame_slot_mgr u_slots (
        .clk(clk), .rst(rst), .begin_load(slot_start),
        .target_slot(valid_count[1:0]),
        .pixel_accepted(write_en), .source_done(source_done),
        .write_finish(finish_pulse), .load_error(1'b0),
        .busy(slot_busy), .active_slot(slot_active),
        .valid_mask(valid_mask), .error_mask(slot_error_mask),
        .valid_count(valid_count), .load_committed(slot_committed),
        .load_failed(slot_failed)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_INIT;
            state_code <= 4'd0;
            error_code <= 4'd0;
            scan_lba <= 32'd0;
            current_lba <= 32'd0;
            sector_index <= 9'd0;
            sector_byte_count <= 10'd0;
            read_ptr <= 9'd54;
            bytes_left <= 20'd0;
            pixel_phase <= 2'd0;
            pixel_b <= 8'd0;
            pixel_g <= 8'd0;
            header_start <= 1'b0;
            slot_start <= 1'b0;
            idle_cycles <= 32'd0;
            ms_div <= 32'd0;
            scan_ms <= 16'd0;
            frame_ms <= 13'd0;
            finish_sync <= 3'b000;
        end else begin
            finish_sync <= {finish_sync[1:0], write_finish_toggle};
            header_start <= 1'b0;
            slot_start <= 1'b0;
            if (ms_tick)
                ms_div <= 32'd0;
            else
                ms_div <= ms_div + 1'b1;
            if (ms_tick && state != S_READY && state != S_ERROR)
                scan_ms <= scan_ms + 1'b1;
            if (ms_tick && (state == S_WRITE_REQ || state == S_WRITE_ACK_LOW ||
                state == S_CONSUME || state == S_READ_NEXT ||
                state == S_LOAD_WAIT || state == S_WAIT_FINISH))
                frame_ms <= frame_ms + 1'b1;

            if (state == S_SCAN_WAIT || state == S_LOAD_WAIT) begin
                if (sd_data_valid || sd_end)
                    idle_cycles <= 32'd0;
                else
                    idle_cycles <= idle_cycles + 1'b1;
                if (sd_data_valid) begin
                    sector_buffer[sector_index] <= sd_data;
                    sector_index <= sector_index + 1'b1;
                    if (sector_byte_count < 10'd513)
                        sector_byte_count <= sector_byte_count + 1'b1;
                end
            end else begin
                idle_cycles <= 32'd0;
            end

            if ((state == S_INIT && scan_ms >= 16'd5000) ||
                ((state == S_SCAN_WAIT || state == S_LOAD_WAIT) &&
                 idle_cycles >= SECTOR_TIMEOUT)) begin
                state <= S_ERROR;
                state_code <= 4'he;
                error_code <= state == S_INIT ? 4'd1 : 4'd2;
            end else if (state != S_ERROR &&
                         (scan_ms >= 16'd60000 ||
                          frame_ms >= 13'd5000 || slot_failed)) begin
                state <= S_ERROR;
                state_code <= 4'he;
                error_code <= slot_failed ? 4'd6 : 4'd4;
            end else begin
                case (state)
                    S_INIT: if (sd_init_done) begin
                        state <= S_SCAN_START;
                        state_code <= 4'd2;
                    end
                    S_SCAN_START: begin
                        current_lba <= scan_lba;
                        sector_index <= 9'd0;
                        sector_byte_count <= 10'd0;
                        header_start <= 1'b1;
                        state <= S_SCAN_WAIT;
                    end
                    S_SCAN_WAIT: if (sd_end) begin
                        if (sector_has_exact_bytes)
                            state <= S_SCAN_EVAL;
                        else begin
                            state <= S_ERROR;
                            state_code <= 4'he;
                            error_code <= 4'd3;
                        end
                    end
                    S_SCAN_EVAL: if (header_done) begin
                        if (header_ok) begin
                            slot_start <= 1'b1;
                            bytes_left <= PIXEL_BYTES;
                            read_ptr <= 9'd54;
                            pixel_phase <= 2'd0;
                            frame_ms <= 13'd0;
                            state_code <= 4'd3;
                            state <= S_WRITE_REQ;
                        end else if (scan_lba == SCAN_LAST_LBA) begin
                            state <= S_ERROR;
                            state_code <= 4'he;
                            error_code <= 4'd5;
                        end else begin
                            scan_lba <= scan_lba + 1'b1;
                            state <= S_SCAN_START;
                        end
                    end
                    S_WRITE_REQ: if (write_req_ack) state <= S_WRITE_ACK_LOW;
                    S_WRITE_ACK_LOW: if (!write_req_ack) state <= S_CONSUME;
                    S_CONSUME: if (consume) begin
                        case (pixel_phase)
                            2'd0: pixel_b <= sector_buffer[read_ptr];
                            2'd1: pixel_g <= sector_buffer[read_ptr];
                            default: ;
                        endcase
                        pixel_phase <= pixel_phase == 2'd2 ? 2'd0 :
                                       pixel_phase + 1'b1;
                        bytes_left <= bytes_left - 1'b1;
                        if (bytes_left == 20'd1) begin
                            state <= S_WAIT_FINISH;
                        end else if (read_ptr == 9'd511) begin
                            current_lba <= current_lba + 1'b1;
                            sector_index <= 9'd0;
                            sector_byte_count <= 10'd0;
                            read_ptr <= 9'd0;
                            state <= S_READ_NEXT;
                        end else begin
                            read_ptr <= read_ptr + 1'b1;
                        end
                    end
                    S_READ_NEXT: state <= S_LOAD_WAIT;
                    S_LOAD_WAIT: if (sd_end) begin
                        if (sector_has_exact_bytes)
                            state <= S_CONSUME;
                        else begin
                            state <= S_ERROR;
                            state_code <= 4'he;
                            error_code <= 4'd3;
                        end
                    end
                    S_WAIT_FINISH: if (slot_committed) begin
                        if (valid_count == 3'd4) begin
                            state <= S_READY;
                            state_code <= 4'd4;
                        end else if (scan_lba > SCAN_LAST_LBA - FILE_SECTORS) begin
                            state <= S_ERROR;
                            state_code <= 4'he;
                            error_code <= 4'd5;
                        end else begin
                            scan_lba <= scan_lba + FILE_SECTORS;
                            state <= S_SCAN_START;
                            state_code <= 4'd2;
                        end
                    end
                    S_READY: state_code <= 4'd4;
                    S_ERROR: begin
                        state <= S_ERROR;
                        state_code <= 4'he;
                    end
                    default: begin
                        state <= S_ERROR;
                        state_code <= 4'he;
                        error_code <= 4'd7;
                    end
                endcase
            end
        end
    end
endmodule
