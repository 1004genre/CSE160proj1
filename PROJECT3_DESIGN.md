# Project 3: Reliable Transport and Congestion Control

## Current status

- Project 2 has a separate distance-vector build and multi-hop routing path.
- `lib/interfaces/Transport.nc` defines the transport API, and
  `includes/socket.h` defines the bounded connection records.
- `Project3C` / `Project3Node` and `TransportP` implement connection setup,
  a fixed sliding sender window, and orderly close over routed
  `PROTOCOL_TCP` packets.
- `tests/project3/mid_review.py` exercises a three-node line, verifies multiple
  outstanding segments and partial-write resumption in a byte-exact 256-byte
  transfer, pauses the consumer through a zero window, drops one reopening
  update, and checks probe recovery and close.
  Zero-window recovery with a dropped reopening update is covered; concurrent
  active connections and broader deterministic loss cases still need validation.

## Mid-review target

Demonstrate on a stable three-node line (1-2-3), after routes converge:

1. Node 3 starts listening; node 1 opens a connection to it.
2. Logs show `SYN -> SYN-ACK -> ACK` and the client and server reaching
   `ESTABLISHED`.
3. Node 1 transfers an identifiable byte pattern with a four-segment sender
   window; node 3 checks the bytes and returns cumulative ACKs.
4. Node 1 initiates an orderly close after accepted data is acknowledged;
   logs show the FIN/ACK exchange, the peer FIN/final ACK, and cleanup.
5. A paused test consumer fills the receive buffer; the harness drops its first
   reopening update, and a later probe recovers the advertised window without
   exceeding the 128-byte receiver bound.
6. The demo exposes the connection record, retry timer, outstanding byte
   ranges, and advertised-window behavior.

The mid-review demonstrates a fixed sliding window and one zero-window recovery
case. Broader loss scenarios and long transfers remain separate validation stages.

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
- The 8-byte transport header contains two 8-bit ports, a packed type/length
  code, 16-bit sequence and acknowledgment numbers, and an 8-bit advertised
  window. Distinct control codes represent SYN, SYN-ACK, ACK, FIN, and probe;
  data codes 5..18 encode lengths 1..14 in the low five bits. Control types
  carry no data; the upper three bits are reserved as zero.
- The Project 3 packet budget is the course's 29 bytes: a 7-byte network
  header plus a 22-byte transport payload. The network header has 16-bit
  end-to-end source/destination addresses, a distinct 16-bit packet ID, an
  combined 4-bit TTL and 4-bit protocol. The in-payload link-layer header is
  zero bytes because the next hop is passed separately to `SimpleSend`; AM
  fields are outside this course budget. The 8-byte transport header leaves
  14 bytes per segment, for 15 bytes total in-payload overhead. `nx_struct`
  encodes multibyte fields in network byte order; compile-time size checks
  enforce 29-byte packets and 22-byte transport segments without padding.
  `TOSH_DATA_LENGTH` remains 29.
- Transport sequence numbers are 16-bit and deliberately do not wrap. Each
  direction starts with SYN sequence 0; up to 1,024 data bytes use sequences
  1..1,024, FIN uses 1,025, and its cumulative ACK is 1,026. The API enforces
  `TCP_MAX_TRANSFER_BYTES=1024` on both send and receive. All required tests
  must stay at or below this per-direction cap. Network packet IDs remain
  separate from transport byte sequence numbers.
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
| Closing endpoint has no queued or unacknowledged bytes | Send FIN using the next sequence; start retry timer | FIN_WAIT / LAST_ACK |
| Peer receives FIN in order | ACK it; drain its own data; send its FIN | CLOSE_WAIT / LAST_ACK |
| Client receives peer FIN | Send final ACK; retain closing state for duplicate FINs | TIME_WAIT |
| Retry budget exhausted | Report failure and release bounded state safely | CLOSED |

The mid-review implementation uses a fixed 3-second retransmission timeout,
five retransmissions, and explicit failure reporting. It was exercised on the
two-hop demo route; calibrate it again for longer routes and loss scenarios.
Duplicate SYN and data packets are handled idempotently; expand tests for
duplicate FIN and lost final ACK during the full-project stages. Both endpoints
retain the tuple for 18 seconds: the 3-second initial RTO plus five retry
intervals. This covers the full FIN retry horizon and lets the client
acknowledge a retransmitted FIN if the first final ACK is lost.

The receiver accepts only data beginning at `rcvNext`; it drops gaps and
duplicates and returns the current cumulative ACK for each valid data segment,
including when receive space is exhausted. Malformed or unmatched segments are
dropped without an ACK, and a pure ACK never triggers another ACK. The sender
uses Go-Back-N: it retains unacknowledged bytes, retransmits them in order with
the same transport sequence range, and allocates a fresh network packet ID for
each routed transmission. `Transport.write` reports locally accepted bytes;
the application retries any unaccepted suffix after `sendReady` reports space.

