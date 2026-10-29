# Project 2 Discussion Answers

1. our implementation stores one route per destination and exchanges bounded vectors only with direct neighbors. link state stores a network-wide link map and floods link state advertisements. DV has smaller per-node topology state and simpler local updates, but the convergence can be slower. link state uses more control traffic and memory for global topology, then runs a shortest-path computation; its implementation is more involved.

2. suppose node A reaches D through B at cost 2. if B loses its route and advertises 16, A must withdraw its route. if A accepts only smaller costs, it keeps the stale cost 2 forever, continues sending packets to B, and never recovers correctly. the implementation processes increases and poison from the selected next hop and expires stale selected routes.

3. if A reaches D through B, simple split horizon omits D from A's vector to B. poison reverse includes D with cost 16 to B; A sends its finite cost to another neighbor C. after a failure, route poisoning advertises 16 to neighbors to withdraw the failed route. poison reverse blocks the two-node A-B feedback route, but three nodes can still advertise stale paths to one another during convergence; bounded cost and packet TTL limit the damage.

4. forward and reverse routes don't need to be symmetric. each node learns routes independently, and equal-cost ties retain each node's current next hop. asymmetric links, different information timing, and local ties can therefore select different paths in each direction.

5. a lost page provides no new information as omission is not a withdrawal. periodic staged vectors resend entries and the receiver checks the fixed packet length, count, and cost bounds before reading entries. malformed packets are ignored. per-destination ages expire routes whose selected information stops arriving. a send queue triggers a page retry.

6. repeated advertisements can destabilize neighbors since a node may also advertise a route without actually forwarding. one possible mitigation is a hold-down timer, which delays reuse of unstable routes. this implementation uses a bounded metric, TTL, route freshness, and a finite withdrawal interval but does not implement hold-down.