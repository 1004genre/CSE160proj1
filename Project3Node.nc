#include <Timer.h>
#include <string.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/channels.h"
#include "includes/socket.h"

module Project3Node {
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface AMPacket;
   uses interface SimpleSend as Sender;
   uses interface CommandHandler;
   uses interface NeighborDiscovery;
   uses interface DistanceVector;
   uses interface Transport;
   uses interface Timer<TMilli> as ConsumerTimer;
   provides interface TransportNetwork;
}
implementation {
   enum {
      TCP_CONSUMER_PAUSE_MS = 8000,
      TCP_CONSUMER_INTERVAL_MS = 500
   };

   // Per-socket test state keeps concurrent producers and consumers independent.
   typedef struct test_connection_t {
      bool active;
      bool isClient;
      bool established;
      bool consumerPaused;
      bool autoPause;
      bool sawZeroWindow;
      bool dropNextWindowUpdate;
      bool closeRequested;
      bool closeStarted;
      uint16_t localAddress;
      uint16_t remoteAddress;
      uint8_t localPort;
      uint8_t remotePort;
      uint16_t requestedBytes;
      uint16_t acceptedBytes;
      uint16_t acknowledgedBytes;
      uint16_t consumedBytes;
      uint16_t mismatches;
      uint8_t pauseTicks;
   } test_connection_t;

   uint16_t nextSequenceNumber = 0;
   socket_t serverSocket = SOCKET_NONE;
   test_connection_t testConnections[MAX_NUM_OF_SOCKETS];

#ifndef TOSSIM
   // Only the simulator has virtual time; keep hardware builds compilable.
#define sim_time_string() "hardware"
#endif

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl,
                 uint8_t protocol, uint16_t seq, const void *payload);
   bool sendRouted(pack *p);
   void processRouted(pack *p);

   test_connection_t *testConnection(socket_t fd) {
      if (fd >= MAX_NUM_OF_SOCKETS || !testConnections[fd].active) return NULL;
      return &testConnections[fd];
   }

   // Keep one compact progress line per producer offer or consumer read.
   void logTestProgress(socket_t fd, const char *event) {
      test_connection_t *record = testConnection(fd);
      const char *state;
      if (record == NULL) return;
      state = !record->isClient && record->consumerPaused ? "PAUSED" :
              record->closeStarted ? "CLOSING" :
              record->established ? "ESTABLISHED" : "CONNECTING";
      dbg(PROJECT3_TGEN_CHANNEL,
          "t=%s node=%d conn=%d %d:%d->%d:%d event=%s state=%s accepted=%d acknowledged=%d consumed=%d target=%d mismatches=%d\n",
          sim_time_string(), TOS_NODE_ID, fd, record->localAddress,
          record->localPort, record->remoteAddress, record->remotePort,
          event, state, record->acceptedBytes, record->acknowledgedBytes,
          record->consumedBytes, record->requestedBytes, record->mismatches);
   }

   void clearTestConnection(socket_t fd) {
      if (fd < MAX_NUM_OF_SOCKETS) {
         memset(&testConnections[fd], 0, sizeof(test_connection_t));
      }
   }

   socket_t findTestEndpoint(uint16_t localAddress, uint8_t localPort,
                             uint16_t remoteAddress, uint8_t remotePort,
                             bool isClient) {
      socket_t fd;
      for (fd = 0; fd < MAX_NUM_OF_SOCKETS; fd++) {
         test_connection_t *record = testConnection(fd);
         if (record != NULL && record->isClient == isClient &&
             record->localAddress == localAddress &&
             record->localPort == localPort &&
             record->remoteAddress == remoteAddress &&
             record->remotePort == remotePort) return fd;
      }
      return SOCKET_NONE;
   }

   void maybeCloseClient(socket_t fd) {
      test_connection_t *record = testConnection(fd);
      if (record == NULL || !record->isClient || !record->closeRequested ||
          !record->established || record->closeStarted ||
          record->acceptedBytes != record->requestedBytes) return;
      record->acknowledgedBytes = call Transport.sendAcknowledged(fd);
      if (record->acknowledgedBytes != record->acceptedBytes) return;
      if (call Transport.close(fd) == SUCCESS) {
         record->closeStarted = TRUE;
         logTestProgress(fd, "CLIENT_FIN_REQUEST");
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP client close started after %d/%d bytes acknowledged\n",
             TOS_NODE_ID, record->acknowledgedBytes, record->requestedBytes);
      } else {
         logTestProgress(fd, "CLIENT_FIN_FAILURE");
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP client close failed before FIN\n", TOS_NODE_ID);
      }
   }

   void queueClientData(socket_t fd) {
      test_connection_t *record = testConnection(fd);
      uint8_t data[SOCKET_BUFFER_SIZE];
      uint16_t remaining;
      uint16_t offered;
      uint16_t accepted;
      uint16_t i;

      if (record == NULL || !record->isClient || !record->established ||
          record->acceptedBytes >= record->requestedBytes) return;
      remaining = record->requestedBytes - record->acceptedBytes;
      offered = remaining > SOCKET_BUFFER_SIZE ? SOCKET_BUFFER_SIZE : remaining;
      for (i = 0; i < offered; i++) {
         data[i] = (record->acceptedBytes + i) & 0xff;
      }
      accepted = call Transport.write(fd, data, offered);
      // Producer offset advances only by bytes Transport.write accepted locally.
      record->acceptedBytes += accepted;
      record->acknowledgedBytes = call Transport.sendAcknowledged(fd);
      logTestProgress(fd, "APP_ACCEPT");
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP client accepted %d/%d, acknowledged %d\n",
          TOS_NODE_ID, record->acceptedBytes, record->requestedBytes,
          record->acknowledgedBytes);
      maybeCloseClient(fd);
   }

   void consumeServerData(socket_t fd) {
      test_connection_t *record = testConnection(fd);
      uint8_t data[SOCKET_BUFFER_SIZE];
      uint16_t amount;
      uint16_t i;

      if (record == NULL || record->isClient || record->consumerPaused) return;
      amount = call Transport.read(fd, data, sizeof(data));
      for (i = 0; i < amount; i++) {
         if (data[i] != ((record->consumedBytes + i) & 0xff)) {
            record->mismatches++;
         }
      }
      record->consumedBytes += amount;
      if (amount > 0) {
         logTestProgress(fd, record->mismatches == 0 ?
                         "APP_CONTENT_OK" : "APP_CONTENT_MISMATCH");
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP consumer fd %d read chunk %d; consumed %d; pattern %s; mismatches %d\n",
             TOS_NODE_ID, fd, amount, record->consumedBytes,
             record->mismatches == 0 ? "valid" : "INVALID",
             record->mismatches);
      }
   }

   event void Boot.booted() {
      call AMControl.start();
      call NeighborDiscovery.start();
      call DistanceVector.start();
      // One bounded timer services each test consumer independently.
      call ConsumerTimer.startPeriodic(TCP_CONSUMER_INTERVAL_MS);
   }

   event void AMControl.startDone(error_t err) {
      if (err != SUCCESS) call AMControl.start();
   }

   event void AMControl.stopDone(error_t err) {}

   event void ConsumerTimer.fired() {
      socket_t fd;
      for (fd = 0; fd < MAX_NUM_OF_SOCKETS; fd++) {
         test_connection_t *record = testConnection(fd);
         if (record == NULL || record->isClient) continue;
         if (record->consumerPaused && record->autoPause &&
             record->pauseTicks > 0) {
            record->pauseTicks--;
            if (record->pauseTicks == 0) {
               record->consumerPaused = FALSE;
               record->autoPause = FALSE;
               if (record->sawZeroWindow) record->dropNextWindowUpdate = TRUE;
               logTestProgress(fd, "CONSUMER_RESUME");
               dbg(TRANSPORT_CHANNEL,
                   "Node %d TCP test consumer resumed fd %d%s\n", TOS_NODE_ID, fd,
                   record->dropNextWindowUpdate ?
                   "; dropping first reopening update" : "");
            }
         }
         consumeServerData(fd);
      }
   }

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *received;
      if (len != sizeof(pack)) return msg;

      received = (pack *)payload;
      if (PACK_PROTOCOL(received) == PROTOCOL_PING ||
          PACK_PROTOCOL(received) == PROTOCOL_PINGREPLY ||
          PACK_PROTOCOL(received) == PROTOCOL_TCP) {
         if (call AMPacket.destination(msg) != AM_BROADCAST_ADDR) {
            processRouted(received);
         }
      }
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      pack p;
      makePack(&p, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING,
               nextSequenceNumber++, payload);
      if (destination == TOS_NODE_ID) processRouted(&p);
      else sendRouted(&p);
   }

   event void CommandHandler.floodPing(uint16_t destination,
                                       uint8_t *payload) {}

   event void CommandHandler.setRoutingMetric(uint8_t enabled) {
      call DistanceVector.setQualityMetric(enabled != 0);
   }

   event void CommandHandler.printNeighbors() {
      call NeighborDiscovery.print();
   }

   event void CommandHandler.printRouteTable() {
      call DistanceVector.print();
   }

   event void CommandHandler.printLinkState() {}

   event void CommandHandler.printDistanceVector() {
      call DistanceVector.print();
   }

   event void CommandHandler.setAppServer() {}
   event void CommandHandler.setAppClient() {}

   event void CommandHandler.setTestServer(uint16_t address,
                                           uint8_t listenPort) {
      socket_addr_t local;
      socket_t fd;

      if (address != TOS_NODE_ID || listenPort == 0) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d rejected invalid TCP server command\n", TOS_NODE_ID);
         return;
      }
      if (serverSocket != SOCKET_NONE) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d already has a TCP test listener\n", TOS_NODE_ID);
         return;
      }

      fd = call Transport.socket();
      if (fd == SOCKET_NONE) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d cannot allocate TCP listener\n", TOS_NODE_ID);
         return;
      }
      local.addr = address;
      local.port = listenPort;
      if (call Transport.bind(fd, &local) != SUCCESS ||
          call Transport.listen(fd) != SUCCESS) {
         call Transport.release(fd);
         dbg(TRANSPORT_CHANNEL,
             "Node %d failed to bind TCP listener port %d\n",
             TOS_NODE_ID, listenPort);
         return;
      }
      serverSocket = fd;
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP test server listening on port %d\n",
          TOS_NODE_ID, listenPort);
   }

   event void CommandHandler.setTestClient(uint16_t clientAddress,
                                           uint16_t serverAddress,
                                           uint8_t sourcePort,
                                           uint8_t destinationPort,
                                           uint16_t transferBytes) {
      socket_addr_t local;
      socket_addr_t remote;
      socket_t fd;

      if (clientAddress != TOS_NODE_ID || serverAddress == TOS_NODE_ID ||
          sourcePort == 0 || destinationPort == 0 ||
          transferBytes == 0 || transferBytes > TCP_MAX_TRANSFER_BYTES) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d rejected invalid TCP client command\n", TOS_NODE_ID);
         return;
      }

      fd = call Transport.socket();
      if (fd == SOCKET_NONE) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d cannot allocate TCP client\n", TOS_NODE_ID);
         return;
      }
      local.addr = TOS_NODE_ID;
      local.port = sourcePort;
      remote.addr = serverAddress;
      remote.port = destinationPort;
      if (call Transport.bind(fd, &local) != SUCCESS) {
         call Transport.release(fd);
         dbg(TRANSPORT_CHANNEL,
             "Node %d failed to bind TCP client port %d\n",
             TOS_NODE_ID, sourcePort);
         return;
      }

      memset(&testConnections[fd], 0, sizeof(test_connection_t));
      testConnections[fd].active = TRUE;
      testConnections[fd].isClient = TRUE;
      testConnections[fd].localAddress = clientAddress;
      testConnections[fd].remoteAddress = serverAddress;
      testConnections[fd].localPort = sourcePort;
      testConnections[fd].remotePort = destinationPort;
      testConnections[fd].requestedBytes = transferBytes;
      logTestProgress(fd, "CONN_ALLOC");
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP test client connecting to %d:%d for %d bytes\n",
          TOS_NODE_ID, serverAddress, destinationPort, transferBytes);
      if (call Transport.connect(fd, &remote) != SUCCESS) {
         clearTestConnection(fd);
         call Transport.release(fd);
         dbg(TRANSPORT_CHANNEL,
             "Node %d failed to start TCP connection\n", TOS_NODE_ID);
      }
   }

   event void CommandHandler.closeTestClient(uint16_t clientAddress,
                                             uint16_t serverAddress,
                                             uint8_t sourcePort,
                                             uint8_t destinationPort) {
      socket_t fd;
      test_connection_t *record;
      if (clientAddress != TOS_NODE_ID) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d rejected TCP close command: wrong target client\n",
             TOS_NODE_ID);
         return;
      }
      fd = findTestEndpoint(clientAddress, sourcePort, serverAddress,
                            destinationPort, TRUE);
      record = testConnection(fd);
      if (record == NULL) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d rejected TCP close command: no matching client\n",
             TOS_NODE_ID);
         return;
      }
      record->closeRequested = TRUE;
      logTestProgress(fd, "CLIENT_CLOSE_REQUEST");
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP client close requested for %d:%d -> %d:%d\n",
          TOS_NODE_ID, clientAddress, sourcePort,
          serverAddress, destinationPort);
      maybeCloseClient(fd);
   }

   event void CommandHandler.pauseTestConsumer(uint16_t serverAddress,
                                                uint8_t listenPort,
                                                uint16_t clientAddress,
                                                uint8_t sourcePort) {
      socket_t fd;
      test_connection_t *record;
      if (serverAddress != TOS_NODE_ID) return;
      fd = findTestEndpoint(serverAddress, listenPort, clientAddress,
                            sourcePort, FALSE);
      record = testConnection(fd);
      if (record == NULL) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d cannot pause unknown TCP consumer %d:%d -> %d:%d\n",
             TOS_NODE_ID, clientAddress, sourcePort, serverAddress, listenPort);
         return;
      }
      record->consumerPaused = TRUE;
      record->autoPause = FALSE;
      record->pauseTicks = 0;
      logTestProgress(fd, "CONSUMER_PAUSE");
      dbg(TRANSPORT_CHANNEL,
          "Node %d paused TCP consumer fd %d for %d:%d -> %d:%d\n",
          TOS_NODE_ID, fd, clientAddress, sourcePort, serverAddress, listenPort);
   }

   event void CommandHandler.resumeTestConsumer(uint16_t serverAddress,
                                                 uint8_t listenPort,
                                                 uint16_t clientAddress,
                                                 uint8_t sourcePort) {
      socket_t fd;
      test_connection_t *record;
      if (serverAddress != TOS_NODE_ID) return;
      fd = findTestEndpoint(serverAddress, listenPort, clientAddress,
                            sourcePort, FALSE);
      record = testConnection(fd);
      if (record == NULL) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d cannot resume unknown TCP consumer %d:%d -> %d:%d\n",
             TOS_NODE_ID, clientAddress, sourcePort, serverAddress, listenPort);
         return;
      }
      record->consumerPaused = FALSE;
      record->autoPause = FALSE;
      record->pauseTicks = 0;
      logTestProgress(fd, "CONSUMER_RESUME");
      dbg(TRANSPORT_CHANNEL,
          "Node %d resumed TCP consumer fd %d for %d:%d -> %d:%d\n",
          TOS_NODE_ID, fd, clientAddress, sourcePort, serverAddress, listenPort);
      consumeServerData(fd);
   }

   event void Transport.connectionEstablished(socket_t fd) {
      test_connection_t *record = testConnection(fd);
      if (record != NULL && record->isClient) {
         record->established = TRUE;
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP client fd %d established\n", TOS_NODE_ID, fd);
         queueClientData(fd);
      } else {
         socket_t accepted;
         socket_addr_t local;
         socket_addr_t remote;
         if (serverSocket == SOCKET_NONE) return;
         accepted = call Transport.accept(serverSocket);
         if (accepted != fd) {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP listener could not accept child fd %d\n",
                TOS_NODE_ID, fd);
            return;
         }
         if (call Transport.endpoints(accepted, &local, &remote) != SUCCESS) {
            call Transport.release(accepted);
            return;
         }
         memset(&testConnections[accepted], 0, sizeof(test_connection_t));
         testConnections[accepted].active = TRUE;
         testConnections[accepted].established = TRUE;
         testConnections[accepted].localAddress = local.addr;
         testConnections[accepted].remoteAddress = remote.addr;
         testConnections[accepted].localPort = local.port;
         testConnections[accepted].remotePort = remote.port;
         testConnections[accepted].consumerPaused = TRUE;
         // The built-in pause keeps the flow-control demo deterministic.
         testConnections[accepted].autoPause = TRUE;
         testConnections[accepted].pauseTicks =
            TCP_CONSUMER_PAUSE_MS / TCP_CONSUMER_INTERVAL_MS;
         logTestProgress(accepted, "CONN_ACCEPT");
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP server accepted connection fd %d\n",
             TOS_NODE_ID, fd);
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP test consumer paused for %d ms\n",
             TOS_NODE_ID, TCP_CONSUMER_PAUSE_MS);
      }
   }

   event void Transport.sendReady(socket_t fd) {
      test_connection_t *record = testConnection(fd);
      if (record != NULL && record->isClient) {
         record->acknowledgedBytes = call Transport.sendAcknowledged(fd);
         queueClientData(fd);
         maybeCloseClient(fd);
      }
   }

   event void Transport.dataReceived(socket_t fd) {
      test_connection_t *record = testConnection(fd);
      if (record == NULL || record->isClient) return;
      // Packet reception only notifies; the independent timer drives application reads.
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP data buffered on fd %d; timer-driven consumer will read it\n",
          TOS_NODE_ID, fd);
   }

   event void Transport.connectionClosed(socket_t fd) {
      test_connection_t *record = testConnection(fd);
      if (record == NULL) return;
      if (!record->isClient) {
         logTestProgress(fd, "APP_CONTENT_RESULT");
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP server connection %d:%d -> %d:%d closed after %d bytes; mismatches %d\n",
             TOS_NODE_ID, record->remoteAddress, record->remotePort,
             record->localAddress, record->localPort,
             record->consumedBytes, record->mismatches);
      } else {
         record->acknowledgedBytes = call Transport.sendAcknowledged(fd);
         logTestProgress(fd,
             record->acceptedBytes == record->requestedBytes &&
             record->acknowledgedBytes == record->requestedBytes ?
                "APP_CLOSE_SUCCESS" : "APP_CLOSE_FAILURE");
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP client %d:%d -> %d:%d close %s: accepted %d acknowledged %d of %d\n",
             TOS_NODE_ID, record->localAddress, record->localPort,
             record->remoteAddress, record->remotePort,
             record->acceptedBytes == record->requestedBytes &&
             record->acknowledgedBytes == record->requestedBytes ?
                "succeeded" : "failed",
             record->acceptedBytes, record->acknowledgedBytes,
             record->requestedBytes);
      }
      clearTestConnection(fd);
   }

   event void Transport.connectionFailed(socket_t fd, uint8_t reason) {
      test_connection_t *record = testConnection(fd);
      if (record != NULL && record->isClient)
         record->acknowledgedBytes = call Transport.sendAcknowledged(fd);
      logTestProgress(fd, "APP_TRANSFER_FAILURE");
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP connection fd %d failed, reason %d\n",
          TOS_NODE_ID, fd, reason);
      if (record != NULL && record->isClient) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP client transfer failed: accepted %d acknowledged %d of %d\n",
             TOS_NODE_ID, record->acceptedBytes, record->acknowledgedBytes,
             record->requestedBytes);
      } else if (record != NULL) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP server consumer ended after %d bytes; mismatches %d\n",
             TOS_NODE_ID, record->consumedBytes, record->mismatches);
      }
      clearTestConnection(fd);
   }

   command error_t TransportNetwork.send(uint16_t destination,
                                         const uint8_t *payload) {
      pack p;
      const tcp_segment_t *segment = (const tcp_segment_t *)payload;
      socket_t fd;
      test_connection_t *record;
      // Each transport transmission, including a retry, gets a fresh network packet ID.
      makePack(&p, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_TCP,
               nextSequenceNumber++, payload);
      fd = findTestEndpoint(TOS_NODE_ID, segment->srcPort, destination,
                            segment->destPort, FALSE);
      record = testConnection(fd);
      if (record != NULL && segment->kindLength == TCP_CODE_ACK &&
          segment->window == 0) {
         record->sawZeroWindow = TRUE;
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP test receiver advertised zero window on fd %d\n",
             TOS_NODE_ID, fd);
      }
      if (record != NULL && record->dropNextWindowUpdate &&
          segment->kindLength == TCP_CODE_ACK &&
          segment->window > 0) {
         record->dropNextWindowUpdate = FALSE;
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP test dropped reopening window update packet %d\n",
             TOS_NODE_ID, p.seq);
         return SUCCESS;
      }
      if (destination == TOS_NODE_ID) {
         processRouted(&p);
         return SUCCESS;
      }
      return sendRouted(&p) ? SUCCESS : FAIL;
   }

   void processRouted(pack *p) {
      uint16_t next;
      uint8_t cost;

      if (PACK_TTL(p) == 0) return;
      if (p->dest == TOS_NODE_ID) {
         if (PACK_PROTOCOL(p) == PROTOCOL_TCP) {
            call Transport.receive(p);
         } else if (PACK_PROTOCOL(p) == PROTOCOL_PING) {
            pack reply;
            makePack(&reply, TOS_NODE_ID, p->src, MAX_TTL,
                     PROTOCOL_PINGREPLY, nextSequenceNumber++, p->payload);
            sendRouted(&reply);
         } else if (PACK_PROTOCOL(p) == PROTOCOL_PINGREPLY) {
            dbg(ROUTING_CHANNEL,
                "Node %d received ping reply from %d seq %d\n",
                TOS_NODE_ID, p->src, p->seq);
         }
         return;
      }

      if (PACK_TTL(p) <= 1 ||
          !call DistanceVector.nextHop(p->dest, &next, &cost)) {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped routed packet src %d dest %d seq %d\n",
             TOS_NODE_ID, p->src, p->dest, p->seq);
         return;
      }

      PACK_SET_TTL(p, PACK_TTL(p) - 1);
      // Each forwarding event handles one packet, so routing work stays bounded.
      if (call Sender.send(*p, next) == SUCCESS) {
         dbg(ROUTING_CHANNEL,
             "Node %d Routing Packet - src: %d, dest: %d, seq: %d, next hop: %d, cost: %d\n",
             TOS_NODE_ID, p->src, p->dest, p->seq, next, cost);
      } else {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped routed packet seq %d: send queue full\n",
             TOS_NODE_ID, p->seq);
      }
   }

   bool sendRouted(pack *p) {
      uint16_t next;
      uint8_t cost;
      if (p->dest == TOS_NODE_ID) return FALSE;
      // Resolve the next hop on every send so retries use repaired or changed routes.
      if (!call DistanceVector.nextHop(p->dest, &next, &cost)) {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped packet src %d dest %d seq %d: no route\n",
             TOS_NODE_ID, p->src, p->dest, p->seq);
         return FALSE;
      }
      if (call Sender.send(*p, next) == SUCCESS) {
         dbg(ROUTING_CHANNEL,
             "Node %d Routing Packet - src: %d, dest: %d, seq: %d, next hop: %d, cost: %d\n",
             TOS_NODE_ID, p->src, p->dest, p->seq, next, cost);
         return TRUE;
      }
      return FALSE;
   }

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl,
                 uint8_t protocol, uint16_t seq, const void *payload) {
      p->src = src;
      p->dest = dest;
      p->seq = seq;
      p->ttlProtocol = ((ttl & 0x0f) << 4) | (protocol & 0x0f);
      memcpy(p->payload, payload, PACKET_MAX_PAYLOAD_SIZE);
   }
}
