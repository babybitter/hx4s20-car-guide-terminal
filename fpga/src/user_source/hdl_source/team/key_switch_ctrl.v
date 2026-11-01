module key_switch_ctrl #(
    parameter integer CLK_HZ = 25000000,
    parameter integer DEBOUNCE_MS = 20
) (
    input wire clk,
    input wire rst,
    input wire key_next_n,
    input wire key_auto_n,
    input wire key_prompt_n,
    input wire [1:0] period_sw,
    output wire next_pulse,
    output wire auto_pulse,
    output wire prompt_pulse,
    output reg [1:0] period_sel,
    output reg period_changed
);
    localparam integer STABLE_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_MS;

    key_press_filter #(.STABLE_CYCLES(STABLE_CYCLES)) next_key (
        .clk(clk), .rst(rst), .key_n(key_next_n), .press(next_pulse)
    );
    key_press_filter #(.STABLE_CYCLES(STABLE_CYCLES)) auto_key (
        .clk(clk), .rst(rst), .key_n(key_auto_n), .press(auto_pulse)
    );
    key_press_filter #(.STABLE_CYCLES(STABLE_CYCLES)) prompt_key (
        .clk(clk), .rst(rst), .key_n(key_prompt_n), .press(prompt_pulse)
    );

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
    localparam integer COUNTER_WIDTH=counter_width((CLK_HZ / 1000) * DEBOUNCE_MS);
    reg [1:0] sw_meta;
    reg [1:0] sw_sync;
    reg [1:0] sw_candidate;
    reg [COUNTER_WIDTH-1:0] sw_count;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw_meta <= 2'b01;
            sw_sync <= 2'b01;
            sw_candidate <= 2'b01;
            sw_count <= 32'd0;
            period_sel <= 2'b01;
            period_changed <= 1'b0;
        end else begin
            sw_meta <= period_sw;
            sw_sync <= sw_meta;
            period_changed <= 1'b0;
            if (sw_sync != sw_candidate) begin
                sw_candidate <= sw_sync;
                sw_count <= 32'd0;
            end else if (sw_candidate != period_sel) begin
                if (sw_count == STABLE_CYCLES - 1) begin
                    period_sel <= sw_candidate;
                    period_changed <= 1'b1;
                    sw_count <= 32'd0;
                end else begin
                    sw_count <= sw_count + 1'b1;
                end
            end else begin
                sw_count <= 32'd0;
            end
        end
    end
endmodule

module key_press_filter #(
    parameter integer STABLE_CYCLES = 500000
) (
    input wire clk,
    input wire rst,
    input wire key_n,
    output reg press
);
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
    localparam integer COUNTER_WIDTH=counter_width(STABLE_CYCLES);
    reg meta;
    reg sync;
    reg stable;
    reg [COUNTER_WIDTH-1:0] count;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            meta <= 1'b1;
            sync <= 1'b1;
            stable <= 1'b1;
            count <= 32'd0;
            press <= 1'b0;
        end else begin
            meta <= key_n;
            sync <= meta;
            press <= 1'b0;
            if (sync == stable) begin
                count <= 32'd0;
            end else if (count == STABLE_CYCLES - 1) begin
                stable <= sync;
                press <= stable && !sync;
                count <= 32'd0;
            end else begin
                count <= count + 1'b1;
            end
        end
    end
endmodule
