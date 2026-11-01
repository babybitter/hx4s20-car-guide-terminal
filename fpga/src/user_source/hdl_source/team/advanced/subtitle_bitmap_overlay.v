// S18 candidate, Verilog-2005. All signals belong to clk (pixel domain).
// 40 cells * 16 rows * 16 bits * 2 banks = 20480 bits, NO memory reset.
// Fixed two-register video latency; read and write ports share one clock.
module subtitle_bitmap_overlay #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer MARGIN_X = 16,
    parameter integer TOP_Y = 384,
    parameter integer SCROLL_GAP = 32
)(
    input wire clk, rst, blank_tick, enable, legacy_select,
    input wire sub_begin, sub_write, sub_commit, sub_abort,
    input wire [15:0] sub_tag, sub_crc,
    input wire [5:0] sub_len0, sub_len1,
    input wire [6:0] sub_index,
    input wire [127:0] sub_chunk,
    output wire [79:0] sub_status,
    output reg bitmap_active,
    input wire [23:0] I_rgb,
    input wire I_hs, I_vs, I_de,
    output reg [23:0] O_rgb,
    output reg O_hs, O_vs, O_de
);
    reg [15:0] bitmap [0:1279];
    reg bank, upload_open, pending, busy, legacy_pending;
    reg [15:0] active_tag, active_crc, upload_tag, version;
    reg [15:0] expected_crc, running_crc;
    reg [5:0] next_len0, next_len1, len0, len1;
    reg [7:0] count;
    reg [3:0] error;
    reg [2:0] pair;
    reg [127:0] data_shift;
    // Error codes: 1 busy, 2 no begin, 3 order, 4 CRC, 5 count,
    // 6 token, 7 range. Sticky until OB or OX; bad uploads cannot commit.
    assign sub_status={active_tag,active_crc,upload_tag,version,count,
                       busy,bitmap_active,pending,upload_open,error};
    function [15:0] crc_byte;
        input [15:0] crc;
        input [7:0] data;
        reg [15:0] c;
        integer i;
        begin
            c=crc^{data,8'd0};
            for(i=0;i<8;i=i+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_byte=c;
        end
    endfunction
    wire [15:0] pair_crc=crc_byte(crc_byte(running_crc,data_shift[127:120]),data_shift[119:112]);
    wire [10:0] write_addr=(bank ? 11'd0 : 11'd640)+{1'b0,count[6:0],3'b000}+{8'd0,pair};
    // Writes always target the inactive bank. Aborting may leave partial data
    // there, but the next OB must overwrite all 80 chunks before commit.
    always @(posedge clk) begin
        if(busy && !rst && !sub_abort && !legacy_select)
            bitmap[write_addr]<=data_shift[127:112];
    end

    wire publish=pending && blank_tick && !I_de && !sub_abort && !legacy_select;
    wire legacy_publish=legacy_pending && blank_tick && !I_de;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            bank<=0; bitmap_active<=0; upload_open<=0; pending<=0; busy<=0;
            legacy_pending<=0; active_tag<=0; active_crc<=0; upload_tag<=0; version<=0;
            expected_crc<=0; running_crc<=16'hffff; next_len0<=0; next_len1<=0;
            len0<=0; len1<=0; count<=0; error<=0; pair<=0; data_shift<=0;
        end else begin
            if(publish) begin
                bank<=~bank; bitmap_active<=1; pending<=0;
                active_tag<=upload_tag; active_crc<=expected_crc;
                len0<=next_len0; len1<=next_len1; version<=version+1'b1;
            end
            if(legacy_publish) begin
                bitmap_active<=0; legacy_pending<=0;
            end
            if(busy) begin
                running_crc<=pair_crc; data_shift<={data_shift[111:0],16'd0};
                pair<=pair+1'b1;
                if(pair==7) begin busy<=0; count<=count+1'b1; end
            end
            if(legacy_select || sub_abort) begin
                busy<=0; pending<=0; upload_open<=0; count<=0; error<=0;
                if(legacy_select) legacy_pending<=1;
            end else if(sub_begin) begin
                if(busy || pending) error<=1;
                else if(({1'b0,sub_len0}+{1'b0,sub_len1})>7'd40) begin
                    error<=7; upload_open<=0;
                end else begin
                    upload_tag<=sub_tag; expected_crc<=sub_crc;
                    next_len0<=sub_len0; next_len1<=sub_len1;
                    // Protect line layout as well as all fixed-size bitmap bytes.
                    count<=0; running_crc<=crc_byte(crc_byte(16'hffff,{2'b0,sub_len0}),{2'b0,sub_len1});
                    upload_open<=1; error<=0;
                end
            end else if(sub_write) begin
                if(busy || pending) error<=1;
                else if(!upload_open) error<=2;
                else if(error!=0) begin upload_open<=0; end
                else if(count>=80 || {1'b0,sub_index}!=count) begin
                    error<=3; upload_open<=0;
                end else begin
                    busy<=1; pair<=0; data_shift<=sub_chunk;
                end
            end else if(sub_commit) begin
                if(busy || pending) error<=1;
                else if(!upload_open) error<=2;
                else begin
                    upload_open<=0;
                    if(error!=0) begin end
                    else if(sub_tag!=upload_tag) error<=6;
                    else if(count!=80) error<=5;
                    else if(running_crc!=expected_crc) error<=4;
                    else begin pending<=1; legacy_pending<=0; end
                end
            end
        end
    end

    // Coordinates count active pixels; VS resets y regardless of polarity
    // because only the rising edge is used, wholly within vertical blank.
    reg de_d, vs_d;
    reg [10:0] x;
    reg [9:0] y;
    reg [10:0] scroll0, scroll1;
    // Exact +30% relative to 1px/frame: retain the fractional 3/10 pixel.
    // Position after N blank ticks is floor(13*N/10), modulo each extent.
    reg [3:0] scroll_fraction;
    wire [1:0] scroll_step=scroll_fraction>=7 ? 2'd2 : 2'd1;
    wire [11:0] next_scroll0={1'b0,scroll0}+scroll_step;
    wire [11:0] next_scroll1={1'b0,scroll1}+scroll_step;
    wire [10:0] width0={1'b0,len0,4'd0};
    wire [10:0] width1={1'b0,len1,4'd0};
    wire [10:0] extent0=(width0>ACTIVE_WIDTH-2*MARGIN_X) ?
        width0+SCROLL_GAP : ACTIVE_WIDTH-2*MARGIN_X+SCROLL_GAP;
    wire [10:0] extent1=(width1>ACTIVE_WIDTH-2*MARGIN_X) ?
        width1+SCROLL_GAP : ACTIVE_WIDTH-2*MARGIN_X+SCROLL_GAP;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            de_d<=0; vs_d<=0; x<=0; y<=0;
            scroll0<=0; scroll1<=0; scroll_fraction<=0;
        end else begin
            de_d<=I_de; vs_d<=I_vs;
            if(I_vs && !vs_d) begin x<=0; y<=0; end
            else begin
                if(I_de) x<=x+1'b1; else x<=0;
                if(de_d && !I_de) y<=y+1'b1;
            end
            if(publish || legacy_publish) begin
                scroll0<=0; scroll1<=0; scroll_fraction<=0;
            end else if(blank_tick && !I_de && bitmap_active && enable) begin
                scroll_fraction<=scroll_fraction>=7 ? scroll_fraction-4'd7 : scroll_fraction+4'd3;
                scroll0<=next_scroll0>=extent0 ? next_scroll0-extent0 : next_scroll0[10:0];
                scroll1<=next_scroll1>=extent1 ? next_scroll1-extent1 : next_scroll1[10:0];
            end
        end
    end
    wire second_line=(y>=TOP_Y+16);
    wire [5:0] line_len=second_line ? len1 : len0;
    wire [10:0] shift=second_line ? scroll1 : scroll0;
    // Text traverses the 608px safe viewport, then a 32px gap. A single
    // subtract is sufficient since x < 640 and extent >= 32 only for long
    // strings; short strings use a minimum viewport-length cycle.
    wire [10:0] text_width={1'b0,line_len,4'd0};
    wire [10:0] cycle_width=(text_width>ACTIVE_WIDTH-2*MARGIN_X) ?
                               text_width+SCROLL_GAP : ACTIVE_WIDTH-2*MARGIN_X+SCROLL_GAP;
    wire [11:0] shifted_x={1'b0,x}+{1'b0,shift}-MARGIN_X;
    wire [10:0] source_x=(shifted_x>=cycle_width) ? shifted_x-cycle_width : shifted_x[10:0];
    wire draw_inside=I_de && enable && bitmap_active &&
        x>=MARGIN_X && x<ACTIVE_WIDTH-MARGIN_X && y>=TOP_Y && y<TOP_Y+32 &&
        source_x<text_width;
    wire [6:0] cell_index={1'b0,source_x[9:4]}+(second_line ? {1'b0,len0} : 7'd0);
    wire [3:0] row=y-TOP_Y;
    wire [10:0] read_addr=(bank ? 11'd640 : 11'd0)+{cell_index,4'b0000}+{7'd0,row};
    reg [15:0] read_word;
    // Clamp inactive addressing; uninitialized RAM never contributes a pixel.
    always @(posedge clk) read_word<=bitmap[draw_inside ? read_addr : 11'd0];
    reg [23:0] rgb_d;
    reg hs_d, vs_pipe, de_pipe, inside_d;
    reg [3:0] bit_d;
    function [7:0] glyph_alpha;
        input [7:0] c;
        reg [9:0] sum;
        begin sum={2'b0,c}+10'd765; glyph_alpha=sum[9:2]; end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            rgb_d<=0; hs_d<=0; vs_pipe<=0; de_pipe<=0; inside_d<=0; bit_d<=0;
            O_rgb<=0; O_hs<=0; O_vs<=0; O_de<=0;
        end else begin
            rgb_d<=I_rgb; hs_d<=I_hs; vs_pipe<=I_vs; de_pipe<=I_de;
            inside_d<=draw_inside; bit_d<=source_x[3:0];
            O_hs<=hs_d; O_vs<=vs_pipe; O_de<=de_pipe;
            O_rgb<=rgb_d;
            if(inside_d && read_word[15-bit_d])
                O_rgb<={glyph_alpha(rgb_d[23:16]),glyph_alpha(rgb_d[15:8]),glyph_alpha(rgb_d[7:0])};
        end
    end
endmodule
