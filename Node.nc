// put flooding in a different module, like neighbordiscovery

#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node {
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface SimpleSend as Sender;
   uses interface CommandHandler;
   uses interface NeighborDiscovery; 
}
implementation {
   // fixed-size packet history prevents floods from circulating in cycles.
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

   event void Boot.booted() {
      call AMControl.start();
      call NeighborDiscovery.start(); // starts the periodic one-hop beacon timer.
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err) {
      if (err == SUCCESS) {
         dbg(GENERAL_CHANNEL, "Radio On\n");
      } else {
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err) {}

   // receives, suppresses duplicates, delivers, and rebroadcasts floods.
   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *received;
      if (len != sizeof(pack)) return msg;
      received = (pack *)payload;
      if (received->protocol != PROTOCOL_PING && received->protocol != PROTOCOL_PINGREPLY) return msg;
      if (wasSeen(received)) {
         dbg(FLOODING_CHANNEL, "Node %d dropped duplicate from %d seq %d\n", TOS_NODE_ID, received->src, received->seq);
         return msg;
      }
      remember(received);
      dbg(FLOODING_CHANNEL, "Node %d received packet from %d seq %d\n", TOS_NODE_ID, received->src, received->seq);
      if (received->dest == TOS_NODE_ID) {
         if (received->protocol == PROTOCOL_PING) {
            // the destination creates and floods a reply to the original source.
            makePack(&sendPackage, TOS_NODE_ID, received->src, MAX_TTL, PROTOCOL_PINGREPLY, nextSequenceNumber++, received->payload, PACKET_MAX_PAYLOAD_SIZE);
            remember(&sendPackage);
            dbg(FLOODING_CHANNEL, "Node %d sent ping reply to %d\n", TOS_NODE_ID, received->src);
            flood(&sendPackage);
         } else {
            dbg(FLOODING_CHANNEL, "Node %d received ping reply from %d\n", TOS_NODE_ID, received->src);
         }
      } else if (received->TTL > 1) {
         received->TTL--;
         flood(received);
      }
      return msg;
   }

   // injects a ping as a broadcast flood instead of a direct radio send.
   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, nextSequenceNumber++, payload, PACKET_MAX_PAYLOAD_SIZE);
      remember(&sendPackage);
      dbg(FLOODING_CHANNEL, "Node %d sent ping toward %d\n", TOS_NODE_ID, destination);
      flood(&sendPackage);
   }

   event void CommandHandler.printNeighbors() {
      call NeighborDiscovery.print(); // dumps the neighbor table for the command handler.
   }
   event void CommandHandler.printRouteTable() {}
   event void CommandHandler.printLinkState() {}
   event void CommandHandler.printDistanceVector() {}
   event void CommandHandler.setTestServer() {}
   event void CommandHandler.setTestClient() {}
   event void CommandHandler.setAppServer() {}
   event void CommandHandler.setAppClient() {}

   // identifies a flood using only the supplied source and sequence header fields.
   bool wasSeen(pack *p) {
      uint8_t i;
      for (i = 0; i < seenCount; i++) {
         if (seenPackets[i].src == p->src && seenPackets[i].seq == p->seq) return TRUE;
      }
      return FALSE;
   }

   // uses unused history slots first, then replaces entries circularly to bound memory.
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

   // xbroadcasts through SimpleSend so every directly connected node receives the flood.
   void flood(pack *p) {
      call Sender.send(*p, AM_BROADCAST_ADDR);
      dbg(FLOODING_CHANNEL, "Node %d broadcast packet from %d seq %d\n", TOS_NODE_ID, p->src, p->seq);
   }

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl, uint8_t protocol, uint16_t seq, uint8_t *payload, uint8_t length) {
      p->src = src;
      p->dest = dest;
      p->TTL = ttl;
      p->seq = seq;
      p->protocol = protocol;
      memcpy(p->payload, payload, length);
   }
}
