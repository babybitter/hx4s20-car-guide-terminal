// Adapted from user advanced solution; see docs/advanced-port-audit.md.
module uart_rx_8n1 #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst,
    input wire rx,
    output reg data_valid,
    output reg [7:0] data,
    output reg frame_error
);
    localparam integer CLKS_PER_BIT = (CLK_FREQ_HZ + BAUD_RATE/2) / BAUD_RATE;
    localparam integer HALF_BIT = CLKS_PER_BIT / 2;
    localparam [2:0] RX_IDLE = 3'd0;
    localparam [2:0] RX_START = 3'd1;
    localparam [2:0] RX_DATA = 3'd2;
    localparam [2:0] RX_STOP = 3'd3;
    localparam [2:0] RX_RECOVER = 3'd4;

    // Preserve original 32-bit wrap for zero/one/negative/unknown limits.
    // For limit > 1, reset/terminal logic bounds count to [0, limit-1].
    function integer counter_width;
        input integer limit;
        integer remaining;
        begin
            counter_width=32;
            if(limit>1) begin
                counter_width=0;
                for(remaining=limit-1;remaining>0;remaining=remaining>>1)
                    counter_width=counter_width+1;
            end
        end
    endfunction
    localparam integer COUNTER_WIDTH=counter_width(CLKS_PER_BIT);
    reg rx_meta;
    reg rx_sync;
    reg [2:0] state;
    reg [COUNTER_WIDTH-1:0] clk_count;
    reg [2:0] bit_index;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            data_valid <= 1'b0;
            frame_error <= 1'b0;
            data <= 8'h00;
            state <= RX_IDLE;
            clk_count <= 32'd0;
            bit_index <= 3'd0;
        end else begin
            data_valid <= 1'b0;
            frame_error <= 1'b0;
            case (state)
                RX_IDLE: begin
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    if (!rx_sync)
                        state <= RX_START;
                end

                RX_START: begin
                    if (clk_count == HALF_BIT - 1) begin
                        clk_count <= 32'd0;
                        state <= rx_sync ? RX_IDLE : RX_DATA;
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                RX_DATA: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 32'd0;
                        data[bit_index] <= rx_sync;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state <= RX_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                RX_STOP: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        data_valid <= rx_sync; // Reject a low stop bit.
                        frame_error <= !rx_sync;
                        clk_count <= 32'd0;
                        state <= rx_sync ? RX_IDLE : RX_RECOVER;
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                RX_RECOVER: begin
                    // A break must not repeatedly manufacture bytes/start bits.
                    if (rx_sync) state <= RX_IDLE;
                end
                default: begin
                    state <= RX_IDLE;
                end
            endcase
        end
    end
endmodule

module uart_tx_8n1 #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst,
    input wire start,
    input wire [7:0] data,
    output reg tx,
    output reg busy
);
    localparam integer CLKS_PER_BIT = (CLK_FREQ_HZ + BAUD_RATE/2) / BAUD_RATE;

    // Preserve original 32-bit wrap for zero/one/negative/unknown limits.
    // For limit > 1, reset/terminal logic bounds count to [0, limit-1].
    function integer counter_width;
        input integer limit;
        integer remaining;
        begin
            counter_width=32;
            if(limit>1) begin
                counter_width=0;
                for(remaining=limit-1;remaining>0;remaining=remaining>>1)
                    counter_width=counter_width+1;
            end
        end
    endfunction
    localparam integer COUNTER_WIDTH=counter_width(CLKS_PER_BIT);
    reg [COUNTER_WIDTH-1:0] clk_count;
    reg [3:0] bit_index;
    reg [9:0] shifter;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx <= 1'b1;
            busy <= 1'b0;
            clk_count <= 32'd0;
            bit_index <= 4'd0;
            shifter <= 10'h3FF;
        end else if (!busy) begin
            tx <= 1'b1;
            clk_count <= 32'd0;
            bit_index <= 4'd0;
            if (start) begin
                busy <= 1'b1;
                shifter <= {1'b1, data, 1'b0};
                tx <= 1'b0;
            end
        end else begin
            if (clk_count == (CLKS_PER_BIT - 1)) begin
                clk_count <= 32'd0;
                if (bit_index == 4'd9) begin
                    busy <= 1'b0;
                    tx <= 1'b1;
                    bit_index <= 4'd0;
                end else begin
                    bit_index <= bit_index + 4'd1;
                    tx <= shifter[1];
                    shifter <= {1'b1, shifter[9:1]};
                end
            end else begin
                clk_count <= clk_count + 32'd1;
            end
        end
    end
endmodule
