# util_upack2_axis

Splits each 64-bit TX DMA beat into two 32-bit complex AXI4-Stream masters.
Each input beat must be a full four-lane frame in this order:
`TX1 I, TX1 Q, TX2 I, TX2 Q`. The outputs carry `{Q[15:0], I[15:0]}` and use
independent ready/valid handshakes. The input accepts a new beat only when both
output holding slots can retain their corresponding complex samples.

The DMA stream has no `TKEEP` or channel-mask sideband. A TX buffer must
therefore use all four scan channels and put zeroes in the unused TX pair;
opening a buffer with only one pair selected compacts its samples and does not
match this fixed lane mapping.
