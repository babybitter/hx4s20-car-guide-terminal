module frame_slot_mgr (
    input wire clk,
    input wire rst,
    input wire begin_load,
    input wire [1:0] target_slot,
    input wire pixel_accepted,
    input wire source_done,
    input wire write_finish,
    input wire load_error,
    output reg busy,
    output reg [1:0] active_slot,
    output reg [3:0] valid_mask,
    output reg [3:0] error_mask,
    output reg [2:0] valid_count,
    output reg load_committed,
    output reg load_failed
);
    localparam [18:0] FRAME_PIXELS = 19'd307200;
    reg [18:0] pixels;
    reg source_complete;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy <= 1'b0;
            active_slot <= 2'd0;
            pixels <= 19'd0;
            source_complete <= 1'b0;
            valid_mask <= 4'b0000;
            error_mask <= 4'b0000;
            valid_count <= 3'd0;
            load_committed <= 1'b0;
            load_failed <= 1'b0;
        end else begin
            load_committed <= 1'b0;
            load_failed <= 1'b0;
            if (!busy) begin
                if (begin_load) begin
                    if (valid_mask[target_slot]) begin
                        load_failed <= 1'b1;
                    end else begin
                        busy <= 1'b1;
                        active_slot <= target_slot;
                        pixels <= 19'd0;
                        source_complete <= 1'b0;
                        error_mask[target_slot] <= 1'b0;
                    end
                end
            end else if (load_error || (pixel_accepted && pixels == FRAME_PIXELS)) begin
                busy <= 1'b0;
                error_mask[active_slot] <= 1'b1;
                load_failed <= 1'b1;
            end else begin
                if (pixel_accepted)
                    pixels <= pixels + 1'b1;
                if (source_done)
                    source_complete <= 1'b1;
                if (write_finish) begin
                    busy <= 1'b0;
                    if ((source_complete || source_done) &&
                        (pixels == FRAME_PIXELS ||
                         (pixel_accepted && pixels == FRAME_PIXELS - 1'b1))) begin
                        valid_mask[active_slot] <= 1'b1;
                        valid_count <= valid_count + 1'b1;
                        load_committed <= 1'b1;
                    end else begin
                        error_mask[active_slot] <= 1'b1;
                        load_failed <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
