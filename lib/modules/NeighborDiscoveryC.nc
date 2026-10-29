#include "../../includes/packet.h"

configuration NeighborDiscoveryC {
   provides interface NeighborDiscovery;
}
implementation {
   components NeighborDiscoveryP;
   components new TimerMilliC() as BeaconTimer;
   components new SimpleSendC(AM_PACK) as BeaconSender;
   components new AMReceiverC(AM_PACK) as BeaconReceiver;
   components RandomC;
   NeighborDiscovery = NeighborDiscoveryP.NeighborDiscovery;
   NeighborDiscoveryP.BeaconTimer -> BeaconTimer;
   NeighborDiscoveryP.Sender -> BeaconSender;
   NeighborDiscoveryP.Receive -> BeaconReceiver;
   NeighborDiscoveryP.Random -> RandomC;
}
