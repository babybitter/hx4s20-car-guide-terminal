// Shared constant palette, no storage array. Include inside each consumer.
// Natural notes C/D/E/F/G/A/B remain distinct; all five semitones retained.
function [23:0] note_color;
    input [3:0] pitch_class;
    begin
        case(pitch_class)
            0:note_color=24'h4fd9d0; 1:note_color=24'h51bfea;
            2:note_color=24'h7098f4; 3:note_color=24'h9b8bea;
            4:note_color=24'hc08be6; 5:note_color=24'he68eb5;
            6:note_color=24'hf39a8a; 7:note_color=24'hf2b76e;
            8:note_color=24'heacc68; 9:note_color=24'hd4da75;
            10:note_color=24'ha5d984; 11:note_color=24'h73d2a6;
            default:note_color=24'h73969c;
        endcase
    end
endfunction
function [23:0] band_color;
    input [2:0] band;
    begin
        case(band)
            0:band_color=24'h7098f4; // 125 Hz: cool blue
            1:band_color=24'h51bfea; // 250 Hz
            2:band_color=24'h4fd9d0; // 500 Hz
            3:band_color=24'h73d2a6; // 750 Hz
            4:band_color=24'hd4da75; // 1000 Hz
            5:band_color=24'heacc68; // 1500 Hz
            6:band_color=24'hf2b76e; // 2000 Hz
            7:band_color=24'hf39a8a; // 3000 Hz: warm coral
        endcase
    end
endfunction
