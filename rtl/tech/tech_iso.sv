// -----------------------------------------------------------------------------
// tech_iso - isolation cell wrapper (clamp to constant)
//
// Placed in the always-on parent domain on every output of a switchable
// domain. While iso_en_i is high the output is clamped to CLAMP regardless of
// the (possibly unpowered / corrupted) input. Replace with library isolation
// cells (ISO AND/OR, or enable level-shifter cells when voltages differ).
// -----------------------------------------------------------------------------
module tech_iso #(
  parameter int              WIDTH = 1,
  parameter logic [WIDTH-1:0] CLAMP = '0
) (
  input  logic             iso_en_i,
  input  logic [WIDTH-1:0] d_i,
  output logic [WIDTH-1:0] q_o
);
  assign q_o = iso_en_i ? CLAMP : d_i;
endmodule
