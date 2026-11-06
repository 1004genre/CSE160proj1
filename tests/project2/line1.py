# Line topology 1-2-3-4: minimum-hop routes, routed ping + reply, no flooding.
# Run from the repo root:  python2 tests/project2/line.py
import sys
from common import Scenario, route, path_of


def main():
    s = Scenario("line", "p2_line.topo", settle=30)
    s.header("Line 1-2-3-4: hop-count distance vector",
             ["t=0-30s startup: last boot 5.3s + 3-way neighbor handshake + several 1s DV rounds (3 hops) fits easily",
              "t=30s routingTableDump on nodes 1-4, then ping 1 -> 4 (reply returns by routing), wait 10s"],
             ["node 1 -> 4 via 2 cost 3; node 4 -> 1 via 3 cost 3",
              "ping forwarded only along 1->2->3->4 (3 transmissions), reply along 4->3->2->1, no FLOOD lines"])
    s.run(s.settle)

    s.say("t=%5.1fs  command: routingTableDump on nodes 1-4" % s.now())
    t = s.tables([1, 2, 3, 4])
    s.expect(route(t, 1, 4) == (2, 3), "node 1 -> 4: via 2, cost 3", route(t, 1, 4))
    s.expect(route(t, 4, 1) == (3, 3), "node 4 -> 1: via 3, cost 3", route(t, 4, 1))
    s.expect(all(route(t, n, n) == (n, 0) for n in (1, 2, 3, 4)), "every node keeps self-route at cost 0")

    log = s.ping(1, 4, "line-test")
    fwd, nf = path_of(log, 4)
    rev, nr = path_of(log, 1)
    s.expect("Node 4 delivered ping from 1" in log, "ping delivered at node 4")
    s.expect(fwd == "1->2->3->4" and nf == 3, "ping path %s (%d transmissions)" % (fwd, nf), "%s (%d)" % (fwd, nf))
    s.expect("Node 1 received ping reply from 4" in log, "reply received at node 1")
    s.expect(rev == "4->3->2->1" and nr == 3, "reply path %s (%d transmissions)" % (rev, nr), "%s (%d)" % (rev, nr))
    s.expect("FLOOD " not in log, "no data flooding (no FLOOD lines in this window)")
    return s.finish()


if __name__ == "__main__":
    sys.exit(main())