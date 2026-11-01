module page_audio_cue #(
    parameter integer PIXEL_HZ = 25000000,
    parameter integer SAMPLE_HZ = 48000,
    parameter integer CUE_SAMPLES = 9600,
    parameter integer FADE_SAMPLES = 240
) (
    input wire clk,
    input wire rst,
    input wire page_commit,
    input wire [1:0] page_id,
    input wire prompt_open_event,
    input wire test_tone_enable,
    output reg audio_valid,
    output reg [23:0] audio_left,
    output reg [23:0] audio_right,
    output wire cue_busy
);
    localparam [2:0] IDLE = 3'd0, PAGE = 3'd1,
                     PROMPT_FIRST = 3'd2, PROMPT_GAP = 3'd3,
                     PROMPT_SECOND = 3'd4, FADE_OUT = 3'd5;
    localparam integer PROMPT_SAMPLES = SAMPLE_HZ / 10;
    reg [24:0] sample_acc;
    reg [31:0] phase;
    reg [31:0] phase_step;
    reg [13:0] cue_index;
    reg [7:0] envelope;
    reg [2:0] cue_state;
    reg pending_prompt;
    reg pending_page;
    reg [1:0] pending_page_id;
    wire [11:0] triangle_u = phase[31] ? ~phase[30:19] : phase[30:19];
    wire signed [12:0] triangle_s = $signed({1'b0, triangle_u}) - 13'sd2048;
    wire signed [21:0] product = triangle_s * $signed({1'b0, envelope});
    wire [23:0] pcm = {{2{product[21]}}, product};
    wire sample_tick = sample_acc >= PIXEL_HZ - SAMPLE_HZ;
    wire prompt_requested = pending_prompt || prompt_open_event;
    wire page_requested = pending_page || page_commit;
    assign cue_busy = cue_state != IDLE;

    function [31:0] tone_step;
        input [1:0] id;
        begin
            case (id)
                2'd0: tone_step = 32'd39370534; // 440 Hz
                2'd1: tone_step = 32'd49571081; // 554 Hz
                2'd2: tone_step = 32'd58966322; // 659 Hz
                default: tone_step = 32'd78741067; // 880 Hz
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sample_acc <= 25'd0;
            phase <= 32'd0;
            phase_step <= tone_step(2'd0);
            cue_index <= 14'd0;
            envelope <= 8'd0;
            cue_state <= IDLE;
            pending_prompt <= 1'b0;
            pending_page <= 1'b0;
            pending_page_id <= 2'd0;
            audio_valid <= 1'b0;
            audio_left <= 24'd0;
            audio_right <= 24'd0;
        end else begin
            if (page_commit && !prompt_requested) begin
                pending_page <= 1'b1;
                pending_page_id <= page_id;
            end
            if (prompt_open_event) begin
                pending_prompt <= 1'b1;
                pending_page <= 1'b0;
            end
            audio_valid <= sample_tick;
            if (sample_tick)
                sample_acc <= sample_acc + SAMPLE_HZ - PIXEL_HZ;
            else
                sample_acc <= sample_acc + SAMPLE_HZ;

            if (sample_tick) begin
                phase <= phase + phase_step;
                audio_left <= ((cue_state == PAGE ||
                                cue_state == PROMPT_FIRST ||
                                cue_state == PROMPT_SECOND ||
                                cue_state == FADE_OUT) ||
                               (cue_state == IDLE && test_tone_enable)) ?
                              pcm : 24'd0;
                audio_right <= ((cue_state == PAGE ||
                                 cue_state == PROMPT_FIRST ||
                                 cue_state == PROMPT_SECOND ||
                                 cue_state == FADE_OUT) ||
                                (cue_state == IDLE && test_tone_enable)) ?
                               pcm : 24'd0;
                case (cue_state)
                    IDLE: begin
                        envelope <= test_tone_enable ? 8'd96 : 8'd0;
                        if (prompt_requested) begin
                            cue_state <= PROMPT_FIRST;
                            phase <= 32'd0;
                            phase_step <= 32'd89478485; // 1000 Hz
                            cue_index <= 14'd0;
                            pending_prompt <= 1'b0;
                            pending_page <= 1'b0;
                        end else if (page_requested) begin
                            cue_state <= PAGE;
                            phase <= 32'd0;
                            phase_step <= tone_step(
                                page_commit ? page_id : pending_page_id
                            );
                            cue_index <= 14'd0;
                            pending_page <= 1'b0;
                        end
                    end
                    PAGE: begin
                        if (prompt_requested || page_requested) begin
                            cue_state <= FADE_OUT;
                        end else if (cue_index == CUE_SAMPLES - 1) begin
                            cue_state <= IDLE;
                            envelope <= 8'd0;
                        end else begin
                            cue_index <= cue_index + 1'b1;
                            if (cue_index < FADE_SAMPLES)
                                envelope <= cue_index[7:0];
                            else if (cue_index >= CUE_SAMPLES - FADE_SAMPLES)
                                envelope <= CUE_SAMPLES - cue_index - 1'b1;
                            else
                                envelope <= 8'd240;
                        end
                    end
                    PROMPT_FIRST, PROMPT_SECOND: begin
                        if (prompt_requested) begin
                            cue_state <= FADE_OUT;
                        end else if (cue_index == PROMPT_SAMPLES - 1) begin
                            cue_index <= 14'd0;
                            envelope <= 8'd0;
                            cue_state <= cue_state == PROMPT_FIRST ?
                                         PROMPT_GAP : IDLE;
                        end else begin
                            cue_index <= cue_index + 1'b1;
                            if (cue_index < FADE_SAMPLES)
                                envelope <= cue_index[7:0];
                            else if (cue_index >= PROMPT_SAMPLES - FADE_SAMPLES)
                                envelope <= PROMPT_SAMPLES - cue_index - 1'b1;
                            else
                                envelope <= 8'd240;
                        end
                    end
                    PROMPT_GAP: begin
                        envelope <= 8'd0;
                        if (prompt_requested) begin
                            cue_state <= PROMPT_FIRST;
                            cue_index <= 14'd0;
                            phase <= 32'd0;
                            pending_prompt <= 1'b0;
                            pending_page <= 1'b0;
                        end else if (cue_index == PROMPT_SAMPLES - 1) begin
                            cue_state <= PROMPT_SECOND;
                            cue_index <= 14'd0;
                            phase <= 32'd0;
                        end else begin
                            cue_index <= cue_index + 1'b1;
                        end
                    end
                    FADE_OUT: begin
                        if (envelope == 8'd0) begin
                            cue_state <= IDLE;
                        end else begin
                            envelope <= envelope - 1'b1;
                        end
                    end
                    default: cue_state <= IDLE;
                endcase
            end
        end
    end
endmodule
