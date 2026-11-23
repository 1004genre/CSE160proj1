#!/usr/bin/env python2
"""Check Tahoe slow start, congestion avoidance, and timeout backoff."""
import argparse
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, ROOT)

from TestSim import TestSim


def read_log(path):
    with open(path, "r") as source:
        return source.read()


def run_case(sim, output, log_path, case, source_port):
    if case == "timeout":
        # Lose the first segment so its retransmission timer reports congestion.
        sim.dropTransportPacket(
            2, 1, 3, source_port, 80, sim.TEST_DROP_ANY_DATA,
            sim.TEST_DROP_SEQUENCE, 1)
        sim.runTime(1)
    sim.testClient(1, 3, source_port, 80, 1024)

    accepted = re.compile(
        r"node=1 conn=\d+ 1:{0}->3:80 event=APP_ACCEPT .*?accepted=(\d+)".format(
            source_port))
    for unused in range(120):
        sim.runTime(1)  # Keep simulation and unrelated timers event-driven.
        output.flush()
        values = [int(value) for value in accepted.findall(read_log(log_path))]
        if values and max(values) == 1024:
            break
    else:
        output.close()
        raise RuntimeError("{0}: producer did not accept 1,024 bytes; see {1}".format(
            case, log_path))

    sim.closeTestClient(1, 3, source_port, 80)
    sim.runTime(40)  # Wait through graceful close and TIME_WAIT.
    output.flush()
    log = read_log(log_path)
    # Limit congestion assertions to this connection's own endpoint tuple.
    client_log = "\n".join(
        line for line in log.splitlines()
        if " 1:{0}->3:80 ".format(source_port) in line)

    initial = re.search(
        r"node=1 conn=\d+ 1:{0}->3:80 event=CONGESTION_INIT .*?cwnd=(\d+) ssthresh=(\d+)".format(
            source_port), log)
    windows = [int(value) for value in re.findall(
        r"node=1 conn=\d+ 1:{0}->3:80 event=CONGESTION_.*?cwnd=(\d+)".format(
            source_port), client_log)]
    if initial is None or [int(value) for value in initial.groups()] != [14, 42]:
        raise RuntimeError("{0}: initial congestion state is incorrect; see {1}".format(
            case, log_path))
    if ("phase=SLOW_START" not in client_log or
            "phase=CONGESTION_AVOIDANCE" not in client_log):
        raise RuntimeError("{0}: both growth phases were not observed; see {1}".format(
            case, log_path))
    if not windows or max(windows) != 56:
        raise RuntimeError("{0}: congestion window did not reach its 56-byte cap; see {1}".format(
            case, log_path))

    if case == "timeout":
        if not re.search(
                r"node=1 conn=\d+ 1:{0}->3:80 event=CONGESTION_TIMEOUT .*?cwnd=14 ssthresh=\d+".format(
                    source_port), client_log):
            raise RuntimeError("timeout did not cut cwnd to one segment")
        if not re.search(
                r"node=1 conn=\d+ 1:{0}->3:80 event=DATA_RETX .*?seq=1 len=14".format(
                    source_port), client_log):
            raise RuntimeError("lost first segment was not retransmitted")

    received = re.search(
        r"node=3 conn=\d+ 3:80->1:{0} event=APP_CONTENT_RESULT .*?consumed=(\d+).*?mismatches=(\d+)".format(
            source_port), log)
    closed = re.search(
        r"node=1 conn=\d+ 1:{0}->3:80 event=APP_CLOSE_SUCCESS .*?accepted=(\d+) acknowledged=(\d+) .*?target=(\d+)".format(
            source_port), log)
    if received is None or [int(value) for value in received.groups()] != [1024, 0]:
        raise RuntimeError("{0}: exact content check failed; see {1}".format(
            case, log_path))
    if closed is None or [int(value) for value in closed.groups()] != [1024] * 3:
        raise RuntimeError("{0}: orderly close failed; see {1}".format(case, log_path))
    print "PASS: {0} congestion control, max cwnd {1}".format(case, max(windows))


def main():
    parser = argparse.ArgumentParser(description="Project 3 Tahoe congestion control")
    parser.add_argument("--case", choices=("all", "baseline", "timeout"),
                        default="all")
    parser.add_argument("--topology", default="p3_midreview.topo")
    parser.add_argument("--noise", default="no_noise.txt")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    cases = (("baseline", 81), ("timeout", 82)) if args.case == "all" else (
        (args.case, 81 if args.case == "baseline" else 82),)

    # Reuse one TOSSIM instance; the Python binding cannot reliably restart its event queue.
    log_dir = os.path.join(ROOT, "logs")
    if not os.path.isdir(log_dir):
        os.makedirs(log_dir)
    log_path = os.path.join(log_dir, "project3-congestion.log")
    output = open(log_path, "w")
    sim = TestSim(args.seed)
    sim.loadTopo(args.topology)
    sim.loadNoise(args.noise)
    sim.bootAll()
    for channel in (sim.COMMAND_CHANNEL, sim.NEIGHBOR_CHANNEL,
                    sim.ROUTING_CHANNEL, sim.PROJECT3_TGEN_CHANNEL):
        sim.addChannel(channel, output)
    sim.runTime(30)  # Route convergence keeps congestion from mixing with startup.
    sim.testServer(3, 80)
    sim.runTime(1)
    for case, source_port in cases:
        run_case(sim, output, log_path, case, source_port)
    output.close()


if __name__ == "__main__":
    main()
