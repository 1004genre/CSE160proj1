//Author: UCM ANDES Lab
#ifndef PACKET_H
#define PACKET_H

#include "protocol.h"
#include "channels.h"

enum {
   PACKET_HEADER_LENGTH = 7,
   // The course budget is 29 bytes total; the compact network header uses 7.
   PACKET_MAX_PAYLOAD_SIZE = 29 - PACKET_HEADER_LENGTH,
   MAX_TTL = 15,
   AM_PACK = 6,
   AM_ROUTING = 7
};

// nx_struct serializes multibyte fields in network byte order; routing supplies next hop.
typedef nx_struct pack {
   nx_uint16_t dest; // End-to-end destination, not the current link neighbor.
   nx_uint16_t src;
   nx_uint16_t seq; // Network packet ID; transport byte sequence lives in the payload.
   nx_uint8_t ttlProtocol; // TTL 0..15 high nibble; routed protocol 0..15 low nibble.
   nx_uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
} pack;

// The combined TTL/protocol byte is accessed separately without losing either field.
#define PACK_TTL(p) (((p)->ttlProtocol >> 4) & 0x0f)
#define PACK_PROTOCOL(p) ((p)->ttlProtocol & 0x0f)
#define PACK_SET_TTL(p, value) \
   ((p)->ttlProtocol = (((value) & 0x0f) << 4) | PACK_PROTOCOL(p))

// The serialized network header and payload must exactly fill the 29-byte budget.
typedef char pack_must_fit_course_budget[sizeof(pack) == 29 ? 1 : -1];

void logPack(pack *input) {
   dbg(GENERAL_CHANNEL, "Src: %hhu Dest: %hhu Seq: %hhu TTL: %hhu Protocol:%hhu Payload: %s\n",
       input->src, input->dest, input->seq, PACK_TTL(input),
       PACK_PROTOCOL(input), input->payload);
}
#endif
