#include "../../includes/channels.h"
#include "../../includes/packet.h"

enum {
   BEACON_PERIOD = 1000,
   NEIGHBOR_TIMEOUT = 5,
   MAX_NEIGHBORS = 32,
   QUALITY_SCALE = 8
};

module NeighborDiscoveryP {
   provides interface NeighborDiscovery;
   uses interface Timer<TMilli> as BeaconTimer;
   uses interface SimpleSend as Sender;
   uses interface Receive;
   uses interface Random;
}
implementation {
   uint16_t neighbors[MAX_NEIGHBORS];
   uint8_t remainingBeacons[MAX_NEIGHBORS];
   uint8_t linkQuality[MAX_NEIGHBORS];
   uint16_t pendingBeacon[MAX_NEIGHBORS];
   bool beaconPending[MAX_NEIGHBORS];
   uint8_t neighborCount = 0;
   bool beaconTimerStarted = FALSE;
   uint16_t nextBeaconSequence = 0;
   void refreshNeighbor(uint16_t node);
   void recordBeaconResult(uint16_t node, uint16_t sequence);
   uint8_t qualityCostForNode(uint16_t node);
   void sendNeighborMessage(uint16_t destination, uint8_t kind,
                            uint16_t sequence);

   // Start periodic neighbor probes after a randomized initial delay.
   command void NeighborDiscovery.start() {
      call BeaconTimer.startOneShot(1 + call Random.rand16() % BEACON_PERIOD);
   }

   command uint8_t NeighborDiscovery.count() {
      return neighborCount;
   }

   command uint16_t NeighborDiscovery.neighborAt(uint8_t index) {
      if (index >= neighborCount) return AM_BROADCAST_ADDR;
      return neighbors[index];
   }

   command bool NeighborDiscovery.isNeighbor(uint16_t node) {
      uint8_t i;
      for (i = 0; i < neighborCount; i++) {
         if (neighbors[i] == node) return TRUE;
      }
      return FALSE;
   }

   command uint8_t NeighborDiscovery.qualityCost(uint16_t node) {
      return qualityCostForNode(node);
   }

   // Convert the smoothed beacon delivery score into a bounded ETX-like cost.
   uint8_t qualityCostForNode(uint16_t node) {
      uint8_t i;
      uint16_t cost;
      for (i = 0; i < neighborCount; i++) {
         if (neighbors[i] == node) {
            if (linkQuality[i] == 0) return 255;
            cost = (255 * QUALITY_SCALE + linkQuality[i] - 1) /
                   linkQuality[i];
            return cost >= 255 ? 255 : (uint8_t)cost;
         }
      }
      return 255;
   }

   command void NeighborDiscovery.print() {
      uint8_t i;
      dbg(NEIGHBOR_CHANNEL, "Node %d neighbors (quality 0-255):\n", TOS_NODE_ID);
      for (i = 0; i < neighborCount; i++)
         dbg(NEIGHBOR_CHANNEL, "  %d quality %d cost %d\n", neighbors[i],
             linkQuality[i], qualityCostForNode(neighbors[i]));
   }

   // Probe neighbors, decay missed acknowledgments, and expire inactive links.
   event void BeaconTimer.fired() {
      pack beacon;
      uint8_t i, j;
      error_t sendResult;
      beacon.src = TOS_NODE_ID;
      beacon.dest = AM_BROADCAST_ADDR;
      beacon.seq = nextBeaconSequence++;
      beacon.TTL = 1;
      beacon.protocol = PROTOCOL_NAME;
      memset(beacon.payload, 0, PACKET_MAX_PAYLOAD_SIZE);
      beacon.payload[0] = 'N';
      beacon.payload[1] = 'D';
      for (i = 0; i < neighborCount; i++) {
         if (beaconPending[i]) {
            linkQuality[i] = ((uint16_t)linkQuality[i] * 7) / 8;
            beaconPending[i] = FALSE;
         }
      }
      sendResult = call Sender.send(beacon, AM_BROADCAST_ADDR);
      if (sendResult == SUCCESS) {
         for (i = 0; i < neighborCount; i++) {
            pendingBeacon[i] = beacon.seq;
            beaconPending[i] = TRUE;
         }
      }
      if (!beaconTimerStarted) {
         beaconTimerStarted = TRUE;
         call BeaconTimer.startPeriodic(BEACON_PERIOD);
      }

      for (i = 0; i < neighborCount; i++) {
         if (remainingBeacons[i] > 0) remainingBeacons[i]--;
         if (remainingBeacons[i] == 0) {
            dbg(NEIGHBOR_CHANNEL, "Node %d lost neighbor %d\n",
                TOS_NODE_ID, neighbors[i]);
            for (j = i; j + 1 < neighborCount; j++) {
               neighbors[j] = neighbors[j + 1];
               remainingBeacons[j] = remainingBeacons[j + 1];
               linkQuality[j] = linkQuality[j + 1];
               pendingBeacon[j] = pendingBeacon[j + 1];
               beaconPending[j] = beaconPending[j + 1];
            }
            neighborCount--;
            i--;
         }
      }
   }

   // Handle beacon/ack/confirmation exchange and record matching probe results.
   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *received;
      if (len != sizeof(pack)) return msg;
      received = (pack *)payload;
      if (received->protocol == PROTOCOL_NAME && received->TTL == 1 &&
          received->payload[0] == 'N' && received->src != TOS_NODE_ID) {
         if (received->payload[1] == 'D') {
             sendNeighborMessage(received->src, 'A', received->seq);
         } else if (received->payload[1] == 'A') {
            refreshNeighbor(received->src);
             recordBeaconResult(received->src, received->seq);
             sendNeighborMessage(received->src, 'C', received->seq);
          } else if (received->payload[1] == 'C') {
            refreshNeighbor(received->src);
         }
      }
      return msg;
   }

   // Send one-hop neighbor-discovery control messages with the probe sequence.
   void sendNeighborMessage(uint16_t destination, uint8_t kind,
                            uint16_t sequence) {
      pack message;
      message.src = TOS_NODE_ID;
      message.dest = destination;
      message.seq = sequence;
      message.TTL = 1;
      message.protocol = PROTOCOL_NAME;
      memset(message.payload, 0, PACKET_MAX_PAYLOAD_SIZE);
      message.payload[0] = 'N';
      message.payload[1] = kind;
      call Sender.send(message, destination);
   }

   // Refresh an active neighbor or add it if the bounded table has space.
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
         linkQuality[neighborCount] = 255;
         pendingBeacon[neighborCount] = 0;
         beaconPending[neighborCount] = FALSE;
         neighborCount++;
         dbg(NEIGHBOR_CHANNEL, "Node %d discovered neighbor %d\n",
             TOS_NODE_ID, node);
      } else {
         dbg(NEIGHBOR_CHANNEL, "Node %d neighbor table full; ignored %d\n",
             TOS_NODE_ID, node);
      }
   }

   // Update the link-quality EWMA only for the matching beacon acknowledgment.
   void recordBeaconResult(uint16_t node, uint16_t sequence) {
      uint8_t i;
      for (i = 0; i < neighborCount; i++) {
         if (neighbors[i] == node && beaconPending[i] &&
             pendingBeacon[i] == sequence) {
            linkQuality[i] = ((uint16_t)linkQuality[i] * 7 + 255) / 8;
            beaconPending[i] = FALSE;
            return;
         }
      }
   }
}
