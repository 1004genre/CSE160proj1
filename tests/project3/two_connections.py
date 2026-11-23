#!/usr/bin/env python2
"""Verify two independent routed connections and listener persistence."""
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


def wait_for(sim, output, path, pattern, seconds, message):
    matcher = re.compile(pattern)
    for unused in range(seconds):
        sim.runTime(1)  # Advance simulation in bounded one-second batches.
        output.flush()
        found = matcher.search(read_log(path))
        if found:
            return found
    raise RuntimeError("{0}; see {1}".format(message, path))


def main():
    parser = argparse.ArgumentParser(description="Project 3 concurrent connections")
    parser.add_argument("--topology", default="p3_midreview.topo")
    parser.add_argument("--noise", default="no_noise.txt")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()

    log_dir = os.path.join(ROOT, "logs")
    if not os.path.isdir(log_dir):
        os.makedirs(log_dir)
    log_path = os.path.join(log_dir, "project3-two-connections.log")
    output = open(log_path, "w")
    sim = TestSim(args.seed)
    sim.loadTopo(args.topology)
    sim.loadNoise(args.noise)
    sim.bootAll()
    for channel in (sim.COMMAND_CHANNEL, sim.NEIGHBOR_CHANNEL,
                    sim.ROUTING_CHANNEL, sim.PROJECT3_TGEN_CHANNEL):
        sim.addChannel(channel, output)
    sim.runTime(30)  # Let the routed 1-2-3 paths converge first.
    sim.testServer(3, 80)
    sim.runTime(1)

    sim.testClient(1, 3, 81, 80, 300)
    wait_for(sim, output, log_path,
             r"node=3 conn=\d+ 3:80->1:81 event=CONN_ACCEPT", 15,
             "first connection was not accepted")
    sim.pauseTestConsumer(3, 80, 1, 81)
    sim.runTime(10)  # Fill only connection A's receive window and sender queue.
    before = read_log(log_path)
    first_progress = re.findall(
        r"node=1 conn=\d+ 1:81->3:80 event=APP_ACCEPT .*?accepted=(\d+)", before)
    if not first_progress or max([int(value) for value in first_progress]) >= 300:
        output.close()
        raise RuntimeError("first sender did not block behind its paused consumer")

    sim.testClient(2, 3, 82, 80, 200)
    wait_for(sim, output, log_path,
             r"node=3 conn=\d+ 3:80->2:82 event=CONN_ACCEPT", 15,
             "second connection was not accepted while first remained paused")
    wait_for(sim, output, log_path,
             r"node=2 conn=\d+ 2:82->3:80 event=APP_ACCEPT .*?accepted=200",
             120, "second producer did not finish")
    sim.closeTestClient(2, 3, 82, 80)
    wait_for(sim, output, log_path,
             r"node=2 conn=\d+ 2:82->3:80 event=APP_CLOSE_SUCCESS .*?target=200",
             60, "second connection did not close successfully")

    # Connection A must still be paused while B completes on the same listener.
    mid_log = read_log(log_path)
    if "node=1 conn=" not in mid_log or "event=CONSUMER_PAUSE" not in mid_log:
        output.close()
        raise RuntimeError("first connection lost its independent paused state")
    if re.search(r"node=1 conn=\d+ 1:81->3:80 event=APP_CLOSE_SUCCESS", mid_log):
        output.close()
        raise RuntimeError("first connection closed before its unread bytes were consumed")

    sim.resumeTestConsumer(3, 80, 1, 81)
    wait_for(sim, output, log_path,
             r"node=1 conn=\d+ 1:81->3:80 event=APP_ACCEPT .*?accepted=300",
             120, "first producer did not resume")
    sim.closeTestClient(1, 3, 81, 80)
    sim.runTime(45)  # Finish A's close and retain duplicate-FIN ACK state.
    output.flush()
    log = read_log(log_path)
    output.close()

    for client, port, length in ((1, 81, 300), (2, 82, 200)):
        received = re.search(
            r"node=3 conn=\d+ 3:80->%d:%d event=APP_CONTENT_RESULT .*?consumed=(\d+).*?mismatches=(\d+)" % (client, port),
            log)
        closed = re.search(
            r"node=%d conn=\d+ %d:%d->3:80 event=APP_CLOSE_SUCCESS .*?accepted=(\d+) acknowledged=(\d+) .*?target=(\d+)" % (client, client, port),
            log)
        if received is None or [int(value) for value in received.groups()] != [length, 0]:
            raise RuntimeError("connection {0}:{1} content mismatch; see {2}".format(
                client, port, log_path))
        if closed is None or [int(value) for value in closed.groups()] != [length] * 3:
            raise RuntimeError("connection {0}:{1} close failure; see {2}".format(
                client, port, log_path))

    occupancies = [int(value) for value in re.findall(
        r"event=DATA_ACCEPT .*? buffered=(\d+)", log)]
    if not occupancies or max(occupancies) > 128:
        raise RuntimeError("receiver buffer occupancy check failed")
    print "PASS: both independent connections delivered and closed; max occupancy {0}".format(
        max(occupancies))
    print "Detailed TOSSIM output: {0}".format(log_path)


if __name__ == "__main__":
    main()
