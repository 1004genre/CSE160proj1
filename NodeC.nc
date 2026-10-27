#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC {}
implementation {
    components MainC, Node, ActiveMessageC, CommandHandlerC;
    components NeighborDiscoveryC, FloodingC, DistanceVectorC;
    components new AMReceiverC(AM_PACK) as GeneralReceive;
    components new SimpleSendC(AM_PACK) as DataSender;

    Node -> MainC.Boot;
    Node.Receive -> GeneralReceive;
    Node.AMPacket -> ActiveMessageC;
    Node.AMControl -> ActiveMessageC;
    Node.Sender -> DataSender;
    Node.CommandHandler -> CommandHandlerC;
    Node.NeighborDiscovery -> NeighborDiscoveryC;
    Node.Flooding -> FloodingC;
    Node.DistanceVector -> DistanceVectorC;
    DistanceVectorC.Neighbors -> NeighborDiscoveryC;
}
