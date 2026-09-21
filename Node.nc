/* Project 1 node: controls flooding and starts neighbor discovery. */
#include <Timer.h>                       // Supplies TinyOS timing-related definitions.
#include "includes/command.h"            // Defines simulator command identifiers.
#include "includes/packet.h"             // Defines the project packet header and packet constants.
#include "includes/CommandMsg.h"         // Defines messages sent by the simulator command handler.
#include "includes/sendInfo.h"           // Defines SimpleSend queue information.
#include "includes/channels.h"           // Defines the required debug channel names.

module Node {                             // Declares the application-level TinyOS module.
   uses interface Boot;                   // Receives the event that starts each simulated node.
   uses interface SplitControl as AMControl; // Starts the active-message radio stack.
   uses interface Receive;                // Receives project packets from the radio.
   uses interface SimpleSend as Sender;   // Sends queued project packets through the radio.
   uses interface CommandHandler;         // Receives ping and print-neighbor commands from TOSSIM.
   uses interface NeighborDiscovery;      // Starts and prints the neighbor-discovery service.
}
implementation {                          // Contains the module state and event implementations.
   enum { SEEN_PACKET_COUNT = 64 };       // Bounds duplicate history so it uses fixed mote memory.
   typedef struct seenPacket {            // Stores only header fields needed to identify a flood.
      uint16_t src;                       // Original sender of a packet.
      uint16_t seq;                       // Sequence number chosen by that sender.
   } seenPacket;                          // Names the small duplicate-history record.

   pack sendPackage;                      // Reusable packet buffer for locally created packets.
   seenPacket seenPackets[SEEN_PACKET_COUNT]; // Fixed history of packets this node has processed.
   uint8_t seenCount = 0;                 // Number of history entries filled before the table wraps.
   uint8_t nextSeenSlot = 0;              // Replacement position after the history becomes full.
   uint16_t nextSequenceNumber = 0;       // Sequence number for packets originating at this node.

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl, uint8_t protocol, uint16_t seq, uint8_t *payload, uint8_t length); // Builds a packet header and payload.
   bool wasSeen(pack *p);                 // Checks whether this source/sequence pair was processed.
   void remember(pack *p);                // Adds a source/sequence pair to the bounded history.
   void flood(pack *p);                   // Broadcasts a packet to every physical neighbor.

   event void Boot.booted() {             // Runs once when TinyOS boots this node.
      call AMControl.start();              // Turns on the active-message radio stack.
      call NeighborDiscovery.start();     // Begins the periodic one-hop beacon timer.
      dbg(GENERAL_CHANNEL, "Booted\n");  // Reports successful node startup.
   }

   event void AMControl.startDone(error_t err) { // Runs after an attempt to start the radio.
      if (err == SUCCESS) {               // Checks whether the radio startup succeeded.
         dbg(GENERAL_CHANNEL, "Radio On\n"); // Reports that the radio is ready.
      } else {                            // Handles a transient radio startup failure.
         call AMControl.start();          // Retries until the radio is available.
      }
   }

   event void AMControl.stopDone(error_t err) {} // Required callback; Project 1 never stops the radio.

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) { // Handles an incoming packet.
      pack *received;                     // Will point at the received project packet.
      if (len != sizeof(pack)) {          // Rejects radio messages that are not project packets.
         return msg;                      // Returns the buffer unchanged to TinyOS.
      }
      received = (pack *)payload;         // Views the radio payload as the project's packet type.
      if (received->protocol != PROTOCOL_PING && received->protocol != PROTOCOL_PINGREPLY) { // Leaves beacons to neighbor discovery.
         return msg;                      // Does not flood unrelated protocol packets.
      }
      if (wasSeen(received)) {            // Stops a flood when this packet arrives by another path.
         dbg(FLOODING_CHANNEL, "Node %d dropped duplicate from %d seq %d\n", TOS_NODE_ID, received->src, received->seq); // Shows duplicate suppression.
         return msg;                      // Avoids rebroadcasting the duplicate.
      }
      remember(received);                 // Records this first arrival before any forwarding.
      dbg(FLOODING_CHANNEL, "Node %d received packet from %d seq %d\n", TOS_NODE_ID, received->src, received->seq); // Shows each new flood arrival.
      if (received->dest == TOS_NODE_ID) { // Checks whether this node is the final destination.
         if (received->protocol == PROTOCOL_PING) { // Converts an arriving ping into its reply.
            makePack(&sendPackage, TOS_NODE_ID, received->src, MAX_TTL, PROTOCOL_PINGREPLY, nextSequenceNumber++, received->payload, PACKET_MAX_PAYLOAD_SIZE); // Addresses a new reply to the original sender.
            remember(&sendPackage);       // Prevents this node from forwarding its own reply later.
            dbg(FLOODING_CHANNEL, "Node %d sent ping reply to %d\n", TOS_NODE_ID, received->src); // Shows reply creation.
            flood(&sendPackage);          // Floods the reply back through the network.
         } else {                         // Handles a ping reply that reached its requester.
            dbg(FLOODING_CHANNEL, "Node %d received ping reply from %d\n", TOS_NODE_ID, received->src); // Shows ping completion.
         }
      } else if (received->TTL > 1) {     // Forwards only non-destination packets with hops remaining.
         received->TTL--;                 // Consumes one allowed hop for this rebroadcast.
         flood(received);                 // Broadcasts the first copy to all physical neighbors.
      }
      return msg;                         // Returns the receive buffer to TinyOS.
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) { // Creates a simulator-requested ping.
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, nextSequenceNumber++, payload, PACKET_MAX_PAYLOAD_SIZE); // Fills all flooding header fields.
      remember(&sendPackage);             // Marks the locally originated ping as already processed.
      dbg(FLOODING_CHANNEL, "Node %d sent ping toward %d\n", TOS_NODE_ID, destination); // Shows ping injection.
      flood(&sendPackage);                // Starts flooding with a local broadcast.
   }
   event void CommandHandler.printNeighbors() { call NeighborDiscovery.print(); } // Delegates the required dump-neighbors command.
   event void CommandHandler.printRouteTable() {} // Unused until a later routing project.
   event void CommandHandler.printLinkState() {} // Unused until a later routing project.
   event void CommandHandler.printDistanceVector() {} // Unused until a later routing project.
   event void CommandHandler.setTestServer() {} // Unused until a later transport project.
   event void CommandHandler.setTestClient() {} // Unused until a later transport project.
   event void CommandHandler.setAppServer() {} // Unused until a later application project.
   event void CommandHandler.setAppClient() {} // Unused until a later application project.

   bool wasSeen(pack *p) {                // Searches the bounded source/sequence history.
      uint8_t i;                          // Iterates over used history entries.
      for (i = 0; i < seenCount; i++) {   // Examines every recorded packet identity.
         if (seenPackets[i].src == p->src && seenPackets[i].seq == p->seq) { // Matches the fields required by the handout.
            return TRUE;                  // Reports that another path already delivered this packet.
         }
      }
      return FALSE;                       // Reports a first-time packet arrival.
   }

   void remember(pack *p) {               // Records a packet identity without dynamic allocation.
      if (seenCount < SEEN_PACKET_COUNT) { // Uses an unused entry while the table has room.
         seenPackets[seenCount].src = p->src; // Saves the original sender.
         seenPackets[seenCount].seq = p->seq; // Saves that sender's sequence number.
         seenCount++;                     // Makes the newly filled entry searchable.
      } else {                            // Handles a full fixed-size history.
         seenPackets[nextSeenSlot].src = p->src; // Replaces the oldest rotating entry's sender.
         seenPackets[nextSeenSlot].seq = p->seq; // Replaces the oldest rotating entry's sequence.
         nextSeenSlot = (nextSeenSlot + 1) % SEEN_PACKET_COUNT; // Advances the circular replacement position.
      }
   }

   void flood(pack *p) {                  // Sends a packet to all directly reachable nodes.
      call Sender.send(*p, AM_BROADCAST_ADDR); // Uses the required TinyOS broadcast address.
      dbg(FLOODING_CHANNEL, "Node %d broadcast packet from %d seq %d\n", TOS_NODE_ID, p->src, p->seq); // Shows every rebroadcast.
   }

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl, uint8_t protocol, uint16_t seq, uint8_t *payload, uint8_t length) { // Initializes a project packet.
      p->src = src;                       // Stores the original sender for duplicate detection and replies.
      p->dest = dest;                     // Stores the intended final destination.
      p->TTL = ttl;                       // Limits the number of possible flood hops.
      p->seq = seq;                       // Distinguishes packets from the same original sender.
      p->protocol = protocol;             // Identifies ping versus ping-reply behavior.
      memcpy(p->payload, payload, length); // Copies the simulator's ping text into the packet.
   }
}
