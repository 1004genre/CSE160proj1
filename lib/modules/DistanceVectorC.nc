#include "../../includes/packet.h"

configuration DistanceVectorC {
   provides interface DistanceVector;
   uses interface NeighborDiscovery as Neighbors;
}
implementation {
   components DistanceVectorP;
   components new TimerMilliC() as AgeTimer;
   components new TimerMilliC() as RoundTimer;
   components new TimerMilliC() as StageTimer;
   components new SimpleSendC(AM_ROUTING) as DVSender;
   components new AMReceiverC(AM_ROUTING) as DVReceiver;
   components ActiveMessageC;

   DistanceVector = DistanceVectorP.DistanceVector;
   DistanceVectorP.Neighbors -> Neighbors;
   DistanceVectorP.AgeTimer -> AgeTimer;
   DistanceVectorP.RoundTimer -> RoundTimer;
   DistanceVectorP.StageTimer -> StageTimer;
   DistanceVectorP.Sender -> DVSender;
   DistanceVectorP.Receive -> DVReceiver;
   DistanceVectorP.AMPacket -> ActiveMessageC;
}
