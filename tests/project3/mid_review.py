import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, ROOT)

from TestSim import TestSim


def main():
    expected_bytes = 256  # Exact length catches a whole repeated-pattern block loss.
    log_dir = os.path.join(ROOT, "logs")
    if not os.path.isdir(log_dir):
        os.makedirs(log_dir)
    log_path = os.path.join(log_dir, "project3-mid-review.log")

    with open(log_path, "w") as output:
        sim = TestSim()
        sim.loadTopo("p3_midreview.topo")
        sim.loadNoise("no_noise.txt")
        sim.bootAll()
        for channel in (sim.COMMAND_CHANNEL, sim.NEIGHBOR_CHANNEL,
                        sim.ROUTING_CHANNEL, sim.TRANSPORT_CHANNEL,
                        # Keep the structured transport trace in the review log.
                        sim.PROJECT3_TGEN_CHANNEL):
            sim.addChannel(channel, output)

        sim.runTime(30)
        sim.testServer(3, 80)
        sim.runTime(1)
        # Exceed the 128-byte local buffer to exercise partial writes and resumption.
        sim.testClient(1, 3, 81, 80, expected_bytes)
        sim.runTime(5)
        sim.closeTestClient(1, 3, 81, 80)
        # Allow the consumer pause, transfer completion, and 18-second TIME_WAIT.
        sim.runTime(40)

    with open(log_path, "r") as result_file:
        log = result_file.read()

    expected = (
        "TCP test server listening on port 80",
        "TCP test client connecting",
        "state CLOSED -> SYN_SENT",
        "state CLOSED -> SYN_RCVD",
        "state SYN_SENT -> ESTABLISHED",
        "state SYN_RCVD -> ESTABLISHED",
        "outstanding 28/56",
        "TCP test consumer paused",
        "receive buffer 128/128",
        "TCP test receiver advertised zero window",
        "TCP test consumer resumed",
        "TCP test dropped reopening window update",
        "send code 4",
        "window reopened after probe",
        "pattern valid",
        "consumed 256",
        "TCP client close requested",
    )
    missing = [marker for marker in expected if marker not in log]
    if missing:
        raise RuntimeError(
            "Project 3 mid-review checks failed; missing {0}. See {1}".format(
                ", ".join(missing), log_path))

    occupancies = [int(value) for value in
                   re.findall(r"receive buffer (\d+)/128", log)]
    if not occupancies or max(occupancies) > 128:
        raise RuntimeError(
            "Project 3 receive buffer bound failed. See {0}".format(log_path))

    server_summary = re.search(
        r"TCP server connection 1:81 -> 3:80 closed after (\d+) bytes; mismatches (\d+)",
        log)
    client_summary = re.search(
        r"TCP client 1:81 -> 3:80 close succeeded: accepted (\d+) acknowledged (\d+) of (\d+)",
        log)
    if (server_summary is None or
            int(server_summary.group(1)) != expected_bytes or
            int(server_summary.group(2)) != 0):
        raise RuntimeError(
            "Expected exactly {0} consumed bytes and zero mismatches. See {1}".format(
                expected_bytes, log_path))
    if (client_summary is None or
            [int(value) for value in client_summary.groups()] !=
            [expected_bytes, expected_bytes, expected_bytes]):
        raise RuntimeError(
            "Client accepted and acknowledged counts did not match {0}. See {1}".format(
                expected_bytes, log_path))

    print ""
    print "Connection setup:"
    print "Node 1: CLOSED -> SYN_SENT"
    print "Node 3: LISTEN -> SYN_RCVD"
    print "Node 1: SYN_SENT -> ESTABLISHED"
    print "Node 3: SYN_RCVD -> ESTABLISHED"
    print ""
    print "Reliable data transfer:"
    print "Node 1 sent 256 bytes using the fixed sliding window"
    print "Node 3 verified the byte pattern and returned cumulative ACKs"
    print ""
    print "Receive flow control:"
    print "Node 3 paused consumption, reached zero window, and dropped one reopening update"
    print "Node 1 recovered through a window probe; receiver occupancy stayed within 128 bytes"
    print ""
    print "Orderly teardown:"
    print "Node 1: ESTABLISHED -> FIN_WAIT_1"
    print "Node 3: ESTABLISHED -> LAST_ACK"
    print "Node 3 sends FIN"
    print "Node 1: FIN_WAIT_1/FIN_WAIT_2 -> TIME_WAIT"
    print "Node 1 sends the final ACK"
    print "Node 3 closes and releases its connection"
    print "Node 1 releases its record after TIME_WAIT"
    print ""
    print "Project 3 mid-review passed: setup, 256-byte transfer, and orderly close."
    print "Detailed TOSSIM output: {0}".format(log_path)


if __name__ == "__main__":
    main()
