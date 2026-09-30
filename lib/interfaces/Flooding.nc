// Added: Node uses this interface to inject pings and hand received packets to flooding.
interface Flooding {
   command void ping(uint16_t destination, uint8_t *payload);
   command void receive(pack *packet);
}
