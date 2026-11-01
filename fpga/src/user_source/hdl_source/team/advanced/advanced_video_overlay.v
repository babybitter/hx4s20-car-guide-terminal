// s08 isolated candidate: three registered RGB stages, including bypass.
// S0 contrast/brightness/filter + input metadata, S1 transition/blend,
// S2 overlay selection. Coordinate and text decisions belong to the S0 pixel.
module advanced_video_overlay #(parameter HALF_ZOOM_ENABLE=0) (
    input wire        video_clk,
    input wire        rst,
    input wire        enable,
    input wire        hs,
    input wire        vs,
    input wire        de,
    input wire [23:0] rgb_in,
    input wire [6:0]  image_index,
    input wire        auto_play,
    input wire        zoom_2x,
    input wire        audio_ready,
    input wire [1:0]  brightness_level,
    input wire [1:0]  contrast_level,
    input wire [2:0]  filter_mode,
    input wire [1:0]  transition_style,
    input wire [3:0]  transition_level,
    input wire        uart_seen,
    input wire        stability_alert,
    input wire [3:0]  stability_error_count,
    input wire [3:0]  audio_level,
    input wire [319:0] scroll_text,
    input wire [5:0]  scroll_text_len,
    output reg [23:0] rgb_out,
    input wire [1:0] zoom_setting
);
    localparam [10:0] SCROLL_PERIOD = 11'd1280;
    localparam [10:0] SCROLL_TEXT_START = 11'd640;
    localparam [10:0] SCROLL_TEXT_END = 11'd1280;
    localparam [5:0] SCROLL_TEXT_SLOTS = 6'd40;

    reg de_d;
    reg vs_d;
    reg [10:0] x_pos;
    reg [9:0] y_pos;
    reg [10:0] scroll_offset;
    // 1 + 3/10 pixels/frame: exactly 13 pixels per ten VS rising edges.
    reg [3:0] scroll_fraction;
    wire scroll_extra = (scroll_fraction >= 4'd7);
    wire [10:0] scroll_next = scroll_offset + (scroll_extra ? 11'd2 : 11'd1);
    reg [5:0] frame_div;
    reg [3:0] sec_ones;
    reg [3:0] sec_tens;
    reg [3:0] min_ones;
    reg [3:0] min_tens;
    reg [6:0] image_index_meta;
    reg [6:0] image_index_sync;
    reg auto_meta;
    reg auto_sync;
    reg [1:0] zoom_meta;
    reg [1:0] zoom_sync;
    reg audio_meta;
    reg audio_sync;
    reg stability_meta;
    reg stability_sync;
    reg [3:0] health_count_meta;
    reg [3:0] health_count_sync;
    reg [3:0] audio_level_meta;
    reg [3:0] audio_level_sync;
    reg [23:0] prep_rgb_in, prep_processed_rgb;
    reg [3:0] prep_transition_level;
    reg [1:0] prep_transition_style;
    reg prep_wipe_x_visible, prep_wipe_y_visible, prep_checker_visible;
    reg [14:0] prep_overlay_flags;
    reg [2:0] prep_top_col, prep_top_shadow_col;
    reg [2:0] prep_scroll_col, prep_scroll_shadow_col;
    reg [23:0] stage_rgb_in;
    reg [23:0] stage_transition_rgb;
    reg [23:0] stage_osd_band_rgb;
    reg [23:0] stage_side_border_rgb;
    reg [23:0] stage_meter_bg_rgb;
    reg stage_enable;
    reg stage_de;
    reg stage_top_band;
    reg stage_top_shadow_pixel;
    reg stage_top_text_pixel;
    reg stage_top_edge;
    reg stage_bottom_band;
    reg stage_scroll_shadow_pixel;
    reg stage_scroll_text_pixel;
    reg stage_bottom_edge;
    reg stage_side_border;
    reg stage_meter_bg;
    reg stage_meter_pixel;
    reg stage_alert_border;
    reg stage_stability_sync;

    function [7:0] hex_char;
        input [3:0] value;
        begin
            if (value < 4'd10)
                hex_char = 8'h30 + value;
            else
                hex_char = 8'h41 + (value - 4'd10);
        end
    endfunction

    // The displayed page is exactly 1..128. Keep every intermediate bounded;
    // no 32-bit constant division/remainder or multiplier-based reciprocal.
    function [11:0] page_decimal;
        input [6:0] image_num;
        reg [7:0] number;
        reg hundreds, t8, t4, t2, t1;
        reg [6:0] r100, r80;
        reg [5:0] r40;
        reg [4:0] r20;
        reg [3:0] units;
        begin
            number = {1'b0, image_num} + 8'd1;
            hundreds = number >= 8'd100;
            r100 = hundreds ? number - 8'd100 : number[6:0];
            t8 = r100 >= 7'd80;
            r80 = t8 ? r100 - 7'd80 : r100;
            t4 = r80 >= 7'd40;
            r40 = t4 ? r80 - 7'd40 : r80[5:0];
            t2 = r40 >= 6'd20;
            r20 = t2 ? r40 - 6'd20 : r40[4:0];
            t1 = r20 >= 5'd10;
            units = t1 ? r20 - 5'd10 : r20[3:0];
            page_decimal = {3'b000, hundreds, t8, t4, t2, t1, units};
        end
    endfunction

    function [7:0] top_char;
        input [5:0] index;
        input [6:0] image_num;
        input       auto_mode;
        input [1:0] zoom_mode;
        input       audio_mode;
        input       serial_seen;
        input [1:0] brightness_value;
        input [1:0] contrast_value;
        input [2:0] filter_value;
        input [1:0] trans_style;
        input       health_alert;
        input [3:0] health_count;
        input [3:0] level;
        input [3:0] mt;
        input [3:0] mo;
        input [3:0] st;
        input [3:0] so;
        reg [11:0] page_digits;
        begin
            page_digits = page_decimal(image_num);
            top_char = 8'h20;
            case (index)
                6'd0:  top_char = "P";
                6'd1:  top_char = {4'h3, page_digits[11:8]};
                6'd2:  top_char = {4'h3, page_digits[7:4]};
                6'd3:  top_char = {4'h3, page_digits[3:0]};
                6'd4:  top_char = " ";
                6'd5:  top_char = 8'h30 + mt;
                6'd6:  top_char = 8'h30 + mo;
                6'd7:  top_char = ":";
                6'd8:  top_char = 8'h30 + st;
                6'd9:  top_char = 8'h30 + so;
                6'd10: top_char = " ";
                6'd11: top_char = auto_mode ? "A" : "M";
                6'd12: top_char = auto_mode ? "U" : "A";
                6'd13: top_char = auto_mode ? "T" : "N";
                6'd14: top_char = auto_mode ? "O" : "U";
                6'd15: top_char = " ";
                6'd16: top_char = "Z";
                6'd17: top_char = "0" + {6'b0,zoom_mode};
                6'd18: top_char = " ";
                6'd19: top_char = "B";
                6'd20: top_char = 8'h30 + {6'd0, brightness_value};
                6'd21: top_char = " ";
                6'd22: top_char = "C";
                6'd23: top_char = 8'h30 + {6'd0, contrast_value};
                6'd24: top_char = " ";
                6'd25: top_char = "F";
                6'd26: top_char = 8'h30 + {5'd0, filter_value};
                6'd27: top_char = " ";
                6'd28: top_char = "T";
                6'd29: top_char = 8'h30 + {6'd0, trans_style};
                6'd30: top_char = " ";
                6'd31: top_char = audio_mode ? "A" : "-";
                6'd32: top_char = serial_seen ? "U" : "-";
                6'd33: top_char = " ";
                6'd34: top_char = "H";
                6'd35: top_char = hex_char(health_count);
                6'd36: top_char = health_alert ? "E" : " ";
                6'd37: top_char = "L";
                6'd38: top_char = hex_char(level);
                default: top_char = 8'h20;
            endcase
        end
    endfunction

    function [7:0] default_scroll_char;
        input [5:0] index;
        begin
            default_scroll_char = 8'h20;
            case (index)
                6'd0:  default_scroll_char = "H";
                6'd1:  default_scroll_char = "X";
                6'd2:  default_scroll_char = "4";
                6'd3:  default_scroll_char = "S";
                6'd4:  default_scroll_char = "2";
                6'd5:  default_scroll_char = "0";
                6'd6:  default_scroll_char = " ";
                6'd7:  default_scroll_char = "I";
                6'd8:  default_scroll_char = "M";
                6'd9:  default_scroll_char = "A";
                6'd10: default_scroll_char = "G";
                6'd11: default_scroll_char = "E";
                6'd12: default_scroll_char = " ";
                6'd13: default_scroll_char = "P";
                6'd14: default_scroll_char = "R";
                6'd15: default_scroll_char = "O";
                6'd16: default_scroll_char = "C";
                6'd17: default_scroll_char = "E";
                6'd18: default_scroll_char = "S";
                6'd19: default_scroll_char = "S";
                6'd20: default_scroll_char = "I";
                6'd21: default_scroll_char = "N";
                6'd22: default_scroll_char = "G";
                6'd23: default_scroll_char = " ";
                6'd24: default_scroll_char = "O";
                6'd25: default_scroll_char = "S";
                6'd26: default_scroll_char = "D";
                6'd27: default_scroll_char = " ";
                6'd28: default_scroll_char = "L";
                6'd29: default_scroll_char = "A";
                6'd30: default_scroll_char = "Y";
                6'd31: default_scroll_char = "E";
                6'd32: default_scroll_char = "R";
                default: default_scroll_char = 8'h20;
            endcase
        end
    endfunction

    function [7:0] scroll_char;
        input [5:0] index;
        input [319:0] dynamic_text;
        input [5:0] dynamic_len;
        begin
            if (dynamic_len == 6'd0)
                scroll_char = 8'h20;
            else if ((index < dynamic_len) && (index < SCROLL_TEXT_SLOTS))
                scroll_char = dynamic_text[index*8 +: 8];
            else
                scroll_char = 8'h20;
        end
    endfunction

    // Font data is read synchronously at S0 by the shared dual-port ROM below.

    function [7:0] fade_channel;
        input [7:0] value;
        input [3:0] level;
        reg [11:0] product;
        reg [8:0] correction;
        reg [7:0] rounded;
        begin
            product=value*level;
            // If p=16*a+b, floor((17*p+128)/256)
            // is a+floor((a+b+8)/16), exactly (0<=b<16).
            correction={1'b0,product[11:4]}+{5'd0,product[3:0]}+9'd8;
            rounded=product[11:4]+{3'd0,correction[8:4]};
            if(level==0)fade_channel=0;
            else if(level==15)fade_channel=value;
            else fade_channel=rounded;
        end
    endfunction

    function [23:0] fade_rgb;
        input [23:0] rgb;
        input [3:0] level;
        begin
            fade_rgb = {
                fade_channel(rgb[23:16], level),
                fade_channel(rgb[15:8], level),
                fade_channel(rgb[7:0], level)
            };
        end
    endfunction

    function [7:0] blend25_channel;
        input [7:0] base;
        input [7:0] layer;
        reg [9:0] sum;
        begin
            sum = {2'b00, base} + {2'b00, base} + {2'b00, base} + {2'b00, layer};
            blend25_channel = sum[9:2];
        end
    endfunction

    function [23:0] blend25_rgb;
        input [23:0] base;
        input [23:0] layer;
        begin
            blend25_rgb = {
                blend25_channel(base[23:16], layer[23:16]),
                blend25_channel(base[15:8], layer[15:8]),
                blend25_channel(base[7:0], layer[7:0])
            };
        end
    endfunction

    function [7:0] blend50_channel;
        input [7:0] base;
        input [7:0] layer;
        begin
            blend50_channel = ({1'b0, base} + {1'b0, layer}) >> 1;
        end
    endfunction

    function [23:0] blend50_rgb;
        input [23:0] base;
        input [23:0] layer;
        begin
            blend50_rgb = {
                blend50_channel(base[23:16], layer[23:16]),
                blend50_channel(base[15:8], layer[15:8]),
                blend50_channel(base[7:0], layer[7:0])
            };
        end
    endfunction

    function glyph_col_bit;
        input [4:0] bits;
        input [2:0] col;
        begin
            case (col)
                3'd0: glyph_col_bit = bits[4];
                3'd1: glyph_col_bit = bits[3];
                3'd2: glyph_col_bit = bits[2];
                3'd3: glyph_col_bit = bits[1];
                3'd4: glyph_col_bit = bits[0];
                default: glyph_col_bit = 1'b0;
            endcase
        end
    endfunction

    function [7:0] sat_add;
        input [7:0] value;
        input [6:0] amount;
        reg [8:0] sum;
        begin
            sum = {1'b0, value} + {2'b00, amount};
            sat_add = sum[8] ? 8'hFF : sum[7:0];
        end
    endfunction

    function [7:0] sat_sub;
        input [7:0] value;
        input [6:0] amount;
        begin
            sat_sub = (value > {1'b0, amount}) ? (value - {1'b0, amount}) : 8'h00;
        end
    endfunction

    function [7:0] contrast_high;
        input [7:0] value;
        reg [8:0] scaled;
        reg [9:0] shifted;
        begin
            // Below 128, the old subtract uses floor((128-value)/2):
            // its odd input correction must survive before clipping.
            scaled={1'b0,value}+{2'b0,value[7:1]}+
                {8'd0,(!value[7] && value[0])};
            shifted={1'b0,scaled}-10'd64;
            contrast_high=shifted[9] ? 8'd0 : shifted[8] ? 8'hff : shifted[7:0];
        end
    endfunction

    function [7:0] contrast_low;
        input [7:0] value;
        begin
            contrast_low = {value[7],~value[7],value[6:1]};
        end
    endfunction

    function [7:0] brightness_adjust_channel;
        input [7:0] value;
        input [1:0] level;
        reg [3:0] delta, high_sum;
        begin
            // All offsets are multiples of 32. Preserve low five bits unless
            // saturation occurs; the fourth sum bit is carry or borrow.
            case(level)
                2'd0:delta=4'hf;
                2'd2:delta=4'd1;
                2'd3:delta=4'd2;
                default:delta=4'd0;
            endcase
            high_sum={1'b0,value[7:5]}+delta;
            brightness_adjust_channel=high_sum[3] ?
                (level==0 ? 8'd0 : 8'hff) : {high_sum[2:0],value[4:0]};
        end
    endfunction

    function [7:0] contrast_adjust_channel;
        input [7:0] value;
        input [1:0] level;
        reg [7:0] base;
        reg [8:0] delta, sum;
        reg negative, round_up;
        begin
            base=value;delta=0;negative=0;round_up=0;
            case(level)
                2'd0:begin base={1'b0,value[7:1]};delta=9'd64;end
                2'd2:begin
                    delta={{3{~value[7]}},value[6:1]};
                    negative=~value[7];round_up=~value[7] && value[0];
                end
                2'd3:begin
                    delta=value[7] ? 9'd48 : 9'h1d0;negative=~value[7];
                end
                default:;
            endcase
            sum={1'b0,base}+delta+{8'd0,round_up};
            contrast_adjust_channel=sum[8] ? (negative ? 8'd0 : 8'hff) : sum[7:0];
        end
    endfunction

    function [7:0] adjust_channel;
        input [7:0] value;
        input [1:0] brightness;
        input [1:0] contrast;
        begin
            adjust_channel =
                brightness_adjust_channel(contrast_adjust_channel(value, contrast), brightness);
        end
    endfunction

    function [23:0] adjust_rgb;
        input [23:0] rgb;
        input [1:0] brightness;
        input [1:0] contrast;
        begin
            adjust_rgb = {
                adjust_channel(rgb[23:16], brightness, contrast),
                adjust_channel(rgb[15:8], brightness, contrast),
                adjust_channel(rgb[7:0], brightness, contrast)
            };
        end
    endfunction

    function [7:0] luma8;
        input [23:0] rgb;
        reg [9:0] y_sum;
        begin
            y_sum = {1'b0, rgb[23:16] >> 2} +
                    {2'b00, rgb[23:16] >> 5} +
                    {1'b0, rgb[15:8] >> 1} +
                    {2'b00, rgb[15:8] >> 4} +
                    {2'b00, rgb[7:0] >> 4} +
                    {2'b00, rgb[7:0] >> 5};
            luma8 = y_sum[7:0];
        end
    endfunction

    function [23:0] pseudo_color_rgb;
        input [7:0] gray;
        begin
            if (gray < 8'd64)
                pseudo_color_rgb = {8'h00, gray[5:0], 2'b00, 8'hFF};
            else if (gray < 8'd128)
                pseudo_color_rgb = {8'h00, 8'hFF, 8'd191 - gray};
            else if (gray < 8'd192)
                pseudo_color_rgb = {gray, 8'hFF, 8'h00};
            else
                pseudo_color_rgb = {8'hFF, 8'd255 - gray, 8'h00};
        end
    endfunction

    function [23:0] filter_rgb;
        input [23:0] rgb;
        input [2:0] mode;
        reg [7:0] gray;
        begin
            gray = luma8(rgb);
            case (mode)
                3'd1: filter_rgb = {gray, gray, gray};
                3'd2: filter_rgb = ~rgb;
                3'd3: filter_rgb = (gray > 8'd128) ? 24'hFFFFFF : 24'h000000;
                3'd4: filter_rgb = pseudo_color_rgb(gray);
                3'd5: filter_rgb = {
                    rgb[23:21], 5'b00000,
                    rgb[15:13], 5'b00000,
                    rgb[7:5], 5'b00000
                };
                default: filter_rgb = rgb;
            endcase
        end
    endfunction

    function [5:0] meter_height;
        input [3:0] level;
        input [2:0] bar_index;
        input [3:0] phase;
        reg [4:0] mixed;
        begin
            mixed = {1'b0, level} + {2'b00, bar_index} + {4'b0000, phase[0]};
            if (mixed > 5'd15)
                mixed = 5'd15;
            meter_height = {mixed, 1'b0} + 6'd6;
        end
    endfunction

    wire frame_tick = (!vs_d && vs);
    wire [23:0] adjusted_rgb =
        adjust_rgb(rgb_in, brightness_level, contrast_level);
    wire [23:0] processed_rgb = filter_rgb(adjusted_rgb, filter_mode);
    wire [23:0] faded_rgb = fade_rgb(prep_processed_rgb, prep_transition_level);
    wire [10:0] wipe_x_limit = {transition_level, 5'b00000} + {transition_level, 3'b000};
    wire [9:0] wipe_y_limit = {transition_level, 5'b00000} - {transition_level, 1'b0};
    wire wipe_x_visible = (transition_level == 4'hF) || (x_pos < wipe_x_limit);
    wire wipe_y_visible = (transition_level == 4'hF) || (y_pos < wipe_y_limit);
    wire [3:0] checker_phase = x_pos[7:4] + y_pos[7:4];
    wire checker_visible = (transition_level == 4'hF) || (checker_phase < transition_level);
    reg [23:0] transition_rgb;

    wire top_text_region = (y_pos >= 10'd10) && (y_pos < 10'd24);
    wire [10:0] top_text_x = x_pos - 11'd12;
    wire [5:0] top_slot = (x_pos >= 11'd12) ? top_text_x[9:4] : 6'd63;
    wire [3:0] top_col = top_text_x[3:0];
    wire [2:0] top_row = (y_pos - 10'd10) >> 1;
    // Select before the original S0 edge. Both valid top requests share
    // a slot (10-pixel glyph, 16-pixel pitch, 2-pixel shadow offset).
    // On shadow-only tail rows/columns select its slot instead.
    wire [5:0] top_character_slot = top_text_pixel ? top_slot : top_shadow_slot;
    wire [7:0] top_glyph_char = top_char(
        top_character_slot,
        image_index_sync,
        auto_sync,
        zoom_sync,
        audio_sync,
        uart_seen,
        brightness_level,
        contrast_level,
        filter_mode,
        transition_style,
        stability_sync,
        health_count_sync,
        audio_level_sync,
        min_tens,
        min_ones,
        sec_tens,
        sec_ones
    );
    wire [4:0] top_bits;
    wire [2:0] top_glyph_col = top_col[3:1];
    wire top_text_pixel = top_text_region && (top_slot < 6'd39) && (top_col < 4'd10);

    wire top_shadow_region = (y_pos >= 10'd12) && (y_pos < 10'd26);
    wire [10:0] top_shadow_x = x_pos - 11'd14;
    wire [5:0] top_shadow_slot = (x_pos >= 11'd14) ? top_shadow_x[9:4] : 6'd63;
    wire [3:0] top_shadow_col = top_shadow_x[3:0];
    wire [2:0] top_shadow_row = (y_pos - 10'd12) >> 1;
    wire [7:0] top_shadow_glyph_char = top_glyph_char;
    wire [4:0] top_shadow_bits;
    wire [2:0] top_shadow_glyph_col = top_shadow_col[3:1];
    wire top_shadow_pixel = top_shadow_region && (top_shadow_slot < 6'd39) &&
                            (top_shadow_col < 4'd10);

    wire [11:0] scroll_sum = {1'b0, x_pos} + {1'b0, scroll_offset};
    wire [11:0] scroll_sub = scroll_sum - {1'b0, SCROLL_PERIOD};
    wire [10:0] scroll_cycle = (scroll_sum >= {1'b0, SCROLL_PERIOD}) ?
                               scroll_sub[10:0] :
                               scroll_sum[10:0];
    wire scroll_active = (scroll_cycle >= SCROLL_TEXT_START) &&
                         (scroll_cycle < SCROLL_TEXT_END);
    wire [10:0] scroll_text_x = scroll_cycle - SCROLL_TEXT_START;
    wire [5:0] scroll_slot = scroll_text_x[9:4];
    wire [3:0] scroll_col = scroll_text_x[3:0];
    wire scroll_text_region = (y_pos >= 10'd387) && (y_pos < 10'd408);
    wire [2:0] scroll_row =
        (y_pos < 10'd390) ? 3'd0 :
        (y_pos < 10'd393) ? 3'd1 :
        (y_pos < 10'd396) ? 3'd2 :
        (y_pos < 10'd399) ? 3'd3 :
        (y_pos < 10'd402) ? 3'd4 :
        (y_pos < 10'd405) ? 3'd5 : 3'd6;
    // Two live 20:1 byte selectors replace two independent 40:1 selectors.
    // At the original S0 boundary both consumers see this cycle's text bus.
    wire [159:0] scroll_even_text, scroll_odd_text;
    genvar text_lane;
    generate for (text_lane=0; text_lane<20; text_lane=text_lane+1) begin : text_banks
        assign scroll_even_text[text_lane*8 +: 8] = scroll_text[text_lane*16 +: 8];
        assign scroll_odd_text[text_lane*8 +: 8] = scroll_text[text_lane*16+8 +: 8];
    end endgenerate
    wire [4:0] scroll_even_index = !scroll_slot[0] ? scroll_slot[5:1] : scroll_shadow_slot[5:1];
    wire [4:0] scroll_odd_index = scroll_slot[0] ? scroll_slot[5:1] : scroll_shadow_slot[5:1];
    wire [7:0] scroll_even_char = scroll_even_text[scroll_even_index*8 +: 8];
    wire [7:0] scroll_odd_char = scroll_odd_text[scroll_odd_index*8 +: 8];
    wire [7:0] scroll_glyph_char =
        (scroll_slot < scroll_text_len && scroll_slot < SCROLL_TEXT_SLOTS) ?
        (scroll_slot[0] ? scroll_odd_char : scroll_even_char) : 8'h20;
    wire [4:0] scroll_bits;
    wire [2:0] scroll_glyph_col =
        (scroll_col < 4'd3) ? 3'd0 :
        (scroll_col < 4'd6) ? 3'd1 :
        (scroll_col < 4'd9) ? 3'd2 :
        (scroll_col < 4'd12) ? 3'd3 : 3'd4;
    wire scroll_text_pixel = scroll_text_region && scroll_active &&
                             (scroll_slot < SCROLL_TEXT_SLOTS) &&
                             (scroll_col < 4'd15);

    wire [11:0] scroll_shadow_sum = (x_pos >= 11'd2) ?
        ({1'b0, x_pos - 11'd2} + {1'b0, scroll_offset}) :
        {1'b0, scroll_offset};
    wire [11:0] scroll_shadow_sub = scroll_shadow_sum - {1'b0, SCROLL_PERIOD};
    wire [10:0] scroll_shadow_cycle = (scroll_shadow_sum >= {1'b0, SCROLL_PERIOD}) ?
                                      scroll_shadow_sub[10:0] :
                                      scroll_shadow_sum[10:0];
    wire scroll_shadow_active = (scroll_shadow_cycle >= SCROLL_TEXT_START) &&
                                (scroll_shadow_cycle < SCROLL_TEXT_END);
    wire [10:0] scroll_shadow_text_x = scroll_shadow_cycle - SCROLL_TEXT_START;
    wire [5:0] scroll_shadow_slot = scroll_shadow_text_x[9:4];
    wire [3:0] scroll_shadow_col = scroll_shadow_text_x[3:0];
    wire scroll_shadow_region = (y_pos >= 10'd389) && (y_pos < 10'd410);
    wire [2:0] scroll_shadow_row =
        (y_pos < 10'd392) ? 3'd0 :
        (y_pos < 10'd395) ? 3'd1 :
        (y_pos < 10'd398) ? 3'd2 :
        (y_pos < 10'd401) ? 3'd3 :
        (y_pos < 10'd404) ? 3'd4 :
        (y_pos < 10'd407) ? 3'd5 : 3'd6;
    wire [7:0] scroll_shadow_glyph_char =
        (scroll_shadow_slot < scroll_text_len && scroll_shadow_slot < SCROLL_TEXT_SLOTS) ?
        (scroll_shadow_slot[0] ? scroll_odd_char : scroll_even_char) : 8'h20;
    wire [4:0] scroll_shadow_bits;
    wire [2:0] scroll_shadow_glyph_col =
        (scroll_shadow_col < 4'd3) ? 3'd0 :
        (scroll_shadow_col < 4'd6) ? 3'd1 :
        (scroll_shadow_col < 4'd9) ? 3'd2 :
        (scroll_shadow_col < 4'd12) ? 3'd3 : 3'd4;
    wire scroll_shadow_pixel = scroll_shadow_region && scroll_shadow_active &&
                               (scroll_shadow_slot < SCROLL_TEXT_SLOTS) &&
                               (scroll_shadow_col < 4'd15);

    // Top text/shadow occupy y=10..25; scroll text/shadow y=387..409.
    // Select the entire owner (INCLUDING its shadow tail) before the S0 ROM
    // read edge. Ports A/B retain independent text/shadow addresses. Do not
    // OR glyph addresses/data or select using a delayed/current output pixel.
    // No extra register boundary: the existing prep_overlay_flags and column
    // registers identify the very same pixel as these synchronous ROM outputs.
    wire font_use_scroll = scroll_text_region || scroll_shadow_region;
    wire [7:0] font_char_a = font_use_scroll ? scroll_glyph_char : top_glyph_char;
    wire [2:0] font_row_a = font_use_scroll ? scroll_row : top_row;
    wire [7:0] font_char_b = font_use_scroll ? scroll_shadow_glyph_char : top_shadow_glyph_char;
    wire [2:0] font_row_b = font_use_scroll ? scroll_shadow_row : top_shadow_row;
    wire [4:0] font_bits_a, font_bits_b;
    advanced_ascii_glyph_dp_rom u_shared_font (
        .clk(video_clk), .char_a(font_char_a), .row_a(font_row_a), .bits_a(font_bits_a),
        .char_b(font_char_b), .row_b(font_row_b), .bits_b(font_bits_b));
    // Inactive aliases are don't-care data. All four consumers retain their
    // original, S0-registered region/pixel flags in S1; no inactive data leaks.
    assign top_bits = font_bits_a;
    assign scroll_bits = font_bits_a;
    assign top_shadow_bits = font_bits_b;
    assign scroll_shadow_bits = font_bits_b;

    wire meter_bg = 1'b0 && (x_pos >= 11'd572) && (x_pos < 11'd636) &&
                    (y_pos >= 10'd384) && (y_pos < 10'd436);
    wire [5:0] meter_x = x_pos - 11'd572;
    wire [5:0] meter_y_from_bottom = 10'd435 - y_pos;
    wire [2:0] meter_bar = meter_x[5:3];
    wire [2:0] meter_col = meter_x[2:0];
    wire [5:0] meter_level = meter_height(audio_level_sync, meter_bar, sec_ones);
    wire meter_pixel = meter_bg && (meter_col < 3'd5) &&
                       (meter_y_from_bottom < meter_level);
    wire alert_border = stability_sync &&
        ((x_pos < 11'd3) || (x_pos >= 11'd637) ||
         (y_pos < 10'd3) || (y_pos >= 10'd477));

    wire [23:0] osd_band_rgb = blend50_rgb(transition_rgb, 24'h061923);
    wire [23:0] side_border_rgb = blend25_rgb(transition_rgb, 24'h22D3EE);
    wire [23:0] meter_bg_rgb = blend25_rgb(transition_rgb, 24'h061923);
    wire top_band = (y_pos < 10'd36);
    wire top_edge = (y_pos < 10'd2);
    wire bottom_band = (y_pos >= 10'd380) && (y_pos < 10'd416);
    wire bottom_edge = (y_pos >= 10'd414) && (y_pos < 10'd416);
    wire side_border = ((x_pos < 11'd2) || (x_pos >= 11'd638));
    reg [23:0] rgb_out_next;

    always @(*) begin
        case (prep_transition_style)
            2'd1: transition_rgb = prep_wipe_x_visible ? prep_processed_rgb : 24'h000000;
            2'd2: transition_rgb = prep_wipe_y_visible ? prep_processed_rgb : 24'h000000;
            2'd3: transition_rgb = prep_checker_visible ? prep_processed_rgb : 24'h000000;
            default: transition_rgb = faded_rgb;
        endcase
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            de_d <= 1'b0;
            vs_d <= 1'b0;
            x_pos <= 11'd0;
            y_pos <= 10'd0;
            scroll_offset <= 11'd0;
            scroll_fraction <= 4'd0;
            frame_div <= 6'd0;
            sec_ones <= 4'd0;
            sec_tens <= 4'd0;
            min_ones <= 4'd0;
            min_tens <= 4'd0;
            image_index_meta <= 2'd0;
            image_index_sync <= 2'd0;
            auto_meta <= 1'b0;
            auto_sync <= 1'b0;
            zoom_meta <= 1'b0;
            zoom_sync <= 1'b0;
            audio_meta <= 1'b0;
            audio_sync <= 1'b0;
            stability_meta <= 1'b0;
            stability_sync <= 1'b0;
            health_count_meta <= 4'd0;
            health_count_sync <= 4'd0;
            audio_level_meta <= 4'd0;
            audio_level_sync <= 4'd0;
            prep_rgb_in <= 0;
            prep_processed_rgb <= 0;
            prep_transition_level <= 0;
            prep_transition_style <= 0;
            prep_wipe_x_visible <= 0;
            prep_wipe_y_visible <= 0;
            prep_checker_visible <= 0;
            prep_overlay_flags <= 0;
            prep_top_col <= 0; prep_top_shadow_col <= 0;
            prep_scroll_col <= 0; prep_scroll_shadow_col <= 0;
            stage_rgb_in <= 24'h000000;
            stage_transition_rgb <= 24'h000000;
            stage_osd_band_rgb <= 24'h000000;
            stage_side_border_rgb <= 24'h000000;
            stage_meter_bg_rgb <= 24'h000000;
            stage_enable <= 1'b0;
            stage_de <= 1'b0;
            stage_top_band <= 1'b0;
            stage_top_shadow_pixel <= 1'b0;
            stage_top_text_pixel <= 1'b0;
            stage_top_edge <= 1'b0;
            stage_bottom_band <= 1'b0;
            stage_scroll_shadow_pixel <= 1'b0;
            stage_scroll_text_pixel <= 1'b0;
            stage_bottom_edge <= 1'b0;
            stage_side_border <= 1'b0;
            stage_meter_bg <= 1'b0;
            stage_meter_pixel <= 1'b0;
            stage_alert_border <= 1'b0;
            stage_stability_sync <= 1'b0;
        end else begin
            de_d <= de;
            vs_d <= vs;
            image_index_meta <= image_index;
            image_index_sync <= image_index_meta;
            auto_meta <= auto_play;
            auto_sync <= auto_meta;
            zoom_meta <= HALF_ZOOM_ENABLE ? zoom_setting : {1'b0,zoom_2x};
            zoom_sync <= zoom_meta;
            audio_meta <= audio_ready;
            audio_sync <= audio_meta;
            stability_meta <= stability_alert;
            stability_sync <= stability_meta;
            health_count_meta <= stability_error_count;
            health_count_sync <= health_count_meta;
            audio_level_meta <= audio_level;
            audio_level_sync <= audio_level_meta;
            prep_rgb_in <= rgb_in;
            prep_processed_rgb <= processed_rgb;
            prep_transition_level <= transition_level;
            prep_transition_style <= transition_style;
            prep_wipe_x_visible <= wipe_x_visible;
            prep_wipe_y_visible <= wipe_y_visible;
            prep_checker_visible <= checker_visible;
            prep_top_col <= top_glyph_col; prep_top_shadow_col <= top_shadow_glyph_col;
            prep_scroll_col <= scroll_glyph_col; prep_scroll_shadow_col <= scroll_shadow_glyph_col;
            prep_overlay_flags <= {enable, de, top_band, top_shadow_pixel,
                top_text_pixel, top_edge, bottom_band, scroll_shadow_pixel,
                scroll_text_pixel, bottom_edge, side_border, meter_bg,
                meter_pixel, alert_border, stability_sync};
            stage_rgb_in <= prep_rgb_in;
            stage_transition_rgb <= transition_rgb;
            stage_osd_band_rgb <= osd_band_rgb;
            stage_side_border_rgb <= side_border_rgb;
            stage_meter_bg_rgb <= meter_bg_rgb;
            {stage_enable, stage_de, stage_top_band, stage_top_shadow_pixel,
                stage_top_text_pixel, stage_top_edge, stage_bottom_band,
                stage_scroll_shadow_pixel, stage_scroll_text_pixel,
                stage_bottom_edge, stage_side_border, stage_meter_bg,
                stage_meter_pixel, stage_alert_border, stage_stability_sync}
                <= {prep_overlay_flags[14:12],
                    prep_overlay_flags[11] && glyph_col_bit(top_shadow_bits, prep_top_shadow_col),
                    prep_overlay_flags[10] && glyph_col_bit(top_bits, prep_top_col),
                    prep_overlay_flags[9:8],
                    prep_overlay_flags[7] && glyph_col_bit(scroll_shadow_bits, prep_scroll_shadow_col),
                    prep_overlay_flags[6] && glyph_col_bit(scroll_bits, prep_scroll_col),
                    prep_overlay_flags[5:0]};

            if (frame_tick) begin
                scroll_fraction <= scroll_extra ? scroll_fraction - 4'd7 :
                                                  scroll_fraction + 4'd3;
                scroll_offset <= (scroll_next >= SCROLL_PERIOD) ?
                    scroll_next - SCROLL_PERIOD : scroll_next;
                if (frame_div == 6'd59) begin
                    frame_div <= 6'd0;
                    if (sec_ones != 4'd9) begin
                        sec_ones <= sec_ones + 4'd1;
                    end else begin
                        sec_ones <= 4'd0;
                        if (sec_tens != 4'd5) begin
                            sec_tens <= sec_tens + 4'd1;
                        end else begin
                            sec_tens <= 4'd0;
                            if (min_ones != 4'd9) begin
                                min_ones <= min_ones + 4'd1;
                            end else begin
                                min_ones <= 4'd0;
                                min_tens <= (min_tens == 4'd9) ? 4'd0 : min_tens + 4'd1;
                            end
                        end
                    end
                end else begin
                    frame_div <= frame_div + 6'd1;
                end
            end

            if (vs_d != vs)
                y_pos <= 10'd0;
            else if (!de && de_d && (y_pos != 10'd479))
                y_pos <= y_pos + 10'd1;

            if (de)
                x_pos <= (x_pos == 11'd639) ? 11'd0 : x_pos + 11'd1;
            else
                x_pos <= 11'd0;
        end
    end

    always @(*) begin
        rgb_out_next = stage_rgb_in;
        if (stage_enable && stage_de) begin
            rgb_out_next = stage_transition_rgb;
            if (stage_top_band) begin
                rgb_out_next = stage_osd_band_rgb;
                if (stage_top_shadow_pixel)
                    rgb_out_next = 24'h02070A;
                if (stage_top_text_pixel)
                    rgb_out_next = 24'hFFFFFF;
                if (stage_top_edge)
                    rgb_out_next = 24'h22D3EE;
            end else if (stage_bottom_band) begin
                rgb_out_next = stage_osd_band_rgb;
                if (stage_scroll_shadow_pixel)
                    rgb_out_next = 24'h02070A;
                if (stage_scroll_text_pixel)
                    rgb_out_next = 24'hFFE066;
                if (stage_bottom_edge)
                    rgb_out_next = 24'h22D3EE;
            end else if (stage_side_border) begin
                rgb_out_next = stage_side_border_rgb;
            end
            if (stage_meter_bg)
                rgb_out_next = stage_meter_bg_rgb;
            if (stage_meter_pixel)
                rgb_out_next = stage_stability_sync ? 24'hFF4040 : 24'h22D3EE;
            if (stage_alert_border)
                rgb_out_next = 24'hFF3030;
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst)
            rgb_out <= 24'h000000;
        else
            rgb_out <= rgb_out_next;
    end
endmodule

// Complete S18 5x7 glyph mapping, including the original eighth-row defaults.
// SHA256 of the generating S18 source: 507aed9069d56e4249889ea77ed69c10d9128652397149ee300eef95851720a9
// 128 x 8 x 5 bits per dual-read ROM; one shared instance in the overlay.
// Non-ASCII bytes 128..255 were exhaustively verified blank in the source.
// Inline initialization: no external .hex/.mif file or additional AL source.
module advanced_ascii_glyph_dp_rom (
    input wire clk,
    input wire [7:0] char_a, char_b,
    input wire [2:0] row_a, row_b,
    output wire [4:0] bits_a, bits_b
);
    (* rom_style = "bram", ram_style = "block" *) reg [4:0] glyph [0:1023]; /* synthesis ram_style="block" */
    reg [4:0] row_bits_a, row_bits_b;
    reg nonascii_a, nonascii_b;
    integer i;
    initial begin
        for (i=0; i<1024; i=i+1) glyph[i]=5'b00000;
        glyph[363]=5'b11111;
        glyph[374]=5'b00100;
        glyph[376]=5'b00001;
        glyph[377]=5'b00010;
        glyph[378]=5'b00100;
        glyph[379]=5'b01000;
        glyph[380]=5'b10000;
        glyph[384]=5'b01110;
        glyph[385]=5'b10001;
        glyph[386]=5'b10011;
        glyph[387]=5'b10101;
        glyph[388]=5'b11001;
        glyph[389]=5'b10001;
        glyph[390]=5'b01110;
        glyph[391]=5'b01110;
        glyph[392]=5'b00100;
        glyph[393]=5'b01100;
        glyph[394]=5'b00100;
        glyph[395]=5'b00100;
        glyph[396]=5'b00100;
        glyph[397]=5'b00100;
        glyph[398]=5'b01110;
        glyph[399]=5'b01110;
        glyph[400]=5'b01110;
        glyph[401]=5'b10001;
        glyph[402]=5'b00001;
        glyph[403]=5'b00110;
        glyph[404]=5'b01000;
        glyph[405]=5'b10000;
        glyph[406]=5'b11111;
        glyph[407]=5'b11111;
        glyph[408]=5'b11110;
        glyph[409]=5'b00001;
        glyph[410]=5'b00001;
        glyph[411]=5'b01110;
        glyph[412]=5'b00001;
        glyph[413]=5'b00001;
        glyph[414]=5'b11110;
        glyph[415]=5'b11110;
        glyph[416]=5'b00010;
        glyph[417]=5'b00110;
        glyph[418]=5'b01010;
        glyph[419]=5'b10010;
        glyph[420]=5'b11111;
        glyph[421]=5'b00010;
        glyph[422]=5'b00010;
        glyph[423]=5'b00010;
        glyph[424]=5'b11111;
        glyph[425]=5'b10000;
        glyph[426]=5'b10000;
        glyph[427]=5'b11110;
        glyph[428]=5'b00001;
        glyph[429]=5'b00001;
        glyph[430]=5'b11110;
        glyph[431]=5'b11110;
        glyph[432]=5'b00110;
        glyph[433]=5'b01000;
        glyph[434]=5'b10000;
        glyph[435]=5'b11110;
        glyph[436]=5'b10001;
        glyph[437]=5'b10001;
        glyph[438]=5'b01110;
        glyph[439]=5'b01110;
        glyph[440]=5'b11111;
        glyph[441]=5'b00001;
        glyph[442]=5'b00010;
        glyph[443]=5'b00100;
        glyph[444]=5'b01000;
        glyph[445]=5'b01000;
        glyph[446]=5'b01000;
        glyph[447]=5'b01000;
        glyph[448]=5'b01110;
        glyph[449]=5'b10001;
        glyph[450]=5'b10001;
        glyph[451]=5'b01110;
        glyph[452]=5'b10001;
        glyph[453]=5'b10001;
        glyph[454]=5'b01110;
        glyph[455]=5'b01110;
        glyph[456]=5'b01110;
        glyph[457]=5'b10001;
        glyph[458]=5'b10001;
        glyph[459]=5'b01111;
        glyph[460]=5'b00001;
        glyph[461]=5'b00010;
        glyph[462]=5'b01100;
        glyph[463]=5'b01100;
        glyph[465]=5'b00100;
        glyph[466]=5'b00100;
        glyph[468]=5'b00100;
        glyph[469]=5'b00100;
        glyph[520]=5'b01110;
        glyph[521]=5'b10001;
        glyph[522]=5'b10001;
        glyph[523]=5'b11111;
        glyph[524]=5'b10001;
        glyph[525]=5'b10001;
        glyph[526]=5'b10001;
        glyph[527]=5'b10001;
        glyph[528]=5'b11110;
        glyph[529]=5'b10001;
        glyph[530]=5'b10001;
        glyph[531]=5'b11110;
        glyph[532]=5'b10001;
        glyph[533]=5'b10001;
        glyph[534]=5'b11110;
        glyph[535]=5'b11110;
        glyph[536]=5'b01110;
        glyph[537]=5'b10001;
        glyph[538]=5'b10000;
        glyph[539]=5'b10000;
        glyph[540]=5'b10000;
        glyph[541]=5'b10001;
        glyph[542]=5'b01110;
        glyph[543]=5'b01110;
        glyph[544]=5'b11110;
        glyph[545]=5'b10001;
        glyph[546]=5'b10001;
        glyph[547]=5'b10001;
        glyph[548]=5'b10001;
        glyph[549]=5'b10001;
        glyph[550]=5'b11110;
        glyph[551]=5'b11110;
        glyph[552]=5'b11111;
        glyph[553]=5'b10000;
        glyph[554]=5'b10000;
        glyph[555]=5'b11110;
        glyph[556]=5'b10000;
        glyph[557]=5'b10000;
        glyph[558]=5'b11111;
        glyph[559]=5'b11111;
        glyph[560]=5'b11111;
        glyph[561]=5'b10000;
        glyph[562]=5'b10000;
        glyph[563]=5'b11110;
        glyph[564]=5'b10000;
        glyph[565]=5'b10000;
        glyph[566]=5'b10000;
        glyph[567]=5'b10000;
        glyph[568]=5'b01110;
        glyph[569]=5'b10001;
        glyph[570]=5'b10000;
        glyph[571]=5'b10111;
        glyph[572]=5'b10001;
        glyph[573]=5'b10001;
        glyph[574]=5'b01110;
        glyph[575]=5'b01110;
        glyph[576]=5'b10001;
        glyph[577]=5'b10001;
        glyph[578]=5'b10001;
        glyph[579]=5'b11111;
        glyph[580]=5'b10001;
        glyph[581]=5'b10001;
        glyph[582]=5'b10001;
        glyph[583]=5'b10001;
        glyph[584]=5'b11111;
        glyph[585]=5'b00100;
        glyph[586]=5'b00100;
        glyph[587]=5'b00100;
        glyph[588]=5'b00100;
        glyph[589]=5'b00100;
        glyph[590]=5'b11111;
        glyph[591]=5'b11111;
        glyph[592]=5'b00111;
        glyph[593]=5'b00010;
        glyph[594]=5'b00010;
        glyph[595]=5'b00010;
        glyph[596]=5'b10010;
        glyph[597]=5'b10010;
        glyph[598]=5'b01100;
        glyph[599]=5'b01100;
        glyph[600]=5'b10001;
        glyph[601]=5'b10010;
        glyph[602]=5'b10100;
        glyph[603]=5'b11000;
        glyph[604]=5'b10100;
        glyph[605]=5'b10010;
        glyph[606]=5'b10001;
        glyph[607]=5'b10001;
        glyph[608]=5'b10000;
        glyph[609]=5'b10000;
        glyph[610]=5'b10000;
        glyph[611]=5'b10000;
        glyph[612]=5'b10000;
        glyph[613]=5'b10000;
        glyph[614]=5'b11111;
        glyph[615]=5'b11111;
        glyph[616]=5'b10001;
        glyph[617]=5'b11011;
        glyph[618]=5'b10101;
        glyph[619]=5'b10101;
        glyph[620]=5'b10001;
        glyph[621]=5'b10001;
        glyph[622]=5'b10001;
        glyph[623]=5'b10001;
        glyph[624]=5'b10001;
        glyph[625]=5'b11001;
        glyph[626]=5'b10101;
        glyph[627]=5'b10011;
        glyph[628]=5'b10001;
        glyph[629]=5'b10001;
        glyph[630]=5'b10001;
        glyph[631]=5'b10001;
        glyph[632]=5'b01110;
        glyph[633]=5'b10001;
        glyph[634]=5'b10001;
        glyph[635]=5'b10001;
        glyph[636]=5'b10001;
        glyph[637]=5'b10001;
        glyph[638]=5'b01110;
        glyph[639]=5'b01110;
        glyph[640]=5'b11110;
        glyph[641]=5'b10001;
        glyph[642]=5'b10001;
        glyph[643]=5'b11110;
        glyph[644]=5'b10000;
        glyph[645]=5'b10000;
        glyph[646]=5'b10000;
        glyph[647]=5'b10000;
        glyph[648]=5'b01110;
        glyph[649]=5'b10001;
        glyph[650]=5'b10001;
        glyph[651]=5'b10001;
        glyph[652]=5'b10101;
        glyph[653]=5'b10010;
        glyph[654]=5'b01101;
        glyph[655]=5'b01101;
        glyph[656]=5'b11110;
        glyph[657]=5'b10001;
        glyph[658]=5'b10001;
        glyph[659]=5'b11110;
        glyph[660]=5'b10100;
        glyph[661]=5'b10010;
        glyph[662]=5'b10001;
        glyph[663]=5'b10001;
        glyph[664]=5'b01111;
        glyph[665]=5'b10000;
        glyph[666]=5'b10000;
        glyph[667]=5'b01110;
        glyph[668]=5'b00001;
        glyph[669]=5'b00001;
        glyph[670]=5'b11110;
        glyph[671]=5'b11110;
        glyph[672]=5'b11111;
        glyph[673]=5'b00100;
        glyph[674]=5'b00100;
        glyph[675]=5'b00100;
        glyph[676]=5'b00100;
        glyph[677]=5'b00100;
        glyph[678]=5'b00100;
        glyph[679]=5'b00100;
        glyph[680]=5'b10001;
        glyph[681]=5'b10001;
        glyph[682]=5'b10001;
        glyph[683]=5'b10001;
        glyph[684]=5'b10001;
        glyph[685]=5'b10001;
        glyph[686]=5'b01110;
        glyph[687]=5'b01110;
        glyph[688]=5'b10001;
        glyph[689]=5'b10001;
        glyph[690]=5'b10001;
        glyph[691]=5'b10001;
        glyph[692]=5'b01010;
        glyph[693]=5'b01010;
        glyph[694]=5'b00100;
        glyph[695]=5'b00100;
        glyph[696]=5'b10001;
        glyph[697]=5'b10001;
        glyph[698]=5'b10001;
        glyph[699]=5'b10101;
        glyph[700]=5'b10101;
        glyph[701]=5'b11011;
        glyph[702]=5'b10001;
        glyph[703]=5'b10001;
        glyph[704]=5'b10001;
        glyph[705]=5'b10001;
        glyph[706]=5'b01010;
        glyph[707]=5'b00100;
        glyph[708]=5'b01010;
        glyph[709]=5'b10001;
        glyph[710]=5'b10001;
        glyph[711]=5'b10001;
        glyph[712]=5'b10001;
        glyph[713]=5'b10001;
        glyph[714]=5'b01010;
        glyph[715]=5'b00100;
        glyph[716]=5'b00100;
        glyph[717]=5'b00100;
        glyph[718]=5'b00100;
        glyph[719]=5'b00100;
        glyph[720]=5'b11111;
        glyph[721]=5'b00001;
        glyph[722]=5'b00010;
        glyph[723]=5'b00100;
        glyph[724]=5'b01000;
        glyph[725]=5'b10000;
        glyph[726]=5'b11111;
        glyph[727]=5'b11111;
    end
    always @(posedge clk) begin
        row_bits_a <= glyph[{char_a[6:0],row_a}];
        row_bits_b <= glyph[{char_b[6:0],row_b}];
        nonascii_a <= char_a[7];
        nonascii_b <= char_b[7];
    end
    assign bits_a = nonascii_a ? 5'b00000 : row_bits_a;
    assign bits_b = nonascii_b ? 5'b00000 : row_bits_b;
endmodule
