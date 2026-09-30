#include "../../includes/packet.h"

// Added: wires the flooding protocol to the existing queued project-packet sender.
configuration FloodingC {
   provides interface Flooding;
}
implementation {
   components FloodingP;
   components new SimpleSendC(AM_PACK) as FloodSender;

   Flooding = FloodingP.Flooding;
   FloodingP.Sender -> FloodSender;
}
