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
   uses interface Random;
}
implementation {
   uint16_t neighbors[MAX_NEIGHBORS];
   uint8_t remainingBeacons[MAX_NEIGHBORS];
   uint8_t neighborCount = 0;
   bool beaconTimerStarted = FALSE;
   void refreshNeighbor(uint16_t node);
   void sendNeighborMessage(uint16_t destination, uint8_t kind);

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

   command void NeighborDiscovery.print() {
      uint8_t i;
      dbg(NEIGHBOR_CHANNEL, "Node %d neighbors:\n", TOS_NODE_ID);
      for (i = 0; i < neighborCount; i++)
         dbg(NEIGHBOR_CHANNEL, "  %d\n", neighbors[i]);
   }

   event void BeaconTimer.fired() {
      pack beacon;
      uint8_t i, j;
      beacon.src = TOS_NODE_ID;
      beacon.dest = AM_BROADCAST_ADDR;
      beacon.seq = 0;
      beacon.TTL = 1;
      beacon.protocol = PROTOCOL_NAME;
      memset(beacon.payload, 0, PACKET_MAX_PAYLOAD_SIZE);
      beacon.payload[0] = 'N';
      beacon.payload[1] = 'D';
      call Sender.send(beacon, AM_BROADCAST_ADDR);
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
      if (received->protocol == PROTOCOL_NAME && received->TTL == 1 &&
          received->payload[0] == 'N' && received->src != TOS_NODE_ID) {
         if (received->payload[1] == 'D') {
            sendNeighborMessage(received->src, 'A');
         } else if (received->payload[1] == 'A') {
            refreshNeighbor(received->src);
            sendNeighborMessage(received->src, 'C');
         } else if (received->payload[1] == 'C') {
            refreshNeighbor(received->src);
         }
      }
      return msg;
   }

   void sendNeighborMessage(uint16_t destination, uint8_t kind) {
      pack message;
      message.src = TOS_NODE_ID;
      message.dest = destination;
      message.seq = 0;
      message.TTL = 1;
      message.protocol = PROTOCOL_NAME;
      memset(message.payload, 0, PACKET_MAX_PAYLOAD_SIZE);
      message.payload[0] = 'N';
      message.payload[1] = kind;
      call Sender.send(message, destination);
   }

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
         dbg(NEIGHBOR_CHANNEL, "Node %d discovered neighbor %d\n",
             TOS_NODE_ID, node);
      } else {
         dbg(NEIGHBOR_CHANNEL, "Node %d neighbor table full; ignored %d\n",
             TOS_NODE_ID, node);
      }
   }
}
