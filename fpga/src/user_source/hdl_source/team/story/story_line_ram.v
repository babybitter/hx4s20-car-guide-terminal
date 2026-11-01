// New team implementation, not vendor IP. 640 RGB pixels; no reset on RAM.
// One memory-clock write port and one synchronous pixel-clock read port.
module story_line_ram (
    input wire mem_clk, input wire wr_en,
    input wire [9:0] wr_x, input wire [23:0] wr_rgb,
    input wire pixel_clk, input wire rd_en,
    input wire [9:0] rd_x, output reg [23:0] rd_rgb
);
    reg [23:0] pixels [0:639];
    always @(posedge mem_clk)
        if (wr_en) pixels[wr_x] <= wr_rgb;
    always @(posedge pixel_clk)
        if (rd_en) rd_rgb <= pixels[rd_x];
endmodule
