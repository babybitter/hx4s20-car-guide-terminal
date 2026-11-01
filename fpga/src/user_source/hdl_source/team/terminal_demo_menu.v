`timescale 1ns/1ps
`default_nettype none
// All inputs are synchronous to pixelclk. Keys are debounced, one-cycle events.
// cmd_valid is a combinational acceptance strobe AT the blank_tick edge, not
// a register delayed beyond blank_tick. The consumer must sample that edge.
module terminal_demo_menu (
    input wire pixelclk, rst, blank_tick,
    input wire menu_mode, key_next, key_prompt, key_auto, serial_busy,
    input wire [2:0] applied_filter,
    input wire [1:0] applied_t, applied_x, applied_z, applied_l, applied_r,
    input wire applied_g, applied_e,
    input wire [2:0] applied_y,
    output wire cmd_valid,
    output reg [7:0] cmd, value,
    output reg [3:0] selection,
    output reg [2:0] edit_value
);
    reg menu_d, pending;
    wire [3:0] next_selection = selection == 4'd8 ? 4'd0 : selection + 1'b1;

    function [2:0] maximum;
        input [3:0] item;
        begin
            case (item)
                0: maximum=5;
                3: maximum=2;
                6,7: maximum=1;
                8: maximum=4;
                default: maximum=3;
            endcase
        end
    endfunction

    function [7:0] command_for;
        input [3:0] item;
        begin
            case (item)
                0: command_for="F"; 1: command_for="T"; 2: command_for="X";
                3: command_for="Z"; 4: command_for="L"; 5: command_for="R";
                6: command_for="G"; 7: command_for="E"; 8: command_for="Y";
                default: command_for="F";
            endcase
        end
    endfunction

    reg [2:0] live_value;
    wire [3:0] load_selection = !menu_d ? 4'd0 : next_selection;
    always @* begin
        case (load_selection)
            0: live_value=applied_filter;
            1: live_value={1'b0,applied_t};
            2: live_value={1'b0,applied_x};
            3: live_value={1'b0,applied_z};
            4: live_value={1'b0,applied_l};
            5: live_value={1'b0,applied_r};
            6: live_value={2'b0,applied_g};
            7: live_value={2'b0,applied_e};
            8: live_value=applied_y;
            default: live_value=0;
        endcase
        if (live_value > maximum(load_selection)) live_value=0;
    end

    // serial_busy must include a same-edge serial command and any outstanding
    // serial reservation; no UART output/state is driven by this module.
    assign cmd_valid = !rst && menu_mode && pending && blank_tick && !serial_busy;
    always @(posedge pixelclk or posedge rst) begin
        if (rst) begin
            menu_d<=0; pending<=0; selection<=0; edit_value<=0; cmd<=0; value<=0;
        end else begin
            menu_d<=menu_mode;
            if (!menu_mode) begin
                pending<=0;
            end else if (!menu_d) begin
                selection<=0; edit_value<=live_value; pending<=0;
            end else begin
                if (cmd_valid) pending<=0;
                // Navigation wins over edit, which wins over apply.
                if (key_next) begin
                    selection<=next_selection; edit_value<=live_value;
                end else if (key_prompt) begin
                    edit_value<=edit_value>=maximum(selection) ? 3'd0 : edit_value+1'b1;
                end else if (key_auto && !pending) begin
                    // One entry, first apply wins. Edits/navigation cannot
                    // mutate this snapshot; apply while full is ignored.
                    pending<=1; cmd<=command_for(selection); value<={5'd0,edit_value};
                end
            end
        end
    end
endmodule
`default_nettype wire
