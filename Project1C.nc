#include <Timer.h>

configuration Project1C {}
implementation {
   components MainC, Project1Node, ActiveMessageC, CommandHandlerC;
   components NeighborDiscoveryC, FloodingC;
   components new AMReceiverC(AM_PACK) as GeneralReceive;

   Project1Node -> MainC.Boot;
   Project1Node.Receive -> GeneralReceive;
   Project1Node.AMPacket -> ActiveMessageC;
   Project1Node.AMControl -> ActiveMessageC;
   Project1Node.CommandHandler -> CommandHandlerC;
   Project1Node.NeighborDiscovery -> NeighborDiscoveryC;
   Project1Node.Flooding -> FloodingC;
}
