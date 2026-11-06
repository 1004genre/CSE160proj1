# Links 1-2, 2-4, 1-3, 3-5, 5-4: failover to the longer path and return to the short one.
# Run from the repo root:  python2 tests/project2/alternative.py
import sys
from common import Scenario, route, path_of


def phase(s, label, want_route, want_path, ping_label):
    t = s.tables([1, 2])
    s.expect(2 in t, "node 2 still running (answered routingTableDump)")
    s.expect(route(t, 1, 4) == want_route, "%s: node 1 -> 4 via %d, cost %d" % ((label,) + want_route),
             route(t, 1, 4))
    log = s.ping(1, 4, ping_label)
    chain, _ = path_of(log, 4)
    s.expect("Node 4 delivered ping from 1" in log and chain == want_path,
             "%s: ping delivered along %s" % (label, want_path), chain)


def main():
    s = Scenario("alternative", "p2_alternative.topo", settle=30)
    s.header("Alternative path: failover and recovery",
             ["t=0-30s startup (last boot 6.7s), then check route + ping",
              "cut 2<->4 (both directions, node 2 stays up), wait 20s: neighbor timeout 5s + withdrawal/relearn rounds ~ 6-10s",
              "restore 2<->4, wait 20s: rediscovery ~3s + one DV round, then check route + ping"],
             ["initially 1 -> 4 via 2 cost 2 (path 1->2->4)",
              "after cut: 1 -> 4 via 3 cost 3 (path 1->3->5->4)",
              "after restore: back to via 2 cost 2"])
    s.run(s.settle)

    s.say("t=%5.1fs  command: routingTableDump on nodes 1,2" % s.now())
    phase(s, "initial", (2, 2), "1->2->4", "via-2")

    s.cut(2, 4)
    s.run(20)
    s.say("t=%5.1fs  command: routingTableDump on nodes 1,2" % s.now())
    phase(s, "after cut", (3, 3), "1->3->5->4", "via-3")

    s.heal(2, 4)
    s.run(20)
    s.say("t=%5.1fs  command: routingTableDump on nodes 1,2" % s.now())
    phase(s, "after restore", (2, 2), "1->2->4", "restored")
    return s.finish()


if __name__ == "__main__":
    sys.exit(main())