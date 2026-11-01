// Verilog-2005; all signals belong to clk (pixel domain).
// Wire storage stays 40 * 16 * 16 * 2 banks = 20480 bits, NO RAM reset.
// Display cells are 21x21. Exactly two RAM ports and two video registers.
module subtitle_bitmap_overlay #(
    parameter integer ACTIVE_WIDTH = 640,
    parameter integer MARGIN_X = 16,
    parameter integer TOP_Y = 406,
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
    reg [5:0] next_len0, len0;
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
    // Port A writes only during blanking, and reads foreground during active
    // video. CRC/data/pair advance on exactly the same write enable. A chunk
    // can span several blank intervals without modifying the visible bank.
    wire write_enable=busy && !I_de && !rst && !sub_abort && !legacy_select;

    wire publish=pending && blank_tick && !I_de && !sub_abort && !legacy_select;
    wire legacy_publish=legacy_pending && blank_tick && !I_de;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            bank<=0; bitmap_active<=0; upload_open<=0; pending<=0; busy<=0;
            legacy_pending<=0; active_tag<=0; active_crc<=0; upload_tag<=0; version<=0;
            expected_crc<=0; running_crc<=16'hffff; next_len0<=0;
            len0<=0; count<=0; error<=0; pair<=0; data_shift<=0;
        end else begin
            if(publish) begin
                bank<=~bank; bitmap_active<=1; pending<=0;
                active_tag<=upload_tag; active_crc<=expected_crc;
                len0<=next_len0; version<=version+1'b1;
            end
            if(legacy_publish) begin
                bitmap_active<=0; legacy_pending<=0;
            end
            if(write_enable) begin
                running_crc<=pair_crc; data_shift<={data_shift[111:0],16'd0};
                pair<=pair+1'b1;
                if(pair==7) begin busy<=0; count<=count+1'b1; end
            end
            if(legacy_select || sub_abort) begin
                busy<=0; pending<=0; upload_open<=0; count<=0; error<=0;
                if(legacy_select) legacy_pending<=1;
            end else if(sub_begin) begin
                if(busy || pending) error<=1;
                else if(sub_len0>6'd40 || sub_len1!=0) begin
                    error<=7; upload_open<=0;
                end else begin
                    upload_tag<=sub_tag; expected_crc<=sub_crc;
                    next_len0<=sub_len0;
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
    localparam integer RIGHT_X=ACTIVE_WIDTH-MARGIN_X;
    localparam integer VIEW_WIDTH=ACTIVE_WIDTH-2*MARGIN_X;
    // Signed cell + 0..20 column represent source x at screen x=0.
    // Only constant parameter arithmetic uses division; the pixel path uses
    // small wrapping counters, avoiding a /21 divider or extra lookup RAM.
    localparam integer START_CELL=-(RIGHT_X+20)/21;
    localparam integer START_COL=-(START_CELL*21)-RIGHT_X;
    reg [10:0] scroll0;
    reg signed [7:0] seed_cell, pixel_cell;
    reg [4:0] seed_col, pixel_col;
    // Exact +30% relative to 1px/frame: retain the fractional 3/10 pixel.
    // Position after N blank ticks is floor(13*N/10), modulo the extent.
    reg [3:0] scroll_fraction;
    wire [1:0] scroll_step=scroll_fraction>=7 ? 2'd2 : 2'd1;
    wire [11:0] next_scroll0={1'b0,scroll0}+scroll_step;
    wire [10:0] width0={1'b0,len0,4'd0}+{3'b0,len0,2'd0}+{5'd0,len0};
    // Start wholly beyond the right edge, leave wholly beyond the left edge,
    // then retain a gap. Short strings travel the entire viewport as well.
    wire [10:0] extent0=VIEW_WIDTH+width0+SCROLL_GAP;
    wire advance=blank_tick && !I_de && bitmap_active && enable;
    wire restart=publish || legacy_publish;
    wire wrap_scroll=next_scroll0>=extent0;
    wire [5:0] next_seed_col={1'b0,seed_col}+scroll_step;
    wire [5:0] wrap_seed_col=START_COL+(next_scroll0-extent0);
    wire signed [7:0] updated_cell=restart ? START_CELL :
        !advance ? seed_cell : wrap_scroll ? START_CELL+(wrap_seed_col>=21) :
        seed_cell+(next_seed_col>=21);
    wire [4:0] updated_col=restart ? START_COL : !advance ? seed_col :
        wrap_scroll ? (wrap_seed_col>=21 ? wrap_seed_col-21 : wrap_seed_col) :
        (next_seed_col>=21 ? next_seed_col-21 : next_seed_col);
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            de_d<=0; vs_d<=0; x<=0; y<=0;
            scroll0<=0; scroll_fraction<=0;
            seed_cell<=START_CELL; seed_col<=START_COL;
            pixel_cell<=START_CELL; pixel_col<=START_COL;
        end else begin
            de_d<=I_de; vs_d<=I_vs;
            if(I_vs && !vs_d) begin x<=0; y<=0; end
            else begin
                if(I_de) x<=x+1'b1; else x<=0;
                if(de_d && !I_de) y<=y+1'b1;
            end
            seed_cell<=updated_cell; seed_col<=updated_col;
            if(!I_de) begin
                pixel_cell<=updated_cell; pixel_col<=updated_col;
            end else if(pixel_col==20) begin
                pixel_cell<=pixel_cell+1'b1; pixel_col<=0;
            end else pixel_col<=pixel_col+1'b1;
            if(restart) begin
                scroll0<=0; scroll_fraction<=0;
            end else if(advance) begin
                scroll_fraction<=scroll_fraction>=7 ? scroll_fraction-4'd7 : scroll_fraction+4'd3;
                scroll0<=wrap_scroll ? next_scroll0-extent0 : next_scroll0[10:0];
            end
        end
    end
    // floor(display_coordinate * 16 / 21), shared with the host preview.
    function [3:0] source_pixel;
        input [4:0] p;
        begin
            case(p)
                0,1: source_pixel=0;
                2: source_pixel=1; 3: source_pixel=2;
                4,5: source_pixel=3;
                6: source_pixel=4; 7: source_pixel=5;
                8,9: source_pixel=6;
                10: source_pixel=7; 11: source_pixel=8;
                12,13: source_pixel=9;
                14: source_pixel=10; 15: source_pixel=11;
                16,17: source_pixel=12;
                18: source_pixel=13; 19: source_pixel=14;
                20: source_pixel=15;
                default: source_pixel=0;
            endcase
        end
    endfunction
    wire signed [7:0] shadow_cell=pixel_col<2 ? pixel_cell-8'sd1 : pixel_cell;
    wire [4:0] shadow_col=pixel_col<2 ? pixel_col+5'd19 : pixel_col-5'd2;
    wire viewport=I_de && enable && bitmap_active && x>=MARGIN_X && x<RIGHT_X;
    wire draw_inside=viewport && y>=TOP_Y && y<TOP_Y+21 &&
        !pixel_cell[7] && pixel_cell[6:0]<{1'b0,len0};
    wire shadow_inside=viewport && y>=TOP_Y+2 && y<TOP_Y+23 &&
        !shadow_cell[7] && shadow_cell[6:0]<{1'b0,len0};
    wire draw_line=viewport && y>=TOP_Y+27 && y<TOP_Y+29;
    wire [4:0] row=y-TOP_Y, shadow_row=y-TOP_Y-2;
    wire [10:0] read_addr=(bank ? 11'd640 : 11'd0)+
        {1'b0,pixel_cell[5:0],4'b0000}+{7'd0,source_pixel(row)};
    wire [10:0] shadow_addr=(bank ? 11'd640 : 11'd0)+
        {1'b0,shadow_cell[5:0],4'b0000}+{7'd0,source_pixel(shadow_row)};
    // One address mux for the read/write port, not a third memory port.
    wire [10:0] port_a_addr=write_enable ? write_addr : (draw_inside ? read_addr : 11'd0);
    reg [15:0] read_word, shadow_word;
    always @(posedge clk) begin
        if(write_enable) bitmap[port_a_addr]<=data_shift[127:112];
        read_word<=bitmap[port_a_addr];
    end
    always @(posedge clk)
        shadow_word<=bitmap[shadow_inside ? shadow_addr : 11'd0];
    reg [23:0] rgb_d;
    reg hs_d, vs_pipe, de_pipe, inside_d, shadow_d, line_d;
    reg [3:0] bit_d, shadow_bit_d;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            rgb_d<=0; hs_d<=0; vs_pipe<=0; de_pipe<=0; inside_d<=0; bit_d<=0;
            shadow_d<=0; shadow_bit_d<=0; line_d<=0;
            O_rgb<=0; O_hs<=0; O_vs<=0; O_de<=0;
        end else begin
            rgb_d<=I_rgb; hs_d<=I_hs; vs_pipe<=I_vs; de_pipe<=I_de;
            inside_d<=draw_inside; bit_d<=source_pixel(pixel_col);
            shadow_d<=shadow_inside; shadow_bit_d<=source_pixel(shadow_col);
            line_d<=draw_line;
            O_hs<=hs_d; O_vs<=vs_pipe; O_de<=de_pipe;
            O_rgb<=rgb_d;
            if(shadow_d && shadow_word[15-shadow_bit_d])
                O_rgb<={1'b0,rgb_d[23:17],1'b0,rgb_d[15:9],1'b0,rgb_d[7:1]};
            if(inside_d && read_word[15-bit_d])
                O_rgb<=24'hE5E7EB;
            if(line_d) O_rgb<=24'h36D5E3;
        end
    end
endmodule
