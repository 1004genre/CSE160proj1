#include <Timer.h>                        // Makes TinyOS timer types available to this configuration.
#include "includes/CommandMsg.h"          // Makes command-message definitions available to components.
#include "includes/packet.h"              // Supplies AM_PACK, the project's active-message type.

configuration NodeC {}                    // Declares the top-level application wiring.
implementation {                          // Connects Node to the TinyOS services it uses.
    components MainC, Node, ActiveMessageC, CommandHandlerC, NeighborDiscoveryC; // Instantiates the application and shared services.
    components new AMReceiverC(AM_PACK) as GeneralReceive; // Receives normal project packets.
    components new SimpleSendC(AM_PACK);  // Provides queued sending for flooded packets.
    Node -> MainC.Boot;                   // Delivers the boot event to Node.
    Node.Receive -> GeneralReceive;       // Delivers received project packets to Node.
    Node.AMControl -> ActiveMessageC;     // Lets Node start the radio stack.
    Node.Sender -> SimpleSendC;           // Lets Node broadcast through the send queue.
    Node.CommandHandler -> CommandHandlerC; // Delivers simulator commands to Node.
    Node.NeighborDiscovery -> NeighborDiscoveryC; // Connects Node to the beacon service.
}
