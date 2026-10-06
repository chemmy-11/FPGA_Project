module tiny(input clk, output q);
  reg r = 1'b0;
  always @(posedge clk) r <= ~r;
  assign q = r;
endmodule
