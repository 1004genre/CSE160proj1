#include "../../includes/packet.h"
#include "../../includes/channels.h"

enum {
   DV_INFINITY = 16,
   DV_QUALITY_INFINITY = 255,
   DV_DESTINATIONS = 256,
   DV_ENTRIES_PER_PACKET = 9,
   DV_EXPIRE_MS = 300000,
   DV_WITHDRAW_MS = 1200000,
   DV_STAGE_MS = 250
};

module DistanceVectorP {
   provides interface DistanceVector;
   uses interface NeighborDiscovery as Neighbors;
   uses interface SimpleSend as Sender;
   uses interface Receive;
   uses interface AMPacket;
   uses interface Timer<TMilli> as AgeTimer;
   uses interface Timer<TMilli> as StageTimer;
   uses interface Random;
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
   bool ageTimerStarted = FALSE;
   bool qualityMetricEnabled = FALSE;

   void invalidate(uint16_t dest, const char *reason);
   void sendNextPage();
   uint8_t infinityCost();
   uint8_t linkCost(uint16_t neighbor);
   void updateNeighborRoutes();

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
      qualityMetricEnabled = FALSE;
      call AgeTimer.startOneShot(1 + call Random.rand16() % 1000);
      call StageTimer.startPeriodic(DV_STAGE_MS);
      roundActive = FALSE;
   }

   command void DistanceVector.setQualityMetric(bool enabled) {
      uint16_t i;
      if (qualityMetricEnabled == enabled) return;

      qualityMetricEnabled = enabled;
      for (i = 0; i < DV_DESTINATIONS; i++) {
         if (i == TOS_NODE_ID) continue;
         routes[i].known = FALSE;
         routes[i].valid = FALSE;
         routes[i].age = 0;
         routes[i].withdrawal = 0;
      }
      routes[TOS_NODE_ID].known = TRUE;
      routes[TOS_NODE_ID].valid = TRUE;
      routes[TOS_NODE_ID].cost = 0;
      routes[TOS_NODE_ID].next = TOS_NODE_ID;
      roundActive = FALSE;
      updateNeighborRoutes();
      dbg(ROUTING_CHANNEL, "Node %d quality metric enabled %d\n",
          TOS_NODE_ID, qualityMetricEnabled);
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

   event void StageTimer.fired() {
      if (roundActive) sendNextPage();
   }

   event void AgeTimer.fired() {
      uint16_t d;
      if (!roundActive && call Neighbors.count() > 0) {
         roundActive = TRUE;
         neighborCursor = 0;
         destinationCursor = 0;
      }
      updateNeighborRoutes();
      for (d = 0; d < DV_DESTINATIONS; d++) {
         if (d == TOS_NODE_ID) continue;
         if (routes[d].valid && !call Neighbors.isNeighbor(routes[d].next)) {
            invalidate(d, "next hop expired");
         } else if (routes[d].valid && routes[d].next != d) {
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
      if (!ageTimerStarted) {
         ageTimerStarted = TRUE;
         call AgeTimer.startPeriodic(1000);
      }
   }

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *adv = (pack *)payload;
      uint16_t sender;
      uint8_t count, i;
      uint8_t localLinkCost;
      uint16_t infinity;
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
      infinity = infinityCost();
      localLinkCost = linkCost(sender);
      if (localLinkCost >= infinity) {
         uint16_t dest;
         for (dest = 0; dest < DV_DESTINATIONS; dest++) {
            if (routes[dest].valid && routes[dest].next == sender)
               invalidate(dest, "link quality reached infinity");
         }
         return msg;
      }
      for (i = 0; i < count; i++) {
         uint16_t dest = adv->payload[1 + 2 * i];
         uint8_t advertised = adv->payload[2 + 2 * i];
         uint16_t candidate;
         bool selected;
         if (dest >= DV_DESTINATIONS || dest == TOS_NODE_ID ||
             advertised > infinity) continue;
         selected = routes[dest].valid && routes[dest].next == sender;
         if (advertised >= infinity) {
            if (selected) invalidate(dest, "poisoned by next hop");
            continue;
         }
         candidate = (uint16_t)advertised + localLinkCost;
         if (candidate >= infinity) {
            if (selected) invalidate(dest, "path cost reached infinity");
            continue;
         }
         if (selected || !routes[dest].valid || candidate < routes[dest].cost) {
            bool changed = !routes[dest].valid || routes[dest].next != sender ||
                           routes[dest].cost != candidate;
            routes[dest].known = TRUE;
            routes[dest].valid = TRUE;
            routes[dest].next = sender;
            routes[dest].cost = (uint8_t)candidate;
            routes[dest].age = 0;
            routes[dest].withdrawal = 0;
            if (changed)
               dbg(ROUTING_CHANNEL, "Node %d route %d via %d cost %d\n",
                   TOS_NODE_ID, dest, sender, (uint8_t)candidate);
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
      routes[dest].cost = infinityCost();
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
      uint8_t neighborCount = call Neighbors.count();
      error_t sendError;
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
            adv.payload[2 + 2 * count] = infinityCost();
         count++;
      }
      adv.payload[0] = count;
      sendError = call Sender.send(adv, neighbor);
      if (sendError != SUCCESS) {
         dbg(ROUTING_CHANNEL, "Node %d deferred DV page for neighbor %d (send queue full)\n",
             TOS_NODE_ID, neighbor);
         return;
      }
      for (i = 0; i < count; i++)
         dbg(ROUTING_CHANNEL, "Node %d advert to %d: dest %d cost %d\n",
             TOS_NODE_ID, neighbor, adv.payload[1 + 2 * i], adv.payload[2 + 2 * i]);
      destinationCursor = scanned;
      if (destinationCursor >= DV_DESTINATIONS) {
         neighborCursor++;
         destinationCursor = 0;
      }
   }

   uint8_t infinityCost() {
      return qualityMetricEnabled ? DV_QUALITY_INFINITY : DV_INFINITY;
   }

   uint8_t linkCost(uint16_t neighbor) {
      return qualityMetricEnabled ? call Neighbors.qualityCost(neighbor) : 1;
   }

   void updateNeighborRoutes() {
      uint8_t n;
      uint8_t infinity = infinityCost();
      for (n = 0; n < call Neighbors.count(); n++) {
         uint16_t id = call Neighbors.neighborAt(n);
         uint8_t cost;
         bool changed;
         if (id >= DV_DESTINATIONS || id == TOS_NODE_ID) continue;
         cost = linkCost(id);
         if (cost >= infinity) {
            if (routes[id].valid && routes[id].next == id)
               invalidate(id, "direct link quality too low");
            continue;
         }
         if (routes[id].valid && routes[id].next != id &&
             cost >= routes[id].cost) continue;

         changed = !routes[id].valid || routes[id].next != id ||
                   routes[id].cost != cost;
         routes[id].known = TRUE;
         routes[id].valid = TRUE;
         routes[id].next = id;
         routes[id].cost = cost;
         routes[id].age = 0;
         routes[id].withdrawal = 0;
         if (changed)
            dbg(ROUTING_CHANNEL, "Node %d route %d via %d cost %d\n",
                TOS_NODE_ID, id, id, cost);
      }
   }
}
