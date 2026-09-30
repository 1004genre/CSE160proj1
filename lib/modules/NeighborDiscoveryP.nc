#include "../../includes/channels.h"
#include "../../includes/packet.h"

enum {
   BEACON_PERIOD = 1000,
   NEIGHBOR_TIMEOUT = 5,
   MAX_NEIGHBORS = 32
};

module NeighborDiscoveryP {
   provides interface NeighborDiscovery;
   uses interface Timer<TMilli> as BeaconTimer;
   uses interface SimpleSend as Sender;
   uses interface Receive;
}
implementation {
   uint16_t neighbors[MAX_NEIGHBORS];
   uint8_t remainingBeacons[MAX_NEIGHBORS];
   uint8_t neighborCount = 0;
   void refreshNeighbor(uint16_t node);

   command void NeighborDiscovery.start() {
      call BeaconTimer.startPeriodic(BEACON_PERIOD); // continuously probes for direct neighbors.
   }

   command void NeighborDiscovery.print() {
      uint8_t i;
      dbg(NEIGHBOR_CHANNEL, "Node %d neighbors:\n", TOS_NODE_ID);
      for (i = 0; i < neighborCount; i++) {
         dbg(NEIGHBOR_CHANNEL, "  %d\n", neighbors[i]);
      }
   }

   event void BeaconTimer.fired() {
      pack beacon;
      uint8_t i;
      uint8_t j;

      // sends an existing packet format with TTL 1, so discovery stays one hop.
      beacon.src = TOS_NODE_ID;
      beacon.dest = AM_BROADCAST_ADDR;
      beacon.seq = 0;
      beacon.TTL = 1;
      beacon.protocol = PROTOCOL_NAME;
      memset(beacon.payload, 0, PACKET_MAX_PAYLOAD_SIZE);
      strcpy((char *)beacon.payload, "ND");
      call Sender.send(beacon, AM_BROADCAST_ADDR);

      // expires nodes that have not refreshed their liveness countdown.
      for (i = 0; i < neighborCount; i++) {
         if (remainingBeacons[i] > 0) remainingBeacons[i]--;
         if (remainingBeacons[i] == 0) {
            dbg(NEIGHBOR_CHANNEL, "Node %d lost neighbor %d\n", TOS_NODE_ID, neighbors[i]);
            for (j = i; j + 1 < neighborCount; j++) {
               neighbors[j] = neighbors[j + 1];
               remainingBeacons[j] = remainingBeacons[j + 1];
            }
            neighborCount--;
            i--;
         }
      }
   }

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *received;
      if (len != sizeof(pack)) return msg;
      received = (pack *)payload;
      // accepts only one-hop ND beacons, not ordinary flooded packets.
      if (received->protocol == PROTOCOL_NAME && received->TTL == 1 && strcmp((char *)received->payload, "ND") == 0 && received->src != TOS_NODE_ID) {
         refreshNeighbor(received->src);
      }
      return msg;
   }

   // avoids duplicate neighbors and refreshes a neighbor on each beacon.
   void refreshNeighbor(uint16_t node) {
      uint8_t i;
      for (i = 0; i < neighborCount; i++) {
         if (neighbors[i] == node) {
            remainingBeacons[i] = NEIGHBOR_TIMEOUT;
            return;
         }
      }
      if (neighborCount < MAX_NEIGHBORS) {
         neighbors[neighborCount] = node;
         remainingBeacons[neighborCount] = NEIGHBOR_TIMEOUT;
         neighborCount++;
         dbg(NEIGHBOR_CHANNEL, "Node %d discovered neighbor %d\n", TOS_NODE_ID, node);
      }
   }
}
