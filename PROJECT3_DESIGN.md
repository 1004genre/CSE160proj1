# Project 3: Reliable Transport and Congestion Control

## Current status

- Project 2 has a separate distance-vector build and multi-hop routing path.
- `lib/interfaces/Transport.nc` defines the transport API, and
  `includes/socket.h` defines the bounded connection records.
- `Project3C` / `Project3Node` and `TransportP` now implement the mid-review
  setup, stop-and-wait data transfer, and orderly-close path over routed
  `PROTOCOL_TCP` packets.
- `tests/project3/mid_review.py` exercises a three-node line and checks the
  handshake, byte-exact 32-byte transfer, and close. Sliding windows,
  receiver-driven flow control, concurrent active connections, and loss
  injection are still future work.

## Mid-review target

Demonstrate on a stable three-node line (1-2-3), after routes converge:

1. Node 3 starts listening; node 1 opens a connection to it.
2. Logs show `SYN -> SYN-ACK -> ACK` and the client and server reaching
   `ESTABLISHED`.
3. Node 1 transfers a short, identifiable byte pattern using stop-and-wait;
   node 3 checks the bytes and returns a cumulative ACK.
4. Node 1 initiates an orderly close after accepted data is acknowledged;
   logs show the FIN/ACK exchange, the peer FIN/final ACK, and cleanup.
5. The demo can explain the connection record, retry timer, and the planned
   sliding-window and receive-flow-control work.

The mid-review does not require the final loss, flow-control, or full sliding
window tests, but the code should be structured so those stages extend the
same engine.

## Proposed architecture and invariants

- `Project3C` / `Project3Node` is the application build, preserving the
  Project 2 build. `TransportP` uses the network-send interface and the
  existing command/routing layers.
- Transport sends `PROTOCOL_TCP` packets through network forwarding and
  distance-vector next-hop lookup. It never floods transport packets or calls
  the radio directly. Every retransmission gets a fresh network TTL and packet
  identifier while retaining its transport sequence range.
- Keep a statically bounded connection table. Identify a connection by the
  full tuple `(local address, local port, remote address, remote port)`.
  Support at least two connected records per node and keep a listener separate
  from its accepted child records.
- Keep 128-byte send and receive buffers per connected endpoint. Track absolute
  sequence positions and byte counts with widths that can represent the full
  supported transfer; do not use byte-sized counters for cumulative sequence
  positions.
- The implemented transport header contains source and destination ports,
  flags, data length, 16-bit sequence and acknowledgment numbers, and an
  advertised receive window. The encoded header is 9 bytes; the fixed 20-byte
  network payload therefore carries at most 11 data bytes per segment.
- The Project 3 build reports `sizeof(pack)=28` and
  `sizeof(tcp_segment_t)=20`: an 8-byte network header plus 9-byte transport
  header leaves 11 bytes for data. This honors the existing
  `TOSH_DATA_LENGTH=28`; the assignment's 29-byte budget wording remains a
  configuration discrepancy to confirm before final submission. No MTU
  increase is made.
- Start with a documented no-wrap sequence range for required tests. Keep
  network packet IDs distinct from transport byte sequence numbers.
- Maintain these invariants: acknowledged bytes never exceed sent bytes;
  consumed bytes never exceed received bytes; outstanding send bytes fit the
  sender buffer; receive occupancy never exceeds 128 bytes.

## State and timer policy

| State/event | Action | Next state |
|---|---|---|
| Listener receives SYN | Allocate one child record; choose server ISN; send SYN-ACK; start retry timer | SYN_RCVD |
| Client receives matching SYN-ACK | Validate its ACK; send final ACK | ESTABLISHED |
| Server receives matching final ACK | Stop handshake timer; preserve listener | ESTABLISHED |
| Established endpoint receives in-order data | Store only if it fits; advance expected byte; send cumulative ACK | ESTABLISHED |
| Established endpoint receives duplicate/out-of-order data | Do not redeliver or skip a gap; send current cumulative ACK | ESTABLISHED |
| Client has no queued or unacknowledged bytes | Send FIN using the next sequence; start retry timer | FIN_WAIT |
| Peer receives FIN in order | ACK it; drain its own data; send its FIN | CLOSE_WAIT / LAST_ACK |
| Client receives peer FIN | Send final ACK; retain closing state for duplicate FINs | TIME_WAIT |
| Retry budget exhausted | Report failure and release bounded state safely | CLOSED |

The mid-review implementation uses a fixed 3-second retransmission timeout,
five retransmissions, and explicit failure reporting. It was exercised on the
two-hop demo route; calibrate it again for longer routes and loss scenarios.
Duplicate SYN and data packets are handled idempotently; expand tests for
duplicate FIN and lost final ACK during the full-project stages. The client
retains its TIME_WAIT record for 6 seconds (twice the current RTO) so it can
acknowledge a retransmitted FIN if the first final ACK is lost.

