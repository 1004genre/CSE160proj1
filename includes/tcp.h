#ifndef __TCP_H__
#define __TCP_H__

#include "packet.h"

enum {
   TCP_HEADER_SIZE = 8,
   // The 22-byte network payload holds this compact header plus 14 data bytes.
   TCP_DATA_SIZE = PACKET_MAX_PAYLOAD_SIZE - TCP_HEADER_SIZE,
   // Both peers start at this ISN; each socket tracks its own next sequence value.
   TCP_INITIAL_SEQUENCE = 0,
   // No-wrap cap: SYN + 1,024 data bytes + FIN ends at sequence 1,026.
   TCP_MAX_TRANSFER_BYTES = 1024,
   // Low five bits encode five controls or a data length; high bits stay zero.
   TCP_CODE_SYN = 0,
   TCP_CODE_ACK = 1,
   TCP_CODE_SYN_ACK = 2,
   TCP_CODE_FIN = 3,
   TCP_CODE_PROBE = 4, // Requests an ACK/window update; consumes no sequence space.
   TCP_CODE_DATA_BASE = 4, // Data code is base + length, so 5..18 encode 1..14.
   TCP_KIND_DATA = 255, // Internal sendSegment selector; never appears on the wire.
   TCP_RTO_SECONDS = 3, // Wait three seconds before retrying an outstanding segment.
   TCP_MAX_RETRIES = 5, // Fail after five retries plus one final timeout interval.
   // 18s retains tuples for the 3s initial RTO and all five 3s retries.
   TCP_TIME_WAIT_SECONDS = TCP_RTO_SECONDS * (TCP_MAX_RETRIES + 1),
   // Four maximum-sized segments may be outstanding when the peer window permits.
   TCP_SENDER_WINDOW_SIZE = TCP_DATA_SIZE * 4,
   // A send event submits at most two data packets; remaining work resumes later.
   TCP_DATA_BATCH_SEGMENTS = 2,
   TCP_FAILURE_RETRY_LIMIT = 1,
   TCP_TIMER_INTERVAL_MS = 1000
};

// nx fields are network byte order; this compact layout has no alignment padding.
// SYN-ACK has distinct seq/ack; pure ACK has no data; FIN consumes one seq.
typedef nx_struct tcp_segment_t {
   nx_uint8_t srcPort;
   nx_uint8_t destPort;
   nx_uint8_t kindLength; // Message kind or data length, encoded in low five bits.
   nx_uint16_t seq;       // Transport byte position, independent of pack.seq.
   nx_uint16_t ack;       // Next byte expected; SYN-ACK keeps seq/ack distinct.
   nx_uint8_t window;
   nx_uint8_t data[TCP_DATA_SIZE];
} tcp_segment_t;

typedef char tcp_segment_must_fill_payload[
   sizeof(tcp_segment_t) == PACKET_MAX_PAYLOAD_SIZE ? 1 : -1];

#endif
