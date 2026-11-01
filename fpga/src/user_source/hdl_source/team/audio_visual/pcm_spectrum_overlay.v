`timescale 1ns/1ps
`default_nettype none
// Exactly ONE register on RGB/HS/VS/DE, including bypass/blank/silence.
// 32 independent analyzer responses, one 5-bit height per physical column.
// NO frequency interpolation, FFT, extra sample memory or peak-history RAM.
// 640 contiguous active pixels/line, 480 lines/frame; VS changes in vblank.
module pcm_spectrum_overlay (
    input wire clk, rst,
    input wire enable, half_layout,
    input wire [159:0] band_heights,
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
    reg shown_enable,shown_half,shown_silence;
    reg [159:0] shown_heights;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            de_d<=0;vs_d<=0;frame_arm<=1;x<=0;y<=0;
            shown_enable<=0;shown_half<=0;shown_silence<=1;shown_heights<=0;
        end else begin
            de_d<=I_de;vs_d<=I_vs;
            if(vs_d!=I_vs) frame_arm<=1;
            if(I_de) begin x<=px;y<=py;if(!de_d)frame_arm<=0;end
            if(snapshot) begin
                shown_enable<=enable;shown_half<=half_layout;
                shown_silence<=silence;shown_heights<=band_heights;
            end
        end
    end
    wire [9:0] panel_left=shown_half ? 10'd192 : 10'd160;
    wire [9:0] panel_right=shown_half ? 10'd448 : 10'd480;
    wire in_x=px>=panel_left && px<panel_right;
    reg [4:0] slot;
    reg [3:0] phase;
    // 32 x 10px (7px ink) normal; 32 x 8px (5px ink) half.
    // Pixel counters replace a divide/modulo-by-10 datapath.
    always @(posedge clk or posedge rst) begin
        if(rst) begin slot<=0;phase<=0;end
        else if(!I_de || !in_x) begin slot<=0;phase<=0;end
        else if(phase==(shown_half ? 4'd7 : 4'd9)) begin slot<=slot+5'd1;phase<=0;end
        else phase<=phase+4'd1;
    end
    wire in_slot=phase>=4'd1 && phase<=(shown_half ? 4'd5 : 4'd7);
    // Static 5-bit lanes infer a 32:1 word mux, rather than a variable bit
    // offset/shift through the 160-bit snapshot. These wires add no storage.
    wire [4:0] height_by_slot [0:31];
    genvar height_slot;
    generate
        for(height_slot=0; height_slot<32; height_slot=height_slot+1) begin : g_height_lanes
            assign height_by_slot[height_slot]=shown_heights[height_slot*5 +: 5];
        end
    endgenerate
    wire [4:0] h=shown_silence ? 5'd0 : height_by_slot[slot];
    // floor(27*h/16): monotonic 0..31 -> 0..52px, shifts/subtractions only.
    wire [9:0] scaled_height={h,5'b0}-{3'b0,h,2'b0}-{5'b0,h};
    wire [5:0] height=scaled_height[9:4];
    wire [8:0] bar_top=9'd400-{3'd0,height};
    wire in_body=py>=9'd344 && py<9'd400 && py>=bar_top && height!=0;
    // Static spatial rainbow; audio changes actual bar heights. The light
    // cap is the current top, not an invented or held spectral peak.
    function [23:0] rainbow;
        input [4:0] band;
        reg [2:0] phase;
        reg [7:0] rise,fall;
        begin
            // Four wired ramps, no 32-entry RGB lookup. Adjacent segment
            // endpoints repeat: 32 columns contain 29 distinct body colors.
            phase=band[2:0];
            rise={phase,5'b11111};
            fall={~phase,5'b11111};
            case(band[4:3])
                2'd0:rainbow={rise,8'h1F,8'hFF};
                2'd1:rainbow={8'hFF,8'h1F,fall};
                2'd2:rainbow={8'hFF,rise,8'h1F};
                2'd3:rainbow={fall,8'hFF,8'h1F};
            endcase
        end
    endfunction
    wire [23:0] color=rainbow(slot);
    wire [23:0] cap_color={1'b1,color[23:17],1'b1,color[15:9],1'b1,color[7:1]};
    wire [23:0] tint=py==bar_top ? cap_color : color;
    // Silence, gaps and unfilled bar area never darken the panel again.
    // The registered actual-wave mask has absolute priority over spectrum.
    wire draw=I_de && shown_enable && in_x && in_slot && in_body && !I_wave_hit;
    always @(posedge clk or posedge rst) begin
        if(rst) begin O_rgb<=0;O_hs<=0;O_vs<=0;O_de<=0;end
        else begin
            O_hs<=I_hs;O_vs<=I_vs;O_de<=I_de;
            O_rgb<=draw ? tint : I_rgb;
        end
    end
endmodule
`default_nettype wire
