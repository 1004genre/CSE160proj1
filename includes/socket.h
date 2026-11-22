#ifndef __SOCKET_H__
#define __SOCKET_H__

#include "tcp.h"

enum{
    // Each record owns its connection state; multiple records may coexist per node.
    MAX_NUM_OF_SOCKETS = 10,
    ROOT_SOCKET_ADDR = 255,
    ROOT_SOCKET_PORT = 255,
    SOCKET_BUFFER_SIZE = 128,
    SOCKET_NONE = 255,
};

enum socket_state{
    CLOSED,
    LISTEN,
    ESTABLISHED,
    SYN_SENT,
    SYN_RCVD,
    FIN_WAIT_1,
    FIN_WAIT_2,
    LAST_ACK,
    TIME_WAIT,
};


typedef nx_uint8_t nx_socket_port_t;
typedef uint8_t socket_port_t;

// socket_addr_t is a simplified version of an IP connection.
typedef nx_struct socket_addr_t{
    nx_socket_port_t port;
    nx_uint16_t addr;
}socket_addr_t;


// File descripter id. Each id is associated with a socket_store_t
typedef uint8_t socket_t;

// State for a bounded transport connection or listener.
typedef struct socket_store_t{
    bool allocated;
    bool accepted;
    enum socket_state state;
    uint16_t localAddr;
    socket_port_t localPort;
    uint16_t remoteAddr;
    socket_port_t remotePort;
    uint16_t remoteInitialSequence;
    socket_t pendingChild;
    uint8_t sendBuff[SOCKET_BUFFER_SIZE];
    // Buffer holds outstanding prefix plus unsent suffix; totals track accepted/ACKed.
    uint16_t sendLength;
    uint16_t sendTotal;
    uint16_t sendAcked;
    // sendUna is oldest unacked; sendNext is next unsent sequence position.
    uint16_t sendNext;
    uint16_t sendUna;
    uint8_t senderWindow; // Local fixed upper bound for outstanding data.
    uint8_t peerWindow;   // Latest window from a valid peer ACK or handshake.
    uint8_t rcvdBuff[SOCKET_BUFFER_SIZE];
    // rcvLength is received data not yet consumed by the local test application.
    uint16_t rcvLength;
    uint16_t rcvTotal;
    uint16_t rcvNext;
    tcp_segment_t lastSegment;
    tcp_segment_t handshakeReply;
    bool hasOutstanding;
    bool controlOutstanding;
    bool persistProbing; // A queued sender waits for a response while peer window is zero.
    bool closeRequested;
    bool peerFinReceived;
    bool localFinAcknowledged;
    bool timeWaitExpired;
    // A shared timer ticks these per-connection retry and TIME_WAIT counters.
    uint8_t retries;
    uint8_t elapsedSeconds;
    uint8_t timeWaitSeconds;
}socket_store_t;

#endif
