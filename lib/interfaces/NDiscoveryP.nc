#include "../../includes/channels.h"

module NDiscoveryP {
    provides interface NDiscovery;

    uses interface Time<TimerMilliC> as nieghborTimer;
    uses interface Random as Random;
}

implemenation {
    command void NDisocvery.start() {
        dbg(NEIGHBOR_CHANNEL, "neighbor discovery started!")
        call neighborTimer.startOneShot(500 + (uint16_t) (call Random.rand16()%500));
    }

    event neighborTimer.fired() {
        dbg(NEIGHBOR_CHANNEL, "neighbor discovery started!");
    }

    command void NDisocvery.printNeighbors(){
        dbg(NEIGHBOR_CHANNEL, "print neighbor tables")
    }
}