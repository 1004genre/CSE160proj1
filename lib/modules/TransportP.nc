#include <Timer.h>
#include <string.h>
#include "../../includes/packet.h"
#include "../../includes/socket.h"
#include "../../includes/tcp.h"
#include "../../includes/channels.h"

module TransportP {
   provides interface Transport;
   uses interface TransportNetwork as Network;
   uses interface Boot;
   uses interface Timer<TMilli> as RetryTimer;
}
implementation {
   socket_store_t sockets[MAX_NUM_OF_SOCKETS];

   char *stateName(enum socket_state state) {
      switch (state) {
         case LISTEN: return "LISTEN";
         case ESTABLISHED: return "ESTABLISHED";
         case SYN_SENT: return "SYN_SENT";
         case SYN_RCVD: return "SYN_RCVD";
         case FIN_WAIT_1: return "FIN_WAIT_1";
         case FIN_WAIT_2: return "FIN_WAIT_2";
         case LAST_ACK: return "LAST_ACK";
         case TIME_WAIT: return "TIME_WAIT";
         default: return "CLOSED";
      }
   }

   void setState(socket_t fd, enum socket_state state) {
      enum socket_state previous = sockets[fd].state;

      if (previous == CLOSED && state == SYN_SENT) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d: CLOSED -> SYN_SENT\n", TOS_NODE_ID);
      } else if (previous == CLOSED && state == SYN_RCVD) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d: LISTEN -> SYN_RCVD\n", TOS_NODE_ID);
      } else if (previous == SYN_SENT && state == ESTABLISHED) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d: SYN_SENT -> ESTABLISHED\n", TOS_NODE_ID);
      } else if (previous == SYN_RCVD && state == ESTABLISHED) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d: SYN_RCVD -> ESTABLISHED\n", TOS_NODE_ID);
      } else if (previous == ESTABLISHED && state == FIN_WAIT_1) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d: ESTABLISHED -> FIN_WAIT_1\n", TOS_NODE_ID);
      } else if (previous == ESTABLISHED && state == LAST_ACK) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d: ESTABLISHED -> LAST_ACK\n", TOS_NODE_ID);
      } else if (previous == FIN_WAIT_2 && state == TIME_WAIT) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d: FIN_WAIT_1/FIN_WAIT_2 -> TIME_WAIT\n", TOS_NODE_ID);
      }

      dbg(TRANSPORT_CHANNEL, "Node %d TCP fd %d state %s -> %s\n",
          TOS_NODE_ID, fd, stateName(previous), stateName(state));
      sockets[fd].state = state;
   }

   bool validSocket(socket_t fd) {
      return fd < MAX_NUM_OF_SOCKETS && sockets[fd].allocated;
   }

   socket_t allocateSocket() {
      socket_t fd;
      for (fd = 0; fd < MAX_NUM_OF_SOCKETS; fd++) {
         if (!sockets[fd].allocated) {
            memset(&sockets[fd], 0, sizeof(socket_store_t));
            sockets[fd].allocated = TRUE;
            sockets[fd].state = CLOSED;
            sockets[fd].pendingChild = SOCKET_NONE;
            sockets[fd].senderWindow = TCP_SENDER_WINDOW_SIZE;
            return fd;
         }
      }
      return SOCKET_NONE;
   }

   void clearSocket(socket_t fd) {
      uint8_t i;
      enum socket_state previous = sockets[fd].state;
      for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         if (sockets[i].allocated && sockets[i].pendingChild == fd) {
            sockets[i].pendingChild = SOCKET_NONE;
         }
      }
      if (previous == LAST_ACK) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d closes and releases its connection\n", TOS_NODE_ID);
      } else if (previous == TIME_WAIT) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d releases its record after TIME_WAIT\n", TOS_NODE_ID);
      }
      dbg(TRANSPORT_CHANNEL, "Node %d TCP fd %d released\n",
          TOS_NODE_ID, fd);
      memset(&sockets[fd], 0, sizeof(socket_store_t));
   }

   // Keep closing tuples until retry retention expires and unread bytes are consumed.
   void releaseIfDrained(socket_t fd) {
      if (!validSocket(fd) || sockets[fd].rcvLength != 0 ||
          sockets[fd].hasOutstanding || !sockets[fd].localFinAcknowledged ||
          sockets[fd].state != TIME_WAIT || !sockets[fd].timeWaitExpired) {
         return;
      }
      // connectionClosed means both FIN acknowledgment and local consumption completed.
      signal Transport.connectionClosed(fd);
      clearSocket(fd);
   }

   socket_t findConnection(uint16_t remoteAddr, uint8_t remotePort,
                           uint16_t localAddr, uint8_t localPort) {
      socket_t fd;
      for (fd = 0; fd < MAX_NUM_OF_SOCKETS; fd++) {
         if (sockets[fd].allocated && sockets[fd].state != LISTEN &&
             sockets[fd].localAddr == localAddr &&
             sockets[fd].localPort == localPort &&
             sockets[fd].remoteAddr == remoteAddr &&
             sockets[fd].remotePort == remotePort) {
            return fd;
         }
      }
      return SOCKET_NONE;
   }

   socket_t findListener(uint16_t localAddr, uint8_t localPort) {
      socket_t fd;
      for (fd = 0; fd < MAX_NUM_OF_SOCKETS; fd++) {
         if (sockets[fd].allocated && sockets[fd].state == LISTEN &&
             sockets[fd].localAddr == localAddr &&
             sockets[fd].localPort == localPort) {
            return fd;
         }
      }
      return SOCKET_NONE;
   }

   uint8_t receiveWindow(socket_store_t *connection) {
      if (connection->rcvLength >= SOCKET_BUFFER_SIZE) return 0;
      return SOCKET_BUFFER_SIZE - connection->rcvLength;
   }

   error_t sendSegment(socket_t fd, uint8_t flags, uint16_t seq,
                       uint16_t ack, const uint8_t *data, uint8_t length,
                       bool track) {
      tcp_segment_t segment;
      uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
      error_t result;

      if (!validSocket(fd) || length > TCP_DATA_SIZE ||
          (length > 0 && data == NULL)) return FAIL;

      memset(&segment, 0, sizeof(segment));
      segment.srcPort = sockets[fd].localPort;
      segment.destPort = sockets[fd].remotePort;
      segment.flags = flags;
      segment.dataLength = length;
      segment.seq = seq;
      segment.ack = ack;
      segment.window = receiveWindow(&sockets[fd]);
      if (length > 0) memcpy(segment.data, data, length);

      memset(payload, 0, sizeof(payload));
      memcpy(payload, &segment, sizeof(segment));
      if (track) {
         memcpy(&sockets[fd].lastSegment, &segment, sizeof(segment));
         sockets[fd].hasOutstanding = TRUE;
         sockets[fd].controlOutstanding = TRUE;
         sockets[fd].retries = 0;
         sockets[fd].elapsedSeconds = 0;
      }
      result = call Network.send(sockets[fd].remoteAddr, payload);
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP fd %d send flags %d seq %d ack %d len %d window %d%s\n",
          TOS_NODE_ID, fd, flags, seq, ack, length, segment.window,
          track ? " tracked" : "");
      return result;
   }

   void sendDataRange(socket_t fd, uint16_t sequence, uint16_t offset,
                      uint16_t length) {
      uint8_t chunk;
      if (!validSocket(fd) || sockets[fd].sendLength > SOCKET_BUFFER_SIZE ||
          offset > sockets[fd].sendLength ||
          length > sockets[fd].sendLength - offset) return;
      while (length > 0) {
         chunk = length > TCP_DATA_SIZE ? TCP_DATA_SIZE : length;
         // Replaying a retained range does not advance sequence or app byte counts.
         sendSegment(fd, TCP_FLAG_DATA, sequence, 0,
                     &sockets[fd].sendBuff[offset], chunk, FALSE);
         sequence += chunk;
         offset += chunk;
         length -= chunk;
      }
   }

   void resendOutstanding(socket_t fd) {
      uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
      uint16_t outstanding;
      uint16_t retransmitLength;
      uint16_t window;
      if (sockets[fd].controlOutstanding) {
         memset(payload, 0, sizeof(payload));
         memcpy(payload, &sockets[fd].lastSegment,
                sizeof(tcp_segment_t));
         call Network.send(sockets[fd].remoteAddr, payload);
      } else {
         // Go-back-N starts at the oldest byte and stays inside the current peer window.
         outstanding = sockets[fd].sendNext - sockets[fd].sendUna;
         window = sockets[fd].senderWindow < sockets[fd].peerWindow ?
                  sockets[fd].senderWindow : sockets[fd].peerWindow;
         retransmitLength = outstanding < window ? outstanding : window;
         sendDataRange(fd, sockets[fd].sendUna, 0,
                       retransmitLength);
      }
      dbg(TRANSPORT_CHANNEL, "Node %d TCP fd %d retransmit #%d\n",
          TOS_NODE_ID, fd, sockets[fd].retries);
   }

   void sendAck(socket_t fd) {
      sendSegment(fd, TCP_FLAG_ACK, sockets[fd].sendNext,
                  sockets[fd].rcvNext, NULL, 0, FALSE);
   }

   void sendFin(socket_t fd, enum socket_state state) {
      uint16_t seq = sockets[fd].sendNext;
      sockets[fd].sendNext++;
      setState(fd, state);
      if (state == LAST_ACK) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d sends FIN\n", TOS_NODE_ID);
      }
      // FIN consumes one sequence number; its ACK is sent separately.
      sendSegment(fd, TCP_FLAG_FIN, seq, 0, NULL, 0, TRUE);
   }

   void pumpData(socket_t fd) {
      uint16_t outstanding;
      uint16_t unsent;
      uint16_t window;
      uint16_t allowance;
      uint8_t length;

      if (!validSocket(fd) || sockets[fd].state != ESTABLISHED ||
          sockets[fd].controlOutstanding) return;

      // The buffer prefix is in flight; only its suffix is eligible for sending.
      if (sockets[fd].sendLength > SOCKET_BUFFER_SIZE ||
          sockets[fd].sendNext < sockets[fd].sendUna) return;
      outstanding = sockets[fd].sendNext - sockets[fd].sendUna;
      if (outstanding > sockets[fd].sendLength) return;
      window = sockets[fd].senderWindow < sockets[fd].peerWindow ?
               sockets[fd].senderWindow : sockets[fd].peerWindow;
      unsent = sockets[fd].sendLength > outstanding ?
               sockets[fd].sendLength - outstanding : 0;
      while (unsent > 0 && outstanding < window) {
         allowance = window - outstanding;
         length = unsent > TCP_DATA_SIZE ? TCP_DATA_SIZE : unsent;
         if (length > allowance) length = allowance;
         if (outstanding >= SOCKET_BUFFER_SIZE || length == 0) return;
         if (!sockets[fd].hasOutstanding) {
            sockets[fd].hasOutstanding = TRUE;
            sockets[fd].controlOutstanding = FALSE;
            sockets[fd].retries = 0;
            sockets[fd].elapsedSeconds = 0;
         }
         // Fill the fixed sender window with separate data and ACK segments.
         sendSegment(fd, TCP_FLAG_DATA, sockets[fd].sendNext, 0,
                     &sockets[fd].sendBuff[outstanding], length, FALSE);
         sockets[fd].sendNext += length;
         outstanding += length;
         unsent -= length;
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d window DATA seq %d len %d outstanding %d/%d\n",
             TOS_NODE_ID, fd, sockets[fd].sendNext - length, length,
             outstanding, window);
      }

      if (sockets[fd].closeRequested && sockets[fd].sendLength == 0 &&
          !sockets[fd].hasOutstanding) {
         sendFin(fd, sockets[fd].peerFinReceived ? LAST_ACK : FIN_WAIT_1);
      }
   }

   void reportFailure(socket_t fd, uint8_t reason) {
      signal Transport.connectionFailed(fd, reason);
      clearSocket(fd);
   }

   void processAck(socket_t fd, tcp_segment_t *segment) {
      uint16_t highestSent;
      uint16_t newlyAcked;
      uint16_t outstanding;
      uint8_t previousWindow;

      if (!(segment->flags & TCP_FLAG_ACK)) return;
      if (sockets[fd].sendNext < sockets[fd].sendUna ||
          sockets[fd].sendLength > SOCKET_BUFFER_SIZE) return;
      highestSent = sockets[fd].sendNext;
      if (sockets[fd].controlOutstanding &&
          (sockets[fd].lastSegment.flags & TCP_FLAG_FIN)) {
         highestSent = sockets[fd].lastSegment.seq + 1;
      }
      // ACKs outside sent sequence space cannot move the window or free storage.
      if (segment->ack < sockets[fd].sendUna ||
          segment->ack > highestSent) return;

      previousWindow = sockets[fd].peerWindow;
      sockets[fd].peerWindow = segment->window;
      if (sockets[fd].persistProbing) {
         // Any in-range ACK proves the peer is alive; zero window alone is not failure.
         if (previousWindow == 0 && segment->window > 0) {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP fd %d window reopened after probe: %d bytes\n",
                TOS_NODE_ID, fd, segment->window);
         }
         sockets[fd].persistProbing = FALSE;
         sockets[fd].retries = 0;
         sockets[fd].elapsedSeconds = 0;
      }
      if (sockets[fd].controlOutstanding) {
         if ((sockets[fd].lastSegment.flags & TCP_FLAG_FIN) &&
             segment->ack == sockets[fd].lastSegment.seq + 1) {
            sockets[fd].sendUna = segment->ack;
            sockets[fd].hasOutstanding = FALSE;
            sockets[fd].controlOutstanding = FALSE;
            sockets[fd].localFinAcknowledged = TRUE;
            sockets[fd].elapsedSeconds = 0;
            if (sockets[fd].state == FIN_WAIT_1) {
               setState(fd, FIN_WAIT_2);
            } else if (sockets[fd].state == LAST_ACK) {
               // Retain the passive tuple too, so delayed packets cannot reopen it.
               sockets[fd].timeWaitSeconds = 0;
               sockets[fd].timeWaitExpired = FALSE;
               setState(fd, TIME_WAIT);
            }
            releaseIfDrained(fd);
         }
         return;
      }

      if (segment->ack > sockets[fd].sendUna) {
         newlyAcked = segment->ack - sockets[fd].sendUna;
         outstanding = sockets[fd].sendNext - sockets[fd].sendUna;
         if (newlyAcked > outstanding || newlyAcked > sockets[fd].sendLength) {
            return;
         }
         // Slide retained storage only over bytes cumulatively acknowledged in order.
         memmove(sockets[fd].sendBuff,
                 &sockets[fd].sendBuff[newlyAcked],
                 sockets[fd].sendLength - newlyAcked);
         sockets[fd].sendLength -= newlyAcked;
         sockets[fd].sendAcked += newlyAcked;
         sockets[fd].sendUna = segment->ack;
         sockets[fd].elapsedSeconds = 0;
         sockets[fd].retries = 0;
         if (sockets[fd].sendUna == sockets[fd].sendNext) {
            sockets[fd].hasOutstanding = FALSE;
         }
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d data acknowledged %d/%d\n",
             TOS_NODE_ID, fd, sockets[fd].sendAcked,
             sockets[fd].sendTotal);
         // Notify the app that cumulative progress freed local send-buffer space.
         signal Transport.sendReady(fd);
      }
      pumpData(fd); // An ACK or valid window update may allow another segment.
   }

   void receiveData(socket_t fd, tcp_segment_t *segment) {
      if (segment->dataLength == 0) return;
      if (!(segment->flags & TCP_FLAG_DATA) ||
          segment->dataLength > TCP_DATA_SIZE) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d dropped malformed data length %d\n",
             TOS_NODE_ID, fd, segment->dataLength);
         return;
      }

      if (sockets[fd].rcvLength > SOCKET_BUFFER_SIZE) {
         sendAck(fd);
         return;
      }
      if (sockets[fd].rcvTotal > TCP_MAX_TRANSFER_BYTES ||
          segment->dataLength > TCP_MAX_TRANSFER_BYTES - sockets[fd].rcvTotal) {
         sendAck(fd);
         return;
      }

      if (sockets[fd].peerFinReceived) {
         sendAck(fd);
         return;
      }

      // Accept only the next expected byte; discard gaps and duplicates, then ACK the gap edge.
      if (segment->seq == sockets[fd].rcvNext &&
          segment->dataLength <= SOCKET_BUFFER_SIZE - sockets[fd].rcvLength) {
         memcpy(&sockets[fd].rcvdBuff[sockets[fd].rcvLength],
                segment->data, segment->dataLength);
         sockets[fd].rcvLength += segment->dataLength;
         sockets[fd].rcvTotal += segment->dataLength;
         sockets[fd].rcvNext += segment->dataLength;
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d receive buffer %d/128 window %d\n",
             TOS_NODE_ID, fd, sockets[fd].rcvLength,
             receiveWindow(&sockets[fd]));
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d accepted data seq %d len %d next %d\n",
             TOS_NODE_ID, fd, segment->seq, segment->dataLength,
             sockets[fd].rcvNext);
         sendAck(fd);
         signal Transport.dataReceived(fd);
      } else {
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d duplicate/out-of-order seq %d expected %d\n",
             TOS_NODE_ID, fd, segment->seq, sockets[fd].rcvNext);
         sendAck(fd);
      }
   }

   command socket_t Transport.socket() {
      return allocateSocket();
   }

   command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
      socket_t i;
      if (!validSocket(fd) || addr == NULL ||
          sockets[fd].state != CLOSED ||
          (addr->addr != TOS_NODE_ID) || addr->port == 0) {
         return FAIL;
      }

      for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         if (i != fd && sockets[i].allocated &&
             sockets[i].localAddr == addr->addr &&
             sockets[i].localPort == addr->port &&
             sockets[i].localPort != 0) {
            return FAIL;
         }
      }

      sockets[fd].localAddr = addr->addr;
      sockets[fd].localPort = addr->port;
      return SUCCESS;
   }

   command error_t Transport.listen(socket_t fd) {
      if (!validSocket(fd) || sockets[fd].state != CLOSED ||
          sockets[fd].localPort == 0) return FAIL;
      sockets[fd].pendingChild = SOCKET_NONE;
      setState(fd, LISTEN);
      return SUCCESS;
   }

   command socket_t Transport.accept(socket_t fd) {
      socket_t child;
      if (!validSocket(fd) || sockets[fd].state != LISTEN) {
         return SOCKET_NONE;
      }
      child = sockets[fd].pendingChild;
      if (!validSocket(child) || sockets[child].state != ESTABLISHED) {
         return SOCKET_NONE;
      }
      sockets[fd].pendingChild = SOCKET_NONE;
      sockets[child].accepted = TRUE;
      return child;
   }

   command error_t Transport.connect(socket_t fd, socket_addr_t *addr) {
      if (!validSocket(fd) || addr == NULL ||
          sockets[fd].state != CLOSED ||
          sockets[fd].localPort == 0 || addr->addr == TOS_NODE_ID ||
          addr->port == 0) {
         return FAIL;
      }

      sockets[fd].remoteAddr = addr->addr;
      sockets[fd].remotePort = addr->port;
      sockets[fd].sendUna = TCP_INITIAL_SEQUENCE;
      sockets[fd].sendNext = TCP_INITIAL_SEQUENCE + 1;
      setState(fd, SYN_SENT);
      sendSegment(fd, TCP_FLAG_SYN, TCP_INITIAL_SEQUENCE, 0, NULL, 0, TRUE);
      return SUCCESS;
   }

   command uint16_t Transport.write(socket_t fd, uint8_t *buff,
                                    uint16_t bufflen) {
      uint16_t available;
      uint16_t accepted;
      uint16_t transferRemaining;

      if (!validSocket(fd) || buff == NULL ||
          sockets[fd].state != ESTABLISHED || sockets[fd].closeRequested) {
         return 0;
      }
      if (sockets[fd].sendLength > SOCKET_BUFFER_SIZE) return 0;
      if (sockets[fd].sendTotal >= TCP_MAX_TRANSFER_BYTES) return 0;
      // Return only the bytes copied into this connection's local send buffer.
      available = SOCKET_BUFFER_SIZE - sockets[fd].sendLength;
      transferRemaining = TCP_MAX_TRANSFER_BYTES - sockets[fd].sendTotal;
      accepted = bufflen < available ? bufflen : available;
      if (accepted > transferRemaining) accepted = transferRemaining;
      if (accepted > 0) {
         memcpy(&sockets[fd].sendBuff[sockets[fd].sendLength], buff, accepted);
         sockets[fd].sendLength += accepted;
         sockets[fd].sendTotal += accepted;
         if (!sockets[fd].hasOutstanding) {
            sockets[fd].elapsedSeconds = 0;
         }
         pumpData(fd);
      }
      return accepted;
   }

   command uint16_t Transport.read(socket_t fd, uint8_t *buff,
                                   uint16_t bufflen) {
      uint16_t amount;
      if (!validSocket(fd) || buff == NULL ||
          sockets[fd].rcvLength > SOCKET_BUFFER_SIZE) return 0;

      amount = bufflen < sockets[fd].rcvLength ?
               bufflen : sockets[fd].rcvLength;
      if (amount > 0) {
         memcpy(buff, sockets[fd].rcvdBuff, amount);
         sockets[fd].rcvLength -= amount;
         memmove(sockets[fd].rcvdBuff,
                 &sockets[fd].rcvdBuff[amount], sockets[fd].rcvLength);
         // Consumption frees storage; advertise the larger window without waiting for data.
         sendAck(fd);
         releaseIfDrained(fd);
      }
      return amount;
   }

   command error_t Transport.close(socket_t fd) {
      if (!validSocket(fd)) return FAIL;
      if (sockets[fd].state == LISTEN) {
         clearSocket(fd);
         return SUCCESS;
      }
      if (sockets[fd].state != ESTABLISHED) return FAIL;
      sockets[fd].closeRequested = TRUE;
      pumpData(fd);
      return SUCCESS;
   }

   command error_t Transport.release(socket_t fd) {
      if (!validSocket(fd)) return FAIL;
      clearSocket(fd);
      return SUCCESS;
   }

   command error_t Transport.receive(pack *package) {
      tcp_segment_t *segment;
      socket_t fd;
      socket_t listener;
      bool controlOnly;

      if (package == NULL || package->protocol != PROTOCOL_TCP) return FAIL;
      segment = (tcp_segment_t *)package->payload;
      controlOnly = segment->flags == TCP_FLAG_SYN ||
                    segment->flags == TCP_FLAG_ACK ||
                    segment->flags == (TCP_FLAG_SYN | TCP_FLAG_ACK) ||
                    segment->flags == TCP_FLAG_FIN ||
                    segment->flags == TCP_FLAG_PROBE;
      // Accept only handshake, pure ACK, FIN, probe, or data-only wire forms.
      if (segment->window > SOCKET_BUFFER_SIZE ||
          (!controlOnly && segment->flags != TCP_FLAG_DATA) ||
          (controlOnly && segment->dataLength != 0) ||
          (segment->flags == TCP_FLAG_DATA &&
           (segment->dataLength == 0 ||
            segment->dataLength > TCP_DATA_SIZE))) {
         dbg(TRANSPORT_CHANNEL, "Node %d TCP dropped malformed segment\n",
             TOS_NODE_ID);
         return FAIL;
      }

      fd = findConnection(package->src, segment->srcPort,
                          package->dest, segment->destPort);
      if (fd == SOCKET_NONE && (segment->flags & TCP_FLAG_SYN) &&
          !(segment->flags & TCP_FLAG_ACK)) {
         // All nodes use ISN zero so plain integer comparisons remain no-wrap safe.
         if (segment->seq != TCP_INITIAL_SEQUENCE) return FAIL;
         listener = findListener(package->dest, segment->destPort);
         if (listener == SOCKET_NONE) {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP refused SYN from %d port %d: no listener\n",
                TOS_NODE_ID, package->src, segment->srcPort);
            return FAIL;
         }
         if (sockets[listener].pendingChild != SOCKET_NONE) {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP refused SYN: listener accept slot is occupied\n",
                TOS_NODE_ID);
            return FAIL;
         }

         fd = allocateSocket();
         if (fd == SOCKET_NONE) {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP refused SYN: no connection record available\n",
                TOS_NODE_ID);
            return FAIL;
         }
         sockets[fd].localAddr = package->dest;
         sockets[fd].localPort = segment->destPort;
         sockets[fd].remoteAddr = package->src;
         sockets[fd].remotePort = segment->srcPort;
         sockets[fd].sendNext = TCP_INITIAL_SEQUENCE + 1;
         sockets[fd].sendUna = TCP_INITIAL_SEQUENCE;
         sockets[fd].peerWindow = segment->window;
         sockets[fd].rcvNext = segment->seq + 1;
         sockets[fd].remoteInitialSequence = segment->seq;
         sockets[listener].pendingChild = fd;
         setState(fd, SYN_RCVD);
         sendSegment(fd, TCP_FLAG_SYN | TCP_FLAG_ACK, TCP_INITIAL_SEQUENCE,
                     sockets[fd].rcvNext, NULL, 0, TRUE);
         // Keep SYN-ACK available after its ACK so duplicate SYNs get the same reply.
         memcpy(&sockets[fd].handshakeReply, &sockets[fd].lastSegment,
                sizeof(tcp_segment_t));
         return SUCCESS;
      }

      if (!validSocket(fd)) {
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP dropped unmatched segment src %d:%d dest %d:%d\n",
             TOS_NODE_ID, package->src, segment->srcPort,
             package->dest, segment->destPort);
         return FAIL;
      }

      if (sockets[fd].state == SYN_RCVD &&
          (segment->flags & TCP_FLAG_SYN) &&
          !(segment->flags & TCP_FLAG_ACK) &&
          segment->seq == sockets[fd].remoteInitialSequence) {
         resendOutstanding(fd);
         return SUCCESS;
      }

      if (sockets[fd].state == SYN_SENT) {
         if ((segment->flags & (TCP_FLAG_SYN | TCP_FLAG_ACK)) ==
                (TCP_FLAG_SYN | TCP_FLAG_ACK) &&
             segment->seq == TCP_INITIAL_SEQUENCE &&
             segment->ack == sockets[fd].sendNext) {
            sockets[fd].hasOutstanding = FALSE;
            sockets[fd].controlOutstanding = FALSE;
            sockets[fd].sendUna = segment->ack;
            sockets[fd].peerWindow = segment->window;
            sockets[fd].rcvNext = segment->seq + 1;
            sockets[fd].remoteInitialSequence = segment->seq;
            setState(fd, ESTABLISHED);
            sendAck(fd);
            signal Transport.connectionEstablished(fd);
         } else {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP fd %d ignored invalid SYN-ACK ack %d\n",
                TOS_NODE_ID, fd, segment->ack);
         }
         return SUCCESS;
      }

      if (sockets[fd].state == SYN_RCVD) {
         if ((segment->flags & TCP_FLAG_ACK) &&
             segment->ack == sockets[fd].sendNext &&
             segment->seq == sockets[fd].rcvNext) {
            sockets[fd].hasOutstanding = FALSE;
            sockets[fd].controlOutstanding = FALSE;
            sockets[fd].sendUna = segment->ack;
            sockets[fd].peerWindow = segment->window;
            setState(fd, ESTABLISHED);
            signal Transport.connectionEstablished(fd);
         } else {
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP fd %d ignored invalid handshake ACK\n",
                TOS_NODE_ID, fd);
         }
         return SUCCESS;
      }

      if (sockets[fd].state == ESTABLISHED &&
          (segment->flags & (TCP_FLAG_SYN | TCP_FLAG_ACK)) ==
             (TCP_FLAG_SYN | TCP_FLAG_ACK) &&
          segment->ack == TCP_INITIAL_SEQUENCE + 1 &&
          segment->seq == sockets[fd].remoteInitialSequence) {
         sendAck(fd);
         return SUCCESS;
      }

      if (sockets[fd].state == ESTABLISHED &&
          segment->flags == TCP_FLAG_SYN &&
          segment->seq == sockets[fd].remoteInitialSequence &&
          sockets[fd].handshakeReply.flags ==
             (TCP_FLAG_SYN | TCP_FLAG_ACK)) {
         // The tuple already exists; replay the original SYN-ACK without allocating.
         uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
         memset(payload, 0, sizeof(payload));
         memcpy(payload, &sockets[fd].handshakeReply,
                sizeof(tcp_segment_t));
         call Network.send(sockets[fd].remoteAddr, payload);
         return SUCCESS;
      }

      if (segment->flags == TCP_FLAG_PROBE) {
         if (sockets[fd].state == ESTABLISHED ||
             sockets[fd].state == FIN_WAIT_1 ||
             sockets[fd].state == FIN_WAIT_2 ||
             sockets[fd].state == LAST_ACK ||
             sockets[fd].state == TIME_WAIT) {
            sockets[fd].peerWindow = segment->window;
            sendAck(fd); // A probe requests a window update, not application data.
            pumpData(fd);
         }
         return SUCCESS;
      }

      processAck(fd, segment);
      if (!validSocket(fd)) return SUCCESS;

      if (segment->dataLength > 0) {
         // Data packets also advertise the sender's latest receive window.
         sockets[fd].peerWindow = segment->window;
         receiveData(fd, segment);
         pumpData(fd);
      }

      if (segment->flags & TCP_FLAG_FIN) {
         sockets[fd].peerWindow = segment->window;
         if (!sockets[fd].peerFinReceived &&
             segment->seq == sockets[fd].rcvNext) {
            sockets[fd].rcvNext++;
            sockets[fd].peerFinReceived = TRUE;
            sendAck(fd);
            if (sockets[fd].state == FIN_WAIT_1 ||
                sockets[fd].state == FIN_WAIT_2) {
               dbg(TRANSPORT_CHANNEL,
                   "Node %d sends the final ACK\n", TOS_NODE_ID);
            }
            if (sockets[fd].state == ESTABLISHED) {
               // Drain queued server data before its FIN; close blocks new writes.
               sockets[fd].closeRequested = TRUE;
               pumpData(fd);
            } else if (sockets[fd].state == FIN_WAIT_1 ||
                       sockets[fd].state == FIN_WAIT_2) {
               sockets[fd].timeWaitSeconds = 0;
               sockets[fd].timeWaitExpired = FALSE;
               setState(fd, TIME_WAIT);
            }
         } else {
            if (sockets[fd].state == TIME_WAIT &&
                segment->seq + 1 == sockets[fd].rcvNext) {
               // A repeated FIN gets a fresh full retention window after its ACK.
               sockets[fd].timeWaitSeconds = 0;
               sockets[fd].timeWaitExpired = FALSE;
            }
            sendAck(fd);
            pumpData(fd);
         }
      }

      return SUCCESS;
   }

   event void Boot.booted() {
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP sizes: packet %d payload %d header %d data %d segment %d\n",
          TOS_NODE_ID, sizeof(pack), PACKET_MAX_PAYLOAD_SIZE,
          TCP_HEADER_SIZE, TCP_DATA_SIZE, sizeof(tcp_segment_t));
      call RetryTimer.startPeriodic(TCP_TIMER_INTERVAL_MS);
   }

   event void RetryTimer.fired() {
      socket_t fd;
      for (fd = 0; fd < MAX_NUM_OF_SOCKETS; fd++) {
         if (!sockets[fd].allocated) continue;

         if (sockets[fd].state == TIME_WAIT &&
             !sockets[fd].timeWaitExpired) {
            sockets[fd].timeWaitSeconds++;
            if (sockets[fd].timeWaitSeconds >= TCP_TIME_WAIT_SECONDS) {
               sockets[fd].timeWaitExpired = TRUE;
            }
         }
         if (sockets[fd].state == ESTABLISHED &&
             sockets[fd].sendLength > 0 &&
             sockets[fd].peerWindow == 0) {
            // A zero window pauses data retries; only unanswered window probes fail.
            if (!sockets[fd].persistProbing) {
               sockets[fd].persistProbing = TRUE;
               sockets[fd].retries = 0;
               sockets[fd].elapsedSeconds = 0;
            }
            sockets[fd].elapsedSeconds++;
            if (sockets[fd].elapsedSeconds >= TCP_RTO_SECONDS) {
               if (sockets[fd].retries >= TCP_MAX_RETRIES) {
                  reportFailure(fd, TCP_FAILURE_RETRY_LIMIT);
               } else {
                  sockets[fd].retries++;
                  sockets[fd].elapsedSeconds = 0;
                  sendSegment(fd, TCP_FLAG_PROBE, sockets[fd].sendNext,
                              sockets[fd].rcvNext, NULL, 0, FALSE);
               }
            }
         } else if (sockets[fd].hasOutstanding) {
            sockets[fd].elapsedSeconds++;
            if (sockets[fd].elapsedSeconds >= TCP_RTO_SECONDS) {
               if (sockets[fd].retries >= TCP_MAX_RETRIES) {
                  dbg(TRANSPORT_CHANNEL,
                      "Node %d TCP fd %d retry limit exhausted\n",
                      TOS_NODE_ID, fd);
                  // Report failure before cleanup; this path never signals graceful close.
                  reportFailure(fd, TCP_FAILURE_RETRY_LIMIT);
               } else {
                  sockets[fd].retries++;
                  sockets[fd].elapsedSeconds = 0;
                  resendOutstanding(fd);
               }
            }
         } else if (sockets[fd].persistProbing) {
            sockets[fd].persistProbing = FALSE;
            sockets[fd].retries = 0;
            sockets[fd].elapsedSeconds = 0;
         }
         releaseIfDrained(fd);
      }
   }
}
