`timescale 1ns/1ps
`default_nettype none
// Known ORIGINAL BGM ID31 metadata, NOT real-time pitch recognition.
// position_samples is the native 16kHz source index; audio_valid is 48kHz.
// Connect music_active only for actual ID31 playback. All inputs clk-synchronous.
module audio_color_theme (
    input wire clk, rst, audio_valid, music_active,
    input wire [20:0] position_samples,
    input wire [2:0] dominant,
    input wire silence,
    output wire [23:0] left_wave_color, right_wave_color,
    output wire note_active,
    output wire [6:0] midi_note
);
    `include "audio_palette.vh"
    // Four 16-bit words/event; ONE synchronous read port, never 32-bit wide.
    // [0] start low; [1] {midi[6:0],pitch_class[3:0],start[20:16]};
    // [2] end-exclusive low; [3] {11'b0,end-exclusive[20:16]}.
    // Block-ROM intent only: actual TD mapping/BRAM count is not verified here.
    (* ram_style = "block" *) reg [15:0] score_rom [0:63];
    initial begin
        `include "bgm_score_words.vh"
    end
    localparam [2:0] IDLE=0, READ=1, USE=2, START_TEST=3, END_TEST=4, COMMIT=5;
    reg [2:0] state;
    reg [5:0] address;
    reg [15:0] rom_q, low_word;
    reg [20:0] target, boundary, resolved_position;
    reg start_ok, candidate_active, resolved_active, have_result;
    reg [6:0] current_note, candidate_note, resolved_note;
    reg [3:0] current_pc, candidate_pc, resolved_pc;
    // One time-shared 21-bit magnitude comparator for both event bounds.
    wire at_or_after = target >= boundary;
    always @(posedge clk) if (state==READ) rom_q<=score_rom[address];

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE; address<=0; low_word<=0; target<=0; boundary<=0;
            resolved_position<=0; start_ok<=0; candidate_active<=0;
            resolved_active<=0; have_result<=0; current_note<=0; candidate_note<=0;
            resolved_note<=0; current_pc<=0; candidate_pc<=0; resolved_pc<=0;
        end else if(!music_active) begin
            state<=IDLE; resolved_active<=0; have_result<=0; candidate_active<=0;
        end else if((state!=IDLE && position_samples!=target) ||
                    (state==IDLE && (audio_valid || !have_result || position_samples!=resolved_position))) begin
            // New position, resume or wrap restarts from event zero. Never commit
            // a stale in-flight lookup. A stable new request completes in 161 clocks.
            target<=position_samples; address<=0; candidate_active<=0;
            candidate_note<=0; candidate_pc<=0; start_ok<=0; state<=READ;
        end else begin
            case(state)
                IDLE: begin end
                READ: state<=USE;
                USE: case(address[1:0])
                    0,2: begin low_word<=rom_q; address<=address+1'b1; state<=READ; end
                    1: begin
                        boundary<={rom_q[4:0],low_word};
                        current_note<=rom_q[15:9]; current_pc<=rom_q[8:5]; state<=START_TEST;
                    end
                    3: begin boundary<={rom_q[4:0],low_word}; state<=END_TEST; end
                endcase
                START_TEST: begin start_ok<=at_or_after; address<=address+1'b1; state<=READ; end
                END_TEST: begin
                    // Ascending starts: the final matching event is the latest.
                    if(start_ok && !at_or_after) begin
                        candidate_active<=1; candidate_note<=current_note; candidate_pc<=current_pc;
                    end
                    if(address==63) state<=COMMIT;
                    else begin address<=address+1'b1; state<=READ; end
                end
                COMMIT: begin
                    resolved_active<=candidate_active; resolved_note<=candidate_note;
                    resolved_pc<=candidate_pc; resolved_position<=target; have_result<=1; state<=IDLE;
                end
                default: begin state<=IDLE; have_result<=0; resolved_active<=0; end
            endcase
        end
    end
    // Hold the previous completed label during a bounded rescan. No wall-time
    // counter advances the score. Stop/music-off and post-volume silence win.
    assign note_active=!rst && music_active && !silence && resolved_active;
    assign midi_note=note_active ? resolved_note : 7'd0;
    assign left_wave_color=(rst || silence) ? 24'h73969c :
                           note_active ? note_color(resolved_pc) : band_color(dominant);
    function [7:0] light_channel;
        input [7:0] c;
        reg [9:0] total;
        begin total={1'b0,c,1'b0}+{2'b0,c}+10'd255; light_channel=total[9:2]; end
    endfunction
    assign right_wave_color=(rst || silence) ? 24'h73969c :
        {light_channel(left_wave_color[23:16]),light_channel(left_wave_color[15:8]),light_channel(left_wave_color[7:0])};
endmodule
`default_nettype wire
