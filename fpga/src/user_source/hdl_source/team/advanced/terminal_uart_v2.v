// S19 isolated streaming-decode resource candidate; S18 external interface unchanged.
// Atomic line-command frontend. All ports belong to the pixel clock domain.
// ACK means the command pulse was emitted, not downstream completion.
module terminal_uart_v2 #(
    parameter integer CLK_HZ = 25000000,
    parameter integer BAUD = 115200,
    parameter integer AUDIO_STATUS_ENABLE = 0,
    parameter integer HALF_ZOOM_ENABLE = 0
)(
    input wire clk, input wire rst,
    input wire uart_rx, output wire uart_tx,
    input wire [6:0] status_page,
    input wire [7:0] status_count,
    input wire status_auto, input wire status_ready,
    input wire [3:0] status_error,
    input wire [1:0] status_period,
    output reg cmd_valid,
    output reg [7:0] cmd, output reg [7:0] value,
    output reg [319:0] text_data,
    output reg [5:0] text_length,
    input wire [31:0] status_config,
    input wire [15:0] event_seq,
    input wire [31:0] sd_init_ms, dir_ms, preload_ms, firstframe_ms, cache_ms,
    input wire [31:0] sequence_status,
    output reg seq_begin, seq_write, seq_commit,
    output reg [3:0] seq_index,
    output reg [39:0] seq_word,
    output reg [4:0] seq_count,
    input wire [79:0] sub_status,
    output reg sub_begin, sub_write, sub_commit, sub_abort,
    output reg [15:0] sub_tag, sub_crc,
    output reg [5:0] sub_len0, sub_len1,
    output reg [6:0] sub_index,
    output reg [127:0] sub_chunk,
    input wire [79:0] audio_status
);
    localparam integer IDLE_LIMIT = CLK_HZ / 10; // 100 ms inter-byte limit
    localparam [3:0] ACK=0, STATUS=1, SYNTAX=2, RANGE=3,
                     LENGTH=4, FRAME=5, TIMEOUT=6, BUSY=7, HARDWARE=8, SUBSTATUS=9, AUDIOSTATUS=10;
    wire rx_valid, rx_error, tx_busy;
    wire [7:0] rx_byte;
    reg tx_start;
    reg [7:0] tx_byte;
    uart_rx_8n1 #(.CLK_FREQ_HZ(CLK_HZ), .BAUD_RATE(BAUD)) rx_phy
        (.clk(clk), .rst(rst), .rx(uart_rx), .data_valid(rx_valid),
         .data(rx_byte), .frame_error(rx_error));
    uart_tx_8n1 #(.CLK_FREQ_HZ(CLK_HZ), .BAUD_RATE(BAUD)) tx_phy
        (.clk(clk), .rst(rst), .start(tx_start), .data(tx_byte),
         .tx(uart_tx), .busy(tx_busy));


    // Decode accepted bytes incrementally. There is no EOL parser busy window:
    // admission, status snapshots and output pulses stay on the S18 EOL edge.
    // Queue publication is delayed 30 clocks; accepted pulses remain at EOL.
    reg [6:0] command_head, command_sub;
    reg [5:0] used;
    reg poisoned, quarantine;
    reg [3:0] poison_kind;
        // S34: preserve 32-bit behavior for exceptional effective integer limits.
    // inclusive=1 includes the increment on the timeout/exit edge (count=L).
    // No limit+1 arithmetic: INT_MAX must not overflow during width selection.
    function integer bounded_timeout_width;
        input integer limit;
        input integer inclusive;
        integer remaining;
        begin
            bounded_timeout_width=32;
            if(limit>1) begin
                bounded_timeout_width=0;
                for(remaining=inclusive ? limit : limit-1;
                    remaining>0;remaining=remaining>>1)
                    bounded_timeout_width=bounded_timeout_width+1;
            end
        end
    endfunction
