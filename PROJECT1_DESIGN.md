# Project 1 design explanation

## Flooding

Each new ping and ping reply is broadcast with `AM_BROADCAST_ADDR`, so every directly reachable node can hear it. A node forwards a packet only when it is not the final destination, it has more than one TTL hop remaining, and that `(source, sequence number)` pair has not already been processed. The source/sequence pair comes entirely from the supplied packet header, satisfying the requirement to avoid topology knowledge and extra packet metadata.

The duplicate table prevents packets from circulating forever when a topology has multiple paths or cycles. Its fixed size keeps memory use bounded, which is important for TinyOS motes. The TTL is a second limit: even after old duplicate entries are eventually replaced, no one packet can continue beyond `MAX_TTL` hops. A destination creates a fresh ping reply and floods it using the same rules, so replies work across multiple hops too.

## Neighbor discovery

Each node periodically broadcasts a normal project packet with the already-provided `PROTOCOL_NAME` value and the payload marker `ND`. Its TTL is one, so it can only be received by direct radio neighbors and is never forwarded. This satisfies the handout's constraint not to add a new packet type.

Receiving a beacon adds the sender to the neighbor table or refreshes a five-period liveness countdown. If the countdown reaches zero because no further beacon arrives, the entry is removed. This detects both new neighbors and nodes that leave the topology. The table is printed only when the existing command requests it, while discovery and loss events go to `NEIGHBOR_CHANNEL`; flooding activity goes to `FLOODING_CHANNEL` as required.

The 1-second beacon period and 5-beacon timeout are deliberately simple: they make discovery reasonably quick in the supplied simulator while tolerating a few lost radio packets. No routing, topology map, or later-project feature is included.
