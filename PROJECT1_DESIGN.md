
# Project 1

### `lib/interfaces/NeighborDiscovery.nc`

This is the interface between `Node` and neighbor discovery. It uses `start()` to periodical signal after it boots, and `print` implements `printNeighbors`. 

### `lib/modules/NeighborDiscoveryC.nc`

This file wires `NeighborDiscoveryP` to 3 TinyOS services:

- `TimerMilliC` produces periodic signal events.
- `SimpleSendC(AM_PACK)` queues signal broadcasts, so that a a busy radio doesn't immediately drop them.
- `AMReceiverC(AM_PACK)` sends received packets to process what was broadcast.

### `NodeC.nc` and `Node.nc`

`NodeC` wires the neighbor-discovery component to `Node`. `Node` declares the `NeighborDiscovery` interface, starts it in `Boot.booted`, and delegates `printNeighbors` command to `NeighborDiscovery.print()`.


### Packet identity and duplicate history

The added `seenPacket` record stores a packet's original `src` and `seq` fields. `wasSeen()` searches this history before a packet is processed, and `remember()` inserts new entries. The table has 64 fixed entries; when full, it replaces entries in circular order. This makes memory usage predictable for a TinyOS mote.

The `seenPacket` record stores a packets original source and sequence details in their respective fields. `wasSeen` searches this history before a packet is processed, and `remember()` inserts new entries into the table. The table has 64 fixed entries, and when it fills up, it replaces entries in a rotating fashion, making the memory usage predicatable. I chose to use the source/sequence pair since both fields are already present in the packet header. It stops repeated rebroadcasting.

### Starting a ping

The `CMD_FLOOD_PING` command is handled by `CommandHandler.floodPing`; it
passes the requested destination and payload to `Flooding.ping`. The flooding
service creates a `PROTOCOL_PING` packet with:

- the local node as `src`
- the command's target as `dest`
- an incrementing sequence number
- `MAX_TTL` to limit the flood's reach.

It records a packet locally, then calls `flood()`. `flood()` sends to `AM_BROADCAST_ADDR`, letting every direct radio neighbor to receive it. The `FLOODING_CHANNEL` messages show packet injection and rebroadcasting.

### Receiving, forwarding, and replying

The receive logic processes only ping and ping-reply packets. It discards bad packets and duplicate source/sequence pairs. For a new packet:

1. If the packet is for this node and is a ping, this node creates a new `PROTOCOL_PINGREPLY` addressed to the original source and floods it.
2. If it is a ping-reply for this node, it reports successful arrival on `FLOODING_CHANNEL`.
3. If it is for another node and its TTL is greater than one, the node decrements TTL and rebroadcasts it.

The duplicate removal and TTL ensure floods stop. The destination node doesn't forward the received ping, it sends a distinct reply.


### Beacon format and schedule

The `BEACON_PERIOD` is around 1000 ms, and the timer handler creates a normal `pack` to broadcast it. The signal uses  `PROTOCOL_NAME` and `ND`, so no new active messages or packet types are introduced. The TTL is exactly 1, so the discovery is limited to direct radio neighbors.

### Neighbor table and failure detection

This module keeps parallel fixed-size arrays:

- `neighbors` stores direct neighbor IDs.
- `remainingBeacons` stores each neighbor's countdown.


To record a valid `ND` signal, `refreshNeighbor()` either adds the sender or resets the countdown to `NEIGHBOR_TIMEOUT` (which is five beacon periods). Each timer event decrements the countdown, and a zero countdown shifts the later entries left, allowing us to discover new neighbors and remove nodes that stop. `NeighbordDiscovery.print()` writes the table to `NEIGHBOR_CHANNEL`, discovery and loss events are also reported to that table.


## Flooding module files

`Flooding.nc` acts as the boundary between `Node` and flooding. Node can start a ping or pass a received packet to it. `FloodingC.nc` wires the protocol to the queued sender. `FloodingP.nc` contains the flooding implementation that has sequence numbers, duplicate history, broadcasts, TTL forwarding, and ping replies. This keeps `Node.nc` as a dispatcher.
