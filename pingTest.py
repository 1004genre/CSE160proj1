<<<<<<< HEAD
from TestSim import *
def main():
    s = TestSim()
    s.loadTopo("long_line.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.NEIGHBOR_CHANNEL)
    s.addChannel(s.FLOODING_CHANNEL)
    s.runForSeconds(8)
    s.neighborDMP(5)
    s.runForSeconds(1)
    s.ping(2, 18, "too far")
    s.runForSeconds(15)
    s.neighborDMP(3)
    s.runForSeconds(1)
    s.moteOff(4)
    s.runForSeconds(7)
    s.neighborDMP(5)
    s.runForSeconds(1)
if __name__ == '__main__': main()
=======
import os
import sys

from TestSim import TestSim


# ------------------------------------------------------------
# Test configuration
# ------------------------------------------------------------

NOISE_FILE = "no_noise.txt"

# Simulated seconds to allow boot and DV convergence.
STARTUP_WAIT = 10
CONVERGENCE_WAIT = 40
POST_FAILURE_WAIT = 40

# Use the channel names defined by your channels.h.
CHANNELS = [
    "command",
    "neighbor",
    "routing",
    "flooding",
]


# ------------------------------------------------------------
# Topology helpers
# ------------------------------------------------------------

def write_topology(filename, node_count, undirected_links):
    """
    Write a TOSSIM topology file.

    Every intended bidirectional link is written in BOTH directions.
    Link gain follows the same -54.0 format used by Project 1.
    """
    with open(filename, "w", encoding="utf-8") as f:
        f.write(f"{node_count}\n")

        for a, b in undirected_links:
            f.write(f"{a} {b} -54.0\n")
            f.write(f"{b} {a} -54.0\n")

    print(f"Created topology: {filename}")
    print(f"Nodes: {node_count}")
    print(f"Bidirectional links: {undirected_links}")


def line_topology():
    """Required line: 1 -- 2 -- 3 -- 4."""
    return "p2_line.topo", 4, [
        (1, 2),
        (2, 3),
        (3, 4),
    ]


def alternative_topology():
    """
    Required alternative-path topology:

             2
            / \
           1   4
            \ / 
             3 -- 5

    Links: 1-2, 2-4, 1-3, 3-5, 5-4.
    """
    return "p2_alternative.topo", 5, [
        (1, 2),
        (2, 4),
        (1, 3),
        (3, 5),
        (5, 4),
    ]


def partition_topology():
    """Required line before removing link 2-3."""
    return line_topology()


def capacity_topology():
    """
    A star with 20 nodes. Its diameter is 2, below INFINITY=16.

    Whether it forces multiple DV packets depends on your actual
    packet-size configuration and advertisement serialization.
    """
    links = [(1, node) for node in range(2, 21)]
    return "p2_capacity.topo", 20, links


# ------------------------------------------------------------
# Simulation helpers
# ------------------------------------------------------------

def create_sim(topology_file, node_count, links):
    write_topology(topology_file, node_count, links)

    sim = TestSim()

    # Load topology and noise before booting the nodes.
    sim.loadTopo(topology_file)
    sim.loadNoise(NOISE_FILE)

    # Enable debug channels.
    for channel in CHANNELS:
        try:
            sim.addChannel(channel)
        except Exception as exc:
            print(
                f"WARNING: Could not enable channel {channel!r}: {exc}"
            )

    sim.bootAll()

    print(f"\nWaiting {STARTUP_WAIT} simulated seconds for startup...")
    sim.runTime(STARTUP_WAIT)

    print(
        f"Waiting {CONVERGENCE_WAIT} simulated seconds "
        "for initial DV convergence..."
    )
    sim.runTime(CONVERGENCE_WAIT)

    return sim


def dump_routes(sim, node_ids):
    """Request a route-table dump from each specified node."""
    print("\n========== ROUTING TABLE DUMPS ==========")

    for node_id in node_ids:
        print(f"\nRequesting route table from node {node_id}")
        sim.routeDMP(node_id)

        # Allow the command and debug output to execute.
        sim.runTime(1)


def ping_test(sim, source, destination, payload):
    """Send a ping and leave time for forwarding and its reply."""
    print(
        f"\n========== ROUTED PING: "
        f"{source} -> {destination} =========="
    )

    sim.ping(source, destination, payload)
    sim.runTime(10)


def require_link_mutation_api(sim):
    """
    Check whether the radio wrapper supports dynamic link changes.

    The supplied Project 1 summary establishes that sim.radio exists,
    but does not establish the exact link-removal method in this
    TOSSIM version. Check the available methods before using failures.
    """
    radio = getattr(sim, "radio", None)

    if radio is None:
        raise RuntimeError(
            "TestSim does not expose sim.radio. "
            "Add a radio-link mutation helper to TestSim.py."
        )

    print("\nRadio object methods that may support link mutation:")
    candidates = [
        name for name in dir(radio)
        if any(word in name.lower()
               for word in ("remove", "delete", "disconnect", "add"))
    ]

    print(candidates or "(no obvious link-mutation methods found)")

    if not any(
        callable(getattr(radio, name, None))
        for name in ("remove", "delete", "disconnect")
    ):
        raise RuntimeError(
            "Cannot safely remove a radio link using the exposed API. "
            "Check your TOSSIM binding or add a tested helper that "
            "removes BOTH directed radio edges while keeping motes "
            "running. Do not substitute moteOff() for a link failure."
        )

    return radio


def remove_bidirectional_link(sim, a, b):
    """
    Remove both directed radio edges while leaving both motes running.

    Confirm the selected method's argument signature for your TOSSIM
    version before relying on this helper.
    """
    radio = require_link_mutation_api(sim)

    for source, destination in ((a, b), (b, a)):
        removed = False

        for method_name in ("remove", "delete", "disconnect"):
            method = getattr(radio, method_name, None)

            if callable(method):
                try:
                    method(source, destination)
                    print(
                        f"Removed radio edge {source} -> {destination}"
                    )
                    removed = True
                    break
                except TypeError:
                    continue

        if not removed:
            raise RuntimeError(
                f"Found no usable link-removal call for "
                f"{source} -> {destination}. Check the TOSSIM API."
            )


def add_bidirectional_link(sim, a, b, gain=-54.0):
    """
    Restore both directed radio edges.

    This uses the commonly exposed radio.add(src, dst, gain) form.
    Verify it against your installed TOSSIM binding.
    """
    radio = getattr(sim, "radio", None)

    if radio is None or not callable(getattr(radio, "add", None)):
        raise RuntimeError(
            "Radio link restoration requires radio.add(src, dst, gain). "
            "Check your TOSSIM binding."
        )

    radio.add(a, b, gain)
    radio.add(b, a, gain)

    print(f"Restored bidirectional link {a} <-> {b}")


# ------------------------------------------------------------
# Test 1: Required line topology
# ------------------------------------------------------------

def test_line():
    """
    Expected after convergence:
      Node 1 -> destination 4: next hop 2, cost 3.
      Node 4 -> destination 1: next hop 3, cost 3.
      Ping 1 -> 4 and its reply use routed forwarding.
    """
    print("\n\n############################################")
    print("TEST 1: LINE TOPOLOGY")
    print("############################################")

    topo, count, links = line_topology()
    sim = create_sim(topo, count, links)

    dump_routes(sim, [1, 2, 3, 4])

    ping_test(sim, 1, 4, "line-forward")
    ping_test(sim, 4, 1, "line-reply-check")

    print("\nEXPECTED:")
    print("Node 1: destination 4, next hop 2, cost 3, finite")
    print("Node 4: destination 1, next hop 3, cost 3, finite")
    print("Ping and reply are routed; ordinary data is not flooded.")


# ------------------------------------------------------------
# Test 2: Alternative path and recovery
# ------------------------------------------------------------

def test_alternative():
    """
    Initially the shortest path 1 -> 2 -> 4 costs 2.
    Remove both directions of link 2-4.
    The alternate path 1 -> 3 -> 5 -> 4 costs 3.
    Restore link 2-4 and check that cost 2 returns.
    """
    print("\n\n############################################")
    print("TEST 2: ALTERNATIVE PATH AND RECOVERY")
    print("############################################")

    topo, count, links = alternative_topology()
    sim = create_sim(topo, count, links)

    dump_routes(sim, [1, 2, 4])
    ping_test(sim, 1, 4, "before-failure")

    print("\nRemoving link 2 <-> 4; motes 2 and 4 remain running.")
    remove_bidirectional_link(sim, 2, 4)

    sim.runTime(POST_FAILURE_WAIT)
    dump_routes(sim, [1, 2, 4])
    ping_test(sim, 1, 4, "after-failure")

    print("\nRestoring link 2 <-> 4.")
    add_bidirectional_link(sim, 2, 4)

    sim.runTime(POST_FAILURE_WAIT)
    dump_routes(sim, [1, 2, 4])
    ping_test(sim, 1, 4, "after-restoration")

    print("\nEXPECTED:")
    print("Initially: node 1 reaches 4 through 2, cost 2.")
    print("After failure: node 1 reaches 4 through 3, cost 3.")
    print("After restoration: node 1 returns to cost 2.")


# ------------------------------------------------------------
# Test 3: Partition, withdrawal, and recovery
# ------------------------------------------------------------

def test_partition():
    """
    Remove link 2-3 from the line 1-2-3-4.

    After convergence, node 1 must not have a usable route to node 4.
    A ping must be dropped instead of falling back to flooding.
    Restore the link and verify route recovery.
    """
    print("\n\n############################################")
    print("TEST 3: PARTITION AND RECOVERY")
    print("############################################")

    topo, count, links = partition_topology()
    sim = create_sim(topo, count, links)

    dump_routes(sim, [1, 4])
    ping_test(sim, 1, 4, "before-partition")

    print("\nRemoving link 2 <-> 3; all motes remain running.")
    remove_bidirectional_link(sim, 2, 3)

    sim.runTime(POST_FAILURE_WAIT)
    dump_routes(sim, [1, 2, 3, 4])

    print("\nAttempting ping across the partition.")
    ping_test(sim, 1, 4, "should-be-dropped")

    print("\nRestoring link 2 <-> 3.")
    add_bidirectional_link(sim, 2, 3)

    sim.runTime(POST_FAILURE_WAIT)
    dump_routes(sim, [1, 4])
    ping_test(sim, 1, 4, "after-recovery")

    print("\nEXPECTED:")
    print("After convergence, node 1's route to node 4 is INF/unusable.")
    print("The partitioned ping is dropped; no data flooding occurs.")
    print("After restoration, node 1 regains a cost-3 route to node 4.")


# ------------------------------------------------------------
# Test 4: Advertisement capacity
# ------------------------------------------------------------

def test_capacity():
    """
    Use a connected star with diameter 2.

    Inspect routing logs to confirm:
      - vectors exceeding one packet are sent in multiple packets;
      - destinations in later packets are learned;
      - omission from an individual packet does not withdraw routes.
    """
    print("\n\n############################################")
    print("TEST 4: ADVERTISEMENT PACKET CAPACITY")
    print("############################################")

    topo, count, links = capacity_topology()
    sim = create_sim(topo, count, links)

    dump_routes(sim, [1, 2, 10, 20])

    print("\nEXPECTED:")
    print("All connected nodes learn routes within the supported metric.")
    print("Node 1 reaches every leaf at cost 1.")
    print("Each leaf reaches other leaves through node 1 at cost 2.")
    print(
        "Inspect DV logs to verify multiple advertisement packets "
        "and correct handling of omitted entries."
    )


# ------------------------------------------------------------
# Tests that require specific packet/debug instrumentation
# ------------------------------------------------------------

def print_manual_checks():
    print("\n\n############################################")
    print("ADDITIONAL REQUIRED CHECKS")
    print("############################################")

    print("""
5. POISON REVERSE
   Create or use a topology where A reaches destination D through B,
   while A also has another neighbor C.
   Inspect the advertisement A sends separately to each neighbor.
   Expected:
       Advertisement to B: D = INFINITY (16)
       Advertisement to C: D = finite selected cost
   Confirm that A always advertises its self-route with cost 0.

6. TTL
   Inject a routed ping with a positive TTL smaller than the path
   length. The source sends the initial TTL unchanged. Every
   intermediate node drops TTL <= 1; otherwise it decrements TTL
   once before forwarding.
   Expected: no reply, no indefinite circulation, no TTL reset.
   The existing TestSim.ping() helper may not expose TTL; if so,
   add a test helper to set it in the packet.

7. LOSS AND EXPIRATION
   Run with a documented lossy noise model. Allow ordinary packet
   loss, then verify that periodic DV advertisements restore routes
   after successful exchanges resume. Verify stale learned routes
   expire even when their next-hop neighbor remains active.

8. NEIGHBOR EXPIRATION
   Stop a forwarding node or cause neighbor discovery to expire it.
   Confirm that routes using it are recomputed, withdrawn, or replaced.

9. ROUTING TABLE FORMAT
   Each routingTableDump should print:
       Dest | NextHop | Cost | State
   Unreachable routes should show INF and no usable next hop.

10. ROUTED FORWARDING LOG
    Each successful forwarding log should identify:
       current node, original source, final destination, sequence
       number, next hop, and selected cost.

11. NO DATA FLOODING
    For a routed ping, ordinary packet logs should show only the
    selected path's forwarding nodes, not every node in the network.
    The flooding duplicate cache must not discard routed packets.
""")


# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------

TESTS = {
    "line": test_line,
    "alternative": test_alternative,
    "partition": test_partition,
    "capacity": test_capacity,
}


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 project2_tests.py "
              "{line|alternative|partition|capacity|all}")
        sys.exit(2)

    selected = sys.argv[1].lower()

    if selected == "all":
        # Each test creates its own simulation instance.
        # This avoids carrying route state from one test into another.
        for name in ("line", "alternative", "partition", "capacity"):
            try:
                TESTS[name]()
            except Exception as exc:
                print(f"\nTEST {name!r} could not complete: {exc}")
                print("Fix the reported API/configuration issue and retry.")

        print_manual_checks()
        return

    if selected not in TESTS:
        print(f"Unknown test: {selected}")
        print("Choose:", ", ".join(TESTS), "or all")
        sys.exit(2)

    TESTS[selected]()
    print_manual_checks()


if __name__ == "__main__":
    main()
>>>>>>> 3e68bf8cadf1f0118e2c1ccebd7a083959b97a43
