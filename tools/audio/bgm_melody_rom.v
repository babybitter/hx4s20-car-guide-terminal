// Original known score, NOT real-time note detection. 16 events x 2 words.
// Even address: {midi[6:0],5'b0,start[19:0]}; odd: {12'b0,end_exclusive[19:0]}.
module bgm_melody_rom(input wire clk, input wire [4:0] addr, output reg [31:0] q);
  reg [31:0] rom [0:31];
  initial begin
    rom[0] = 32'h90001900;
    rom[1] = 32'h00007D00;
    rom[2] = 32'h98007D00;
    rom[3] = 32'h0000ED80;
    rom[4] = 32'h8E011F80;
    rom[5] = 32'h00019000;
    rom[6] = 32'h86019000;
    rom[7] = 32'h00020080;
    rom[8] = 32'h8A020D00;
    rom[9] = 32'h00027D80;
    rom[10] = 32'h90027D80;
    rom[11] = 32'h0002EE00;
    rom[12] = 32'h94032000;
    rom[13] = 32'h00038400;
    rom[14] = 32'h8A038400;
    rom[15] = 32'h0003F480;
    rom[16] = 32'h8E040100;
    rom[17] = 32'h00046500;
    rom[18] = 32'h86046500;
    rom[19] = 32'h0004D580;
    rom[20] = 32'h90051400;
    rom[21] = 32'h00057800;
    rom[22] = 32'h98057800;
    rom[23] = 32'h0005E880;
    rom[24] = 32'h8A060180;
    rom[25] = 32'h00066580;
    rom[26] = 32'h82066580;
    rom[27] = 32'h0006D600;
    rom[28] = 32'h8606EF00;
    rom[29] = 32'h00075300;
    rom[30] = 32'h94075300;
    rom[31] = 32'h0007C380;
  end
  always @(posedge clk) q <= rom[addr];
endmodule
