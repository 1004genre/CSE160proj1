#include "../../includes/packet.h"
#include "../../includes/channels.h"

// Added: implements Project 1 broadcast flooding, duplicate suppression, and ping replies.
module FloodingP {
   provides interface Flooding;
   uses interface SimpleSend as Sender;
}
implementation {
   enum { SEEN_PACKET_COUNT = 64 };

   typedef struct seenPacket {
      uint16_t src;
      uint16_t seq;
   } seenPacket;

   pack sendPackage;
   seenPacket seenPackets[SEEN_PACKET_COUNT];
   uint8_t seenCount = 0;
   uint8_t nextSeenSlot = 0;
   uint16_t nextSequenceNumber = 0;

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl, uint8_t protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   bool wasSeen(pack *p);
   void remember(pack *p);
   void flood(pack *p);

   // Added: originates a unique ping and starts its broadcast flood.
   command void Flooding.ping(uint16_t destination, uint8_t *payload) {
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING,
               nextSequenceNumber++, payload, PACKET_MAX_PAYLOAD_SIZE);
      remember(&sendPackage);
      dbg(FLOODING_CHANNEL, "Node %d sent ping toward %d seq %d\n",
          TOS_NODE_ID, destination, sendPackage.seq);
      flood(&sendPackage);
   }

   // Added: processes one received ping or reply, forwarding only first arrivals.
   command void Flooding.receive(pack *received) {
      if (received->protocol != PROTOCOL_PING &&
          received->protocol != PROTOCOL_PINGREPLY) {
         return;
      }
      if (wasSeen(received)) {
         dbg(FLOODING_CHANNEL, "Node %d dropped duplicate from %d seq %d\n",
             TOS_NODE_ID, received->src, received->seq);
         return;
      }

      remember(received);
      dbg(FLOODING_CHANNEL, "Node %d received packet from %d seq %d\n",
          TOS_NODE_ID, received->src, received->seq);

      if (received->dest == TOS_NODE_ID) {
         if (received->protocol == PROTOCOL_PING) {
            makePack(&sendPackage, TOS_NODE_ID, received->src, MAX_TTL,
                     PROTOCOL_PINGREPLY, nextSequenceNumber++, (uint8_t *)received->payload,
                     PACKET_MAX_PAYLOAD_SIZE);
            remember(&sendPackage);
            dbg(FLOODING_CHANNEL, "Node %d sent ping reply to %d seq %d\n",
                TOS_NODE_ID, received->src, sendPackage.seq);
            flood(&sendPackage);
         } else {
            dbg(FLOODING_CHANNEL, "Node %d received ping reply from %d seq %d\n",
                TOS_NODE_ID, received->src, received->seq);
         }
      } else if (received->TTL > 1) {
         received->TTL = received->TTL - 1;
         flood(received);
      }
   }

   bool wasSeen(pack *p) {
      uint8_t i;
      for (i = 0; i < seenCount; i++) {
         if (seenPackets[i].src == p->src && seenPackets[i].seq == p->seq) {
            return TRUE;
         }
      }
      return FALSE;
   }

   void remember(pack *p) {
      if (seenCount < SEEN_PACKET_COUNT) {
         seenPackets[seenCount].src = p->src;
         seenPackets[seenCount].seq = p->seq;
         seenCount++;
      } else {
         seenPackets[nextSeenSlot].src = p->src;
         seenPackets[nextSeenSlot].seq = p->seq;
         nextSeenSlot = (nextSeenSlot + 1) % SEEN_PACKET_COUNT;
      }
   }

   void flood(pack *p) {
      call Sender.send(*p, AM_BROADCAST_ADDR);
      dbg(FLOODING_CHANNEL, "Node %d broadcast packet from %d seq %d\n",
          TOS_NODE_ID, p->src, p->seq);
   }

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl,
                 uint8_t protocol, uint16_t seq, uint8_t *payload, uint8_t length) {
      p->src = src;
      p->dest = dest;
      p->TTL = ttl;
      p->seq = seq;
      p->protocol = protocol;
      memcpy(p->payload, payload, length);
   }
}
