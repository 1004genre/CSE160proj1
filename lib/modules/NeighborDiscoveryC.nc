#include "../../includes/packet.h"        // Supplies AM_PACK for the beacon sender and receiver.

configuration NeighborDiscoveryC {       // Declares the public neighbor-discovery component.
   provides interface NeighborDiscovery;  // Exposes start and print to Node.
}
implementation {                          // Wires the protocol module to TinyOS components.
   components NeighborDiscoveryP;         // Instantiates the beacon and neighbor-table logic.
   components new TimerMilliC() as BeaconTimer; // Supplies periodic millisecond timer events.
   components new SimpleSendC(AM_PACK) as BeaconSender; // Queues outgoing beacon broadcasts.
   components new AMReceiverC(AM_PACK) as BeaconReceiver; // Delivers incoming one-hop beacons.
   NeighborDiscovery = NeighborDiscoveryP.NeighborDiscovery; // Exposes the protocol module's API.
   NeighborDiscoveryP.BeaconTimer -> BeaconTimer; // Supplies periodic timer events to the protocol.
   NeighborDiscoveryP.Sender -> BeaconSender; // Supplies queued broadcast sending to the protocol.
   NeighborDiscoveryP.Receive -> BeaconReceiver; // Supplies received project packets to the protocol.
}
