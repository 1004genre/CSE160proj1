configuration Project2C {}
implementation {
   components MainC, Project2Node, ActiveMessageC, CommandHandlerC;
   components NeighborDiscoveryC, DistanceVectorC;
   components new AMReceiverC(AM_PACK) as GeneralReceive;
   components new SimpleSendC(AM_PACK) as DataSender;

   Project2Node -> MainC.Boot;
   Project2Node.Receive -> GeneralReceive;
   Project2Node.AMPacket -> ActiveMessageC;
   Project2Node.AMControl -> ActiveMessageC;
   Project2Node.Sender -> DataSender;
   Project2Node.CommandHandler -> CommandHandlerC;
   Project2Node.NeighborDiscovery -> NeighborDiscoveryC;
   Project2Node.DistanceVector -> DistanceVectorC;
   DistanceVectorC.Neighbors -> NeighborDiscoveryC;
}
