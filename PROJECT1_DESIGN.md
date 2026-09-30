
# Project 1

### `lib/interfaces/NeighborDiscovery.nc`

This new interface is the small boundary between `Node` and neighbor discovery. `start()` begins periodic beaconing after boot, and `print()` implements the existing `printNeighbors` command. No routing or topology-map API is exposed because those are outside Project 1.

### `lib/modules/NeighborDiscoveryC.nc`

This configuration wires `NeighborDiscoveryP` to three existing TinyOS services:

- `TimerMilliC` produces periodic beacon events.
- `SimpleSendC(AM_PACK)` queues beacon broadcasts, preventing a busy radio from immediately dropping them.
- `AMReceiverC(AM_PACK)` supplies received project packets for beacon processing.

### `NodeC.nc` and `Node.nc`

`NodeC` wires the new neighbor-discovery component to `Node`. `Node` declares the `NeighborDiscovery` interface, starts it in `Boot.booted`, and delegates the existing `printNeighbors` command to `NeighborDiscovery.print()`.


### Packet identity and duplicate history

The added `seenPacket` record stores a packet's original `src` and `seq` fields. `wasSeen()` searches this history before a packet is processed, and `remember()` inserts new entries. The table has 64 fixed entries; when full, it replaces entries in circular order. This makes memory usage predictable for a TinyOS mote.

The source/sequence pair was chosen because both fields are already present in the supplied packet header. It prevents repeated rebroadcasting through cycles without requiring a topology map or a new packet type.

### Starting a ping

The added `CommandHandler.ping` implementation creates a `PROTOCOL_PING` packet with:

- the local node as `src`;
- the command's target as `dest`;
- an incrementing local sequence number;
- `MAX_TTL` to limit the flood's reach.

It records that packet locally, then calls `flood()`. `flood()` sends to `AM_BROADCAST_ADDR`, allowing every direct radio neighbor to receive it. The required `FLOODING_CHANNEL` messages show packet injection and rebroadcasting.

### Receiving, forwarding, and replying

The added receive logic processes only ping and ping-reply packets. It discards malformed packets and duplicate source/sequence pairs. For a first-time packet:

1. If the packet is for this node and is a ping, this node creates a fresh `PROTOCOL_PINGREPLY` addressed to the original source and floods it.
2. If it is a ping reply for this node, it reports successful arrival on `FLOODING_CHANNEL`.
3. If it is for another node and its TTL is greater than one, the node decrements TTL and rebroadcasts it.

Together, duplicate suppression and TTL ensure floods stop. The destination does not forward the received ping; it sends a distinct reply instead.


### Beacon format and schedule

Every `BEACON_PERIOD` (1,000 ms), the added timer handler creates a normal `pack` and broadcasts it. The beacon uses the already supplied `PROTOCOL_NAME` field and payload text `ND`, so no new active-message or packet type was introduced. Its TTL is exactly one, which keeps discovery limited to direct radio neighbors and distinguishes it from multi-hop flooding.

### Neighbor table and failure detection

The module keeps parallel fixed-size arrays:

- `neighbors` stores direct neighbor node IDs.
- `remainingBeacons` stores each neighbor's liveness countdown.

On receipt of a valid one-hop `ND` beacon, `refreshNeighbor()` either adds the sender or resets its countdown to `NEIGHBOR_TIMEOUT` (five beacon periods). Each timer event decrements the countdowns; a zero countdown removes the corresponding entry by shifting later entries left. This allows the system to discover new neighbors and remove nodes that leave or stop responding.

`NeighborDiscovery.print()` writes the current table to `NEIGHBOR_CHANNEL`; discovery and loss events are also reported there. This provides the project-required visibility without adding routing behavior.

## Flooding module files

`lib/interfaces/Flooding.nc` was added as the small boundary between `Node` and flooding: Node can originate a ping or pass a received packet to it. `lib/modules/FloodingC.nc` wires the protocol to the existing queued sender. `lib/modules/FloodingP.nc` contains the flooding implementation that was moved out of `Node.nc`: sequence numbers, duplicate history, broadcasts, TTL forwarding, and ping replies. This keeps `Node.nc` as a dispatcher rather than mixing the two Project 1 protocols together.

## Verification scenario

`project1Test.py` was added to exercise the requested checks in `long_line.topo`. It sends a ping from node 1 to node 10 (nine hops) and waits for the reply. It then sends two more pings from node 1, so `FLOODING_CHANNEL` should show increasing sequence numbers. Finally it turns off node 10, waits longer than the five-beacon timeout, and dumps nodes 9 and 11; neither should still list node 10.


The design uses broadcast because the assignment requires flooding without prior topology knowledge. It uses only packet-header data for the duplicate key and TTL for a hard forwarding limit. Neighbor discovery reuses the supplied packet format and TTL of one, satisfying the constraint against new packet types while ensuring only physical neighbors are recorded. Fixed-size tables avoid dynamic allocation and keep the scope limited to flooding and neighbor discovery—nothing from later routing or transport projects is added.
