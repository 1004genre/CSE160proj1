configuration Project3C {}
implementation {
   components MainC, Project3Node, ActiveMessageC, CommandHandlerC;
   components NeighborDiscoveryC, DistanceVectorC, TransportP;
   components new AMReceiverC(AM_PACK) as GeneralReceive;
   components new SimpleSendC(AM_PACK) as DataSender;
   components new TimerMilliC() as TransportRetryTimer;

   Project3Node -> MainC.Boot;
   Project3Node.Receive -> GeneralReceive;
   Project3Node.AMPacket -> ActiveMessageC;
   Project3Node.AMControl -> ActiveMessageC;
   Project3Node.Sender -> DataSender;
   Project3Node.CommandHandler -> CommandHandlerC;
   Project3Node.NeighborDiscovery -> NeighborDiscoveryC;
   Project3Node.DistanceVector -> DistanceVectorC;
   DistanceVectorC.Neighbors -> NeighborDiscoveryC;

   Project3Node.Transport -> TransportP;
   TransportP.Network -> Project3Node.TransportNetwork;
   TransportP.Boot -> MainC.Boot;
   TransportP.RetryTimer -> TransportRetryTimer;
}
