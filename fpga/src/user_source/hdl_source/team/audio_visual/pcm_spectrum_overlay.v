`timescale 1ns/1ps
`default_nettype none
// Exactly ONE register on RGB/HS/VS/DE, including bypass/blank/silence.
// 63 real analyzer bins, one 5-bit height per physical column.
// NO frequency interpolation, FFT, extra sample memory or peak-history RAM.
// 640 contiguous active pixels/line, 480 lines/frame; VS changes in vblank.
module pcm_spectrum_overlay #(parameter GUARDED_HEIGHTS=0) (
    input wire clk, rst,
    input wire enable, half_layout,
    input wire [314:0] band_heights,
    input wire heights_ready,
    input wire silence,
    // Compatibility input: Y controls the upstream panel BACKGROUND only.
    // Colored columns/caps remain vivid even at Y0; no second alpha blend.
    input wire [2:0] opacity,
    input wire [23:0] I_rgb,
    input wire I_hs, I_vs, I_de,
    input wire I_wave_hit,
    output reg [23:0] O_rgb,
    output reg O_hs, O_vs, O_de
);
    reg de_d,vs_d,frame_arm;
    reg [9:0] x;
    reg [8:0] y;
    wire [9:0] px=!de_d ? 10'd0 : x+10'd1;
    wire [8:0] py=!de_d ? (frame_arm ? 9'd0 : y+9'd1) : y;
    // First active pixel snapshot, as in pcm_wave_overlay; both VS polarities
    // and layout changes anywhere in vblank are supported.
    wire snapshot=I_de && !de_d && frame_arm;
    reg shown_enable;
    // Legacy unguarded callers retain the parallel snapshot. The production
    // guarded mode uses one BRAM with two 63-word banks instead of 315 FFs.
    reg [314:0] shown_heights;
    (* ram_style = "block" *) reg [4:0] height_ram [0:127];
    reg display_bank,display_valid,copy_active;
    reg [5:0] copy_index;
    reg [4:0] height_read;
    reg [6:0] frame_hue;
    reg [2:0] hue_div;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            de_d<=0;vs_d<=0;frame_arm<=1;x<=0;y<=0;
            shown_enable<=0;shown_heights<=0;
            frame_hue<=0;hue_div<=0;
        end else begin
            de_d<=I_de;vs_d<=I_vs;
            if(vs_d!=I_vs) frame_arm<=1;
            if(I_de) begin x<=px;y<=py;if(!de_d)frame_arm<=0;end
            if(snapshot) begin
                shown_enable<=enable;
                if(!GUARDED_HEIGHTS) shown_heights<=band_heights;
                // One step per eight active frames; silence pauses the hue,
                // never the analyzer's gradual height decay. No level tint.
                if(!silence) begin
                    hue_div<=hue_div+3'd1;
                    if(hue_div==3'd7) frame_hue<=frame_hue+7'd1;
                end
            end
        end
    end
    // half_layout is retained for caller compatibility; geometry is shared.
    wire [9:0] panel_left=10'd16;
    wire [9:0] panel_right=10'd624;
    wire in_x=px>=panel_left && px<panel_right;
    reg [5:0] slot;
    reg [3:0] phase;
    reg [5:0] slot_error;
    // 608 = 63*9 + 41: Bresenham distributes 22 nine-pixel and 41 ten-pixel
    // slots. Seven ink pixels leave 2/3px gaps; no pixel multiply or divide.
    wire wide_slot=slot_error>=6'd22;
    always @(posedge clk or posedge rst) begin
        if(rst) begin slot<=0;phase<=0;slot_error<=0;end
        else if(!I_de || !in_x) begin slot<=0;phase<=0;slot_error<=0;end
        else if(phase==(wide_slot ? 4'd9 : 4'd8)) begin
            slot<=slot+6'd1;phase<=0;
            slot_error<=wide_slot ? slot_error-6'd22 : slot_error+6'd41;
        end
        else phase<=phase+4'd1;
    end
    wire in_slot=phase>=4'd1 && phase<=4'd7;
    // Guarded copy takes 63 clocks in the first active line, well before the
    // visible panel at y343. If the analyzer starts rotating during the copy,
    // discard the back bank and keep the previous complete displayed frame.
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            display_bank<=0;display_valid<=0;copy_active<=0;copy_index<=0;
        end else if(GUARDED_HEIGHTS) begin
            if(snapshot) begin
                copy_active<=enable && heights_ready;
                copy_index<=0;
            end else if(copy_active) begin
                if(!heights_ready) copy_active<=0;
                else if(copy_index==6'd62) begin
                    display_bank<=!display_bank;display_valid<=1;copy_active<=0;
                end else copy_index<=copy_index+6'd1;
            end
        end
    end
    wire [314:0] selection_bus=GUARDED_HEIGHTS ? band_heights : shown_heights;
    wire [5:0] selection_index=GUARDED_HEIGHTS ? copy_index : slot;
    // Two levels of 5-bit selectors: one word copied per clock, not a barrel
    // shifter. Production display reads the BRAM only at a slot's blank pixel.
    wire [4:0] height_group [0:7];
    genvar group,lane;
    generate
        for(group=0; group<8; group=group+1) begin : g_height_groups
            wire [4:0] lanes [0:7];
            for(lane=0; lane<8; lane=lane+1) begin : g_lanes
                if(group*8+lane<63)
                    assign lanes[lane]=selection_bus[(group*8+lane)*5 +: 5];
                else assign lanes[lane]=5'd0;
            end
            assign height_group[group]=lanes[selection_index[2:0]];
        end
    endgenerate
    wire [4:0] selected_height=height_group[selection_index[5:3]];
    always @(posedge clk) begin
        if(GUARDED_HEIGHTS && !rst && copy_active && heights_ready && !snapshot)
            height_ram[{!display_bank,copy_index}]<=selected_height;
        if(GUARDED_HEIGHTS && shown_enable && I_de && in_x && phase==0)
            height_read<=height_ram[{display_bank,slot}];
    end
    // Trust the analyzer's release envelope, including while silent. Invalid
    // input is suppressed by the caller's enable, not by abruptly zeroing h.
    wire [4:0] h=GUARDED_HEIGHTS ? height_read : selected_height;
    // Exact floor(27*h/16) truth table: five inputs, no wide carry chain.
    function [5:0] height_pixels;
        input [4:0] level;
        begin
            case(level)
                0:height_pixels=0; 1:height_pixels=1;
                2:height_pixels=3; 3:height_pixels=5;
                4:height_pixels=6; 5:height_pixels=8;
                6:height_pixels=10; 7:height_pixels=11;
                8:height_pixels=13; 9:height_pixels=15;
                10:height_pixels=16; 11:height_pixels=18;
                12:height_pixels=20; 13:height_pixels=21;
                14:height_pixels=23; 15:height_pixels=25;
                16:height_pixels=27; 17:height_pixels=28;
                18:height_pixels=30; 19:height_pixels=32;
                20:height_pixels=33; 21:height_pixels=35;
                22:height_pixels=37; 23:height_pixels=38;
                24:height_pixels=40; 25:height_pixels=42;
                26:height_pixels=43; 27:height_pixels=45;
                28:height_pixels=47; 29:height_pixels=48;
                30:height_pixels=50; default:height_pixels=52;
            endcase
        end
    endfunction
    wire [5:0] height=height_pixels(h);
    wire [8:0] bar_top=9'd399-{3'd0,height};
    wire in_body=py>=9'd343 && py<9'd399 && py>=bar_top && height!=0;
    // Music-Spectrum README reference: HSL S=.85, L=.6, 128 hue steps.
    // Fixed endpoints 66/240 give L=.6, S=.853 (8-bit quantization).
    // Six continuous ramps cover the FULL rainbow. A five-input truth table
    // plus an exact +87 offset replaces the wider ramp arithmetic.
    function [23:0] rainbow;
        input [6:0] hue;
        reg [9:0] wheel;
        reg [5:0] fraction;
        reg [7:0] ramp;
        reg [7:0] rise,fall;
        begin
            wheel={1'b0,hue,2'b0}+{2'b0,hue,1'b0};
            fraction=wheel[6:1];
            // R(f)=floor((87*f+16)/32). For f=u+32*b, R(f)=R(u)+87*b.
            // The 32-entry combinational table is exact, with no new RAM.
            case(fraction[4:0])
                5'd0: ramp=8'd0;
                5'd1: ramp=8'd3;
                5'd2: ramp=8'd5;
                5'd3: ramp=8'd8;
                5'd4: ramp=8'd11;
                5'd5: ramp=8'd14;
                5'd6: ramp=8'd16;
                5'd7: ramp=8'd19;
                5'd8: ramp=8'd22;
                5'd9: ramp=8'd24;
                5'd10: ramp=8'd27;
                5'd11: ramp=8'd30;
                5'd12: ramp=8'd33;
                5'd13: ramp=8'd35;
                5'd14: ramp=8'd38;
                5'd15: ramp=8'd41;
                5'd16: ramp=8'd44;
                5'd17: ramp=8'd46;
                5'd18: ramp=8'd49;
                5'd19: ramp=8'd52;
                5'd20: ramp=8'd54;
                5'd21: ramp=8'd57;
                5'd22: ramp=8'd60;
                5'd23: ramp=8'd63;
                5'd24: ramp=8'd65;
                5'd25: ramp=8'd68;
                5'd26: ramp=8'd71;
                5'd27: ramp=8'd73;
                5'd28: ramp=8'd76;
                5'd29: ramp=8'd79;
                5'd30: ramp=8'd82;
                5'd31: ramp=8'd84;
                default: ramp=8'bx;
            endcase
            ramp=ramp+(fraction[5] ? 8'd87 : 8'd0);
            rise=8'd66+ramp;fall=8'd240-ramp;
            case(wheel[9:7])
                3'd0:rainbow={8'd240,rise,8'd66};
                3'd1:rainbow={fall,8'd240,8'd66};
                3'd2:rainbow={8'd66,8'd240,rise};
                3'd3:rainbow={8'd66,fall,8'd240};
                3'd4:rainbow={rise,8'd66,8'd240};
                default:rainbow={8'd240,8'd66,fall};
            endcase
        end
    endfunction
    wire [6:0] hue=frame_hue+{slot,1'b0};
    wire [23:0] color=rainbow(hue);
    wire [23:0] cap_color={1'b1,color[23:17],1'b1,color[15:9],1'b1,color[7:1]};
    wire [23:0] tint=py==bar_top ? cap_color : color;
    // Gaps and unfilled bar area never darken the panel again.
    // The registered actual-wave mask has absolute priority over spectrum.
    wire draw=I_de && shown_enable && (!GUARDED_HEIGHTS || display_valid)
              && in_x && in_slot && in_body && !I_wave_hit;
    always @(posedge clk or posedge rst) begin
        if(rst) begin O_rgb<=0;O_hs<=0;O_vs<=0;O_de<=0;end
        else begin
            O_hs<=I_hs;O_vs<=I_vs;O_de<=I_de;
            O_rgb<=draw ? tint : I_rgb;
        end
    end
endmodule
`default_nettype wire
