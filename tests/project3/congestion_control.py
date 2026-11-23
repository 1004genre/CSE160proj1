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


def run_case(case, args):
    log_dir = os.path.join(ROOT, "logs")
    if not os.path.isdir(log_dir):
        os.makedirs(log_dir)
    log_path = os.path.join(log_dir, "project3-congestion-{0}.log".format(case))
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
    if case == "timeout":
        # Lose the first segment so its retransmission timer reports congestion.
        sim.dropTransportPacket(
            2, 1, 3, 81, 80, sim.TEST_DROP_ANY_DATA,
            sim.TEST_DROP_SEQUENCE, 1)
        sim.runTime(1)
    sim.testClient(1, 3, 81, 80, 1024)

    accepted = re.compile(
        r"node=1 conn=\d+ 1:81->3:80 event=APP_ACCEPT .*?accepted=(\d+)")
    for unused in range(120):
        sim.runTime(1)  # Keep simulation and unrelated timers event-driven.
        output.flush()
        values = [int(value) for value in accepted.findall(read_log(log_path))]
        if values and max(values) == 1024:
            break
    else:
        output.close()
        raise RuntimeError("{0}: transfer did not enter transport; see {1}".format(
            case, log_path))

    sim.closeTestClient(1, 3, 81, 80)
    sim.runTime(40)  # Wait through graceful close and TIME_WAIT.
    output.flush()
    log = read_log(log_path)
    output.close()

    initial = re.search(
        r"node=1 conn=\d+ 1:81->3:80 event=CONGESTION_INIT .*?cwnd=(\d+) ssthresh=(\d+)",
        log)
    windows = [int(value) for value in re.findall(
        r"node=1 .*?event=CONGESTION_.*?cwnd=(\d+)", log)]
    if initial is None or [int(value) for value in initial.groups()] != [14, 42]:
        raise RuntimeError("{0}: initial congestion state is incorrect; see {1}".format(
            case, log_path))
    if "phase=SLOW_START" not in log or "phase=CONGESTION_AVOIDANCE" not in log:
        raise RuntimeError("{0}: both growth phases were not observed; see {1}".format(
            case, log_path))
    if not windows or max(windows) != 56:
        raise RuntimeError("{0}: congestion window did not reach its 56-byte cap; see {1}".format(
            case, log_path))

    if case == "timeout":
        if not re.search(
                r"event=CONGESTION_TIMEOUT .*?cwnd=14 ssthresh=\d+", log):
            raise RuntimeError("timeout did not cut cwnd to one segment")
        if not re.search(r"node=1 .*?event=DATA_RETX .*?seq=1 len=14", log):
            raise RuntimeError("lost first segment was not retransmitted")

    received = re.search(
        r"node=3 conn=\d+ 3:80->1:81 event=APP_CONTENT_RESULT .*?consumed=(\d+).*?mismatches=(\d+)",
        log)
    closed = re.search(
        r"node=1 conn=\d+ 1:81->3:80 event=APP_CLOSE_SUCCESS .*?accepted=(\d+) acknowledged=(\d+) .*?target=(\d+)",
        log)
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
    cases = ("baseline", "timeout") if args.case == "all" else (args.case,)
    for case in cases:
        run_case(case, args)


if __name__ == "__main__":
    main()
