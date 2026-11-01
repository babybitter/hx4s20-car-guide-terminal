// Source coordinates in upright SDRAM images; no BMP vertical reversal here.
// mode 0 blend, 1 slide left, 2 slide up, 3 nearest-neighbour 2x source A.
module story_coordinates #(parameter HALF_ZOOM_ENABLE=0)(
    input wire [9:0] x, input wire [8:0] y,
    input wire [1:0] mode, input wire [8:0] alpha,
    input wire [9:0] shift,
    input wire [8:0] zoom_x, input wire [7:0] zoom_y,
    output reg valid,
    output reg [1:0] need, output reg [1:0] row_sources,
    output reg [9:0] x_a, x_b,
    output reg [8:0] y_a, y_b,
    input wire half_zoom
);
    reg [10:0] moved_x;
    reg [9:0] moved_y;
    always @* begin
        valid = (x < 640) && (y < 480) && (alpha <= 256);
        x_a=x; x_b=x; y_a=y; y_b=y;
        need=2'b11; row_sources=2'b11;
        moved_x={1'b0,x}+{1'b0,shift};
        moved_y={1'b0,y}+shift;
        case (mode)
            0: begin
                if (alpha==0) need=2'b01;
                else if (alpha==256) need=2'b10;
                row_sources=need;
            end
            1: begin
                valid=valid && (shift<=640);
                row_sources=(shift==0) ? 2'b01 : ((shift==640) ? 2'b10 : 2'b11);
                if (moved_x<640) begin need=2'b01; x_a=moved_x[9:0]; x_b=0; end
                else begin need=2'b10; x_a=0; x_b=moved_x-640; end
            end
            2: begin
                valid=valid && (shift<=480);
                if (moved_y<480) begin need=2'b01; y_a=moved_y[8:0]; y_b=0; end
                else begin need=2'b10; y_a=0; y_b=moved_y-480; end
                row_sources=need;
            end
            3: begin
                need=2'b01; row_sources=need;
                if(HALF_ZOOM_ENABLE && half_zoom)begin
                    valid=valid && x>=160 && x<480 && y>=72 && y<312;
                    x_a=(x-10'd160)<<1;y_a=(y-9'd72)<<1;
                end else begin
                    valid=valid && (zoom_x<=320) && (zoom_y<=240);
                    x_a={1'b0,zoom_x}+(x>>1); y_a={1'b0,zoom_y}+(y>>1);
                end
                x_b=0; y_b=0;
            end
        endcase
        if (!valid) begin need=0; row_sources=0; x_a=0; x_b=0; y_a=0; y_b=0; end
    end
endmodule