Transport encoding/decoding and data-capacity checks use the encoded segment
size. Each pump or retransmit call submits at most two data packets through the
existing queued `SimpleSend` service. A lower-layer queue failure leaves the
send cursor unchanged; a later ACK or retry-timer event resumes the batch.
Only transport ACKs release retained bytes. The DV layer separately encodes
whole destination-cost pairs, sends one bounded page per timer event, and
advances its table cursor only after the send queue accepts that page; neighbors
process each page independently without table reassembly.

The advertised receive window is `128 - rcvLength`; acknowledged bytes remain
counted until `Transport.read` consumes them. The sender limits outstanding
bytes to the smaller of its 56-byte fixed window and the peer window relative
to the cumulative ACK, so already outstanding bytes use part of that allowance.
It sends a shorter segment when only a partial window remains. At zero window,
it stops new data and sends a non-sequenced window probe every 3 seconds. A
valid probe response with window zero keeps the connection alive; retry failure
requires no valid response to five probes plus the final timeout interval.
Go-Back-N retransmission begins at the oldest unacknowledged byte and limits
each retry to the current fixed and advertised window; remaining bytes stay
retained until later ACK/window progress allows them.

The mid-review consumer pauses for eight seconds after accept; the packet
handler only notifies, while a 500 ms timer resumes reads through
`Transport.read`. The test drops the first positive-window ACK from that read,
then checks that a later probe recovers the window and logged receive occupancy
never exceeds 128 bytes.

The command wrapper in `run.py` targets server creation and receiver pause/resume
at the server address, and client open/close at the client address. Pause and
resume identify `(serverAddress, listenPort, clientAddress, sourcePort)`. Each
accepted socket has its own test record; a shared 500 ms timer reads each
unpaused connection in bounded 128-byte chunks. The producer regenerates bytes
from its accepted-byte offset, while transport state separately counts
acknowledged bytes; the receiver counts consumed bytes and byte mismatches.
The expected transfer length remains in `run.py` or the test script, not in
transport state. Verification requires exact accepted, acknowledged, and
consumed lengths as well as zero mismatches. A read returns any available
in-order prefix; segment boundaries are not application message boundaries,
so Project 4 text messages need delimiters or explicit lengths.

Transport timer work scans a fixed table of at most ten sockets. Each retry is
limited to the current 56-byte sender window (at most four 14-byte segments),
and each routing event forwards one packet. Missing routes or a full network
send queue leave transport bytes and sequence ranges retained for the next
retry; every retry resolves its next hop again, so a repaired route can choose
a different neighbor. Neighbor discovery and distance-vector timers continue
on their own components while transport retries wait.

## Work plan

| Stage | Work | Exit check |
|---|---|---|
| 0. Packet and routing boundary (implemented) | Confirm current packet size; encode the TCP header; add routed TCP dispatch and `Project3C` | Project 3 builds; compiled packet/segment sizes are logged; Project 1/2 builds remain valid |
| 1. Connection setup (implemented) | Static tuple-indexed records, persistent listener, SYN/SYN-ACK/ACK, duplicate SYN handling, handshake retry | Repeatable 1-2-3 handshake; listener remains available |
| 2. Fixed sliding-window data (implemented) | Retained 128-byte send buffer, 14-byte segments, four-segment sender window, advertised peer-window limit, in-order receiver, cumulative ACK, go-back-N retry | Demo confirms 28 bytes outstanding, resumes after partial writes, and transfers 256 bytes byte-exactly over 1-2-3 |
| 3. Orderly close (implemented) | Drain data before FIN; peer FIN/final ACK; bounded retry and TIME_WAIT cleanup | Mid-review script completes setup, transfer, and teardown with state logs |
| 4. Longer sliding-window validation | Transfer at least 1,024 bytes; validate partial ACK advancement and sequence-range retransmission | Byte-exact long transfer with bounded sender and receiver buffers |
| 5. Zero-window validation | 128-byte receive occupancy; test consumer pauses/resumes; probe/recovery for lost reopening update | Sender stops at zero window, resumes, and receiver never overflows |
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
connects node 1 over the bidirectional 1-2-3 line, sends 256 patterned bytes
through the fixed four-segment window, and initiates close after all bytes are acknowledged.
It checks the connection-state transitions, exact pattern verification, and
both endpoints' cleanup. Full TOSSIM output is written to
`logs/project3-mid-review.log`.

For a live explanation, point out that the listener stays separate from its
accepted child; show the 8-byte transport header/14-byte data capacity, the
15-byte combined overhead, multiple outstanding segments, cumulative ACKs,
the 56-byte sender window, advertised
receive windows, and the fixed 3-second retry timer.