reg [bounded_timeout_width(IDLE_LIMIT,1)-1:0] idle_ticks;
    wire eol = rx_valid && ((rx_byte == 13) || (rx_byte == 10));
    wire expired = !rx_valid && !rx_error && !quarantine &&
                   ((used != 0) || poisoned) && (idle_ticks == IDLE_LIMIT-1);
    wire event_valid = expired || (eol && !quarantine && ((used != 0) || poisoned));
    wire accept_printable = rx_valid && !eol && !quarantine && !poisoned &&
                            used < 42 && rx_byte >= 32 && rx_byte <= 126;
    function upper_hex;
        input [7:0] c;
        begin
            upper_hex=((c[7:4]==4'h3) && (c[3:0]<=4'd9)) ||
                ((c[7:4]==4'h4) && (c[3:0]!=0) && (c[3:0]<=4'd6));
        end
    endfunction
    function [3:0] unhex;
        input [7:0] c;
        begin unhex=(c[7:4]==4'h3) ? c[3:0] : c[3:0]+4'd9; end
    endfunction
    wire rx_decimal = rx_byte >= "0" && rx_byte <= "9";
    reg [9:0] decimal_value;
    reg decimal_ok, hex_ok;
    // OD is the longest hexadecimal payload: 2 index + 32 data nibbles.
    // J/OB/OC use constant slices of the same receive accumulator.
    reg [135:0] hex_payload;
    wire [9:0] decimal_times_ten = (decimal_value << 3) + (decimal_value << 1);
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            command_head<=0; command_sub<=0;
            decimal_value<=0; decimal_ok<=1; hex_ok<=1; hex_payload<=0;
        end else if(accept_printable) begin
            if(used==0) begin
                command_head<=rx_byte[6:0]; command_sub<=0;
                decimal_value<=0; decimal_ok<=1; hex_ok<=1; hex_payload<=0;
            end else begin
                if(used==1) command_sub<=rx_byte[6:0];
                if(command_head=="I" || command_head=="K") begin
                    decimal_value<=decimal_times_ten+{6'd0,rx_byte[3:0]};
                    decimal_ok<=decimal_ok && rx_decimal;
                end
                if(command_head=="J" || (command_head=="O" && used>=2)) begin
                    hex_payload<={hex_payload[131:0],unhex(rx_byte)};
                    hex_ok<=hex_ok && upper_hex(rx_byte);
                end
            end
        end
    end

    // S pending storage is private and zero-padded at the first accepted byte.
    // Constant lane enables avoid a variable bit-shift/alignment network.
    // Public text_data is NEVER a receive buffer: it only changes on an
    // admitted, complete S line, preserving terminal_controls HELD_TEXT_INPUT.
    wire [319:0] decoded_text;
    reg [279:0] text_pending;
    integer text_write_lane;
    always @(posedge clk) begin
        if(!rst && accept_printable) begin
            if(used==0) text_pending<=0;
            else if(command_head=="S" && command_sub==":") begin
                for(text_write_lane=0;text_write_lane<40;text_write_lane=text_write_lane+1)
                    if(used==text_write_lane+2)
                        text_pending[text_write_lane*7 +: 7]<=rx_byte[6:0];
            end
        end
    end
    genvar text_lane;
    generate for(text_lane=0;text_lane<40;text_lane=text_lane+1) begin: pending_s
        assign decoded_text[text_lane*8 +: 8]={1'b0,text_pending[text_lane*7 +: 7]};
    end endgenerate

    reg [3:0] event_kind;
    reg [7:0] decoded_value;
    wire [7:0] decoded_seq_index=hex_payload[47:40];
    wire [39:0] decoded_seq_word=hex_payload[39:0];
    wire [7:0] decoded_seq_count=decimal_value[7:0];
    wire [15:0] decoded_sub_tag=(command_sub=="B") ? hex_payload[47:32] : hex_payload[15:0];
    wire [15:0] decoded_sub_crc=hex_payload[15:0];
    wire [7:0] decoded_sub_len0=hex_payload[31:24], decoded_sub_len1=hex_payload[23:16];
    wire [7:0] decoded_sub_index=hex_payload[135:128];
    wire [127:0] decoded_sub_chunk=hex_payload[127:0];
    always @* begin
        event_kind=SYNTAX;
        decoded_value=0;
        if(expired) event_kind=TIMEOUT;
        else if(poisoned) event_kind=poison_kind;
        // AQ is a distinct two-byte command; plain A remains unchanged.
        else if(AUDIO_STATUS_ENABLE && used==2 && command_head=="A" && command_sub=="Q")
            event_kind=AUDIOSTATUS;
        else if(used==1) begin
            case(command_head)
                "N","A","M","P","U": event_kind=ACK;
                "Q": event_kind=STATUS;
                "H": event_kind=HARDWARE;
                default: event_kind=SYNTAX;
            endcase
        end else if(command_head=="O" && used>=2) begin
            if(used==2 && command_sub=="Q") event_kind=SUBSTATUS;
            else if(used==2 && command_sub=="X") event_kind=ACK;
            else if(used==14 && command_sub=="B") begin
                if(!hex_ok) event_kind=SYNTAX;
                else if(({1'b0,decoded_sub_len0}+{1'b0,decoded_sub_len1})>9'd40) event_kind=RANGE;
                else event_kind=ACK;
            end else if(used==36 && command_sub=="D") begin
                if(!hex_ok) event_kind=SYNTAX;
                else if(decoded_sub_index>=80) event_kind=RANGE;
                else event_kind=ACK;
            end else if(used==6 && command_sub=="C") event_kind=hex_ok ? ACK : SYNTAX;
        end else if(used>=2 && command_head=="S" && command_sub==":") event_kind=ACK;
        else if(used==4 && command_head=="I" && decimal_ok) begin
            // Count is deliberately read at EOL, not at the first digit.
            if(decimal_value>=1 && decimal_value<=128 && decimal_value<=status_count) begin
                event_kind=ACK; decoded_value=decimal_value-1'b1;
            end else event_kind=RANGE;
        end else if(used==13 && command_head=="J") begin
            if(!hex_ok) event_kind=SYNTAX;
            else if(decoded_seq_index<=15 &&
                {1'b0,decoded_seq_word[6:0]}<status_count &&
                {1'b0,decoded_seq_word[13:7]}<8'd128 &&
                decoded_seq_word[29:14]>=16'd1000 && decoded_seq_word[29:14]<=16'd60000 &&
                decoded_seq_word[35:33]<=3'd4 && decoded_seq_word[39:37]==0) event_kind=ACK;
            else event_kind=RANGE;
        end else if(used==3 && command_head=="K" && decimal_ok)
            event_kind=(decoded_seq_count>=1 && decoded_seq_count<=16) ? ACK : RANGE;
        else if(used==2 && command_sub>="0" && command_sub<="9") begin
            decoded_value={4'd0,command_sub[3:0]};
            case(command_head)
                "B","C","T","R","X": event_kind=decoded_value<=3 ? ACK : RANGE;
                "L": if(AUDIO_STATUS_ENABLE) event_kind=decoded_value<=3 ? ACK : RANGE;
                "F": event_kind=decoded_value<=5 ? ACK : RANGE;
                "V","Y": event_kind=decoded_value<=4 ? ACK : RANGE;
                "Z": event_kind=decoded_value<=(HALF_ZOOM_ENABLE ? 8'd2 : 8'd1) ? ACK : RANGE;
                "W","E","D","G": event_kind=decoded_value<=1 ? ACK : RANGE;
                default: event_kind=SYNTAX;
            endcase
        end
    end

    // Eight waiting replies PLUS one active reply: nine 30-byte entries.
    // Exactly one 512x8 synchronous 1R/1W RAM, still fits one 9K BRAM.
    // EOL captures an EXTRA 240-bit snapshot, then serializes MSB first.
    // Active payload stays in RAM for the whole reply: one byte is prefetched
    // for each pair of HEX digits. This REMOVES the old 240-bit h_shift FFs.
    // The ninth physical slot replaces that active snapshot, not queue depth.
    // No memory reset; neither uncommitted nor stale RAM contents are visible.
    reg [3:0] kinds [0:8];
    (* ram_style = "block" *) reg [7:0] payloads [0:511];
    reg [239:0] write_snapshot;
    reg [4:0] write_index, read_index;
    reg write_busy, read_pending, low_nibble;
    reg [1:0] read_remaining;
    wire read_busy = (read_remaining != 0);
    reg [3:0] read_slot;
    reg [7:0] payload_read_byte;
    reg [3:0] wr_ptr, rd_ptr;
    reg [3:0] queued;
    reg busy_pending;
    reg [3:0] active_kind;
    reg [7:0] active_payload;
    reg [23:0] q_page, q_count;
    reg [6:0] remaining, char_index;
    reg active, byte_pending, byte_seen_busy;
    // queued + writer <= 8; active retains a separate ninth physical slot.
    // Modulo-nine pointers cannot lap the active slot at this admission bound.
    wire [4:0] occupied = {1'b0,queued}+{4'd0,write_busy};
    wire enqueue = event_valid && !busy_pending && !write_busy && (occupied < 8);
    wire publish = write_busy && (write_index == 29);
    wire dequeue = !active && (queued != 0);

    always @(posedge clk) begin
        if(!rst && write_busy)
            payloads[{wr_ptr,write_index}] <= write_snapshot[239:232];
        if(read_busy)
            payload_read_byte <= payloads[{read_slot,read_index}];
        if(enqueue) begin
            case(event_kind)
                SUBSTATUS: write_snapshot <= {sub_status,160'd0};
                AUDIOSTATUS: write_snapshot <= {audio_status,160'd0};
                HARDWARE: write_snapshot <= {status_config,event_seq,sd_init_ms,dir_ms,
                    preload_ms,firstframe_ms,cache_ms,sequence_status};
                STATUS: write_snapshot <= {217'd0,status_page,status_count,status_auto,
                    status_ready,status_error,status_period};
                default: write_snapshot <= {232'd0,1'b0,command_head};
            endcase
        end else if(write_busy)
            write_snapshot <= {write_snapshot[231:0],8'd0};
    end

    function [23:0] decimal3;
        input [8:0] n;
        reg [7:0] hundreds, tens, ones, remainder;
        begin
            // Q only supplies page 1..128 or count 0..255. Bounded decimal
            // conversion avoids the wide divide/multiply networks of n/100.
            if(n>=9'd200) begin hundreds="2";remainder=n-9'd200;end
            else if(n>=9'd100) begin hundreds="1";remainder=n-9'd100;end
            else begin hundreds="0";remainder=n[7:0];end
            if(remainder>=90) begin tens="9";ones=remainder-8'd90+8'd48;end
            else if(remainder>=80) begin tens="8";ones=remainder-8'd80+8'd48;end
            else if(remainder>=70) begin tens="7";ones=remainder-8'd70+8'd48;end
            else if(remainder>=60) begin tens="6";ones=remainder-8'd60+8'd48;end
            else if(remainder>=50) begin tens="5";ones=remainder-8'd50+8'd48;end
            else if(remainder>=40) begin tens="4";ones=remainder-8'd40+8'd48;end
            else if(remainder>=30) begin tens="3";ones=remainder-8'd30+8'd48;end
            else if(remainder>=20) begin tens="2";ones=remainder-8'd20+8'd48;end
            else if(remainder>=10) begin tens="1";ones=remainder-8'd10+8'd48;end
            else begin tens="0";ones=remainder+8'd48;end
            decimal3 = {hundreds, tens, ones};
        end
    endfunction
    function [7:0] hexchar;
        input [3:0] n;
        begin hexchar = n < 10 ? 48+n : 55+n; end
    endfunction
    // Q retains the v1 wire format/version and appends HXZDGUJKOY to CAP.
    // H is exactly 96 bytes including CRLF. One shared nibble encoder is used.
    function h_digit;
        input [6:0] n;
        begin
            h_digit=((n>=6)&&(n<=13)) || ((n>=18)&&(n<=21)) ||
                ((n>=26)&&(n<=33)) || ((n>=38)&&(n<=45)) ||
                ((n>=50)&&(n<=57)) || ((n>=62)&&(n<=69)) ||
                ((n>=74)&&(n<=81)) || ((n>=86)&&(n<=93));
        end
    endfunction
    function [6:0] reply_length;
        input [3:0] kind;
        begin
            case(kind)
                ACK: reply_length=7;
                STATUS: reply_length=73;
                SUBSTATUS: reply_length=27;
                AUDIOSTATUS: reply_length=24;
                HARDWARE: reply_length=96;
                RANGE,FRAME: reply_length=11;
                LENGTH,SYNTAX: reply_length=12;
                TIMEOUT: reply_length=13;
                default: reply_length=10;
            endcase
        end
    endfunction
    function [7:0] reply_char;
        input [3:0] kind;
        input [6:0] n;
        input [7:0] command;
        input [23:0] page_digits,count_digits;
        input [7:0] flags;
        input [3:0] nibble;
        begin
            reply_char=8'h20;
            case(kind)
                ACK: case(n)
                    0:reply_char="A"; 1:reply_char="C"; 2:reply_char="K";
                    4:reply_char=command; 5:reply_char=13; 6:reply_char=10;
                    default:reply_char=" ";
                endcase
                SUBSTATUS, AUDIOSTATUS: begin
                    // Shared 80-bit nibble formatter. AQ is exactly
                    // A,<20 uppercase hex>\r\n (24 bytes), not O's SB= prefix.
                    if((kind==SUBSTATUS && n>=5 && n<=24) ||
                       (kind==AUDIOSTATUS && n>=2 && n<=21)) reply_char=hexchar(nibble);
                    else if(kind==AUDIOSTATUS) begin
                        case(n)
                            0:reply_char="A"; 1:reply_char=",";
                            22:reply_char=13; 23:reply_char=10;
                            default:reply_char=" ";
                        endcase
                    end else case(n)
                        0:reply_char="O"; 2:reply_char="S"; 3:reply_char="B";
                        4:reply_char="="; 25:reply_char=13; 26:reply_char=10;
                        default:reply_char=" ";
                    endcase
                end
                STATUS: begin
                    case(n)
                        0:reply_char="Q"; 2:reply_char="P"; 3:reply_char="=";
                        4:reply_char=page_digits[23:16]; 5:reply_char=page_digits[15:8]; 6:reply_char=page_digits[7:0];
                        8:reply_char="C"; 9:reply_char="=";
                        10:reply_char=count_digits[23:16]; 11:reply_char=count_digits[15:8]; 12:reply_char=count_digits[7:0];
                        14:reply_char="A"; 15:reply_char="="; 16:reply_char=flags[7]?"1":"0";
                        18:reply_char="R"; 19:reply_char="E"; 20:reply_char="A";
                        21:reply_char="D"; 22:reply_char="Y"; 23:reply_char="=";
                        24:reply_char=flags[6]?"1":"0";
                        26:reply_char="E"; 27,28:reply_char="R"; 29:reply_char="=";
                        30:reply_char=hexchar(flags[5:2]); 32:reply_char="R";
                        33:reply_char="="; 34:reply_char=hexchar({2'b0,flags[1:0]});
                        36,55:reply_char=8'd86;
                        37,58:reply_char=8'd69;
                        38,57:reply_char=8'd82;
                        39,45:reply_char=8'd61;
                        40:reply_char=8'd49;
                        42,52:reply_char=8'd67;
                        43,47:reply_char=8'd65;
                        44,49:reply_char=8'd80;
                        46:reply_char=8'd78;
                        48:reply_char=8'd77;
                        50:reply_char=8'd73;
                        51:reply_char=8'd66;
                        53:reply_char=8'd70;
                        54:reply_char=8'd84;
                        56:reply_char=8'd87;
                        59:reply_char=8'd83;
                        60:reply_char=8'd81;
                        61:reply_char=8'd72;
                        62:reply_char=8'd88;
                        63:reply_char=8'd90;
                        64:reply_char=8'd68;
                        65:reply_char=8'd71;
                        66:reply_char=8'd85;
                        67:reply_char=8'd74;
                        68:reply_char=8'd75;
                        69:reply_char="O";
                        70:reply_char="Y";
                        71:reply_char=8'd13;
                        72:reply_char=8'd10;
                        default:reply_char=" ";
                    endcase
                end
                HARDWARE: begin
                    if(h_digit(n)) reply_char=hexchar(nibble);
                    else case(n)
                        0:reply_char="H"; 2,71:reply_char="C"; 3,59,60:reply_char="F";
                        4:reply_char="G"; 15:reply_char="E"; 16:reply_char="V";
                        23,83:reply_char="S"; 24:reply_char="I";
                        35,48:reply_char="D"; 36:reply_char="M";
                        47,72:reply_char="L"; 84:reply_char="Q";
                        5,17,25,37,49,61,73,85:reply_char="=";
                        94:reply_char=13; 95:reply_char=10;
                        default:reply_char=" ";
                    endcase
                end
                default: begin
                    case(n)
                        0:reply_char="E"; 1,2:reply_char="R";
                        default:begin
                            case(kind)
                                RANGE:case(n)
                                    4:reply_char=8'd82;
                                    5:reply_char=8'd65;
                                    6:reply_char=8'd78;
                                    7:reply_char=8'd71;
                                    8:reply_char=8'd69;
                                    9:reply_char=8'd13;
                                    10:reply_char=8'd10;
                                    default:reply_char=" ";
                                endcase
                                LENGTH:case(n)
                                    4:reply_char=8'd76;
                                    5:reply_char=8'd69;
                                    6:reply_char=8'd78;
                                    7:reply_char=8'd71;
                                    8:reply_char=8'd84;
                                    9:reply_char=8'd72;
                                    10:reply_char=8'd13;
                                    11:reply_char=8'd10;
                                    default:reply_char=" ";
                                endcase
                                FRAME:case(n)
                                    4:reply_char=8'd70;
                                    5:reply_char=8'd82;
                                    6:reply_char=8'd65;
                                    7:reply_char=8'd77;
                                    8:reply_char=8'd69;
                                    9:reply_char=8'd13;
                                    10:reply_char=8'd10;
                                    default:reply_char=" ";
                                endcase
                                TIMEOUT:case(n)
                                    4:reply_char=8'd84;
                                    5:reply_char=8'd73;
                                    6:reply_char=8'd77;
                                    7:reply_char=8'd69;
                                    8:reply_char=8'd79;
                                    9:reply_char=8'd85;
                                    10:reply_char=8'd84;
                                    11:reply_char=8'd13;
                                    12:reply_char=8'd10;
                                    default:reply_char=" ";
                                endcase
                                BUSY:case(n)
                                    4:reply_char=8'd66;
                                    5:reply_char=8'd85;
                                    6:reply_char=8'd83;
                                    7:reply_char=8'd89;
                                    8:reply_char=8'd13;
                                    9:reply_char=8'd10;
                                    default:reply_char=" ";
                                endcase
                                default:case(n)
                                    4:reply_char=8'd83;
                                    5:reply_char=8'd89;
                                    6:reply_char=8'd78;
                                    7:reply_char=8'd84;
                                    8:reply_char=8'd65;
                                    9:reply_char=8'd88;
                                    10:reply_char=8'd13;
                                    11:reply_char=8'd10;
                                    default:reply_char=" ";
                                endcase
                            endcase
                        end
                    endcase
                end
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            used <= 0; poisoned <= 0; quarantine <= 0;
            poison_kind <= SYNTAX; idle_ticks <= 0;
            cmd_valid <= 0; cmd <= 0; value <= 0;
            text_data <= 0; text_length <= 0;
            seq_begin<=0; seq_write<=0; seq_commit<=0;
            seq_index<=0; seq_word<=0; seq_count<=0;
            sub_begin<=0; sub_write<=0; sub_commit<=0; sub_abort<=0;
            sub_tag<=0; sub_crc<=0; sub_len0<=0; sub_len1<=0;
            sub_index<=0; sub_chunk<=0;
            wr_ptr <= 0; rd_ptr <= 0; queued <= 0;
            write_busy<=0; write_index<=0; read_remaining<=0; read_pending<=0; low_nibble<=0;
            read_index<=0; read_slot<=0;
            busy_pending <= 0; active_kind <= ACK;
            active_payload<=0; q_page<=0; q_count<=0;
            remaining <= 0; char_index<=0; active <= 0;
            tx_start <= 0; tx_byte <= 0;
            byte_pending <= 0; byte_seen_busy <= 0;
        end else begin
            cmd_valid <= 0;
            sub_begin<=0; sub_write<=0; sub_commit<=0; sub_abort<=0;
            seq_begin<=0; seq_write<=0; seq_commit<=0;
            tx_start <= 0;
            if (rx_valid || rx_error) idle_ticks <= 0;
            else if (((used != 0) || poisoned) && !quarantine)
                idle_ticks <= idle_ticks + 1;
            else idle_ticks <= 0;

            if (expired) begin
                used <= 0; poisoned <= 0; quarantine <= 1;
            end
            if (rx_error && !quarantine) begin
                poisoned <= 1; poison_kind <= FRAME;
            end
            if (eol) begin
                used <= 0; poisoned <= 0; quarantine <= 0;
            end else if (rx_valid && !quarantine && !poisoned) begin
                if (used == 42) begin
                    poisoned <= 1; poison_kind <= LENGTH;
                end else if ((rx_byte < 32) || (rx_byte > 126)) begin
                    poisoned <= 1; poison_kind <= SYNTAX;
                end else begin
                    used <= used + 1;
                end
            end

            case ({publish,dequeue})
                2'b10: queued <= queued + 1;
                2'b01: queued <= queued - 1;
                default: begin end
            endcase
            if(write_busy) begin
                write_index <= write_index + 1'b1;
                if(publish) begin
                    write_busy <= 0;
                    wr_ptr <= (wr_ptr==8) ? 4'd0 : wr_ptr + 1'b1;
                end
            end
            read_pending <= read_busy;
            if(read_busy) begin
                read_remaining<=read_remaining-1'b1;
                read_index<=read_index+1'b1;
            end
            if(read_pending) begin
                active_payload<=payload_read_byte;
                if(active_kind==STATUS) case(read_remaining)
                    2: q_page<=decimal3({2'b0,payload_read_byte[6:0]}+9'd1);
                    1: q_count<=decimal3({1'b0,payload_read_byte});
                    default: begin end
                endcase
            end
            if (enqueue) begin
                kinds[wr_ptr] <= event_kind;
                write_busy <= 1;
                write_index <= 0;
                if (event_kind == ACK) begin
                    case(command_head)
                        "O": begin
                            case(command_sub)
                                "B": begin
                                    sub_begin<=1; sub_tag<=decoded_sub_tag;
                                    sub_len0<=decoded_sub_len0[5:0];
                                    sub_len1<=decoded_sub_len1[5:0]; sub_crc<=decoded_sub_crc;
                                end
                                "D": begin sub_write<=1; sub_index<=decoded_sub_index[6:0];
                                    sub_chunk<=decoded_sub_chunk; end
                                "C": begin sub_commit<=1; sub_tag<=decoded_sub_tag; end
                                "X": sub_abort<=1;
                                default: begin end
                            endcase
                        end
                        "U": seq_begin<=1;
                        "J": begin seq_write<=1; seq_index<=decoded_seq_index[3:0]; seq_word<=decoded_seq_word; end
                        "K": begin seq_commit<=1; seq_count<=decoded_seq_count[4:0]; end
                        default: begin
                            cmd_valid <= 1;
                            cmd <= command_head; value <= decoded_value;
                            if (command_head == "S") begin
                                text_data <= decoded_text; text_length <= used-2;
                            end
                        end
                    endcase
                end
            end else if (event_valid) busy_pending <= 1;

            if (dequeue) begin
                read_slot<=rd_ptr; low_nibble<=0;
                read_index <= (kinds[rd_ptr]==STATUS) ? 5'd27 :
                              ((kinds[rd_ptr]==ACK) ? 5'd29 : 5'd0);
                read_remaining <= (kinds[rd_ptr]==STATUS) ? 2'd3 : 2'd1;
                char_index<=0;
                remaining <= reply_length(kinds[rd_ptr]);
                active_kind <= kinds[rd_ptr];
                rd_ptr <= (rd_ptr==8) ? 4'd0 : rd_ptr + 1'b1;
                active <= 1;
            end else if (!active && !write_busy && busy_pending) begin
                char_index<=0; remaining <= reply_length(BUSY);
                active_kind <= BUSY; active <= 1;
            end
            if (active) begin
                if (!byte_pending && !tx_busy) begin
                    tx_byte<=reply_char(active_kind,char_index,active_payload,q_page,q_count,active_payload,
                        low_nibble ? active_payload[3:0] : active_payload[7:4]);
                    tx_start<=1;
                    if((active_kind==HARDWARE && h_digit(char_index)) ||
                       (active_kind==SUBSTATUS && char_index>=5 && char_index<=24) ||
                       (active_kind==AUDIOSTATUS && char_index>=2 && char_index<=21)) begin
                        low_nibble<=!low_nibble;
                        if(low_nibble && read_index < ((active_kind==HARDWARE) ? 5'd30 : 5'd10))
                            read_remaining<=1;
                    end
                    char_index<=char_index+1'b1;
                    remaining <= remaining - 1;
                    byte_pending <= 1; byte_seen_busy <= 0;
                end else if (byte_pending) begin
                    if (tx_busy) byte_seen_busy <= 1;
                    if (byte_seen_busy && !tx_busy) begin
                        byte_pending <= 0; byte_seen_busy <= 0;
                        if (remaining == 0) begin
                            active <= 0;
                            if (active_kind == BUSY) busy_pending <= event_valid;
                        end
                    end
                end
            end
        end
    end
endmodule
