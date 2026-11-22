#ifndef __TCP_H__
#define __TCP_H__

#include "packet.h"

enum {
   TCP_HEADER_SIZE = 9,
   // Transport data shares the 21-byte network payload with this 9-byte header.
   TCP_DATA_SIZE = PACKET_MAX_PAYLOAD_SIZE - TCP_HEADER_SIZE,
   TCP_FLAG_SYN = 1,
   TCP_FLAG_ACK = 2,
   TCP_FLAG_DATA = 4,
   TCP_FLAG_FIN = 8,
   TCP_RTO_SECONDS = 3,
   TCP_TIME_WAIT_SECONDS = 6,
   TCP_MAX_RETRIES = 5,
   TCP_TIMER_INTERVAL_MS = 1000
};

// SYN: seq starts setup; SYN|ACK carries its own seq and ack; DATA uses seq/len;
// ACK uses ack only; FIN consumes one seq value and carries the current ack.
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
