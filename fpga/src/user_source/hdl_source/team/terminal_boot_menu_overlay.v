`timescale 1ns/1ps
`default_nettype none
// Two registers of latency for the COMPLETE RGB/HS/VS/DE tuple, in every mode.
// Coordinates describe I_rgb BEFORE both registers. Contiguous 640-pixel DE
// runs, 480 runs/frame, >=1 blank clock between runs, VS transitions only in
// vertical blank. Either VS polarity works. First DE after reset/VS is (0,0).
module terminal_boot_menu_overlay #(
    parameter integer MIN_BOOT_CYCLES = 25000000
)(
    input wire pixelclk, rst, blank_tick,
    input wire [23:0] I_rgb,
    input wire I_hs, I_vs, I_de,
    input wire [6:0] page_id,
    input wire media_ready,
    input wire [3:0] boot_progress,
    input wire display_ready,
    input wire [3:0] fault_code,
    input wire menu_mode,
    input wire [3:0] menu_selection,
    input wire [2:0] edit_value, applied_value,
    output reg [23:0] O_rgb,
    output reg O_hs, O_vs, O_de,
    output reg boot_active
);
    function integer bits_for;
        input integer n;
        integer v;
        begin
            v=n-1; bits_for=0;
            while (v>0) begin bits_for=bits_for+1; v=v>>1; end
            if (bits_for<1) bits_for=1;
        end
    endfunction
    localparam integer TIMER_BITS=bits_for(MIN_BOOT_CYCLES);
    reg [TIMER_BITS-1:0] age;
    reg min_elapsed;
    reg de_d, vs_d, frame_arm;
    reg [9:0] x;
    reg [8:0] y;
    wire [9:0] px = !de_d ? 10'd0 : x+1'b1;
    wire [8:0] py = !de_d ? (frame_arm ? 9'd0 : y+1'b1) : y;
    wire publish = blank_tick && !I_de;

    // Frame snapshots prevent half-frame menu/status changes. First boot fault
    // is sticky until reset: even a one-clock fault must not become fake success.
    reg [3:0] fault_seen, shown_fault, shown_progress;
    reg [6:0] shown_page;
    reg shown_media, shown_menu;
    reg [3:0] shown_selection;
    reg [2:0] shown_edit, shown_applied;
    reg [5:0] animation;
    always @(posedge pixelclk or posedge rst) begin
        if (rst) begin
            age<=0; min_elapsed<=0; boot_active<=1;
            de_d<=0; vs_d<=0; frame_arm<=1; x<=0; y<=0;
            fault_seen<=0; shown_fault<=0; shown_progress<=0; shown_page<=0;
            shown_media<=0; shown_menu<=0; shown_selection<=0;
            shown_edit<=0; shown_applied<=0; animation<=0;
        end else begin
            de_d<=I_de; vs_d<=I_vs;
            if (I_vs!=vs_d) frame_arm<=1;
            if (I_de) begin
                x<=px; y<=py;
                if (!de_d) frame_arm<=0;
            end
            if (!min_elapsed) begin
                if (age==MIN_BOOT_CYCLES-1) min_elapsed<=1;
                else age<=age+1'b1;
            end
            if (boot_active && fault_seen==0 && fault_code!=0) fault_seen<=fault_code;
            if (publish) begin
                shown_fault<=fault_seen!=0 ? fault_seen : fault_code;
                shown_progress<=boot_progress; shown_page<=page_id; shown_media<=media_ready;
                shown_menu<=menu_mode; shown_selection<=menu_selection;
                shown_edit<=edit_value; shown_applied<=applied_value;
                if (boot_active && fault_seen==0 && fault_code==0) animation<=animation+1'b1;
                if (boot_active && min_elapsed && display_ready && fault_seen==0 && fault_code==0)
                    boot_active<=0;
            end
        end
    end

    // A valid bit plus a five-bit glyph ID avoids ASCII decode hardware.
    // All 32 old glyphs, seven five-bit rows each; row 7 is blank padding.
    // Exactly ONE synchronous read port, 256 x 5 bits; one 9K BRAM target.
    (* ram_style = "block" *) reg [4:0] font_rows [0:255];
    reg [4:0] font_row;
    integer font_init;
    initial begin
        for(font_init=0;font_init<256;font_init=font_init+1) font_rows[font_init]=5'd0;
        // 0: glyph ID 0
        font_rows[0]=5'b01110;
        font_rows[1]=5'b10001;
        font_rows[2]=5'b10011;
        font_rows[3]=5'b10101;
        font_rows[4]=5'b11001;
        font_rows[5]=5'b10001;
        font_rows[6]=5'b01110;
        // 1: glyph ID 1
        font_rows[8]=5'b00100;
        font_rows[9]=5'b01100;
        font_rows[10]=5'b00100;
        font_rows[11]=5'b00100;
        font_rows[12]=5'b00100;
        font_rows[13]=5'b00100;
        font_rows[14]=5'b01110;
        // 2: glyph ID 2
        font_rows[16]=5'b01110;
        font_rows[17]=5'b10001;
        font_rows[18]=5'b00001;
        font_rows[19]=5'b00010;
        font_rows[20]=5'b00100;
        font_rows[21]=5'b01000;
        font_rows[22]=5'b11111;
        // 3: glyph ID 3
        font_rows[24]=5'b11110;
        font_rows[25]=5'b00001;
        font_rows[26]=5'b00001;
        font_rows[27]=5'b01110;
        font_rows[28]=5'b00001;
        font_rows[29]=5'b00001;
        font_rows[30]=5'b11110;
        // 4: glyph ID 4
        font_rows[32]=5'b00010;
        font_rows[33]=5'b00110;
        font_rows[34]=5'b01010;
        font_rows[35]=5'b10010;
        font_rows[36]=5'b11111;
        font_rows[37]=5'b00010;
        font_rows[38]=5'b00010;
        // 5: glyph ID 5
        font_rows[40]=5'b11111;
        font_rows[41]=5'b10000;
        font_rows[42]=5'b10000;
        font_rows[43]=5'b11110;
        font_rows[44]=5'b00001;
        font_rows[45]=5'b00001;
        font_rows[46]=5'b11110;
        // 6: glyph ID 6
        font_rows[48]=5'b01110;
        font_rows[49]=5'b10000;
        font_rows[50]=5'b10000;
        font_rows[51]=5'b11110;
        font_rows[52]=5'b10001;
        font_rows[53]=5'b10001;
        font_rows[54]=5'b01110;
        // 7: glyph ID 7
        font_rows[56]=5'b11111;
        font_rows[57]=5'b00001;
        font_rows[58]=5'b00010;
        font_rows[59]=5'b00100;
        font_rows[60]=5'b01000;
        font_rows[61]=5'b01000;
        font_rows[62]=5'b01000;
        // 8: glyph ID 8
        font_rows[64]=5'b01110;
        font_rows[65]=5'b10001;
        font_rows[66]=5'b10001;
        font_rows[67]=5'b01110;
        font_rows[68]=5'b10001;
        font_rows[69]=5'b10001;
        font_rows[70]=5'b01110;
        // 9: glyph ID 9
        font_rows[72]=5'b01110;
        font_rows[73]=5'b10001;
        font_rows[74]=5'b10001;
        font_rows[75]=5'b01111;
        font_rows[76]=5'b00001;
        font_rows[77]=5'b00001;
        font_rows[78]=5'b01110;
        // A: glyph ID 10
        font_rows[80]=5'b01110;
        font_rows[81]=5'b10001;
        font_rows[82]=5'b10001;
        font_rows[83]=5'b11111;
        font_rows[84]=5'b10001;
        font_rows[85]=5'b10001;
        font_rows[86]=5'b10001;
        // B: glyph ID 11
        font_rows[88]=5'b11110;
        font_rows[89]=5'b10001;
        font_rows[90]=5'b10001;
        font_rows[91]=5'b11110;
        font_rows[92]=5'b10001;
        font_rows[93]=5'b10001;
        font_rows[94]=5'b11110;
        // C: glyph ID 12
        font_rows[96]=5'b01111;
        font_rows[97]=5'b10000;
        font_rows[98]=5'b10000;
        font_rows[99]=5'b10000;
        font_rows[100]=5'b10000;
        font_rows[101]=5'b10000;
        font_rows[102]=5'b01111;
        // D: glyph ID 13
        font_rows[104]=5'b11110;
        font_rows[105]=5'b10001;
        font_rows[106]=5'b10001;
        font_rows[107]=5'b10001;
        font_rows[108]=5'b10001;
        font_rows[109]=5'b10001;
        font_rows[110]=5'b11110;
        // E: glyph ID 14
        font_rows[112]=5'b11111;
        font_rows[113]=5'b10000;
        font_rows[114]=5'b10000;
        font_rows[115]=5'b11110;
        font_rows[116]=5'b10000;
        font_rows[117]=5'b10000;
        font_rows[118]=5'b11111;
        // F: glyph ID 15
        font_rows[120]=5'b11111;
        font_rows[121]=5'b10000;
        font_rows[122]=5'b10000;
        font_rows[123]=5'b11110;
        font_rows[124]=5'b10000;
        font_rows[125]=5'b10000;
        font_rows[126]=5'b10000;
        // G: glyph ID 16
        font_rows[128]=5'b01111;
        font_rows[129]=5'b10000;
        font_rows[130]=5'b10000;
        font_rows[131]=5'b10111;
        font_rows[132]=5'b10001;
        font_rows[133]=5'b10001;
        font_rows[134]=5'b01111;
        // I: glyph ID 17
        font_rows[136]=5'b01110;
        font_rows[137]=5'b00100;
        font_rows[138]=5'b00100;
        font_rows[139]=5'b00100;
        font_rows[140]=5'b00100;
        font_rows[141]=5'b00100;
        font_rows[142]=5'b01110;
        // K: glyph ID 18
        font_rows[144]=5'b10001;
        font_rows[145]=5'b10010;
        font_rows[146]=5'b10100;
        font_rows[147]=5'b11000;
        font_rows[148]=5'b10100;
        font_rows[149]=5'b10010;
        font_rows[150]=5'b10001;
        // L: glyph ID 19
        font_rows[152]=5'b10000;
        font_rows[153]=5'b10000;
        font_rows[154]=5'b10000;
        font_rows[155]=5'b10000;
        font_rows[156]=5'b10000;
        font_rows[157]=5'b10000;
        font_rows[158]=5'b11111;
        // M: glyph ID 20
        font_rows[160]=5'b10001;
        font_rows[161]=5'b11011;
        font_rows[162]=5'b10101;
        font_rows[163]=5'b10101;
        font_rows[164]=5'b10001;
        font_rows[165]=5'b10001;
        font_rows[166]=5'b10001;
        // N: glyph ID 21
        font_rows[168]=5'b10001;
        font_rows[169]=5'b11001;
        font_rows[170]=5'b10101;
        font_rows[171]=5'b10011;
        font_rows[172]=5'b10001;
        font_rows[173]=5'b10001;
        font_rows[174]=5'b10001;
        // O: glyph ID 22
        font_rows[176]=5'b01110;
        font_rows[177]=5'b10001;
        font_rows[178]=5'b10001;
        font_rows[179]=5'b10001;
        font_rows[180]=5'b10001;
        font_rows[181]=5'b10001;
        font_rows[182]=5'b01110;
        // P: glyph ID 23
        font_rows[184]=5'b11110;
        font_rows[185]=5'b10001;
        font_rows[186]=5'b10001;
        font_rows[187]=5'b11110;
        font_rows[188]=5'b10000;
        font_rows[189]=5'b10000;
        font_rows[190]=5'b10000;
        // R: glyph ID 24
        font_rows[192]=5'b11110;
        font_rows[193]=5'b10001;
        font_rows[194]=5'b10001;
        font_rows[195]=5'b11110;
        font_rows[196]=5'b10100;
        font_rows[197]=5'b10010;
        font_rows[198]=5'b10001;
        // S: glyph ID 25
        font_rows[200]=5'b01111;
        font_rows[201]=5'b10000;
        font_rows[202]=5'b10000;
        font_rows[203]=5'b01110;
        font_rows[204]=5'b00001;
        font_rows[205]=5'b00001;
        font_rows[206]=5'b11110;
        // T: glyph ID 26
        font_rows[208]=5'b11111;
        font_rows[209]=5'b00100;
        font_rows[210]=5'b00100;
        font_rows[211]=5'b00100;
        font_rows[212]=5'b00100;
        font_rows[213]=5'b00100;
        font_rows[214]=5'b00100;
        // U: glyph ID 27
        font_rows[216]=5'b10001;
        font_rows[217]=5'b10001;
        font_rows[218]=5'b10001;
        font_rows[219]=5'b10001;
        font_rows[220]=5'b10001;
        font_rows[221]=5'b10001;
        font_rows[222]=5'b01110;
        // W: glyph ID 28
        font_rows[224]=5'b10001;
        font_rows[225]=5'b10001;
        font_rows[226]=5'b10001;
        font_rows[227]=5'b10101;
        font_rows[228]=5'b10101;
        font_rows[229]=5'b11011;
        font_rows[230]=5'b10001;
        // X: glyph ID 29
        font_rows[232]=5'b10001;
        font_rows[233]=5'b10001;
        font_rows[234]=5'b01010;
        font_rows[235]=5'b00100;
        font_rows[236]=5'b01010;
        font_rows[237]=5'b10001;
        font_rows[238]=5'b10001;
        // Y: glyph ID 30
        font_rows[240]=5'b10001;
        font_rows[241]=5'b10001;
        font_rows[242]=5'b01010;
        font_rows[243]=5'b00100;
        font_rows[244]=5'b00100;
        font_rows[245]=5'b00100;
        font_rows[246]=5'b00100;
        // Z: glyph ID 31
        font_rows[248]=5'b11111;
        font_rows[249]=5'b00001;
        font_rows[250]=5'b00010;
        font_rows[251]=5'b00100;
        font_rows[252]=5'b01000;
        font_rows[253]=5'b10000;
        font_rows[254]=5'b11111;
    end

    function [5:0] title_code;
        input [3:0] index;
        begin
            case(index)
                4'd5: title_code=6'd43; // B
                4'd6: title_code=6'd59; // U
                4'd7: title_code=6'd57; // S
                4'd9: title_code=6'd48; // G
                4'd10: title_code=6'd59; // U
                4'd11: title_code=6'd49; // I
                4'd12: title_code=6'd45; // D
                4'd13: title_code=6'd46; // E
                default: title_code=6'd0;
            endcase
        end
    endfunction

    function [5:0] hint_code;
        input [4:0] index;
        begin
            case(index)
                5'd2: hint_code=6'd62; // Y
                5'd3: hint_code=6'd34; // 2
                5'd5: hint_code=6'd53; // N
                5'd6: hint_code=6'd46; // E
                5'd7: hint_code=6'd61; // X
                5'd8: hint_code=6'd58; // T
                5'd11: hint_code=6'd50; // K
                5'd12: hint_code=6'd46; // E
                5'd13: hint_code=6'd62; // Y
                5'd14: hint_code=6'd35; // 3
                5'd16: hint_code=6'd46; // E
                5'd17: hint_code=6'd45; // D
                5'd18: hint_code=6'd49; // I
                5'd19: hint_code=6'd58; // T
                5'd22: hint_code=6'd50; // K
                5'd23: hint_code=6'd46; // E
                5'd24: hint_code=6'd62; // Y
                5'd25: hint_code=6'd36; // 4
                5'd27: hint_code=6'd42; // A
                5'd28: hint_code=6'd55; // P
                5'd29: hint_code=6'd55; // P
                5'd30: hint_code=6'd51; // L
                5'd31: hint_code=6'd62; // Y
                default: hint_code=6'd0;
            endcase
        end
    endfunction

    function [5:0] label_code;
        input [3:0] index;
        begin
            case(index)
                4'd0: label_code=6'd47; // F
                4'd1: label_code=6'd58; // T
                4'd2: label_code=6'd61; // X
                4'd3: label_code=6'd63; // Z
                4'd4: label_code=6'd51; // L
                4'd5: label_code=6'd56; // R
                4'd6: label_code=6'd48; // G
                4'd7: label_code=6'd46; // E
                4'd8: label_code=6'd62; // Y
                default: label_code=6'd0;
            endcase
        end
    endfunction

    // Geometry is shared in pixel-cell units. No multiply, variable text
    // shifts, 32-bit text-coordinate subtraction or 35-bit glyph bit mux.
    wire [3:0] cell32 = px[8:5] - {3'd0,!px[4]}; // (px-16)/32 in bounded regions
    wire [4:0] cell16 = px[8:4];
    wire [6:0] marker_cell = 7'd32 + {1'b0,animation};
    wire marker_hit = !px[9] && ((px[8:2]==marker_cell) || (px[8:2]==marker_cell+7'd1));
    reg [2:0] progress_block;
    always @* begin
        case(shown_progress)
            4'd2:progress_block=3'd2;
            4'd3:progress_block=3'd3;
            4'd4:progress_block=3'd4;
            default:progress_block=3'd1;
        endcase
    end
    wire progress_filled = px[9:7]<progress_block;
    wire node_filled = progress_filled || ((px[9:7]==progress_block) && px[6:3]==4'd0);
    reg [23:0] rgb_base;
    reg [5:0] glyph_code;
    reg [2:0] gx,gy;
    reg text_region,text_red;
    always @* begin
        rgb_base=I_rgb; glyph_code=0; gx=0; gy=0; text_region=0; text_red=0;
        if(I_de && px<10'd640 && py<9'd480) begin
            if(boot_active) begin
                rgb_base=24'h061225;
                if((py==9'd96 || py==9'd360) && px>=10'd96 && px<10'd544) rgb_base=24'h12334c;
                if(py>=9'd214 && py<9'd218 && px>=10'd128 && px<10'd512) rgb_base=24'h24617a;
                if((px==10'd192 && py>=9'd200 && py<9'd214) ||
                   (px==10'd448 && py>=9'd218 && py<9'd232)) rgb_base=24'h24617a;
                if(py[8:4]==5'd13 && px>=10'd120 && px<10'd520 &&
                   (px[6:3]==4'd15 || px[6:3]==4'd0))
                    rgb_base=node_filled ? 24'h25d9df : 24'h24617a;
                if(shown_fault==0 && py>=9'd212 && py<9'd220 && marker_hit) rgb_base=24'hbbf6ff;
                if(py[8:4]==5'd17 && px>=10'd124 && px<10'd516) rgb_base=24'h24617a;
                if(py>=9'd275 && py<9'd285 && px>=10'd128 && px<10'd512) begin
                    rgb_base=progress_filled ? 24'h25d9df : 24'h0b2038;
                    if(shown_fault!=0) rgb_base=24'h712b3c;
                end
                if(px>=10'd176 && px<10'd464 && py>=9'd128 && py<9'd156) begin
                    glyph_code=title_code(cell32); gx={!px[4],px[3:2]}; gy=py[4:2]; text_region=1;
                end else if(px>=10'd208 && px<10'd320 && py>=9'd240 && py<9'd254) begin
                    gx=px[3:1]; gy=py[3:1]; text_region=1; text_red=(shown_fault!=0);
                    case(cell16)
                        5'd13:glyph_code=shown_fault!=0 ? 6'd46 : 6'd57;
                        5'd14:glyph_code=shown_fault!=0 ? 6'd56 : 6'd58;
                        5'd15:glyph_code=shown_fault!=0 ? 6'd56 : 6'd42;
                        5'd16:glyph_code=shown_fault!=0 ? 6'd54 : 6'd48;
                        5'd17:glyph_code=shown_fault!=0 ? 6'd56 : 6'd46;
                        5'd19:glyph_code={2'b10,(shown_fault!=0 ? shown_fault : shown_progress)};
                        default:glyph_code=0;
                    endcase
                end else if(px>=10'd128 && px<10'd240 && py>=9'd312 && py<9'd326) begin
                    gx=px[3:1]; gy=py[3:1]-3'd4; text_region=1;
                    case(cell16)
                        5'd8:glyph_code=6'd55; 5'd9:glyph_code=6'd42; 5'd10:glyph_code=6'd48; 5'd11:glyph_code=6'd46;
                        5'd13:glyph_code={3'b100,shown_page[6:4]};
                        5'd14:glyph_code={2'b10,shown_page[3:0]};
                        default:glyph_code=0;
                    endcase
                end else if(px>=10'd336 && px<10'd512 && py>=9'd312 && py<9'd326) begin
                    gx=px[3:1]; gy=py[3:1]-3'd4; text_region=1;
                    case(cell16)
                        5'd21:glyph_code=6'd52; 5'd22:glyph_code=6'd46; 5'd23:glyph_code=6'd45;
                        5'd24:glyph_code=6'd49; 5'd25:glyph_code=6'd42;
                        5'd27:glyph_code=shown_media ? 6'd56 : 6'd60;
                        5'd28:glyph_code=shown_media ? 6'd46 : 6'd42;
                        5'd29:glyph_code=shown_media ? 6'd42 : 6'd49;
                        5'd30:glyph_code=shown_media ? 6'd45 : 6'd58;
                        5'd31:glyph_code=shown_media ? 6'd62 : 6'd0;
                        default:glyph_code=0;
                    endcase
                end
            end
            if(shown_menu && py<9'd48) begin
                rgb_base=24'h0b2038; glyph_code=0; text_region=0; text_red=0;
                if(py>=9'd46) rgb_base=24'h25d9df;
                if(px>=10'd16 && px<10'd304 && py>=9'd4 && py<9'd20 && cell32==shown_selection)
                    rgb_base=24'h176080;
                if(px>=10'd16 && px<10'd304 && py>=9'd8 && py<9'd15) begin
                    gx=px[2:0]; gy=py[2:0]; glyph_code=label_code(cell32);
                    text_region=px[4] && px[3:0]<4'd5;
                end else if(px>=10'd336 && px<10'd512 && py>=9'd8 && py<9'd22) begin
                    gx=px[3:1]; gy=py[3:1]-3'd4; text_region=1;
                    case(cell16)
                        5'd21:glyph_code=6'd57;5'd22:glyph_code=6'd46;5'd23:glyph_code=6'd58;
                        5'd25:glyph_code={3'b100,shown_edit};
                        5'd27:glyph_code=6'd53;5'd28:glyph_code=6'd54;5'd29:glyph_code=6'd60;
                        5'd31:glyph_code={3'b100,shown_applied};
                        default:glyph_code=0;
                    endcase
                end else if(px>=10'd16 && px<10'd256 && py>=9'd28 && py<9'd35) begin
                    gx=px[2:0]; gy=py[2:0]-3'd4;
                    glyph_code=hint_code(px[7:3]);text_region=1;
                end
            end
        end
    end

    // Stage one: one synchronous ROM row + complete matching pixel metadata.
    reg [23:0] base_d;
    reg [2:0] gx_d;
    reg text_d,red_d,hs_d,vs_pipe_d,de_pipe_d;
    always @(posedge pixelclk) font_row<=font_rows[{glyph_code[4:0],gy}];
    always @(posedge pixelclk or posedge rst) begin
        if(rst) begin
            base_d<=0;gx_d<=0;text_d<=0;red_d<=0;hs_d<=0;vs_pipe_d<=0;de_pipe_d<=0;
            O_rgb<=0;O_hs<=0;O_vs<=0;O_de<=0;
        end else begin
            base_d<=rgb_base;gx_d<=gx;text_d<=text_region && glyph_code[5] && gx<3'd5 && gy<3'd7;
            red_d<=text_red;hs_d<=I_hs;vs_pipe_d<=I_vs;de_pipe_d<=I_de;
            // Stage two: output tuple is delayed uniformly in EVERY mode.
            O_rgb <= (text_d && font_row[3'd4-gx_d]) ? (red_d ? 24'hff687c : 24'hbbf6ff) : base_d;
            O_hs<=hs_d;O_vs<=vs_pipe_d;O_de<=de_pipe_d;
        end
    end
endmodule
`default_nettype wire
