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
   provides interface TransportNetwork;
}
implementation {
   uint16_t nextSequenceNumber = 0;
   socket_t serverSocket = SOCKET_NONE;
   socket_t serverConnection = SOCKET_NONE;
   socket_t clientSocket = SOCKET_NONE;
   uint16_t clientServerAddress = 0;
   uint8_t clientSourcePort = 0;
   uint8_t clientDestinationPort = 0;
   uint16_t requestedTransfer = 0;
   uint16_t serverBytesReceived = 0;

   void makePack(pack *p, uint16_t src, uint16_t dest, uint8_t ttl,
                 uint8_t protocol, uint16_t seq, const void *payload);
   bool sendRouted(pack *p);
   void processRouted(pack *p);

   event void Boot.booted() {
      call AMControl.start();
      call NeighborDiscovery.start();
      call DistanceVector.start();
   }

   event void AMControl.startDone(error_t err) {
      if (err != SUCCESS) call AMControl.start();
   }

   event void AMControl.stopDone(error_t err) {}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      pack *received;
      if (len != sizeof(pack)) return msg;

      received = (pack *)payload;
      if (received->protocol == PROTOCOL_PING ||
          received->protocol == PROTOCOL_PINGREPLY ||
          received->protocol == PROTOCOL_TCP) {
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
          transferBytes == 0 || transferBytes > SOCKET_BUFFER_SIZE) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d rejected invalid TCP client command\n", TOS_NODE_ID);
         return;
      }
      if (clientSocket != SOCKET_NONE) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d already has a TCP test client\n", TOS_NODE_ID);
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

      clientSocket = fd;
      clientServerAddress = serverAddress;
      clientSourcePort = sourcePort;
      clientDestinationPort = destinationPort;
      requestedTransfer = transferBytes;
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP test client connecting to %d:%d for %d bytes\n",
          TOS_NODE_ID, serverAddress, destinationPort, transferBytes);
      if (call Transport.connect(fd, &remote) != SUCCESS) {
         clientSocket = SOCKET_NONE;
         call Transport.release(fd);
         dbg(TRANSPORT_CHANNEL,
             "Node %d failed to start TCP connection\n", TOS_NODE_ID);
      }
   }

   event void CommandHandler.closeTestClient(uint16_t clientAddress,
                                             uint16_t serverAddress,
                                             uint8_t sourcePort,
                                             uint8_t destinationPort) {
      if (clientAddress != TOS_NODE_ID || clientSocket == SOCKET_NONE ||
          serverAddress != clientServerAddress ||
          sourcePort != clientSourcePort ||
          destinationPort != clientDestinationPort) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d rejected TCP close command: no matching client\n",
             TOS_NODE_ID);
         return;
      }
      if (call Transport.close(clientSocket) != SUCCESS) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d could not close TCP client %d:%d -> %d:%d\n",
             TOS_NODE_ID, clientAddress, sourcePort,
             serverAddress, destinationPort);
      } else {
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP client close requested\n", TOS_NODE_ID);
      }
   }

   event void Transport.connectionEstablished(socket_t fd) {
      if (fd == clientSocket) {
         uint8_t data[SOCKET_BUFFER_SIZE];
         uint16_t i;
         uint16_t accepted;

         for (i = 0; i < requestedTransfer; i++) data[i] = i & 0xff;
         accepted = call Transport.write(fd, data, requestedTransfer);
         // This count is local queue acceptance; peer ACKs are logged by TransportP.
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP client established; queued %d/%d bytes\n",
             TOS_NODE_ID, accepted, requestedTransfer);
         if (accepted != requestedTransfer) {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP client could not queue full transfer\n",
                TOS_NODE_ID);
            call Transport.release(fd);
            clientSocket = SOCKET_NONE;
         }
      } else {
         socket_t accepted;
         if (serverSocket == SOCKET_NONE) return;
         accepted = call Transport.accept(serverSocket);
         if (accepted != fd) {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP listener could not accept child fd %d\n",
                TOS_NODE_ID, fd);
            return;
         }
         serverConnection = accepted;
         serverBytesReceived = 0;
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP server accepted connection fd %d\n",
             TOS_NODE_ID, fd);
      }
   }

   event void Transport.dataReceived(socket_t fd) {
      uint8_t data[SOCKET_BUFFER_SIZE];
      uint16_t amount;
      uint16_t i;
      bool valid = TRUE;

      if (fd != serverConnection) return;
      amount = call Transport.read(fd, data, sizeof(data));
      // A read here means the test application consumed the delivered bytes.
      for (i = 0; i < amount; i++) {
         if (data[i] != ((serverBytesReceived + i) & 0xff)) valid = FALSE;
      }
      serverBytesReceived += amount;
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP test data: %d bytes, pattern %s (total %d)\n",
          TOS_NODE_ID, amount, valid ? "valid" : "INVALID",
          serverBytesReceived);
   }

   event void Transport.connectionClosed(socket_t fd) {
      if (fd == serverConnection) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP server connection closed after %d bytes\n",
             TOS_NODE_ID, serverBytesReceived);
         serverConnection = SOCKET_NONE;
      } else if (fd == clientSocket) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP client connection closed\n", TOS_NODE_ID);
         clientSocket = SOCKET_NONE;
      }
   }

   event void Transport.connectionFailed(socket_t fd, uint8_t reason) {
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP connection fd %d failed, reason %d\n",
          TOS_NODE_ID, fd, reason);
      if (fd == clientSocket) clientSocket = SOCKET_NONE;
      if (fd == serverConnection) serverConnection = SOCKET_NONE;
   }

   command error_t TransportNetwork.send(uint16_t destination,
                                         const uint8_t *payload) {
      pack p;
      makePack(&p, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_TCP,
               nextSequenceNumber++, payload);
      if (destination == TOS_NODE_ID) {
         processRouted(&p);
         return SUCCESS;
      }
      return sendRouted(&p) ? SUCCESS : FAIL;
   }

   void processRouted(pack *p) {
      uint16_t next;
      uint8_t cost;

      if (p->TTL == 0) return;
      if (p->dest == TOS_NODE_ID) {
         if (p->protocol == PROTOCOL_TCP) {
            call Transport.receive(p);
         } else if (p->protocol == PROTOCOL_PING) {
            pack reply;
            makePack(&reply, TOS_NODE_ID, p->src, MAX_TTL,
                     PROTOCOL_PINGREPLY, nextSequenceNumber++, p->payload);
            sendRouted(&reply);
         } else if (p->protocol == PROTOCOL_PINGREPLY) {
            dbg(ROUTING_CHANNEL,
                "Node %d received ping reply from %d seq %d\n",
                TOS_NODE_ID, p->src, p->seq);
         }
         return;
      }

      if (p->TTL <= 1 ||
          !call DistanceVector.nextHop(p->dest, &next, &cost)) {
         dbg(ROUTING_CHANNEL,
             "Node %d dropped routed packet src %d dest %d seq %d\n",
             TOS_NODE_ID, p->src, p->dest, p->seq);
         return;
      }

      p->TTL = p->TTL - 1;
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
      p->TTL = ttl;
      p->seq = seq;
      p->protocol = protocol;
      memcpy(p->payload, payload, PACKET_MAX_PAYLOAD_SIZE);
   }
}
