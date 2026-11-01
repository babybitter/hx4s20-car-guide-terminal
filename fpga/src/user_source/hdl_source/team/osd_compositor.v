module osd_compositor #(parameter INDEPENDENT_TITLE=0,parameter USE_SYNC_FONT=0)(
    input wire clk,
    input wire rst,
    input wire [23:0] I_rgb,
    input wire I_de,
    input wire I_hs,
    input wire I_vs,
    input wire [6:0] page_id,
    input wire [6:0] title_id,
    input wire [7:0] page_count,
    input wire auto_enabled,
    input wire prompt_active,
    output reg [23:0] O_rgb,
    output reg O_de,
    output reg O_hs,
    output reg O_vs
);
    localparam [23:0] BAR_BG = 24'h103B42;
    localparam [23:0] BAR_TEXT = 24'hF6F9F6;
    localparam [23:0] BAR_ACCENT = 24'hFFAF72;
    localparam [23:0] WINDOW_BG = 24'hF6F9F6;
    localparam [23:0] WINDOW_HEADER = 24'h1B626B;
    localparam [23:0] WINDOW_TEXT = 24'h12363D;

    reg [9:0] x_count;
    reg [8:0] y_count;
    reg de_prev;
    reg vs_prev;
    reg frame_arm;
    wire [9:0] x_now = !de_prev ? 10'd0 : x_count + 1'b1;
    wire [8:0] y_now = !de_prev && frame_arm ? 9'd0 :
                       !de_prev ? y_count + 1'b1 : y_count;
    wire bar_area = I_de && x_now < 10'd640 &&
                    y_now >= 9'd416 && y_now < 9'd480;
    // page_id is zero-based; the catalog supplies a count in 1..128.
    // Four-page callers explicitly connect page_count=8'd4.
    wire [7:0] page_number = {1'b0, page_id} + 8'd1;
    wire window_area = I_de && prompt_active &&
                       x_now >= 10'd64 && x_now <= 10'd575 &&
                       y_now >= 9'd144 && y_now <= 9'd335;

    reg [5:0] glyph_id;
    reg [4:0] glyph_row;
    reg [4:0] glyph_col;
    reg glyph_enable;
    reg [23:0] base_color;
    reg [23:0] text_color;
    wire [31:0] glyph_bits;
    reg [5:0] glyph_id_s1;
    reg [4:0] glyph_row_s1;
    reg [4:0] glyph_col_s1;

    generate if(USE_SYNC_FONT)begin:sync_font
    // ROM captures stage-zero coordinates; its registered output and col_s1
    // arrive together. Total compositor latency remains two clock edges.
    osd_glyph_bram u_glyph(.clk(clk),.glyph_id(glyph_id),.row(glyph_row),.bits(glyph_bits));
    end else begin:async_font
    osd_glyph_rom u_glyph (
        .glyph_id(glyph_id_s1), .row(glyph_row_s1),
        .bits(glyph_bits)
    );
    end endgenerate

    function [5:0] title_glyph;
        input [6:0] page;
        input [1:0] index;
        begin
            case (page)
                7'd0: case (index)
                    2'd0: title_glyph = 6'd1;
                    2'd1: title_glyph = 6'd2;
                    2'd2: title_glyph = 6'd3;
                    default: title_glyph = 6'd4;
                endcase
                7'd1: case (index)
                    2'd0: title_glyph = 6'd5;
                    2'd1: title_glyph = 6'd6;
                    2'd2: title_glyph = 6'd7;
                    default: title_glyph = 6'd8;
                endcase
                7'd2: case (index)
                    2'd0: title_glyph = 6'd9;
                    2'd1: title_glyph = 6'd10;
                    2'd2: title_glyph = 6'd11;
                    default: title_glyph = 6'd12;
                endcase
                7'd3: case (index)
                    2'd0: title_glyph = 6'd13;
                    2'd1: title_glyph = 6'd14;
                    2'd2: title_glyph = 6'd15;
                    default: title_glyph = 6'd16;
                endcase
                7'd4: case (index) // 沿途人文
                    2'd0: title_glyph = 6'd36;
                    2'd1: title_glyph = 6'd37;
                    2'd2: title_glyph = 6'd38;
                    default: title_glyph = 6'd13;
                endcase
                7'd5: case (index) // 雨天出行
                    2'd0: title_glyph = 6'd39;
                    2'd1: title_glyph = 6'd40;
                    2'd2: title_glyph = 6'd41;
                    default: title_glyph = 6'd42;
                endcase
                7'd6: case (index) // 礼让同行
                    2'd0: title_glyph = 6'd43;
                    2'd1: title_glyph = 6'd44;
                    2'd2: title_glyph = 6'd45;
                    default: title_glyph = 6'd42;
                endcase
                7'd7: case (index) // 离车检查
                    2'd0: title_glyph = 6'd46;
                    2'd1: title_glyph = 6'd16;
                    2'd2: title_glyph = 6'd47;
                    default: title_glyph = 6'd48;
                endcase
                default: case (index) // 导览图片, logical pages 009..128
                    2'd0: title_glyph = 6'd55;
                    2'd1: title_glyph = 6'd4;
                    2'd2: title_glyph = 6'd56;
                    default: title_glyph = 6'd57;
                endcase
            endcase
        end
    endfunction

    function [5:0] digit_glyph;
        input [7:0] digit;
        begin
            case (digit)
                0: digit_glyph = 6'd49;
                1: digit_glyph = 6'd31;
                2: digit_glyph = 6'd32;
                3: digit_glyph = 6'd33;
                4: digit_glyph = 6'd34;
                5: digit_glyph = 6'd50;
                6: digit_glyph = 6'd51;
                7: digit_glyph = 6'd52;
                8: digit_glyph = 6'd53;
                9: digit_glyph = 6'd54;
                default: digit_glyph = 6'd0;
            endcase
        end
    endfunction

    function [5:0] page_glyph;
        input [2:0] index;
        input [7:0] number;
        input [7:0] total;
        reg [7:0] selected_number, selected_digit;
        begin
            // Share the decimal datapath and glyph lookup for both numbers.
            selected_number=index[2] ? total : number;
            case(index[1:0])
                0: selected_digit=selected_number / 8'd100;
                1: selected_digit=(selected_number / 8'd10) % 8'd10;
                2: selected_digit=selected_number % 8'd10;
                default: selected_digit=8'd0;
            endcase
            if(index==3) page_glyph=6'd35;
            else if(index==7) page_glyph=6'd0;
            else page_glyph=digit_glyph(selected_digit);
        end
    endfunction

    function [5:0] prompt_glyph;
        input [3:0] index;
        begin
            case (index)
                4'd0: prompt_glyph = 6'd15;
                4'd1: prompt_glyph = 6'd16;
                4'd2: prompt_glyph = 6'd20;
                4'd3: prompt_glyph = 6'd21;
                4'd4: prompt_glyph = 6'd22;
                4'd5: prompt_glyph = 6'd23;
                4'd6: prompt_glyph = 6'd24;
                4'd7: prompt_glyph = 6'd25;
                4'd8: prompt_glyph = 6'd26;
                4'd9: prompt_glyph = 6'd27;
                4'd10: prompt_glyph = 6'd28;
                4'd11: prompt_glyph = 6'd29;
                default: prompt_glyph = 6'd30;
            endcase
        end
    endfunction

    always @* begin
        base_color = I_de ? I_rgb : 24'd0;
        text_color = BAR_TEXT;
        glyph_enable = 1'b0;
        glyph_id = 6'd0;
        glyph_row = 5'd0;
        glyph_col = 5'd0;

        if (bar_area) begin
            base_color = BAR_BG;
            if (y_now >= 9'd432 && y_now < 9'd464) begin
                glyph_row = y_now - 9'd432;
                if (x_now >= 10'd32 && x_now < 10'd160) begin
                    glyph_enable = 1'b1;
                    glyph_id = title_glyph(INDEPENDENT_TITLE?title_id:page_id, (x_now - 10'd32) >> 5);
                    glyph_col = x_now - 10'd32;
                end else if (x_now >= 10'd352 && x_now < 10'd416) begin
                    glyph_enable = 1'b1;
                    glyph_id = (x_now < 10'd384) ?
                               (auto_enabled ? 6'd17 : 6'd19) : 6'd18;
                    glyph_col = x_now - 10'd352;
                    text_color = BAR_ACCENT;
                end else if (x_now >= 10'd480 && x_now < 10'd592) begin
                    glyph_enable = 1'b1;
                    glyph_id = page_glyph((x_now - 10'd480) >> 4,
                                          page_number, page_count);
                    // Seven 16x32 cells: sample columns 0,2,...,30 of
                    // each original 32x32 glyph without changing ROM IDs.
                    glyph_col = (x_now - 10'd480) << 1;
                end
            end
        end

        if (window_area) begin
            base_color = WINDOW_BG;
            text_color = WINDOW_TEXT;
            glyph_enable = 1'b0;
            if (x_now < 10'd68 || x_now > 10'd571 ||
                y_now < 9'd148 || y_now > 9'd331)
                base_color = BAR_ACCENT;
            else if (y_now < 9'd208)
                base_color = WINDOW_HEADER;

            if (x_now >= 10'd192 && x_now < 10'd320 &&
                y_now >= 9'd164 && y_now < 9'd196) begin
                glyph_enable = 1'b1;
                glyph_id = prompt_glyph((x_now - 10'd192) >> 5);
                glyph_row = y_now - 9'd164;
                glyph_col = x_now - 10'd192;
                text_color = BAR_TEXT;
            end else if (x_now >= 10'd192 && x_now < 10'd352 &&
                         y_now >= 9'd228 && y_now < 9'd260) begin
                glyph_enable = 1'b1;
                glyph_id = prompt_glyph(4'd4 + ((x_now - 10'd192) >> 5));
                glyph_row = y_now - 9'd228;
                glyph_col = x_now - 10'd192;
            end else if (x_now >= 10'd224 && x_now < 10'd352 &&
                         y_now >= 9'd276 && y_now < 9'd308) begin
                glyph_enable = 1'b1;
                glyph_id = prompt_glyph(4'd9 + ((x_now - 10'd224) >> 5));
                glyph_row = y_now - 9'd276;
                glyph_col = x_now - 10'd224;
            end
        end
    end

    reg [23:0] base_s1;
    reg [23:0] text_s1;
    reg glyph_s1;
    reg de_s1;
    reg hs_s1;
    reg vs_s1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x_count <= 10'd0;
            y_count <= 9'd0;
            de_prev <= 1'b0;
            vs_prev <= 1'b0;
            frame_arm <= 1'b1;
            base_s1 <= 24'd0;
            text_s1 <= 24'd0;
            glyph_s1 <= 1'b0;
            glyph_id_s1 <= 6'd0;
            glyph_row_s1 <= 5'd0;
            glyph_col_s1 <= 5'd0;
            de_s1 <= 1'b0;
            hs_s1 <= 1'b0;
            vs_s1 <= 1'b0;
            O_rgb <= 24'd0;
            O_de <= 1'b0;
            O_hs <= 1'b0;
            O_vs <= 1'b0;
        end else begin
            de_prev <= I_de;
            vs_prev <= I_vs;
            if (vs_prev != I_vs)
                frame_arm <= 1'b1;
            if (I_de) begin
                x_count <= x_now;
                y_count <= y_now;
                if (!de_prev && frame_arm)
                    frame_arm <= 1'b0;
            end
            base_s1 <= base_color;
            text_s1 <= text_color;
            glyph_s1 <= glyph_enable;
            glyph_id_s1 <= glyph_id;
            glyph_row_s1 <= glyph_row;
            glyph_col_s1 <= glyph_col;
            de_s1 <= I_de;
            hs_s1 <= I_hs;
            vs_s1 <= I_vs;
            O_rgb <= glyph_s1 && glyph_bits[31 - glyph_col_s1] ?
                     text_s1 : base_s1;
            O_de <= de_s1;
            O_hs <= hs_s1;
            O_vs <= vs_s1;
        end
    end
endmodule
