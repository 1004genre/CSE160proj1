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

#ifndef TOSSIM
   // Only the simulator has virtual time; keep hardware builds compilable.
#define sim_time_string() "hardware"
#endif

   // Subtract the encoded transport header from the network payload budget.
   uint8_t segmentDataCapacity() {
      return PACKET_MAX_PAYLOAD_SIZE - TCP_HEADER_SIZE;
   }

   uint8_t segmentDataLength(tcp_segment_t *segment) {
      if (segment->kindLength > TCP_CODE_DATA_BASE &&
          segment->kindLength <= TCP_CODE_DATA_BASE + segmentDataCapacity()) {
         return segment->kindLength - TCP_CODE_DATA_BASE;
      }
      return 0;
   }

   // Decode only known controls or a positive data length within that capacity.
   bool decodeSegment(tcp_segment_t *segment, uint8_t *dataLength) {
      if (segment == NULL || dataLength == NULL) return FALSE;
      *dataLength = segmentDataLength(segment);
      switch (segment->kindLength) {
         case TCP_CODE_SYN:
         case TCP_CODE_ACK:
         case TCP_CODE_SYN_ACK:
         case TCP_CODE_FIN:
         case TCP_CODE_PROBE:
            return TRUE;
         default:
            return *dataLength > 0;
      }
   }

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
      dbg(PROJECT3_TGEN_CHANNEL,
          "t=%s node=%d conn=%d %d:%d->%d:%d event=STATE state=%s previous=%s\n",
          sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
          sockets[fd].localPort, sockets[fd].remoteAddr,
          sockets[fd].remotePort, stateName(state), stateName(previous));
   }

   bool validSocket(socket_t fd) {
      return fd < MAX_NUM_OF_SOCKETS && sockets[fd].allocated;
   }

   // Print the fd-to-endpoint mapping once so every event has a stable connection ID.
   void logConnection(socket_t fd, const char *event) {
      if (!validSocket(fd)) return;
      dbg(PROJECT3_TGEN_CHANNEL,
          "t=%s node=%d conn=%d %d:%d->%d:%d event=%s state=%s\n",
          sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
          sockets[fd].localPort, sockets[fd].remoteAddr,
          sockets[fd].remotePort, event, stateName(sockets[fd].state));
   }

   // Log transport byte positions, current windows, and send-queue acceptance.
   void logWireSegment(socket_t fd, const char *event, uint16_t seq,
                       uint16_t ack, uint8_t length, uint8_t window,
                       error_t result) {
      uint16_t outstanding = 0;
      if (!validSocket(fd)) return;
      if (sockets[fd].sendNext >= sockets[fd].sendUna)
         outstanding = sockets[fd].sendNext - sockets[fd].sendUna;
      if (length > 0 && seq == sockets[fd].sendNext) outstanding += length;
      dbg(PROJECT3_TGEN_CHANNEL,
          "t=%s node=%d conn=%d %d:%d->%d:%d event=%s state=%s seq=%d len=%d ack=%d wnd=%d outstanding=%d peerWnd=%d queued=%d\n",
          sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
          sockets[fd].localPort, sockets[fd].remoteAddr,
          sockets[fd].remotePort, event, stateName(sockets[fd].state),
          seq, length, ack, window, outstanding, sockets[fd].peerWindow, result);
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
      logConnection(fd, "CONN_CLEANUP");
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

   // Encode one transport segment into the fixed-size network payload.
   error_t encodeSegment(socket_t fd, uint8_t kind, uint16_t seq,
                         uint16_t ack, const uint8_t *data, uint8_t length,
                         uint8_t *payload) {
      tcp_segment_t segment;

      if (!validSocket(fd) || payload == NULL ||
          length > segmentDataCapacity() || (length > 0 && data == NULL)) {
         return FAIL;
      }
      if ((kind == TCP_KIND_DATA && length == 0) ||
          (kind != TCP_KIND_DATA && length != 0)) return FAIL;

      memset(&segment, 0, sizeof(segment));
      segment.srcPort = sockets[fd].localPort;
      segment.destPort = sockets[fd].remotePort;
      // Data length shares the kind byte; control kinds carry no application data.
      segment.kindLength = kind == TCP_KIND_DATA ?
                          TCP_CODE_DATA_BASE + length : kind;
      segment.seq = seq;
      segment.ack = ack;
      segment.window = receiveWindow(&sockets[fd]);
      if (length > 0) memcpy(segment.data, data, length);

      memset(payload, 0, PACKET_MAX_PAYLOAD_SIZE);
      memcpy(payload, &segment, sizeof(segment));

      return SUCCESS;
   }

   error_t sendSegment(socket_t fd, uint8_t kind, uint16_t seq,
                       uint16_t ack, const uint8_t *data, uint8_t length,
                       bool track) {
      uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
      tcp_segment_t *segment = (tcp_segment_t *)payload;
      error_t result;

      result = encodeSegment(fd, kind, seq, ack, data, length, payload);
      if (result != SUCCESS) return result;
      if (track) {
         memcpy(&sockets[fd].lastSegment, segment, sizeof(tcp_segment_t));
         sockets[fd].hasOutstanding = TRUE;
         sockets[fd].controlOutstanding = TRUE;
         sockets[fd].retries = 0;
         sockets[fd].elapsedSeconds = 0;
      }
      // Failed tracked sends keep their sequence range for a later transport retry.
      result = call Network.send(sockets[fd].remoteAddr, payload);
      {
         const char *event = "CONTROL_TX";
         if (kind == TCP_KIND_DATA) event = "DATA_TX";
         else if (kind == TCP_CODE_SYN) event = "SYN_TX";
         else if (kind == TCP_CODE_SYN_ACK) event = "SYN_ACK_TX";
         else if (kind == TCP_CODE_ACK) event = "ACK_TX";
         else if (kind == TCP_CODE_FIN) event = "FIN_TX";
         else if (kind == TCP_CODE_PROBE) event = "WINDOW_PROBE_TX";
         logWireSegment(fd, event, seq, ack, length, segment->window, result);
      }
      dbg(TRANSPORT_CHANNEL,
          "Node %d TCP fd %d send code %d seq %d ack %d len %d window %d%s\n",
          TOS_NODE_ID, fd, segment.kindLength, seq, ack, length, segment.window,
          track ? " tracked" : "");
      return result;
   }

   bool advanceSendCursor(socket_t fd, uint8_t length) {
      uint16_t outstanding;
      if (!validSocket(fd) || length == 0 ||
          length > segmentDataCapacity() ||
          sockets[fd].sendNext < sockets[fd].sendUna ||
          sockets[fd].sendLength > SOCKET_BUFFER_SIZE) return FALSE;
      outstanding = sockets[fd].sendNext - sockets[fd].sendUna;
      if (outstanding > sockets[fd].sendLength ||
          length > sockets[fd].sendLength - outstanding) return FALSE;
      if (!sockets[fd].hasOutstanding) {
         sockets[fd].hasOutstanding = TRUE;
         sockets[fd].controlOutstanding = FALSE;
         sockets[fd].retries = 0;
         sockets[fd].elapsedSeconds = 0;
      }
      // Advance only after the send service accepted this encoded packet.
      sockets[fd].sendNext += length;
      return TRUE;
   }

   void sendDataBatch(socket_t fd) {
      uint8_t sent = 0;
      uint8_t length;
      uint16_t outstanding;
      uint16_t window;
      uint16_t allowedEnd;

      if (!validSocket(fd) || sockets[fd].controlOutstanding ||
          sockets[fd].sendNext < sockets[fd].sendUna) return;
      outstanding = sockets[fd].sendNext - sockets[fd].sendUna;
      window = sockets[fd].senderWindow < sockets[fd].peerWindow ?
               sockets[fd].senderWindow : sockets[fd].peerWindow;
      allowedEnd = sockets[fd].sendUna +
                   (outstanding < window ? outstanding : window);
      if (sockets[fd].retransmitCursor < sockets[fd].sendUna) {
         sockets[fd].retransmitCursor = sockets[fd].sendUna;
      }
      if (sockets[fd].retransmitEnd > allowedEnd) {
         sockets[fd].retransmitEnd = allowedEnd;
      }

      // Retries retain the same byte range and submit no more than two packets per batch.
      while (sockets[fd].retransmitCursor < sockets[fd].retransmitEnd &&
             sent < TCP_DATA_BATCH_SEGMENTS) {
         uint16_t offset = sockets[fd].retransmitCursor - sockets[fd].sendUna;
         uint16_t remaining = sockets[fd].retransmitEnd -
                              sockets[fd].retransmitCursor;
         if (offset > sockets[fd].sendLength ||
             remaining > sockets[fd].sendLength - offset) break;
         length = remaining > segmentDataCapacity() ?
                  segmentDataCapacity() : remaining;
         // Re-encode the retained bytes with their original transport sequence range.
         if (sendSegment(fd, TCP_KIND_DATA, sockets[fd].retransmitCursor, 0,
                         &sockets[fd].sendBuff[offset], length, FALSE) != SUCCESS) {
            break;
         }
         logWireSegment(fd, "DATA_RETX", sockets[fd].retransmitCursor,
                        0, length, receiveWindow(&sockets[fd]), SUCCESS);
         sockets[fd].retransmitCursor += length;
         sent++;
      }
      sockets[fd].retransmitPending =
         sockets[fd].retransmitCursor < sockets[fd].retransmitEnd;
   }

   void resendOutstanding(socket_t fd) {
      uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
      uint16_t outstanding;
      uint16_t retransmitLength;
      uint16_t window;
      error_t result;
      if (sockets[fd].controlOutstanding) {
         const char *event = "FIN_RETX";
         memset(payload, 0, sizeof(payload));
         memcpy(payload, &sockets[fd].lastSegment,
                sizeof(tcp_segment_t));
         if (sockets[fd].lastSegment.kindLength == TCP_CODE_SYN)
            event = "SYN_RETX";
         else if (sockets[fd].lastSegment.kindLength == TCP_CODE_SYN_ACK)
            event = "SYN_ACK_RETX";
         result = call Network.send(sockets[fd].remoteAddr, payload);
         logWireSegment(fd, event, sockets[fd].lastSegment.seq,
                        sockets[fd].lastSegment.ack, 0,
                        sockets[fd].lastSegment.window, result);
         if (result != SUCCESS) {
            dbg(PROJECT3_TGEN_CHANNEL,
                "t=%s node=%d conn=%d %d:%d->%d:%d event=RETX_QUEUE_FULL state=%s result=%d\n",
                sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
                sockets[fd].localPort, sockets[fd].remoteAddr,
                sockets[fd].remotePort, stateName(sockets[fd].state), result);
         }
      } else {
         // Go-back-N starts at the oldest byte and stays inside the current peer window.
         outstanding = sockets[fd].sendNext - sockets[fd].sendUna;
         window = sockets[fd].senderWindow < sockets[fd].peerWindow ?
                  sockets[fd].senderWindow : sockets[fd].peerWindow;
         retransmitLength = outstanding < window ? outstanding : window;
         sockets[fd].retransmitCursor = sockets[fd].sendUna;
         sockets[fd].retransmitEnd = sockets[fd].sendUna + retransmitLength;
         sockets[fd].retransmitPending = retransmitLength > 0;
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d->%d:%d event=DATA_RETX state=%s start=%d end=%d outstanding=%d peerWnd=%d retry=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             sockets[fd].retransmitCursor, sockets[fd].retransmitEnd,
             outstanding, sockets[fd].peerWindow, sockets[fd].retries);
         sendDataBatch(fd);
      }
      dbg(TRANSPORT_CHANNEL, "Node %d TCP fd %d retransmit #%d\n",
          TOS_NODE_ID, fd, sockets[fd].retries);
   }

   void sendAck(socket_t fd) {
      sendSegment(fd, TCP_CODE_ACK, sockets[fd].sendNext,
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
      sendSegment(fd, TCP_CODE_FIN, seq, 0, NULL, 0, TRUE);
   }

   void pumpData(socket_t fd) {
      uint16_t outstanding;
      uint16_t unsent;
      uint16_t window;
      uint16_t allowance;
      uint8_t length;
      uint8_t sent = 0;
      error_t result;

      if (!validSocket(fd) || sockets[fd].state != ESTABLISHED ||
          sockets[fd].controlOutstanding || sockets[fd].retransmitPending) return;

      // The buffer prefix is in flight; only its suffix is eligible for sending.
      if (sockets[fd].sendLength > SOCKET_BUFFER_SIZE ||
          sockets[fd].sendNext < sockets[fd].sendUna) return;
      outstanding = sockets[fd].sendNext - sockets[fd].sendUna;
      if (outstanding > sockets[fd].sendLength) return;
      window = sockets[fd].senderWindow < sockets[fd].peerWindow ?
               sockets[fd].senderWindow : sockets[fd].peerWindow;
      unsent = sockets[fd].sendLength > outstanding ?
               sockets[fd].sendLength - outstanding : 0;
      while (unsent > 0 && outstanding < window &&
             sent < TCP_DATA_BATCH_SEGMENTS) {
         allowance = window - outstanding;
         length = unsent > segmentDataCapacity() ?
                  segmentDataCapacity() : unsent;
         if (length > allowance) length = allowance;
         if (outstanding >= SOCKET_BUFFER_SIZE || length == 0) return;
         result = sendSegment(fd, TCP_KIND_DATA, sockets[fd].sendNext, 0,
                              &sockets[fd].sendBuff[outstanding], length, FALSE);
         if (result != SUCCESS) {
            sockets[fd].sendPending = TRUE;
            return;
         }
         if (!advanceSendCursor(fd, length)) return;
         outstanding += length;
         unsent -= length;
         sent++;
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d window DATA seq %d len %d outstanding %d/%d\n",
             TOS_NODE_ID, fd, sockets[fd].sendNext - length, length,
             outstanding, window);
      }
      // A later ACK or retry timer resumes data beyond this two-packet batch.
      sockets[fd].sendPending = unsent > 0 && outstanding < window;

      if (sockets[fd].closeRequested && sockets[fd].sendLength == 0 &&
          !sockets[fd].hasOutstanding) {
         sendFin(fd, sockets[fd].peerFinReceived ? LAST_ACK : FIN_WAIT_1);
      }
   }

   void reportFailure(socket_t fd, uint8_t reason) {
      if (validSocket(fd)) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d->%d:%d event=CONNECTION_FAILURE state=%s reason=%d sendBuffered=%d acked=%d received=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state), reason,
             sockets[fd].sendLength, sockets[fd].sendAcked,
             sockets[fd].rcvTotal);
      }
      signal Transport.connectionFailed(fd, reason);
      clearSocket(fd);
   }

   void processAck(socket_t fd, tcp_segment_t *segment) {
      uint16_t highestSent;
      uint16_t newlyAcked;
      uint16_t outstanding;
      uint8_t previousWindow;

      if (segment->kindLength != TCP_CODE_ACK) return;
      dbg(PROJECT3_TGEN_CHANNEL,
          "t=%s node=%d conn=%d %d:%d<-%d:%d event=ACK_RX state=%s cumAck=%d wnd=%d outstanding=%d\n",
          sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
          sockets[fd].localPort, sockets[fd].remoteAddr,
          sockets[fd].remotePort, stateName(sockets[fd].state),
          segment->ack, segment->window,
          sockets[fd].sendNext - sockets[fd].sendUna);
      if (sockets[fd].sendNext < sockets[fd].sendUna ||
          sockets[fd].sendLength > SOCKET_BUFFER_SIZE) return;
      highestSent = sockets[fd].sendNext;
      if (sockets[fd].controlOutstanding &&
          sockets[fd].lastSegment.kindLength == TCP_CODE_FIN) {
         highestSent = sockets[fd].lastSegment.seq + 1;
      }
      // ACKs outside sent sequence space cannot move the window or free storage.
      if (segment->ack < sockets[fd].sendUna ||
          segment->ack > highestSent) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d<-%d:%d event=ACK_DROP state=%s reason=outside-sent-space ack=%d wnd=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->ack, segment->window);
         return;
      }

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
      if (previousWindow != segment->window) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d<-%d:%d event=WINDOW_UPDATE_RX state=%s cumAck=%d oldWnd=%d newWnd=%d outstanding=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->ack, previousWindow, segment->window,
             sockets[fd].sendNext - sockets[fd].sendUna);
      }
      if (sockets[fd].controlOutstanding) {
         if (sockets[fd].lastSegment.kindLength == TCP_CODE_FIN &&
             segment->ack == sockets[fd].lastSegment.seq + 1) {
            logWireSegment(fd, "FIN_ACK_RX", segment->seq,
                           segment->ack, 0, segment->window, SUCCESS);
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
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d->%d:%d event=ACK_PROGRESS state=%s cumAck=%d wnd=%d outstanding=%d ackedTotal=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->ack, segment->window,
             sockets[fd].sendNext - sockets[fd].sendUna,
             sockets[fd].sendAcked);
         if (sockets[fd].retransmitPending) {
            if (sockets[fd].retransmitCursor < sockets[fd].sendUna)
               sockets[fd].retransmitCursor = sockets[fd].sendUna;
            if (sockets[fd].retransmitEnd < sockets[fd].sendUna)
               sockets[fd].retransmitEnd = sockets[fd].sendUna;
            if (sockets[fd].retransmitCursor >= sockets[fd].retransmitEnd)
               sockets[fd].retransmitPending = FALSE;
         }
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
      uint8_t length = segmentDataLength(segment);
      if (length == 0) return;
      dbg(PROJECT3_TGEN_CHANNEL,
          "t=%s node=%d conn=%d %d:%d<-%d:%d event=DATA_RX state=%s seq=%d len=%d cumAck=%d wnd=%d buffered=%d\n",
          sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
          sockets[fd].localPort, sockets[fd].remoteAddr,
          sockets[fd].remotePort, stateName(sockets[fd].state),
          segment->seq, length, sockets[fd].rcvNext,
          receiveWindow(&sockets[fd]), sockets[fd].rcvLength);
      if (length > TCP_DATA_SIZE) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d<-%d:%d event=DATA_DROP state=%s reason=length seq=%d len=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->seq, length);
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d dropped malformed data length %d\n",
             TOS_NODE_ID, fd, length);
         return;
      }

      if (sockets[fd].rcvLength > SOCKET_BUFFER_SIZE) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d<-%d:%d event=DATA_DROP state=%s reason=buffer-corrupt seq=%d len=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->seq, length);
         sendAck(fd);
         return;
      }
      if (sockets[fd].rcvTotal > TCP_MAX_TRANSFER_BYTES ||
          length > TCP_MAX_TRANSFER_BYTES - sockets[fd].rcvTotal) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d<-%d:%d event=DATA_DROP state=%s reason=transfer-limit seq=%d len=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->seq, length);
         sendAck(fd);
         return;
      }

      if (sockets[fd].peerFinReceived) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d<-%d:%d event=DATA_DROP state=%s reason=after-FIN seq=%d len=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->seq, length);
         sendAck(fd);
         return;
      }

      // Accept only the next expected byte; discard gaps and duplicates, then ACK the gap edge.
      if (segment->seq == sockets[fd].rcvNext &&
          length <= SOCKET_BUFFER_SIZE - sockets[fd].rcvLength) {
         memcpy(&sockets[fd].rcvdBuff[sockets[fd].rcvLength],
                segment->data, length);
         sockets[fd].rcvLength += length;
         sockets[fd].rcvTotal += length;
         sockets[fd].rcvNext += length;
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d receive buffer %d/128 window %d\n",
             TOS_NODE_ID, fd, sockets[fd].rcvLength,
             receiveWindow(&sockets[fd]));
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP fd %d accepted data seq %d len %d next %d\n",
             TOS_NODE_ID, fd, segment->seq, length,
             sockets[fd].rcvNext);
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d<-%d:%d event=DATA_ACCEPT state=%s seq=%d len=%d cumAck=%d wnd=%d buffered=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->seq, length, sockets[fd].rcvNext,
             receiveWindow(&sockets[fd]), sockets[fd].rcvLength);
         sendAck(fd);
         signal Transport.dataReceived(fd);
      } else {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=%d %d:%d<-%d:%d event=DATA_DROP state=%s reason=%s seq=%d len=%d cumAck=%d wnd=%d\n",
             sim_time_string(), TOS_NODE_ID, fd, sockets[fd].localAddr,
             sockets[fd].localPort, sockets[fd].remoteAddr,
             sockets[fd].remotePort, stateName(sockets[fd].state),
             segment->seq == sockets[fd].rcvNext ? "no-space" : "gap-or-duplicate",
             segment->seq, length, sockets[fd].rcvNext,
             receiveWindow(&sockets[fd]));
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
      logConnection(fd, "LISTEN");
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
      logConnection(fd, "CONN_ALLOC");
      sockets[fd].sendUna = TCP_INITIAL_SEQUENCE;
      sockets[fd].sendNext = TCP_INITIAL_SEQUENCE + 1;
      setState(fd, SYN_SENT);
      sendSegment(fd, TCP_CODE_SYN, TCP_INITIAL_SEQUENCE, 0, NULL, 0, TRUE);
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

   command uint16_t Transport.sendAcknowledged(socket_t fd) {
      if (!validSocket(fd)) return 0;
      return sockets[fd].sendAcked;
   }

   command error_t Transport.endpoints(socket_t fd, socket_addr_t *local,
                                       socket_addr_t *remote) {
      if (!validSocket(fd) || local == NULL || remote == NULL) return FAIL;
      local->addr = sockets[fd].localAddr;
      local->port = sockets[fd].localPort;
      remote->addr = sockets[fd].remoteAddr;
      remote->port = sockets[fd].remotePort;
      return SUCCESS;
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
      uint8_t dataLength = 0;

      if (package == NULL || PACK_PROTOCOL(package) != PROTOCOL_TCP) return FAIL;
      segment = (tcp_segment_t *)package->payload;
      // Accept only handshake, pure ACK, FIN, probe, or data-only wire forms.
      if (segment->window > SOCKET_BUFFER_SIZE ||
          !decodeSegment(segment, &dataLength)) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=unknown %d:%d->%d:%d event=SEGMENT_DROP state=UNKNOWN reason=malformed len=%d wnd=%d\n",
             sim_time_string(), TOS_NODE_ID, package->src,
             segment->srcPort, package->dest, segment->destPort,
             dataLength, segment->window);
         dbg(TRANSPORT_CHANNEL, "Node %d TCP dropped malformed segment\n",
             TOS_NODE_ID);
         return FAIL;
      }

      fd = findConnection(package->src, segment->srcPort,
                          package->dest, segment->destPort);
      if (fd == SOCKET_NONE && segment->kindLength == TCP_CODE_SYN) {
         // All nodes use ISN zero so plain integer comparisons remain no-wrap safe.
         if (segment->seq != TCP_INITIAL_SEQUENCE) {
            dbg(PROJECT3_TGEN_CHANNEL,
                "t=%s node=%d conn=unknown %d:%d->%d:%d event=SYN_REJECT state=NO_CONNECTION reason=invalid-ISN seq=%d\n",
                sim_time_string(), TOS_NODE_ID, package->src,
                segment->srcPort, package->dest, segment->destPort,
                segment->seq);
            return FAIL;
         }
         listener = findListener(package->dest, segment->destPort);
         if (listener == SOCKET_NONE) {
            dbg(PROJECT3_TGEN_CHANNEL,
                "t=%s node=%d conn=unknown %d:%d->%d:%d event=SYN_REJECT state=NO_LISTENER reason=no-listener\n",
                sim_time_string(), TOS_NODE_ID, package->src,
                segment->srcPort, package->dest, segment->destPort);
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP refused SYN from %d port %d: no listener\n",
                TOS_NODE_ID, package->src, segment->srcPort);
            return FAIL;
         }
         if (sockets[listener].pendingChild != SOCKET_NONE) {
            dbg(PROJECT3_TGEN_CHANNEL,
                "t=%s node=%d conn=unknown %d:%d->%d:%d event=SYN_REJECT state=LISTEN reason=accept-slot-busy\n",
                sim_time_string(), TOS_NODE_ID, package->src,
                segment->srcPort, package->dest, segment->destPort);
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP refused SYN: listener accept slot is occupied\n",
                TOS_NODE_ID);
            return FAIL;
         }

         fd = allocateSocket();
         if (fd == SOCKET_NONE) {
            dbg(PROJECT3_TGEN_CHANNEL,
                "t=%s node=%d conn=unknown %d:%d->%d:%d event=SYN_REJECT state=LISTEN reason=connection-table-full\n",
                sim_time_string(), TOS_NODE_ID, package->src,
                segment->srcPort, package->dest, segment->destPort);
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP refused SYN: no connection record available\n",
                TOS_NODE_ID);
            return FAIL;
         }
         sockets[fd].localAddr = package->dest;
         sockets[fd].localPort = segment->destPort;
         sockets[fd].remoteAddr = package->src;
         sockets[fd].remotePort = segment->srcPort;
         logConnection(fd, "CONN_ALLOC");
         sockets[fd].sendNext = TCP_INITIAL_SEQUENCE + 1;
         sockets[fd].sendUna = TCP_INITIAL_SEQUENCE;
         sockets[fd].peerWindow = segment->window;
         sockets[fd].rcvNext = segment->seq + 1;
         sockets[fd].remoteInitialSequence = segment->seq;
         sockets[listener].pendingChild = fd;
         setState(fd, SYN_RCVD);
         logWireSegment(fd, "SYN_RX", segment->seq, segment->ack, 0,
                        segment->window, SUCCESS);
         sendSegment(fd, TCP_CODE_SYN_ACK, TCP_INITIAL_SEQUENCE,
                     sockets[fd].rcvNext, NULL, 0, TRUE);
         // Keep SYN-ACK available after its ACK so duplicate SYNs get the same reply.
         memcpy(&sockets[fd].handshakeReply, &sockets[fd].lastSegment,
                sizeof(tcp_segment_t));
         return SUCCESS;
      }

      if (!validSocket(fd)) {
         dbg(PROJECT3_TGEN_CHANNEL,
             "t=%s node=%d conn=unknown %d:%d->%d:%d event=SEGMENT_DROP state=NO_CONNECTION reason=unmatched\n",
             sim_time_string(), TOS_NODE_ID, package->src,
             segment->srcPort, package->dest, segment->destPort);
         dbg(TRANSPORT_CHANNEL,
             "Node %d TCP dropped unmatched segment src %d:%d dest %d:%d\n",
             TOS_NODE_ID, package->src, segment->srcPort,
             package->dest, segment->destPort);
         return FAIL;
      }

      if (sockets[fd].state == SYN_RCVD &&
          segment->kindLength == TCP_CODE_SYN &&
          segment->seq == sockets[fd].remoteInitialSequence) {
         logWireSegment(fd, "SYN_DUP_RX", segment->seq, segment->ack,
                        0, segment->window, SUCCESS);
         resendOutstanding(fd);
         return SUCCESS;
      }

      if (sockets[fd].state == SYN_SENT) {
         if (segment->kindLength == TCP_CODE_SYN_ACK &&
             segment->seq == TCP_INITIAL_SEQUENCE &&
             segment->ack == sockets[fd].sendNext) {
            logWireSegment(fd, "SYN_ACK_RX", segment->seq, segment->ack, 0,
                           segment->window, SUCCESS);
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
            logWireSegment(fd, "SYN_ACK_DROP", segment->seq,
                           segment->ack, 0, segment->window, FAIL);
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP fd %d ignored invalid SYN-ACK ack %d\n",
                TOS_NODE_ID, fd, segment->ack);
         }
         return SUCCESS;
      }

      if (sockets[fd].state == SYN_RCVD) {
         if (segment->kindLength == TCP_CODE_ACK &&
             segment->ack == sockets[fd].sendNext &&
             segment->seq == sockets[fd].rcvNext) {
            logWireSegment(fd, "HANDSHAKE_ACK_RX", segment->seq,
                           segment->ack, 0, segment->window, SUCCESS);
            sockets[fd].hasOutstanding = FALSE;
            sockets[fd].controlOutstanding = FALSE;
            sockets[fd].sendUna = segment->ack;
            sockets[fd].peerWindow = segment->window;
            setState(fd, ESTABLISHED);
            signal Transport.connectionEstablished(fd);
         } else {
            logWireSegment(fd, "HANDSHAKE_ACK_DROP", segment->seq,
                           segment->ack, 0, segment->window, FAIL);
            dbg(TRANSPORT_CHANNEL,
                "Node %d TCP fd %d ignored invalid handshake ACK\n",
                TOS_NODE_ID, fd);
         }
         return SUCCESS;
      }

      if (sockets[fd].state == ESTABLISHED &&
          segment->kindLength == TCP_CODE_SYN_ACK &&
          segment->ack == TCP_INITIAL_SEQUENCE + 1 &&
          segment->seq == sockets[fd].remoteInitialSequence) {
         logWireSegment(fd, "SYN_ACK_DUP_RX", segment->seq, segment->ack,
                        0, segment->window, SUCCESS);
         sendAck(fd);
         return SUCCESS;
      }

      if (sockets[fd].state == ESTABLISHED &&
          segment->kindLength == TCP_CODE_SYN &&
          segment->seq == sockets[fd].remoteInitialSequence &&
          sockets[fd].handshakeReply.kindLength == TCP_CODE_SYN_ACK) {
         // The tuple already exists; replay the original SYN-ACK without allocating.
         uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
         logWireSegment(fd, "SYN_DUP_RX", segment->seq, segment->ack,
                        0, segment->window, SUCCESS);
         memset(payload, 0, sizeof(payload));
         memcpy(payload, &sockets[fd].handshakeReply,
                sizeof(tcp_segment_t));
         call Network.send(sockets[fd].remoteAddr, payload);
         return SUCCESS;
      }

      if (segment->kindLength == TCP_CODE_PROBE) {
         if (sockets[fd].state == ESTABLISHED ||
             sockets[fd].state == FIN_WAIT_1 ||
             sockets[fd].state == FIN_WAIT_2 ||
             sockets[fd].state == LAST_ACK ||
             sockets[fd].state == TIME_WAIT) {
            logWireSegment(fd, "WINDOW_PROBE_RX", segment->seq,
                           segment->ack, 0, segment->window, SUCCESS);
            sockets[fd].peerWindow = segment->window;
            sendAck(fd); // A probe requests a window update, not application data.
            pumpData(fd);
         }
         return SUCCESS;
      }

      processAck(fd, segment);
      if (!validSocket(fd)) return SUCCESS;

      if (dataLength > 0) {
         // Data packets also advertise the sender's latest receive window.
         sockets[fd].peerWindow = segment->window;
         receiveData(fd, segment);
         pumpData(fd);
      }

      if (segment->kindLength == TCP_CODE_FIN) {
         logWireSegment(fd, "FIN_RX", segment->seq, segment->ack, 0,
                        segment->window, SUCCESS);
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
      // The fixed socket table bounds this callback; each data retry is window-limited.
      for (fd = 0; fd < MAX_NUM_OF_SOCKETS; fd++) {
         bool dataBatchUsed = FALSE;
         if (!sockets[fd].allocated) continue;

         // Resume one bounded data batch per connection on each timer event.
         if (sockets[fd].retransmitPending) {
            sendDataBatch(fd);
            dataBatchUsed = TRUE;
         } else if (sockets[fd].state == ESTABLISHED &&
                    sockets[fd].sendPending &&
                    sockets[fd].peerWindow > 0) {
            pumpData(fd);
            dataBatchUsed = TRUE;
         }

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
               dbg(PROJECT3_TGEN_CHANNEL,
                   "t=%s node=%d conn=%d %d:%d->%d:%d event=WINDOW_PROBE_TIMEOUT state=%s retry=%d wnd=0\n",
                   sim_time_string(), TOS_NODE_ID, fd,
                   sockets[fd].localAddr, sockets[fd].localPort,
                   sockets[fd].remoteAddr, sockets[fd].remotePort,
                   stateName(sockets[fd].state), sockets[fd].retries);
               if (sockets[fd].retries >= TCP_MAX_RETRIES) {
                  reportFailure(fd, TCP_FAILURE_RETRY_LIMIT);
               } else {
                  sockets[fd].retries++;
                  sockets[fd].elapsedSeconds = 0;
                  sendSegment(fd, TCP_CODE_PROBE, sockets[fd].sendNext,
                              sockets[fd].rcvNext, NULL, 0, FALSE);
               }
            }
         } else if (sockets[fd].hasOutstanding) {
            sockets[fd].elapsedSeconds++;
            if (sockets[fd].elapsedSeconds >= TCP_RTO_SECONDS) {
               dbg(PROJECT3_TGEN_CHANNEL,
                   "t=%s node=%d conn=%d %d:%d->%d:%d event=TIMEOUT state=%s retry=%d sendUna=%d sendNext=%d peerWnd=%d\n",
                   sim_time_string(), TOS_NODE_ID, fd,
                   sockets[fd].localAddr, sockets[fd].localPort,
                   sockets[fd].remoteAddr, sockets[fd].remotePort,
                   stateName(sockets[fd].state), sockets[fd].retries,
                   sockets[fd].sendUna, sockets[fd].sendNext,
                   sockets[fd].peerWindow);
               if (dataBatchUsed) {
                  // Preserve the two-packet timer budget; retry next timer tick.
                  sockets[fd].elapsedSeconds = TCP_RTO_SECONDS - 1;
               } else if (sockets[fd].retries >= TCP_MAX_RETRIES) {
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
