`timescale 1ns/1ps
`default_nettype none
// Exactly ONE register on RGB/HS/VS/DE, including bypass/blank/silence.
// 640 contiguous active pixels/line, 480 lines/frame; VS transitions in vblank.
// Both sync polarities supported. Reset release must precede a full active frame.
module pcm_spectrum_overlay (
    input wire clk, rst,
    input wire enable, half_layout,
    input wire [39:0] band_heights,
    input wire silence,
    input wire [2:0] opacity,
    input wire [23:0] I_rgb,
    input wire I_hs, I_vs, I_de,
    output reg [23:0] O_rgb,
    output reg O_hs, O_vs, O_de
);
    `include "audio_palette.vh"
    reg de_d,vs_d,frame_arm,configured;
    reg [9:0] x;
    reg [8:0] y;
    wire [9:0] px=!de_d ? 10'd0 : x+1'b1;
    wire [8:0] py=!de_d ? (frame_arm ? 9'd0 : y+1'b1) : y;
    // One VS rising edge/frame, for either polarity. First blank after reset
    // initializes a snapshot even if reset was released after the VS edge.
    wire snapshot=!I_de && ((!vs_d && I_vs) || !configured);
    reg shown_enable,shown_half,shown_silence;
    reg [39:0] shown_heights;
    reg [2:0] shown_opacity;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            de_d<=0;vs_d<=0;frame_arm<=1;configured<=0;x<=0;y<=0;
            shown_enable<=0;shown_half<=0;shown_silence<=1;shown_heights<=0;shown_opacity<=0;
        end else begin
            de_d<=I_de;vs_d<=I_vs;
            if(vs_d!=I_vs) frame_arm<=1;
            if(I_de) begin x<=px;y<=py;if(!de_d)frame_arm<=0;end
            if(snapshot) begin
                configured<=1;shown_enable<=enable;shown_half<=half_layout;
                shown_silence<=silence;shown_heights<=band_heights;shown_opacity<=opacity;
            end
        end
    end

    reg in_slot;
    reg [2:0] slot;
    // Constant ranges avoid /70, /36 or a variable-width horizontal divider.
    always @* begin
        slot=0;in_slot=1;
        if(shown_half) case(1'b1)
            (px>=168 && px<192):slot=0;
            (px>=204 && px<228):slot=1;
            (px>=240 && px<264):slot=2;
            (px>=276 && px<300):slot=3;
            (px>=312 && px<336):slot=4;
            (px>=348 && px<372):slot=5;
            (px>=384 && px<408):slot=6;
            (px>=420 && px<444):slot=7;
            default:in_slot=0;
        endcase
        else case(1'b1)
            (px>=16 && px<64):slot=0;
            (px>=86 && px<134):slot=1;
            (px>=156 && px<204):slot=2;
            (px>=226 && px<274):slot=3;
            (px>=296 && px<344):slot=4;
            (px>=366 && px<414):slot=5;
            (px>=436 && px<484):slot=6;
            (px>=506 && px<554):slot=7;
            default:in_slot=0;
        endcase
    end
    wire [5:0] height_offset={1'b0,slot,2'b00}+{3'b000,slot};
    wire [4:0] h=shown_silence ? 5'd0 : shown_heights[height_offset +: 5];
    // ceil(3*h/4), ceil(5*h/8): 31 reaches 24 / 20; zero stays zero.
    wire [6:0] normal_scaled={1'b0,h,1'b0}+{2'b00,h}+7'd3;
    wire [7:0] half_scaled={1'b0,h,2'b00}+{3'b000,h}+8'd7;
    wire [4:0] height=shown_half ? half_scaled[7:3] : normal_scaled[6:2];
    wire [8:0] bottom=shown_half ? 9'd252 : 9'd312;
    wire in_body=shown_half ? (py>=232 && py<252) : (py>=288 && py<312);
    wire filled=py>=bottom-{4'd0,height};
    wire [23:0] tint=filled ? band_color(slot) : 24'h173541;
    function [7:0] blend;
        input [7:0] base,color;
        input [2:0] alpha;
        reg [8:0] pair_sum;
        reg [7:0] heavier;
        reg [9:0] weighted;
        begin
            pair_sum={1'b0,base}+{1'b0,color};
            case(alpha)
                3'd3:heavier=color;
                default:heavier=base;
            endcase
            weighted={1'b0,pair_sum}+{1'b0,heavier,1'b0};
            case(alpha)
                0:blend=base;
                2:blend=pair_sum[8:1];
                4:blend=color;
                default:blend=weighted[9:2];
            endcase
        end
    endfunction
    wire draw=I_de && shown_enable && in_slot && in_body;
    always @(posedge clk or posedge rst) begin
        if(rst) begin O_rgb<=0;O_hs<=0;O_vs<=0;O_de<=0;end
        else begin
            O_hs<=I_hs;O_vs<=I_vs;O_de<=I_de;
            O_rgb<=draw ? {blend(I_rgb[23:16],tint[23:16],shown_opacity),
                          blend(I_rgb[15:8],tint[15:8],shown_opacity),
                          blend(I_rgb[7:0],tint[7:0],shown_opacity)} : I_rgb;
        end
    end
endmodule
`default_nettype wire
