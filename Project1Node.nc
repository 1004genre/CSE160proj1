#include <Timer.h>
#include "includes/packet.h"

module Project1Node {
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface AMPacket;
   uses interface CommandHandler;
   uses interface NeighborDiscovery;
   uses interface Flooding;
}
implementation {
   event void Boot.booted() {
      call AMControl.start();
      call NeighborDiscovery.start();
   }

   event void AMControl.startDone(error_t err) {
      if (err != SUCCESS) call AMControl.start();
   }

   event void AMControl.stopDone(error_t err) {}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *received;
      if (len != sizeof(pack)) return msg;

      received = (pack *)payload;
      if ((PACK_PROTOCOL(received) == PROTOCOL_PING ||
           PACK_PROTOCOL(received) == PROTOCOL_PINGREPLY) &&
          call AMPacket.destination(msg) == AM_BROADCAST_ADDR) {
         call Flooding.receive(received);
      }
      return msg;
   }

   event void CommandHandler.floodPing(uint16_t destination, uint8_t *payload) {
      call Flooding.ping(destination, payload);
   }

   event void CommandHandler.printNeighbors() {
      call NeighborDiscovery.print();
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {}
   event void CommandHandler.setRoutingMetric(uint8_t enabled) {}
   event void CommandHandler.printRouteTable() {}
   event void CommandHandler.printLinkState() {}
   event void CommandHandler.printDistanceVector() {}
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
   event void CommandHandler.setAppServer() {}
   event void CommandHandler.setAppClient() {}
}
