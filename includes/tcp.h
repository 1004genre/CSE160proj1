#ifndef __TCP_H__
#define __TCP_H__

#include "packet.h"

enum {
   TCP_HEADER_SIZE = 9,
   // Transport data shares the 21-byte network payload with this 9-byte header.
   TCP_DATA_SIZE = PACKET_MAX_PAYLOAD_SIZE - TCP_HEADER_SIZE,
   // Both peers start at this ISN; each socket tracks its own next sequence value.
   TCP_INITIAL_SEQUENCE = 0,
   // No-wrap cap: SYN + 1,024 data bytes + FIN ends at sequence 1,026.
   TCP_MAX_TRANSFER_BYTES = 1024,
   TCP_FLAG_SYN = 1,
   TCP_FLAG_ACK = 2,
   TCP_FLAG_DATA = 4,
   TCP_FLAG_FIN = 8,
   TCP_FLAG_PROBE = 16, // Requests an ACK/window update; consumes no sequence space.
   TCP_RTO_SECONDS = 3, // Wait three seconds before retrying an outstanding segment.
   TCP_MAX_RETRIES = 5, // Fail after five retries plus one final timeout interval.
   // 18s retains tuples for the 3s initial RTO and all five 3s retries.
   TCP_TIME_WAIT_SECONDS = TCP_RTO_SECONDS * (TCP_MAX_RETRIES + 1),
   // Four maximum-sized segments may be outstanding when the peer window permits.
   TCP_SENDER_WINDOW_SIZE = TCP_DATA_SIZE * 4,
   TCP_FAILURE_RETRY_LIMIT = 1,
   TCP_TIMER_INTERVAL_MS = 1000
};

// SYN/SYN-ACK carry no data; SYN-ACK seq and ack are independent values.
// DATA carries seq/len only; pure ACK carries ack only; FIN consumes one seq.
typedef nx_struct tcp_segment_t {
   nx_uint8_t srcPort;
   nx_uint8_t destPort;
   nx_uint8_t flags;
   nx_uint8_t dataLength;
   nx_uint16_t seq;
   nx_uint16_t ack;
   nx_uint8_t window;
   nx_uint8_t data[TCP_DATA_SIZE];
} tcp_segment_t;

#endif
