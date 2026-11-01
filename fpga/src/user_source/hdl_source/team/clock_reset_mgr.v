module clock_reset_mgr #(
    parameter integer STABLE_CYCLES = 1000000
) (
    input wire clk_ref,
    input wire clk_sd,
    input wire clk_mem,
    input wire clk_pixel,
    input wire rst_n,
    input wire sys_locked,
    input wire video_locked,
    output wire rst_sd,
    output wire rst_mem,
    output wire rst_pixel,
    input wire clk_serial,
    output wire rst_serial
);
    wire locks_ok = sys_locked && video_locked;
    (* keep *) wire reference_async_reset = !rst_n || !locks_ok;
    (* preserve *) reg [1:0] reference_pipe;
    (* preserve *) reg reference_release;
    always @(posedge clk_ref or posedge reference_async_reset) begin
        if(reference_async_reset) reference_pipe<=2'b11;
        else reference_pipe<={reference_pipe[0],1'b0};
    end
    always @(negedge clk_ref or posedge reference_async_reset) begin
        if(reference_async_reset) reference_release<=1'b1;
        else reference_release<=reference_pipe[1];
    end
    localparam integer COUNT_BITS = STABLE_CYCLES < 2 ? 1 : $clog2(STABLE_CYCLES);
    reg [COUNT_BITS-1:0] stable_count;
    reg stable;
    wire hold_reset = !rst_n || !locks_ok || !stable;
    // Keep the asynchronous-assert/synchronous-release boundary identifiable.
    // Never merge these stages into downstream functional reset logic.
    (* preserve *) reg [1:0] sd_pipe;
    (* preserve *) reg [1:0] mem_pipe;
    (* preserve *) reg [1:0] pixel_pipe;
    (* preserve *) reg [1:0] serial_pipe;
    // The two positive-edge stages absorb asynchronous release. A final
    // negative-edge register releases functional resets half a cycle away
    // from their positive capture edges, retaining recovery/removal checks.
    (* preserve *) reg sd_release,mem_release,pixel_release,serial_release;

    always @(posedge clk_ref or posedge reference_release) begin
        if (reference_release) begin
            stable_count <= 0;
            stable <= 1'b0;
        end else if (!stable) begin
            if (stable_count == STABLE_CYCLES - 1)
                stable <= 1'b1;
            else
                stable_count <= stable_count + 1'b1;
        end
    end

    always @(posedge clk_sd or posedge hold_reset) begin
        if (hold_reset) sd_pipe <= 2'b11;
        else sd_pipe <= {sd_pipe[0], 1'b0};
    end
    always @(posedge clk_mem or posedge hold_reset) begin
        if (hold_reset) mem_pipe <= 2'b11;
        else mem_pipe <= {mem_pipe[0], 1'b0};
    end
    always @(posedge clk_pixel or posedge hold_reset) begin
        if (hold_reset) pixel_pipe <= 2'b11;
        else pixel_pipe <= {pixel_pipe[0], 1'b0};
    end
    always @(posedge clk_serial or posedge hold_reset) begin
        if (hold_reset) serial_pipe <= 2'b11;
        else serial_pipe <= {serial_pipe[0], 1'b0};
    end
    always @(negedge clk_sd or posedge hold_reset) begin
        if(hold_reset) sd_release<=1'b1; else sd_release<=sd_pipe[1];
    end
    always @(negedge clk_mem or posedge hold_reset) begin
        if(hold_reset) mem_release<=1'b1; else mem_release<=mem_pipe[1];
    end
    always @(negedge clk_pixel or posedge hold_reset) begin
        if(hold_reset) pixel_release<=1'b1; else pixel_release<=pixel_pipe[1];
    end
    always @(negedge clk_serial or posedge hold_reset) begin
        if(hold_reset) serial_release<=1'b1; else serial_release<=serial_pipe[1];
    end
    assign rst_sd = sd_release;
    assign rst_mem = mem_release;
    assign rst_pixel = pixel_release;
    assign rst_serial = serial_release;
endmodule
