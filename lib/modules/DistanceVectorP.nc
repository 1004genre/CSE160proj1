#include "../../includes/packet.h"
#include "../../includes/channels.h"

enum {
   DV_INFINITY = 16,
   DV_DESTINATIONS = 256,
   DV_ENTRIES_PER_PACKET = 9,
   DV_UPDATE_MS = 30000,
   DV_EXPIRE_MS = 12000,
   DV_WITHDRAW_MS = 90000,
   DV_STAGE_MS = 100
};

module DistanceVectorP {
   provides interface DistanceVector;
   uses interface NeighborDiscovery as Neighbors;
   uses interface SimpleSend as Sender;
   uses interface Receive;
   uses interface AMPacket;
   uses interface Timer<TMilli> as AgeTimer;
   uses interface Timer<TMilli> as RoundTimer;
   uses interface Timer<TMilli> as StageTimer;
}
implementation {
   typedef struct routeEntry {
      uint16_t next;
      uint8_t cost;
      uint8_t valid;
      uint8_t known;
      uint32_t age;
      uint32_t withdrawal;
   } routeEntry;

   routeEntry routes[DV_DESTINATIONS];
   bool roundActive = FALSE;
   uint8_t neighborCursor = 0;
   uint16_t destinationCursor = 0;

   void invalidate(uint16_t dest, const char *reason);
   void sendNextPage();

   command void DistanceVector.start() {
      uint16_t i;
      for (i = 0; i < DV_DESTINATIONS; i++) {
         routes[i].known = FALSE;
         routes[i].valid = FALSE;
         routes[i].withdrawal = 0;
         routes[i].age = 0;
      }
      routes[TOS_NODE_ID].known = TRUE;
      routes[TOS_NODE_ID].valid = TRUE;
      routes[TOS_NODE_ID].cost = 0;
      routes[TOS_NODE_ID].next = TOS_NODE_ID;
      call AgeTimer.startPeriodic(1000);
      call RoundTimer.startPeriodic(DV_UPDATE_MS);
      call StageTimer.startPeriodic(DV_STAGE_MS);
      roundActive = TRUE;
      neighborCursor = 0;
      destinationCursor = 0;
   }

   command bool DistanceVector.nextHop(uint16_t destination, uint16_t *next, uint8_t *cost) {
      if (destination >= DV_DESTINATIONS || !routes[destination].valid) return FALSE;
      *next = routes[destination].next;
      *cost = routes[destination].cost;
      return TRUE;
   }

   command void DistanceVector.print() {
      uint16_t d;
      dbg(ROUTING_CHANNEL, "Node %d routing table\nDest NextHop Cost State\n", TOS_NODE_ID);
      for (d = 0; d < DV_DESTINATIONS; d++) {
         if (routes[d].known) {
            if (routes[d].valid)
               dbg(ROUTING_CHANNEL, "%d %d %d VALID\n", d, routes[d].next, routes[d].cost);
            else
               dbg(ROUTING_CHANNEL, "%d - INF UNREACHABLE\n", d);
         }
      }
   }

   event void RoundTimer.fired() {
      roundActive = TRUE;
      neighborCursor = 0;
      destinationCursor = 0;
   }

   event void StageTimer.fired() {
      if (roundActive) sendNextPage();
   }

   event void AgeTimer.fired() {
      uint16_t d;
      uint8_t n;
      if (!roundActive && call Neighbors.count() > 0) {\n         roundActive = TRUE;\n         neighborCursor = 0;\n         destinationCursor = 0;\n      }\n      for (n = 0; n < call Neighbors.count(); n++) {
         uint16_t id = call Neighbors.neighborAt(n);
         if (id < DV_DESTINATIONS && id != TOS_NODE_ID) {
            routes[id].known = TRUE;
            routes[id].valid = TRUE;
            routes[id].next = id;
            routes[id].cost = 1;
            routes[id].age = 0;
            routes[id].withdrawal = 0;
         }
      }
      for (d = 0; d < DV_DESTINATIONS; d++) {
         if (d == TOS_NODE_ID) continue;
         if (routes[d].valid && routes[d].cost == 1 &&
             !call Neighbors.isNeighbor(d)) {
            invalidate(d, "neighbor expired");
         } else if (routes[d].valid && routes[d].cost > 1) {
            routes[d].age += 1000;
            if (routes[d].age >= DV_EXPIRE_MS)
               invalidate(d, "advertisement expired");
         }
         if (!routes[d].valid && routes[d].withdrawal > 0) {
            if (routes[d].withdrawal <= 1000) {
               routes[d].withdrawal = 0;
               routes[d].known = FALSE;
            } else {
               routes[d].withdrawal -= 1000;
            }
         }
      }
   }

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *adv = (pack *)payload;
      uint16_t sender;
      uint8_t count, i;
      if (len != sizeof(pack) || adv->protocol != PROTOCOL_DV) return msg;
      sender = call AMPacket.source(msg);
      if (sender >= DV_DESTINATIONS || !call Neighbors.isNeighbor(sender) ||
          adv->dest != TOS_NODE_ID) return msg;
      count = adv->payload[0];
      if (count > DV_ENTRIES_PER_PACKET ||
          (uint16_t)count * 2 + 1 > PACKET_MAX_PAYLOAD_SIZE) {
         dbg(ROUTING_CHANNEL, "Node %d discarded malformed DV from %d\n", TOS_NODE_ID, sender);
         return msg;
      }
      for (i = 0; i < count; i++) {
         uint16_t dest = adv->payload[1 + 2 * i];
         uint8_t advertised = adv->payload[2 + 2 * i];
         uint8_t candidate;
         bool selected;
         if (dest >= DV_DESTINATIONS || dest == TOS_NODE_ID || advertised > DV_INFINITY) continue;
         selected = routes[dest].valid && routes[dest].next == sender;
         candidate = advertised >= DV_INFINITY ? DV_INFINITY :
                     (advertised >= DV_INFINITY - 1 ? DV_INFINITY : advertised + 1);
         if (candidate >= DV_INFINITY) {
            if (selected) invalidate(dest, "poisoned by next hop");
            continue;
         }
         if (selected || !routes[dest].valid || candidate < routes[dest].cost) {
            bool changed = !routes[dest].valid || routes[dest].next != sender ||
                           routes[dest].cost != candidate;
            routes[dest].known = TRUE;
            routes[dest].valid = TRUE;
            routes[dest].next = sender;
            routes[dest].cost = candidate;
            routes[dest].age = 0;
            routes[dest].withdrawal = 0;
            if (changed)
               dbg(ROUTING_CHANNEL, "Node %d route %d via %d cost %d\n",
                   TOS_NODE_ID, dest, sender, candidate);
         } else if (routes[dest].valid && candidate == routes[dest].cost &&
                    routes[dest].next == sender) {
            routes[dest].age = 0;
         }
      }
      return msg;
   }

   void invalidate(uint16_t dest, const char *reason) {
      if (dest == TOS_NODE_ID || !routes[dest].valid) return;
      routes[dest].valid = FALSE;
      routes[dest].known = TRUE;
      routes[dest].cost = DV_INFINITY;
      routes[dest].age = 0;
      if (routes[dest].withdrawal == 0) routes[dest].withdrawal = DV_WITHDRAW_MS;
      dbg(ROUTING_CHANNEL, "Node %d route %d unreachable (%s)\n", TOS_NODE_ID, dest, reason);
   }

   void sendNextPage() {
      pack adv;
      uint16_t neighbor;
      uint8_t count = 0;
      uint16_t scanned;
      uint8_t i;
      uint8_t neighborCount = call Neighbors.count();\n      error_t sendError;
      if (neighborCursor >= neighborCount) {
         roundActive = FALSE;
         return;
      }
      neighbor = call Neighbors.neighborAt(neighborCursor);
      if (neighbor >= DV_DESTINATIONS) {
         neighborCursor++;
         destinationCursor = 0;
         return;
      }
      adv.dest = neighbor;
      adv.src = TOS_NODE_ID;
      adv.seq = (uint16_t)(destinationCursor / DV_ENTRIES_PER_PACKET);
      adv.TTL = 1;
      adv.protocol = PROTOCOL_DV;
      memset(adv.payload, 0, PACKET_MAX_PAYLOAD_SIZE);
      for (scanned = destinationCursor; scanned < DV_DESTINATIONS &&
           count < DV_ENTRIES_PER_PACKET; scanned++) {
         if (!routes[scanned].known) continue;
         adv.payload[1 + 2 * count] = (uint8_t)scanned;
         if (scanned == TOS_NODE_ID)
            adv.payload[2 + 2 * count] = 0;
         else if (routes[scanned].valid && routes[scanned].next != neighbor)
            adv.payload[2 + 2 * count] = routes[scanned].cost;
         else
            adv.payload[2 + 2 * count] = DV_INFINITY;
         count++;
      }
      adv.payload[0] = count;
      call Sender.send(adv, neighbor);
      destinationCursor = scanned;
      if (destinationCursor >= DV_DESTINATIONS) {
         neighborCursor++;
         destinationCursor = 0;
      }
   }
}
