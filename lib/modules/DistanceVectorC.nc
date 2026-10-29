#include "../../includes/packet.h"

configuration DistanceVectorC {
   provides interface DistanceVector;
   uses interface NeighborDiscovery as Neighbors;
}
implementation {
   components DistanceVectorP;
   components new TimerMilliC() as AgeTimer;
   components new TimerMilliC() as StageTimer;
   components new SimpleSendC(AM_ROUTING) as DVSender;
   components new AMReceiverC(AM_ROUTING) as DVReceiver;
   components ActiveMessageC;
   components RandomC;

   DistanceVector = DistanceVectorP.DistanceVector;
   DistanceVectorP.Neighbors = Neighbors;
   DistanceVectorP.AgeTimer -> AgeTimer;
   DistanceVectorP.StageTimer -> StageTimer;
   DistanceVectorP.Sender -> DVSender;
   DistanceVectorP.Receive -> DVReceiver;
   DistanceVectorP.AMPacket -> ActiveMessageC;
   DistanceVectorP.Random -> RandomC;
}
