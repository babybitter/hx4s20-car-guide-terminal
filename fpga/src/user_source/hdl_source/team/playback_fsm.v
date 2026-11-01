module playback_fsm #(
    parameter integer CLK_HZ = 25000000
) (
    input wire clk,
    input wire rst,
    input wire media_ready,
    input wire [2:0] valid_count,
    input wire next_pulse,
    input wire auto_pulse,
    input wire [1:0] period_sel,
    input wire period_changed,
    input wire prompt_active,
    input wire frame_boundary,
    input wire page_ready,
    output reg auto_enabled,
    output reg page_req,
    output reg [1:0] page_target,
    output reg [1:0] display_page,
    output reg page_commit,
    output reg [15:0] event_seq
);
    localparam integer TICKS_PER_MS = CLK_HZ / 1000;
    reg [31:0] ms_div;
    reg [15:0] elapsed_ms;
    reg pending_next;
    reg prepared;
    reg page_ready_d;
    wire [15:0] period_ms =
        period_sel == 2'b00 ? 16'd2000 :
        period_sel == 2'b01 ? 16'd5000 :
        period_sel == 2'b10 ? 16'd10000 : 16'd15000;
    wire ms_tick = ms_div == TICKS_PER_MS - 1;
    wire automatic_due = !prompt_active && ms_tick &&
                         elapsed_ms == period_ms - 1;
    wire [1:0] next_page =
        (display_page + 3'd1 >= valid_count) ? 2'd0 : display_page + 2'd1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ms_div <= 32'd0;
            elapsed_ms <= 16'd0;
            auto_enabled <= 1'b0;
            pending_next <= 1'b0;
            page_req <= 1'b0;
            page_target <= 2'd0;
            display_page <= 2'd0;
            prepared <= 1'b0;
            page_ready_d <= 1'b0;
            page_commit <= 1'b0;
            event_seq <= 16'd0;
        end else begin
            page_commit <= 1'b0;
            page_ready_d <= page_ready;
            if (ms_tick)
                ms_div <= 32'd0;
            else
                ms_div <= ms_div + 1'b1;

            if (!media_ready || valid_count < 3'd2) begin
                auto_enabled <= 1'b0;
                elapsed_ms <= 16'd0;
                pending_next <= 1'b0;
                page_req <= 1'b0;
                prepared <= 1'b0;
            end else begin
                if (auto_pulse) begin
                    auto_enabled <= !auto_enabled;
                    elapsed_ms <= 16'd0;
                end else if (period_changed || prompt_active) begin
                    elapsed_ms <= 16'd0;
                end else if (auto_enabled && !page_req && !prepared && ms_tick) begin
                    if (automatic_due)
                        elapsed_ms <= 16'd0;
                    else
                        elapsed_ms <= elapsed_ms + 1'b1;
                end

                if (next_pulse || (auto_enabled && automatic_due))
                    pending_next <= 1'b1;

                if (!page_req && !prepared && pending_next) begin
                    page_target <= next_page;
                    page_req <= 1'b1;
                    pending_next <= 1'b0;
                end

                if (page_req && page_ready && !page_ready_d) begin
                    page_req <= 1'b0;
                    prepared <= 1'b1;
                end
                if (prepared && frame_boundary) begin
                    display_page <= page_target;
                    page_commit <= 1'b1;
                    event_seq <= event_seq + 1'b1;
                    prepared <= 1'b0;
                    elapsed_ms <= 16'd0;
                end
            end
        end
    end
endmodule
