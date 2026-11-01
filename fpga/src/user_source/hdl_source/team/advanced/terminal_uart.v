// Atomic line-command frontend. All ports belong to the pixel clock domain.
// ACK means the command pulse was emitted, not downstream completion.
module terminal_uart #(
    parameter integer CLK_HZ = 25000000,
    parameter integer BAUD = 115200
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
    output reg [5:0] text_length
);
    localparam integer IDLE_LIMIT = CLK_HZ / 10; // 100 ms inter-byte limit
    localparam [2:0] ACK=0, STATUS=1, SYNTAX=2, RANGE=3,
                     LENGTH=4, FRAME=5, TIMEOUT=6, BUSY=7;
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

    reg [7:0] line [0:41];
    reg [5:0] used;
    reg poisoned, quarantine;
    reg [2:0] poison_kind;
    reg [31:0] idle_ticks;
    wire eol = rx_valid && ((rx_byte == 13) || (rx_byte == 10));
    wire expired = !rx_valid && !rx_error && !quarantine &&
                   ((used != 0) || poisoned) && (idle_ticks == IDLE_LIMIT-1);
    wire event_valid = expired || (eol && !quarantine && ((used != 0) || poisoned));
    reg [2:0] event_kind;
    reg [7:0] decoded_value;
    reg [319:0] decoded_text;
    integer page_number, k;
    always @* begin
        event_kind = SYNTAX;
        decoded_value = 0;
        decoded_text = 0;
        page_number = 0;
        if (expired) event_kind = TIMEOUT;
        else if (poisoned) event_kind = poison_kind;
        else if (used == 1) begin
            case (line[0])
                "N", "A", "M", "P": event_kind = ACK;
                "Q": event_kind = STATUS;
                default: event_kind = SYNTAX;
            endcase
        end else if ((used >= 2) && (line[0] == "S") && (line[1] == ":")) begin
            event_kind = ACK;
            for (k=0; k<40; k=k+1)
                if (k < used-2) decoded_text[k*8 +: 8] = line[k+2];
        end else if ((used == 4) && (line[0] == "I") &&
                     (line[1] >= "0") && (line[1] <= "9") &&
                     (line[2] >= "0") && (line[2] <= "9") &&
                     (line[3] >= "0") && (line[3] <= "9")) begin
            page_number = (line[1]-48)*100 + (line[2]-48)*10 + line[3]-48;
            if ((page_number >= 1) && (page_number <= 128) &&
                (page_number <= status_count)) begin
                event_kind = ACK;
                decoded_value = page_number - 1;
            end else event_kind = RANGE;
        end else if ((used == 2) && (line[1] >= "0") && (line[1] <= "9")) begin
            decoded_value = line[1]-48;
            case (line[0])
                "B", "C", "T", "R": event_kind = (decoded_value <= 3) ? ACK : RANGE;
                "F": event_kind = (decoded_value <= 5) ? ACK : RANGE;
                "V": event_kind = (decoded_value <= 4) ? ACK : RANGE;
                "W", "E": event_kind = (decoded_value <= 1) ? ACK : RANGE;
                default: event_kind = SYNTAX;
            endcase
        end
    end

    // Eight queued descriptors plus the active response. Each accepted Q owns
    // its snapshot; subsequent input changes cannot alter bytes in that reply.
    reg [2:0] kinds [0:7];
    reg [7:0] commands [0:7];
    reg [22:0] snapshots [0:7];
    reg [2:0] wr_ptr, rd_ptr;
    reg [3:0] queued;
    reg busy_pending;
    reg [2:0] active_kind;
    reg [639:0] response;
    reg [6:0] remaining;
    reg active, byte_pending, byte_seen_busy;
    wire enqueue = event_valid && !busy_pending && (queued < 8);
    wire dequeue = !active && (queued != 0);

    function [23:0] decimal3;
        input [8:0] n;
        reg [7:0] hundreds, tens, ones;
        begin
            hundreds = 48 + n/100;
            tens = 48 + (n/10)%10;
            ones = 48 + n%10;
            decimal3 = {hundreds, tens, ones};
        end
    endfunction
    function [7:0] hexchar;
        input [3:0] n;
        begin hexchar = n < 10 ? 48+n : 55+n; end
    endfunction
    function [639:0] reply;
        input [2:0] kind;
        input [7:0] command;
        input [22:0] snapshot;
        begin
            case (kind)
                ACK: reply = {"ACK ", command, "\015\n", {73{8'd0}}};
                STATUS: reply = {"Q P=", decimal3({2'b0,snapshot[22:16]}+9'd1),
                    " C=", decimal3({1'b0,snapshot[15:8]}),
                    " A=", (snapshot[7] ? "1" : "0"),
                    " READY=", (snapshot[6] ? "1" : "0"),
                    " ERR=", hexchar(snapshot[5:2]), " R=", hexchar({2'b0,snapshot[1:0]}),
                    " VER=1 CAP=NAMPIBCFTVWRESQ\015\n", {17{8'd0}}};
                RANGE: reply = {"ERR RANGE\015\n", {69{8'd0}}};
                LENGTH: reply = {"ERR LENGTH\015\n", {68{8'd0}}};
                FRAME: reply = {"ERR FRAME\015\n", {69{8'd0}}};
                TIMEOUT: reply = {"ERR TIMEOUT\015\n", {67{8'd0}}};
                BUSY: reply = {"ERR BUSY\015\n", {70{8'd0}}};
                default: reply = {"ERR SYNTAX\015\n", {68{8'd0}}};
            endcase
        end
    endfunction
    function [6:0] reply_length;
        input [2:0] kind;
        begin
            case (kind)
                ACK: reply_length=7;
                STATUS: reply_length=63;
                RANGE, FRAME: reply_length=11;
                LENGTH, SYNTAX: reply_length=12;
                TIMEOUT: reply_length=13;
                default: reply_length=10;
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            used <= 0; poisoned <= 0; quarantine <= 0;
            poison_kind <= SYNTAX; idle_ticks <= 0;
            cmd_valid <= 0; cmd <= 0; value <= 0;
            text_data <= 0; text_length <= 0;
            wr_ptr <= 0; rd_ptr <= 0; queued <= 0;
            busy_pending <= 0; active_kind <= ACK;
            response <= 0; remaining <= 0; active <= 0;
            tx_start <= 0; tx_byte <= 0;
            byte_pending <= 0; byte_seen_busy <= 0;
        end else begin
            cmd_valid <= 0;
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
                    line[used] <= rx_byte;
                    used <= used + 1;
                end
            end

            case ({enqueue,dequeue})
                2'b10: queued <= queued + 1;
                2'b01: queued <= queued - 1;
                default: begin end
            endcase
            if (enqueue) begin
                kinds[wr_ptr] <= event_kind;
                commands[wr_ptr] <= line[0];
                snapshots[wr_ptr] <= {status_page,status_count,status_auto,
                                      status_ready,status_error,status_period};
                wr_ptr <= wr_ptr + 1;
                if (event_kind == ACK) begin
                    cmd_valid <= 1;
                    cmd <= line[0]; value <= decoded_value;
                    if (line[0] == "S") begin
                        text_data <= decoded_text; text_length <= used-2;
                    end
                end
            end else if (event_valid) busy_pending <= 1;

            if (dequeue) begin
                response <= reply(kinds[rd_ptr],commands[rd_ptr],snapshots[rd_ptr]);
                remaining <= reply_length(kinds[rd_ptr]);
                active_kind <= kinds[rd_ptr];
                rd_ptr <= rd_ptr + 1;
                active <= 1;
            end else if (!active && busy_pending) begin
                response <= reply(BUSY,0,0); remaining <= reply_length(BUSY);
                active_kind <= BUSY; active <= 1;
            end
            if (active) begin
                if (!byte_pending && !tx_busy) begin
                    tx_byte <= response[639:632]; tx_start <= 1;
                    response <= {response[631:0],8'd0};
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
