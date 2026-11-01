// Optional offline frame-boundary progress controller; no top/playback coupling.
// Start is accepted only with frame_boundary. Duration: 32 or 64 boundaries
// after the initial alpha=0 frame. No queued triggers or duplicate completion.
module story_transition (
    input wire clk, rst, frame_boundary, frame_ready, start,
    input wire duration_64,
    input wire [1:0] source_a, source_b, requested_mode,
    output wire start_ready,
    output reg active,
    output reg [1:0] slot_a, slot_b, mode,
    output reg [8:0] alpha,
    output wire [9:0] horizontal_shift,
    output wire [9:0] vertical_shift,
    output reg page_commit, cue
);
    reg [8:0] step;
    wire [18:0] horizontal_product={10'd0,alpha}*19'd640;
    wire [17:0] vertical_product={9'd0,alpha}*18'd480;
    assign horizontal_shift=horizontal_product[17:8];
    assign vertical_shift=vertical_product[17:8];
    assign start_ready=frame_boundary && frame_ready && !active;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active<=0; slot_a<=0; slot_b<=0; mode<=0; alpha<=0;
            step<=8; page_commit<=0; cue<=0;
        end else begin
            page_commit<=0; cue<=0;
            if (start && start_ready) begin
                active<=1; alpha<=0; step<=duration_64 ? 9'd4 : 9'd8;
                slot_a<=source_a; slot_b<=source_b; mode<=requested_mode;
            end else if (frame_boundary && frame_ready && active) begin
                if (alpha+step>=256) begin
                    alpha<=256; active<=0; page_commit<=1; cue<=1;
                end else alpha<=alpha+step;
            end
        end
    end
endmodule
