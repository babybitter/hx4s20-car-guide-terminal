`timescale 1ns/1ps
// Isolated S21 state-RAM candidate. Numerical interface unchanged; TD mapping pending.
// clk=25MHz, sample_tick=48kHz, post-volume signed 24-bit mono PCM.
// 6:1 boxcar -> 8kHz; 128-point rectangular Goertzel window (16ms).
module audio_band_analyzer #(
    parameter [23:0] SILENCE_PEAK24 = 24'd32768
) (
    input wire clk,
    input wire rst,
    input wire sample_tick,
    input wire signed [23:0] pcm_postvolume,
    output reg [39:0] band_heights,
    output reg [2:0] dominant_band,
    output reg silence,
    output reg valid,
    output reg overflow_sticky,
    output reg overrun_sticky
);
    localparam [2:0] IDLE=0, REC_LOAD=1, REC_OPERANDS=2, REC_WAIT=3,
                     ENERGY=4, PUBLISH=5, REC_STORE=6, REC_WRITE=7;
    reg [2:0] state;
    reg [2:0] band_index;
    reg [3:0] energy_phase;
    reg [2:0] decim_count;
    reg signed [10:0] decim_sum;
    reg [6:0] frame_count;
    reg signed [7:0] sample_latched;
    reg last_sample;
    reg [23:0] frame_peak;
    reg window_silent;
    // Exactly one synchronous read and one write port; even=s1, odd=s2.
    // No reset/clear loop on storage or read register: preserve BRAM inference.
    (* ram_style = "bram" *) reg signed [17:0] state_mem [0:15];
    reg signed [17:0] state_read;
    // Invalid entries are logically zero after reset and after each window.
    reg [7:0] state_valid;
    // Recurrence result awaiting its write; reused as energy s1 afterwards.
    reg signed [17:0] work_state;
    reg signed [15:0] energy_b;
    wire [2:0] next_band = band_index + 3'd1;
    reg state_read_enable, state_write_enable;
    reg [3:0] state_read_address, state_write_address;
    reg signed [17:0] state_write_data;

    always @(*) begin
        state_read_enable=0; state_write_enable=0;
        state_read_address=0; state_write_address=0; state_write_data=0;
        if(!rst && !overrun_sticky) begin
            case(state)
                REC_LOAD: begin
                    state_read_enable=1; state_read_address={band_index,1'b0};
                end
                REC_OPERANDS: begin
                    state_read_enable=1; state_read_address={band_index,1'b1};
                end
                REC_STORE: begin
                    // Old s1 still resides in the shared multiplier operand.
                    state_write_enable=1; state_write_address={band_index,1'b1};
                    state_write_data=mul_a;
                    if(band_index!=7 || last_sample) begin
                        state_read_enable=1;
                        state_read_address={(band_index==7 ? 3'd0 : next_band),1'b0};
                    end
                end
                REC_WRITE: begin
                    state_write_enable=1; state_write_address={band_index,1'b0};
                    state_write_data=work_state;
                    if(band_index!=7 || last_sample) begin
                        state_read_enable=1;
                        state_read_address={(band_index==7 ? 3'd0 : next_band),1'b1};
                    end
                end
                ENERGY: if(band_index!=7) begin
                    // Current energy no longer needs s1 after phase9.
                    if(energy_phase==10 || energy_phase==11) begin
                        state_read_enable=1;
                        state_read_address={next_band,(energy_phase==11)};
                    end
                end
                default: begin end
            endcase
        end
    end
    always @(posedge clk) begin
        if(state_read_enable) state_read<=state_mem[state_read_address];
        if(state_write_enable) state_mem[state_write_address]<=state_write_data;
    end

    reg signed [17:0] mul_a, mul_b;
    reg signed [35:0] mul_product;
    // Shared registered multiplier for all recurrence and energy operations.
    always @(posedge clk) mul_product <= mul_a * mul_b;

    reg signed [17:0] coef_times_b;
    reg signed [37:0] energy_sum;
    reg [35:0] energy_hold;
    reg [35:0] maximum_energy;
    reg [2:0] winner;
    reg [39:0] heights_work;

    function signed [17:0] coefficient;
        input [2:0] index;
        begin
            case(index)
                0: coefficient=18'sd130441; // 125Hz, k=2
                1: coefficient=18'sd128553; // 250Hz, k=4
                2: coefficient=18'sd121095; // 500Hz, k=8
                3: coefficient=18'sd108982; // 750Hz, k=12
                4: coefficient=18'sd92682;  // 1000Hz, k=16
                5: coefficient=18'sd50159;  // 1500Hz, k=24
                6: coefficient=18'sd0;      // 2000Hz, k=32
                7: coefficient=-18'sd92682; // 3000Hz, k=48
            endcase
        end
    endfunction

    // Preserve the historical 11-bit abs/add-3, then discard magnitude[10].
    // For every unsigned n in 0..1023, floor(n/6) == (n*683)>>12.
    // Take the modulo-8-bit quotient before signed negation; no added clock edge.
    wire [10:0] average_magnitude = decim_total[10] ? -decim_total : decim_total;
    wire [10:0] average_rounded = average_magnitude + 11'd3;
    (* dsp_style = "yes" *) wire [19:0] average_product;
    assign average_product = average_rounded[9:0] * 10'd683;
    wire signed [7:0] average_six_result = decim_total[10] ?
        -$signed(average_product[19:12]) : $signed(average_product[19:12]);

    function [4:0] energy_height;
        input [35:0] energy;
        integer j;
        begin
            energy_height=0;
            for(j=6;j<=21;j=j+1)
                if(energy[j]) energy_height=((j-6)<<1) | energy[j-1];
            if(|energy[35:22]) energy_height=5'd31;
        end
    endfunction

    wire signed [7:0] pcm8 = pcm_postvolume[23:16];
    wire signed [10:0] decim_total=decim_sum+{{3{pcm8[7]}},pcm8};
    wire [23:0] pcm_abs=pcm_postvolume[23] ? (~pcm_postvolume+24'd1) : pcm_postvolume;
    wire [23:0] peak_with_sample=(pcm_abs>frame_peak) ? pcm_abs : frame_peak;
    wire signed [37:0] product_extended={{2{mul_product[35]}},mul_product};
    wire signed [17:0] recurrence_s2=state_valid[band_index] ? state_read : 18'sd0;
    wire signed [17:0] scaled_a=work_state >>> 2;
    wire signed [17:0] scaled_b={{2{energy_b[15]}},energy_b};

    // One full-precision signed 38-bit add/subtract datapath. REC_WAIT uses
    // an existing multiplier wait edge to form sample-s2 in energy_sum.
    // ENERGY overwrites that scratch value at phase2 before consuming it.
    reg [37:0] alu_left, alu_right;
    reg alu_subtract;
    always @(*) begin
        alu_left=energy_sum; alu_right=product_extended; alu_subtract=0;
        if(state==REC_WAIT) begin
            alu_left={{30{sample_latched[7]}},sample_latched};
            alu_right={{20{recurrence_s2[17]}},recurrence_s2};
            alu_subtract=1;
        end else if(state==REC_STORE) begin
            alu_left=product_extended >>> 16; alu_right=energy_sum;
        end else if(state==ENERGY) begin
            if(energy_phase==11) alu_subtract=1;
            else if(energy_phase==12) begin
                alu_left={2'b00,energy_hold}; alu_right={2'b00,maximum_energy};
                alu_subtract=1;
            end
        end
    end
    // The bottom bit supplies the two's-complement carry-in in the SAME
    // adder: floor((2*A+1 + 2*(B xor SUB)+SUB)/2) = A+(B xor SUB)+SUB.
    wire [38:0] alu_with_carry={alu_left,1'b1} +
        {(alu_right ^ {38{alu_subtract}}),alu_subtract};
    wire signed [37:0] alu_result=alu_with_carry[38:1];
    wire signed [37:0] recurrence_value=alu_result;
    wire recurrence_fits=(~|recurrence_value[37:17]) || (&recurrence_value[37:17]);
    wire signed [37:0] energy_difference=alu_result;
    // Both energies are unsigned36; signed38 subtraction cannot overflow.
    // Strictly positive keeps the original lower-index winner on ties.
    wire energy_greater=!alu_result[37] && (|alu_result);
    wire [5:0] height_bit={band_index,2'b00}+{3'b000,band_index};
    wire [4:0] old_height=band_heights[height_bit +: 5];
    wire [4:0] target_height=window_silent ? 5'd0 : energy_height(energy_hold);
    wire [4:0] decayed_height=(old_height>5'd2) ? old_height-5'd2 : 5'd0;
    wire [4:0] next_height=(target_height>decayed_height) ? target_height : decayed_height;

    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; band_index<=0; energy_phase<=0;
            decim_count<=0; decim_sum<=0; frame_count<=0;
            sample_latched<=0; last_sample<=0; frame_peak<=0; window_silent<=1;
            mul_a<=0; mul_b<=0; coef_times_b<=0; energy_sum<=0; energy_hold<=0;
            maximum_energy<=0; winner<=0; heights_work<=0;
            band_heights<=0; dominant_band<=0; silence<=1; valid<=0;
            overflow_sticky<=0; overrun_sticky<=0;
            state_valid<=0; work_state<=0; energy_b<=0;
        end else begin
            valid<=0;
            if(!overrun_sticky) begin
                case(state)
                    IDLE: begin end
                    REC_LOAD: state<=REC_OPERANDS;
                    REC_OPERANDS: begin
                        mul_a<=state_valid[band_index] ? state_read : 18'sd0;
                        mul_b<=coefficient(band_index);
                        state<=REC_WAIT;
                    end
                    REC_WAIT: begin
                        energy_sum<=alu_result; state<=REC_STORE;
                    end
                    REC_STORE: begin
                        // Same 38-bit recurrence/saturation as the reference.
                        // This edge writes old s1 to s2 and prefetches next s1.
                        if(recurrence_fits) work_state<=recurrence_value[17:0];
                        else begin
                            work_state<=recurrence_value[37] ? -18'sd131072 : 18'sd131071;
                            overflow_sticky<=1;
                        end
                        state<=REC_WRITE;
                    end
                    REC_WRITE: begin
                        // Commit s1 while fetching next s2. No read/write
                        // address collision and no vendor forwarding assumption.
                        state_valid[band_index]<=1;
                        if(band_index==7) begin
                            band_index<=0;
                            if(last_sample) begin
                                work_state<=state_read;
                                state<=ENERGY; energy_phase<=0;
                                maximum_energy<=0; winner<=0;
                            end else state<=IDLE;
                        end else begin
                            mul_a<=state_valid[next_band] ? state_read : 18'sd0;
                            mul_b<=coefficient(next_band);
                            band_index<=next_band; state<=REC_WAIT;
                        end
                    end
                    ENERGY: begin
                        energy_phase<=energy_phase+1'b1;
                        case(energy_phase)
                            0: begin
                                mul_a<=scaled_a; mul_b<=scaled_a;
                                energy_b<=state_read[17:2];
                            end
                            1: begin end
                            2: energy_sum<=product_extended;
                            3: begin mul_a<=scaled_b; mul_b<=scaled_b; end
                            4: begin end
                            5: energy_sum<=alu_result;
                            6: begin mul_a<=coefficient(band_index); mul_b<=scaled_b; end
                            7: begin end
                            8: coef_times_b<=mul_product >>> 16;
                            9: begin mul_a<=scaled_a; mul_b<=coef_times_b; end
                            10: begin end
                            11: begin
                                energy_hold<=energy_difference[37] ? 36'd0 : energy_difference[35:0];
                                if(band_index!=7) work_state<=state_read;
                            end
                            12: begin
                                heights_work[height_bit +: 5]<=next_height;
                                if(energy_greater) begin
                                    maximum_energy<=energy_hold; winner<=band_index;
                                end
                                state_valid[band_index]<=0;
                                energy_phase<=0;
                                if(band_index==7) state<=PUBLISH;
                                else band_index<=band_index+1'b1;
                            end
                            default: begin state<=IDLE; overrun_sticky<=1; end
                        endcase
                    end
                    PUBLISH: begin
                        band_heights<=heights_work;
                        dominant_band<=window_silent ? 3'd0 : winner;
                        silence<=window_silent; valid<=1; state<=IDLE;
                    end
                    default: begin state<=IDLE; overrun_sticky<=1; end
                endcase
                if(sample_tick) begin
                    frame_peak<=peak_with_sample;
                    if(decim_count==5) begin
                        decim_count<=0; decim_sum<=0;
                        if(state==IDLE) begin
                            sample_latched<=average_six_result;
                            last_sample<=(frame_count==127);
                            frame_count<=frame_count+1'b1;
                            band_index<=0; state<=REC_LOAD;
                            if(frame_count==127) begin
                                window_silent<=(peak_with_sample<=SILENCE_PEAK24);
                                frame_peak<=0;
                            end
                        end else begin
                            // Fail closed: timing violation needs reset, no misleading future valid.
                            overrun_sticky<=1; valid<=0;
                        end
                    end else begin
                        decim_count<=decim_count+1'b1; decim_sum<=decim_total;
                    end
                end
            end
        end
    end
endmodule
