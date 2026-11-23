#!/usr/bin/env python2
"""Check retry-limit failure, record cleanup, and tuple reuse after recovery."""
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


def run_until(sim, output, path, pattern, seconds, description):
    matcher = re.compile(pattern)
    for unused in range(seconds):
        sim.runTime(1)  # Bounded simulated-time steps keep unrelated timers active.
        output.flush()
        found = matcher.search(read_log(path))
        if found:
            return found
    raise RuntimeError("{0}; see {1}".format(description, path))


def main():
    parser = argparse.ArgumentParser(description="Project 3 failure cleanup")
    parser.add_argument("--topology", default="p3_midreview.topo")
    parser.add_argument("--noise", default="no_noise.txt")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()

    log_dir = os.path.join(ROOT, "logs")
    if not os.path.isdir(log_dir):
        os.makedirs(log_dir)
    log_path = os.path.join(log_dir, "project3-failure-cleanup.log")
    output = open(log_path, "w")
    sim = TestSim(args.seed)
    sim.loadTopo(args.topology)
    sim.loadNoise(args.noise)
    sim.bootAll()
    for channel in (sim.COMMAND_CHANNEL, sim.NEIGHBOR_CHANNEL,
                    sim.ROUTING_CHANNEL, sim.PROJECT3_TGEN_CHANNEL):
        sim.addChannel(channel, output)
    sim.runTime(30)  # Routes exist, but port 80 deliberately has no listener.
    sim.testClient(1, 3, 81, 80, 14)
    failure = run_until(
        sim, output, log_path,
        r"node=1 conn=\d+ 1:81->3:80 event=CONNECTION_FAILURE .*?reason=(\d+)",
        25, "unavailable listener did not fail within the retry bound")
    if int(failure.group(1)) != 1:
        output.close()
        raise RuntimeError("unexpected failure reason; see {0}".format(log_path))
    log = read_log(log_path)
    if "node=1 conn=" not in log or "event=APP_TRANSFER_FAILURE" not in log:
        output.close()
        raise RuntimeError("application failure was not explicitly reported")
    if not re.search(r"node=1 conn=\d+ 1:81->3:80 event=CONN_CLEANUP", log):
        output.close()
        raise RuntimeError("failed client record was not cleaned up")
    if "event=APP_CLOSE_SUCCESS" in log:
        output.close()
        raise RuntimeError("retry exhaustion was incorrectly reported as success")

    # Reuse the same four-tuple after timeout cleanup to prove it was released.
    sim.testServer(3, 80)
    sim.runTime(1)
    sim.testClient(1, 3, 81, 80, 14)
    run_until(sim, output, log_path,
              r"node=1 conn=\d+ 1:81->3:80 event=APP_ACCEPT .*?accepted=14",
              60, "connection did not reopen after bounded failure cleanup")
    sim.closeTestClient(1, 3, 81, 80)
    sim.runTime(35)  # Complete close, peer consumption, and TIME_WAIT retention.
    output.flush()
    log = read_log(log_path)
    output.close()

    received = re.search(
        r"node=3 conn=\d+ 3:80->1:81 event=APP_CONTENT_RESULT .*?consumed=(\d+).*?mismatches=(\d+)",
        log)
    closed = re.search(
        r"node=1 conn=\d+ 1:81->3:80 event=APP_CLOSE_SUCCESS .*?accepted=(\d+) acknowledged=(\d+) .*?target=(\d+)",
        log)
    if received is None or [int(value) for value in received.groups()] != [14, 0]:
        raise RuntimeError("reopened tuple failed byte validation; see {0}".format(log_path))
    if closed is None or [int(value) for value in closed.groups()] != [14, 14, 14]:
        raise RuntimeError("reopened tuple failed orderly close; see {0}".format(log_path))
    print "PASS: retry failure was explicit, cleaned up, and the tuple reopened successfully"
    print "Detailed TOSSIM output: {0}".format(log_path)


if __name__ == "__main__":
    main()
