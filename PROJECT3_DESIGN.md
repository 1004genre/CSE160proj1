# Project 3: Reliable Transport and Congestion Control

## Current status

- Project 2 has a separate distance-vector build and multi-hop routing path.
- `lib/interfaces/Transport.nc` defines the transport API, and
  `includes/socket.h` provides a starter socket record.
- There is no transport implementation, TCP packet format, Project 3 test
  generator/consumer, or transport test suite yet.
- The current network receive path handles ping and routing traffic; Project 3
  must add `PROTOCOL_TCP` dispatch and send through the normal routed path.

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

- Add `Project3C` / `Project3Node` as the application build, preserving the
  Project 2 build. Wire a `TransportC` service to the existing command and
  network layers.
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
- Initial transport header proposal: source port, destination port, flags,
  sequence, acknowledgment, and advertised window. Derive data length from the
  validated network payload length if the format permits. Use network-byte-
  order fields and check encoded sizes.
- **Before freezing the header**, measure the compiled `pack` and transport
  sizes. The assignment specifies a 29-byte packet-payload budget, while the
  current Project 2 build uses `TOSH_DATA_LENGTH=28` and an 8-byte network
  header. Resolve this against the course TinyOS configuration; do not increase
  the MTU. Document the actual combined overhead and resulting data capacity.
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

Use one fixed retransmission timeout initially, with a bounded retry count and
explicit failure reporting. A starting value of 2 seconds and five retries is a
testable proposal, not a final constant: measure it against the existing
per-hop send delay and stable multi-hop route before locking it. Duplicate SYN,
SYN-ACK, FIN, and final-ACK-loss cases must be idempotent.

## Work plan

| Stage | Work | Exit check |
|---|---|---|
| 0. Packet and routing boundary | Confirm MTU; define/encode TCP header; add routed TCP send and receive dispatch; add `Project3C` | Compile; packet-size checks pass; ordinary Project 2 ping still passes |
| 1. Connection setup | Static tuple-indexed records, persistent listener, SYN/SYN-ACK/ACK, duplicate handling, handshake timeout | Repeatable 1-2-3 handshake; no duplicate child allocation |
| 2. Stop-and-wait data | Incremental producer, retained send bytes, in-order receiver, cumulative ACK, duplicate suppression, data timeout | Short transfer is byte-exact; dropped data recovers; duplicate delivery is zero |
| 3. Orderly close | Client drains data before FIN; peer FIN/final ACK; retry and closing-state retention | Mid-review demo completes setup, data start, and teardown with state logs |
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

1. Build `Project3C`; load a stable bidirectional 1-2-3 topology and no-noise
   model; boot nodes and wait for Project 2 routes.
2. Run the server command at node 3 and the client command at node 1 using a
   distinct port pair. Show that the listener remains available while its
   connected child is established.
3. Transfer a short pattern such as bytes `0..31`; show sequence starts, ACKs,
   accepted/acknowledged/consumed totals, and exact receiver verification.
4. Request client close; show FIN/ACK state transitions and bounded cleanup.
5. Explain the current record fields and fixed retry policy, then describe how
   the next stage adds multiple outstanding byte ranges and the advertised
   receive window.

Keep test commands aligned with the assignment signatures:
`cmdTestServer(serverAddress, listenPort)`,
`cmdTestClient(clientAddress, serverAddress, srcPort, destPort, transferBytes)`,
and `cmdClientClose(clientAddress, serverAddress, srcPort, destPort)`.
Add pause/resume controls for the flow-control stage. The current dispatcher
has no-argument test events, so the Project 3 command wrapper must carry and
validate these arguments explicitly.