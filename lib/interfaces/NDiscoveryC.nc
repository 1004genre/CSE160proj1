configuration NDiscoveryC {
    provides interface NDiscovery;
}

implementation {
    components NDiscoveryP;
    NDiscovery = NDiscoveryP;
       
    components new TimerMilliC() as sendTimer;
   components RandomC as Random;
   
   NDiscoveryP.neighborTimer -> neighborTimer;
   NDiscoveryP.Random -> Random;
}
