interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void floodPing(uint16_t destination, uint8_t *payload);
   event void setRoutingMetric(uint8_t enabled);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void setTestServer(uint16_t serverAddress, uint8_t listenPort);
   event void setTestClient(uint16_t clientAddress, uint16_t serverAddress,
                            uint8_t sourcePort, uint8_t destinationPort,
                            uint16_t transferBytes);
   event void closeTestClient(uint16_t clientAddress, uint16_t serverAddress,
                              uint8_t sourcePort, uint8_t destinationPort);
   // Test-only controls target the server and identify its client child tuple.
   event void pauseTestConsumer(uint16_t serverAddress, uint8_t listenPort,
                                uint16_t clientAddress, uint8_t sourcePort);
   event void resumeTestConsumer(uint16_t serverAddress, uint8_t listenPort,
                                 uint16_t clientAddress, uint8_t sourcePort);
   // Arm one deterministic packet drop at the node receiving this command.
   event void setTransportDropRule(uint16_t sourceAddress,
                                   uint16_t destinationAddress,
                                   uint8_t sourcePort, uint8_t destinationPort,
                                   uint8_t kind, uint8_t field,
                                   uint16_t value, uint16_t occurrence);
   event void setAppServer();
   event void setAppClient();
}
