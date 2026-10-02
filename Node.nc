#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node {
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface CommandHandler;
   uses interface NeighborDiscovery;
   uses interface Flooding; // Flooding is implemented separately in FloodingP.nc.
}
implementation {
   event void Boot.booted() {
      call AMControl.start();
      call NeighborDiscovery.start();
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

   // Node forwards received project packets to FloodingP for protocol processing.
   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      if (len == sizeof(pack)) {
         call Flooding.receive((pack *)payload);
      }
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      call Flooding.ping(destination, payload);
   }

   event void CommandHandler.printNeighbors() {
      call NeighborDiscovery.print();
   }
   event void CommandHandler.printRouteTable() {}
   event void CommandHandler.printLinkState() {}
   event void CommandHandler.printDistanceVector() {}
   event void CommandHandler.setTestServer() {}
   event void CommandHandler.setTestClient() {}
   event void CommandHandler.setAppServer() {}
   event void CommandHandler.setAppClient() {}
}
