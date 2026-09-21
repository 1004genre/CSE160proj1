interface NeighborDiscovery {             // Defines the small API Node needs from neighbor discovery.
   command void start();                  // Starts periodic neighbor beaconing.
   command void print();                  // Prints the current neighbor table on request.
}
