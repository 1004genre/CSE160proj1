#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC {}
implementation {
    components MainC, Node, ActiveMessageC, CommandHandlerC;
    components NeighborDiscoveryC, FloodingC;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node -> MainC.Boot;
    Node.Receive -> GeneralReceive;
    Node.AMControl -> ActiveMessageC;
    Node.CommandHandler -> CommandHandlerC;
    Node.NeighborDiscovery -> NeighborDiscoveryC;
    Node.Flooding -> FloodingC; // Added: wires all flood send/receive logic through FloodingC.
}
