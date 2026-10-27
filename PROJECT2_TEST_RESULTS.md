# Project 2 Test Results

The drivers and expected checks are in `tests/project2/`. These are expected results, not measured observations: TOSSIM is not available in the editing environment, so no simulation logs have been captured here.

| Scenario | Expected check | Observed |
|---|---|---|
| Line | Node 1 route to 4 is via 2, cost 3; ping and reply use unicast next hops. | Not run |
| Alternative | Route changes 1->2 cost 2, then 1->3 cost 3 after link removal, then returns to cost 2. | Not run |
| Partition | Node 1 drops the ping after 2-3 is removed, then recovers after restoration. | Not run |
| Poison reverse | Node 1 logs destination 4 at cost 16 to neighbor 2 and cost 3 to neighbor 3. | Not run |
| Packet capacity | Node 2 learns and reaches node 20 from later pages in the 20-node, diameter-2 star. | Not run |
| Loss and TTL | Periodic exchanges regain routes under the noisy model; TTL 2 expires at a relay on the 3-hop line. | Not run |

Run each driver from the repository root in the course TinyOS/TOSSIM environment and replace the Observed entries with the relevant log line or outcome before submission.
