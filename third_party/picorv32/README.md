# PicoRV32 (vendored)

Source: https://github.com/YosysHQ/picorv32, commit
`ef203c2b0a3fb793280f5114941416c425c5b461`. License: ISC (see `COPYING`).

Used only by the PicoRV32-based firmware bring-up platform
(`platform/picorv32`). Local modification (`lpsoc.patch`):

- new output `wfi` = internal `do_waitirq`; it is high while the core is
  stalled in the `waitirq` instruction. The platform PMU uses it the way the
  in-house core's WFI-sleep signal is used.
