#include "../../includes/packet.h"

interface TransportNetwork {
   command error_t send(uint16_t destination,
                        const uint8_t *payload);
}
