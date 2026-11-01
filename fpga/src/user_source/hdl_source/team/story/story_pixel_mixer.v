// Real channel interpolation: round((A*(256-alpha)+B*alpha)/256).
// Endpoint requests can omit the unused source. Two registered stages.
module story_pixel_mixer (
    input wire clk, rst,
    input wire in_valid, in_good,
    input wire [1:0] need,
    input wire [8:0] alpha,
    input wire [23:0] rgb_a, rgb_b,
    input wire [95:0] provenance,
    output reg out_valid, out_good, underrun,
    output reg [23:0] rgb,
    output reg [95:0] out_provenance
);
    reg stage_valid, stage_good;
    reg [16:0] sum_r, sum_g, sum_b;
    reg [95:0] stage_provenance;
    wire [8:0] effective_alpha=(need==2'b01) ? 9'd0 : ((need==2'b10) ? 9'd256 : alpha);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            stage_valid<=0; stage_good<=0; stage_provenance<=0;
            sum_r<=0; sum_g<=0; sum_b<=0;
            out_valid<=0; out_good<=0; underrun<=0; rgb<=0; out_provenance<=0;
        end else begin
            stage_valid<=in_valid;
            stage_good<=in_good && (need!=0) && (alpha<=256);
            stage_provenance<=provenance;
            // Explicit 17-bit operands prevent intermediate truncation.
            sum_r<=({9'd0,rgb_a[23:16]}*(17'd256-effective_alpha))+
                   ({9'd0,rgb_b[23:16]}*effective_alpha)+17'd128;
            sum_g<=({9'd0,rgb_a[15:8]}*(17'd256-effective_alpha))+
                   ({9'd0,rgb_b[15:8]}*effective_alpha)+17'd128;
            sum_b<=({9'd0,rgb_a[7:0]}*(17'd256-effective_alpha))+
                   ({9'd0,rgb_b[7:0]}*effective_alpha)+17'd128;
            out_valid<=stage_valid;
            out_good<=stage_valid && stage_good;
            underrun<=stage_valid && !stage_good;
            rgb<=(stage_valid && stage_good) ? {sum_r[15:8],sum_g[15:8],sum_b[15:8]} : 24'd0;
            out_provenance<=stage_provenance;
        end
    end
endmodule
