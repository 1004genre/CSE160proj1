#include <Timer.h>
#include <string.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/channels.h"

module Node {
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface AMPacket;
   uses interface SimpleSend as Sender;
   uses interface CommandHandler;
   uses interface NeighborDiscovery;
   uses interface Flooding;
   uses interface DistanceVector;
}
implementation {
   uint16_t nextSequenceNumber = 0;

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl,
                 uint8_t protocol, uint16_t seq, uint8_t *payload);
   bool sendRouted(pack *p);
   void processRouted(pack *p);

   event void Boot.booted() {
      call AMControl.start();
      call NeighborDiscovery.start();
      call DistanceVector.start();
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

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *received;

      if (len != sizeof(pack)) return msg;
      received = (pack *)payload;

      if (received->protocol == PROTOCOL_PING ||
          received->protocol == PROTOCOL_PINGREPLY) {
         if (call AMPacket.destination(msg) == AM_BROADCAST_ADDR) {
            call Flooding.receive(received);
         } else {
            processRouted(received);
         }
      }

      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      pack p;

      makePack(&p, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING,
               nextSequenceNumber++, payload);

      if (destination == TOS_NODE_ID) {
         processRouted(&p);
      } else {
         sendRouted(&p);
      }
   }

   event void CommandHandler.floodPing(uint16_t destination, uint8_t *payload) {
      call Flooding.ping(destination, payload);
   }

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
   event void CommandHandler.setTestServer() {}
   event void CommandHandler.setTestClient() {}
   event void CommandHandler.setAppServer() {}
   event void CommandHandler.setAppClient() {}

   void processRouted(pack *p) {
      uint16_t next;
      uint8_t cost;

      if (p->TTL == 0) {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped packet src %d dest %d seq %d: TTL expired\n",
             TOS_NODE_ID, p->src, p->dest, p->seq);
         return;
      }

      if (p->dest == TOS_NODE_ID) {
         if (p->protocol == PROTOCOL_PING) {
            pack reply;

            makePack(&reply, TOS_NODE_ID, p->src, MAX_TTL,
                     PROTOCOL_PINGREPLY, nextSequenceNumber++, p->payload);

            dbg(ROUTING_CHANNEL, "Node %d delivered ping from %d seq %d\n",
                TOS_NODE_ID, p->src, p->seq);
            sendRouted(&reply);
         } else if (p->protocol == PROTOCOL_PINGREPLY) {
            dbg(ROUTING_CHANNEL,
                "Node %d received ping reply from %d seq %d\n",
                TOS_NODE_ID, p->src, p->seq);
         }
         return;
      }

      if (p->TTL <= 1) {
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

      p->TTL--;

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
                 uint8_t protocol, uint16_t seq, uint8_t *payload) {
      p->src = src;
      p->dest = dest;
      p->TTL = ttl;
      p->seq = seq;
      p->protocol = protocol;
      memcpy(p->payload, payload, PACKET_MAX_PAYLOAD_SIZE);
   }
}
