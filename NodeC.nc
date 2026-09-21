#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC {}
implementation {
    components MainC, Node, ActiveMessageC, CommandHandlerC, NeighborDiscoveryC;
    components new AMReceiverC(AM_PACK) as GeneralReceive;
    components new SimpleSendC(AM_PACK);
    Node -> MainC.Boot;
    Node.Receive -> GeneralReceive;
    Node.AMControl -> ActiveMessageC;
    Node.Sender -> SimpleSendC;
    Node.CommandHandler -> CommandHandlerC;
    Node.NeighborDiscovery -> NeighborDiscoveryC; // wires Node to the new neighbor service.
}
