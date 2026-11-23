#include <Timer.h>
#include <string.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/channels.h"

module Project2Node {
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface AMPacket;
   uses interface SimpleSend as Sender;
   uses interface CommandHandler;
   uses interface NeighborDiscovery;
   uses interface DistanceVector;
}
implementation {
   uint16_t nextSequenceNumber = 0;

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl,
                 uint8_t protocol, uint16_t seq, const void *payload);
   bool sendRouted(pack *p);
   void processRouted(pack *p);

   event void Boot.booted() {
      call AMControl.start();
      call NeighborDiscovery.start();
      call DistanceVector.start();
   }

   event void AMControl.startDone(error_t err) {
      if (err != SUCCESS) call AMControl.start();
   }

   event void AMControl.stopDone(error_t err) {}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *received;
      if (len != sizeof(pack)) return msg;

      received = (pack *)payload;
      if (PACK_PROTOCOL(received) == PROTOCOL_PING ||
          PACK_PROTOCOL(received) == PROTOCOL_PINGREPLY) {
         if (call AMPacket.destination(msg) == AM_BROADCAST_ADDR) return msg;
         processRouted(received);
      }
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      pack p;
      makePack(&p, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING,
               nextSequenceNumber++, payload);
      if (destination == TOS_NODE_ID) processRouted(&p);
      else sendRouted(&p);
   }

   event void CommandHandler.floodPing(uint16_t destination, uint8_t *payload) {}

   event void CommandHandler.setRoutingMetric(uint8_t enabled) {
      call DistanceVector.setQualityMetric(enabled != 0);
   }

   event void CommandHandler.printNeighbors() {
      call NeighborDiscovery.print();
   }

   event void CommandHandler.printRouteTable() {
      call DistanceVector.print();
   }

   event void CommandHandler.printLinkState() {}

   event void CommandHandler.printDistanceVector() {
      call DistanceVector.print();
   }

   event void CommandHandler.setTestServer(uint16_t serverAddress,
                                           uint8_t listenPort) {}
   event void CommandHandler.setTestClient(uint16_t clientAddress,
                                           uint16_t serverAddress,
                                           uint8_t sourcePort,
                                           uint8_t destinationPort,
                                           uint16_t transferBytes) {}
   event void CommandHandler.closeTestClient(uint16_t clientAddress,
                                             uint16_t serverAddress,
                                             uint8_t sourcePort,
                                             uint8_t destinationPort) {}
   event void CommandHandler.pauseTestConsumer(uint16_t serverAddress,
                                               uint8_t listenPort,
                                               uint16_t clientAddress,
                                               uint8_t sourcePort) {}
   event void CommandHandler.resumeTestConsumer(uint16_t serverAddress,
                                                uint8_t listenPort,
                                                uint16_t clientAddress,
                                                uint8_t sourcePort) {}
   // Project 2 ignores the Project 3-only forwarding test hook.
   event void CommandHandler.setTransportDropRule(
      uint16_t sourceAddress, uint16_t destinationAddress,
      uint8_t sourcePort, uint8_t destinationPort,
      uint8_t kind, uint8_t field, uint16_t value, uint16_t occurrence) {}
   event void CommandHandler.setAppServer() {}
   event void CommandHandler.setAppClient() {}

   void processRouted(pack *p) {
      uint16_t next;
      uint8_t cost;

      if (PACK_TTL(p) == 0) {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped packet src %d dest %d seq %d: TTL expired\n",
             TOS_NODE_ID, p->src, p->dest, p->seq);
         return;
      }

      if (p->dest == TOS_NODE_ID) {
         if (PACK_PROTOCOL(p) == PROTOCOL_PING) {
            pack reply;
            makePack(&reply, TOS_NODE_ID, p->src, MAX_TTL,
                     PROTOCOL_PINGREPLY, nextSequenceNumber++, p->payload);
            dbg(ROUTING_CHANNEL, "Node %d delivered ping from %d seq %d\n",
                TOS_NODE_ID, p->src, p->seq);
            sendRouted(&reply);
         } else if (PACK_PROTOCOL(p) == PROTOCOL_PINGREPLY) {
            dbg(ROUTING_CHANNEL,
                "Node %d received ping reply from %d seq %d\n",
                TOS_NODE_ID, p->src, p->seq);
         }
         return;
      }

      if (PACK_TTL(p) <= 1) {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped packet src %d dest %d seq %d: TTL expired\n",
             TOS_NODE_ID, p->src, p->dest, p->seq);
         return;
      }

      if (!call DistanceVector.nextHop(p->dest, &next, &cost)) {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped packet src %d dest %d seq %d: no route\n",
             TOS_NODE_ID, p->src, p->dest, p->seq);
         return;
      }

      PACK_SET_TTL(p, PACK_TTL(p) - 1);
      if (call Sender.send(*p, next) == SUCCESS) {
         dbg(ROUTING_CHANNEL,
             "Node %d Routing Packet - src: %d, dest: %d, seq: %d, next hop: %d, cost: %d\n",
             TOS_NODE_ID, p->src, p->dest, p->seq, next, cost);
      } else {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped packet seq %d: send queue full\n",
             TOS_NODE_ID, p->seq);
      }
   }

   bool sendRouted(pack *p) {
      uint16_t next;
      uint8_t cost;

      if (p->dest == TOS_NODE_ID) return FALSE;
      if (!call DistanceVector.nextHop(p->dest, &next, &cost)) {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped packet src %d dest %d seq %d: no route\n",
             TOS_NODE_ID, p->src, p->dest, p->seq);
         return FALSE;
      }

      if (call Sender.send(*p, next) == SUCCESS) {
         dbg(ROUTING_CHANNEL,
             "Node %d Routing Packet - src: %d, dest: %d, seq: %d, next hop: %d, cost: %d\n",
             TOS_NODE_ID, p->src, p->dest, p->seq, next, cost);
         return TRUE;
      }

      dbg(ROUTING_CHANNEL,
          "Node %d dropped packet seq %d: send queue full\n",
          TOS_NODE_ID, p->seq);
      return FALSE;
   }

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl,
                 uint8_t protocol, uint16_t seq, const void *payload) {
      p->src = src;
      p->dest = dest;
      p->seq = seq;
      p->ttlProtocol = ((ttl & 0x0f) << 4) | (protocol & 0x0f);
      memcpy(p->payload, payload, PACKET_MAX_PAYLOAD_SIZE);
   }
}
