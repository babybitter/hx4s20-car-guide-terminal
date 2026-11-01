// One-shot catalogue publication across SD -> pixel clocks. Source count is
// frozen before ready_sd rises and stays fixed until the common reset. The
// held fault code is sampled only after its valid flag has crossed three FFs.
// This is a bundled-data contract, not a bitwise synchronizer for changing buses.
module media_status_bridge (
    input wire pixel_clk, pixel_rst,
    input wire ready_sd, fault_sd,
    input wire [7:0] count_sd,
    input wire [3:0] error_sd,
    output reg ready_pixel,
    output reg [7:0] count_pixel,
    output reg [3:0] error_pixel
);
    reg [2:0] ready_sync, fault_sync;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            ready_sync <= 0;
            fault_sync <= 0;
            ready_pixel <= 0;
            count_pixel <= 0;
            error_pixel <= 0;
        end else begin
            ready_sync <= {ready_sync[1:0], ready_sd};
            fault_sync <= {fault_sync[1:0], fault_sd};
            // Publish data and valid on the same pixel edge. Downstream logic
            // sees only this local register, never a live SD-domain count.
            if (ready_sync[2] && !ready_pixel) begin
                count_pixel <= count_sd;
                ready_pixel <= 1;
            end
            error_pixel <= fault_sync[2] ? error_sd : 4'd0;
        end
    end
endmodule