## Work plan

| Stage | Work | Exit check |
|---|---|---|
| 0. Packet and routing boundary (implemented) | Confirm current packet size; encode the TCP header; add routed TCP dispatch and `Project3C` | Project 3 builds; compiled packet/segment sizes are logged; Project 1/2 builds remain valid |
| 1. Connection setup (implemented) | Static tuple-indexed records, persistent listener, SYN/SYN-ACK/ACK, duplicate SYN handling, handshake retry | Repeatable 1-2-3 handshake; listener remains available |
| 2. Stop-and-wait data (implemented) | Retained 128-byte send buffer, 11-byte segments, in-order receiver, cumulative ACK, duplicate suppression, data retry | Demo transfers 32 bytes byte-exactly over 1-2-3 |
| 3. Orderly close (implemented) | Drain data before FIN; peer FIN/final ACK; bounded retry and TIME_WAIT cleanup | Mid-review script completes setup, transfer, and teardown with state logs |
| 4. Fixed sliding window | Multiple outstanding segments; sender bounded by configured and advertised windows; partial segments; ACK validation | At least two outstanding segments; byte-exact transfer of at least 1,024 bytes |
| 5. Receive flow control | 128-byte receive occupancy; test consumer pauses/resumes; window update/probe for lost reopening update | Sender stops at zero window, resumes, and receiver never overflows |
| 6. Independent connections and failure | Two simultaneous connection records; fair bounded work; unavailable-listener and retry-exhaustion cleanup | One connection’s pause/timeout does not block another; all failures release state |
| 7. Validation and submission docs | Deterministic drop hooks, noisy run, reproducible scripts, README results, one-page design PDF, discussion answers | All six required validation scenarios are repeatable and documented |

## Full-project completion criteria

The project is complete only when all of the following hold:

- The transport runs over `PROTOCOL_TCP` using the regular routed network
  service, with the verified packet-size budget and no MTU increase.
- Each node can keep a listener and at least two active connections. Connected
  records use the full local/remote address and port tuple; one connection's
  state, timeout, or backpressure does not corrupt another's.
- Each connection has bounded 128-byte send and receive buffers. The sender
  retains unacknowledged bytes, uses a sliding window, and never exceeds the
  peer's advertised receive capacity. The receiver accepts only valid
  in-order data, acknowledges cumulatively, and never overflows its buffer.
- Connection setup, data delivery, and orderly teardown recover from the
  required losses or report a bounded, visible failure and release their
  records. Duplicate packets do not allocate duplicate connections or deliver
  bytes twice.
- A reproducible end-to-end run transfers at least 1,024 bytes byte-for-byte
  over a multi-hop route. Logs or test output expose connection state, byte
  ranges, acknowledgments, advertised-window changes, retries, and cleanup.
- The final README/design submission explains the wire format and size budget,
  connection records and states, timer/retry policy, sliding-window and
  flow-control behavior, test procedure/results, and any known limitations.

## Required final validation matrix

Use deterministic, reproducible packet-loss controls and verify both endpoints'
byte contents and final connection-table state in every case:

1. **Baseline long transfer:** transfer at least 1,024 bytes over a stable
   multi-hop route; verify exact contents, cumulative acknowledgments, and
   orderly close.
2. **Lost data:** drop a data segment; verify retransmission, correct
   cumulative acknowledgment, and exactly-once delivery.
3. **Lost acknowledgment:** drop an ACK; verify that retransmitted data is
   recognized as a duplicate and is not delivered twice.
4. **Lost control traffic:** drop setup or teardown control traffic; verify
   duplicate-safe retries, eventual success when loss stops, and bounded
   cleanup when retries are exhausted.
5. **Zero-window recovery:** pause the receiver until its advertised window
   reaches zero; verify the sender stops, then resumes after consumption and
   a window update. Also drop the reopening update and verify the specified
   probe/recovery behavior.
6. **Connection isolation and failure cleanup:** keep two connections active
   while one is paused or forced to time out; verify the other makes progress,
   listeners remain usable, and closed/failed records are reclaimed.

Do not begin optional congestion-window/slow-start work until all required
reliability, sliding-window, flow-control, and cleanup behavior is validated.

## Mid-review demo procedure

Run `make micaz sim COMPONENT=Project3C`, then
`python2 tests/project3/mid_review.py`. The script starts a node 3 listener,
connects node 1 over the bidirectional 1-2-3 line, sends bytes `0..31` in
stop-and-wait segments, and initiates close after all bytes are acknowledged.
It checks the connection-state transitions, exact pattern verification, and
both endpoints' cleanup. Full TOSSIM output is written to
`logs/project3-mid-review.log`.

For a live explanation, point out that the listener stays separate from its
accepted child; show the 9-byte header/11-byte data budget, cumulative ACKs,
the fixed 3-second retry timer, and the next planned stages for a sliding
window and receive-window flow control.