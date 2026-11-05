// -----------------------------------------------------------------------------
// axi_lite_bind.sv - bind the AXI4-Lite protocol checker into every
// axi_lite_if instance.
// -----------------------------------------------------------------------------
bind axi_lite_if axi_lite_protocol_checker #(.MAX_WAIT(256)) u_axi_lite_chk (
  .aclk    (aclk),    .aresetn (aresetn),
  .awaddr  (awaddr),  .awprot  (awprot),  .awvalid (awvalid), .awready (awready),
  .wdata   (wdata),   .wstrb   (wstrb),   .wvalid  (wvalid),  .wready  (wready),
  .bresp   (bresp),   .bvalid  (bvalid),  .bready  (bready),
  .araddr  (araddr),  .arprot  (arprot),  .arvalid (arvalid), .arready (arready),
  .rdata   (rdata),   .rresp   (rresp),   .rvalid  (rvalid),  .rready  (rready)
);
