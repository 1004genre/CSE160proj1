#include "../../includes/channels.h"      // Supplies NEIGHBOR_CHANNEL debug output.
#include "../../includes/packet.h"        // Supplies the packet type, protocol ID, and broadcast address.

enum {                                    // Groups the fixed neighbor-discovery parameters.
   BEACON_PERIOD = 1000,                  // Sends a low-rate beacon once per second.
   NEIGHBOR_TIMEOUT = 5,                  // Removes a neighbor after five missed beacon periods.
   MAX_NEIGHBORS = 32                     // Bounds table memory while covering the supplied topologies.
};

module NeighborDiscoveryP {               // Implements periodic one-hop neighbor discovery.
   provides interface NeighborDiscovery;   // Lets Node start discovery and print its table.
   uses interface Timer<TMilli> as BeaconTimer; // Signals each beacon period.
   uses interface SimpleSend as Sender;    // Queues outgoing beacon broadcasts.
   uses interface Receive;                 // Delivers incoming project packets.
}
implementation {                          // Stores neighbor liveness state and implements protocol events.
   uint16_t neighbors[MAX_NEIGHBORS];      // Stores each directly heard neighbor's node ID.
   uint8_t remainingBeacons[MAX_NEIGHBORS]; // Stores liveness countdowns matching the neighbor array.
   uint8_t neighborCount = 0;              // Counts valid entries currently in the neighbor table.

   void refreshNeighbor(uint16_t node);    // Adds a node or resets its liveness countdown.

   command void NeighborDiscovery.start() { // Starts continuous discovery after the node boots.
      call BeaconTimer.startPeriodic(BEACON_PERIOD); // Schedules one beacon event every second.
   }

   command void NeighborDiscovery.print() { // Implements the required neighbor-table dump.
      uint8_t i;                           // Iterates across active neighbor entries.
      dbg(NEIGHBOR_CHANNEL, "Node %d neighbors:\n", TOS_NODE_ID); // Labels this node's table.
      for (i = 0; i < neighborCount; i++) { // Visits every discovered neighbor.
         dbg(NEIGHBOR_CHANNEL, "  %d\n", neighbors[i]); // Prints one directly reachable node ID.
      }
   }

   event void BeaconTimer.fired() {        // Runs once per periodic neighbor-discovery interval.
      pack beacon;                         // Holds this node's one-hop beacon packet.
      uint8_t i;                           // Iterates over neighbor records.
      uint8_t j;                           // Shifts entries when removing a timed-out neighbor.

      beacon.src = TOS_NODE_ID;            // Identifies the node that emits this beacon.
      beacon.dest = AM_BROADCAST_ADDR;     // Sends the beacon to all physical radio neighbors.
      beacon.seq = 0;                      // Beacons are not flooded or duplicate-tracked.
      beacon.TTL = 1;                      // Ensures the beacon remains one hop only.
      beacon.protocol = PROTOCOL_NAME;     // Reuses the supplied protocol field; no new packet type.
      memset(beacon.payload, 0, PACKET_MAX_PAYLOAD_SIZE); // Guarantees a null-terminated marker string.
      strcpy((char *)beacon.payload, "ND"); // Marks this existing packet as a discovery beacon.
      call Sender.send(beacon, AM_BROADCAST_ADDR); // Broadcasts the beacon through the send queue.

      for (i = 0; i < neighborCount; i++) { // Ages every currently known neighbor.
         if (remainingBeacons[i] > 0) {     // Avoids decrementing an already expired countdown.
            remainingBeacons[i]--;         // Records one missed beacon interval.
         }
         if (remainingBeacons[i] == 0) {    // Removes neighbors that have not refreshed in time.
            dbg(NEIGHBOR_CHANNEL, "Node %d lost neighbor %d\n", TOS_NODE_ID, neighbors[i]); // Reports topology disappearance.
            for (j = i; j + 1 < neighborCount; j++) { // Closes the gap in both parallel arrays.
               neighbors[j] = neighbors[j + 1]; // Shifts the following node ID left.
               remainingBeacons[j] = remainingBeacons[j + 1]; // Shifts its matching liveness state left.
            }
            neighborCount--;               // Removes the final duplicate table entry.
            i--;                           // Rechecks the entry that was shifted into this index.
         }
      }
   }

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) { // Handles incoming one-hop packets.
      pack *received;                      // Will point at the received project packet.
      if (len != sizeof(pack)) {           // Ignores malformed or unrelated radio messages.
         return msg;                       // Returns the receive buffer unchanged.
      }
      received = (pack *)payload;          // Views the payload as the project packet format.
      if (received->protocol == PROTOCOL_NAME && received->TTL == 1 && strcmp((char *)received->payload, "ND") == 0 && received->src != TOS_NODE_ID) { // Accepts only another node's one-hop discovery beacon.
         refreshNeighbor(received->src);   // Adds or refreshes that directly heard node.
      }
      return msg;                          // Returns the receive buffer to TinyOS.
   }

   void refreshNeighbor(uint16_t node) {   // Updates one neighbor's presence information.
      uint8_t i;                           // Iterates across the existing neighbor IDs.
      for (i = 0; i < neighborCount; i++) { // Searches for a previously discovered node.
         if (neighbors[i] == node) {       // Detects a beacon from an existing neighbor.
            remainingBeacons[i] = NEIGHBOR_TIMEOUT; // Restores its full liveness window.
            return;                        // Avoids inserting a duplicate table entry.
         }
      }
      if (neighborCount < MAX_NEIGHBORS) { // Adds a new neighbor only when fixed memory has space.
         neighbors[neighborCount] = node;  // Stores the newly heard direct neighbor ID.
         remainingBeacons[neighborCount] = NEIGHBOR_TIMEOUT; // Starts its liveness window.
         neighborCount++;                  // Makes the new entry visible to print and expiry logic.
         dbg(NEIGHBOR_CHANNEL, "Node %d discovered neighbor %d\n", TOS_NODE_ID, node); // Reports topology appearance.
      }
   }
}
