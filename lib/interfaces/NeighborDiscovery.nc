// One-hop neighbor discovery interface. Routing queries this live table.
interface NeighborDiscovery {
   command void start();
   command void print();
   command uint8_t count();
   command uint16_t neighborAt(uint8_t index);
   command bool isNeighbor(uint16_t node);
}
