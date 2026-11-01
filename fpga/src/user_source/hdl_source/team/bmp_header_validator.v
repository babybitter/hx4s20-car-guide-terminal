// s08 candidate only. Register inputs before local strict-profile checks.
module bmp_header_validator (
    input wire clk,rst,start,byte_valid,
    input wire [8:0] byte_index,input wire [7:0] byte_data,
    input wire sector_done,output reg done,accepted
);
    reg start_d,valid_d,sector_done_d;
    reg [8:0] index_d;
    reg [7:0] data_d;
    reg [6:0] received;
    reg bad_order,profile_bad,image_zero,image_exact;
    reg finish_pending,end_seen;
    function [7:0] expected_byte;
        input [5:0] index;
        begin
            case(index)
                0:expected_byte=8'h42;1:expected_byte=8'h4d;
                2:expected_byte=8'h36;3:expected_byte=8'h10;4:expected_byte=8'h0e;
                10:expected_byte=8'h36;14:expected_byte=8'h28;
                18:expected_byte=8'h80;19:expected_byte=8'h02;
                22:expected_byte=8'he0;23:expected_byte=8'h01;
                26:expected_byte=8'h01;28:expected_byte=8'h18;
                35:expected_byte=8'h10;36:expected_byte=8'h0e;
                default:expected_byte=8'h00;
            endcase
        end
    endfunction
    always @(posedge clk or posedge rst)begin
        if(rst)begin start_d<=0;valid_d<=0;sector_done_d<=0;index_d<=0;data_d<=0;end
        else begin
            start_d<=start;valid_d<=byte_valid;sector_done_d<=sector_done;
            index_d<=byte_index;data_d<=byte_data;
        end
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            received<=0;bad_order<=0;profile_bad<=0;image_zero<=1;image_exact<=1;
            finish_pending<=0;end_seen<=0;done<=0;accepted<=0;
        end else begin
            done<=0;accepted<=0;finish_pending<=0;
            if(start_d)begin
                received<=0;bad_order<=0;profile_bad<=0;image_zero<=1;image_exact<=1;end_seen<=0;
            end else begin
                if(valid_d && received<54)begin
                    if(index_d!={2'b00,received})bad_order<=1;
                    else begin
                        received<=received+1'b1;
                        if(index_d<34 && data_d!=expected_byte(index_d[5:0]))profile_bad<=1;
                        if(index_d>=34 && index_d<38)begin
                            image_zero<=image_zero && data_d==0;
                            image_exact<=image_exact && data_d==expected_byte(index_d[5:0]);
                        end
                    end
                end
                if(sector_done_d && !end_seen)begin finish_pending<=1;end_seen<=1;end
                // Final staged byte is consumed before publishing the verdict,
                // including byte53 and sector_done received on the same edge.
                if(finish_pending)begin
                    done<=1;accepted<=received==54 && !bad_order && !profile_bad && (image_zero || image_exact);
                end
            end
        end
    end
endmodule
