#include "../../includes/packet.h"

interface DistanceVector {
   command void start();
   command void setQualityMetric(bool enabled);
   command bool nextHop(uint16_t destination, uint16_t *next, uint8_t *cost);
   command void print();
}
