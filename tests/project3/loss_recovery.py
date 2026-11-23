#!/usr/bin/env python2
"""Exercise one-shot control/data loss and duplicate-safe transport recovery."""
import argparse
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, ROOT)

from TestSim import TestSim


CASES = {
    # Kind, direction, selected field/value, and expected retransmission event.
    "syn": (0, 1, 3, 0, 0, "SYN_RETX"),
    "synack": (2, 3, 1, 1, 1, "SYN_ACK_RETX"),
    "handshake_ack": (1, 1, 3, 1, 1, "SYN_ACK_RETX"),
    "data": (254, 1, 3, 0, 1, "DATA_RETX"),
    "data_ack": (1, 3, 1, 1, 15, "DATA_RETX"),
    "fin": (3, 1, 3, 0, 15, "FIN_RETX"),
    "close_ack": (1, 1, 3, 1, 2, "FIN_RETX"),
}
RETRY_EVENT_NODES = {
    "syn": ("SYN_TX", "SYN_RETX", 1),
    "synack": ("SYN_ACK_TX", "SYN_ACK_RETX", 3),
    "handshake_ack": ("SYN_ACK_TX", "SYN_ACK_RETX", 3),
    "data": ("DATA_TX", "DATA_RETX", 1),
    "data_ack": ("DATA_TX", "DATA_RETX", 1),
    "fin": ("FIN_TX", "FIN_RETX", 1),
    "close_ack": ("FIN_TX", "FIN_RETX", 3),
}


def read_log(path):
    with open(path, "r") as source:
        return source.read()


def arm_drop(sim, case):
    kind, source, destination, field, value, unused_event = CASES[case]
    sim.dropTransportPacket(2, source, destination, 81 if source == 1 else 80,
                            80 if destination == 3 else 81, kind, field, value)


def run_case(case, args):
    kind, source, destination, field, value, retry_event = CASES[case]
    log_dir = os.path.join(ROOT, "logs")
    if not os.path.isdir(log_dir):
        os.makedirs(log_dir)
    log_path = os.path.join(log_dir, "project3-loss-{0}.log".format(case))
    output = open(log_path, "w")
    sim = TestSim(args.seed)
    sim.loadTopo(args.topology)
    sim.loadNoise(args.noise)
    sim.bootAll()
    for channel in (sim.COMMAND_CHANNEL, sim.NEIGHBOR_CHANNEL,
                    sim.ROUTING_CHANNEL, sim.PROJECT3_TGEN_CHANNEL):
        sim.addChannel(channel, output)
    sim.runTime(30)  # Establish routes before injecting a controlled loss.
    sim.testServer(3, 80)
    sim.runTime(1)

    # FIN and final-close-ACK drops are armed only after data is acknowledged.
    if case not in ("fin", "close_ack"):
        arm_drop(sim, case)
        sim.runTime(1)  # Let the forwarding node install the one-shot rule.
    sim.testClient(1, 3, 81, 80, 14)
    accepted_pattern = re.compile(
        r"node=1 conn=\d+ 1:81->3:80 event=APP_ACCEPT .*?accepted=(\d+)")
    for unused in range(90):
        sim.runTime(1)
        output.flush()
        values = [int(value) for value in accepted_pattern.findall(read_log(log_path))]
        if values and max(values) == 14:
            break
    else:
        output.close()
        raise RuntimeError("{0}: sender did not accept test bytes; see {1}".format(
            case, log_path))

    # Target the close path only after the producer has submitted all test data.
    if case in ("fin", "close_ack"):
        arm_drop(sim, case)
        sim.runTime(1)  # Install the rule before the close request sends FIN.
    sim.closeTestClient(1, 3, 81, 80)
    sim.runTime(45)  # Covers retries, duplicate FIN ACK, and TIME_WAIT cleanup.
    output.flush()
    log = read_log(log_path)
    output.close()

    consumed = re.search(
        r"node=3 conn=\d+ 3:80->1:81 event=APP_CONTENT_RESULT .*?consumed=(\d+).*?mismatches=(\d+)",
        log)
    closed = re.search(
        r"node=1 conn=\d+ 1:81->3:80 event=APP_CLOSE_SUCCESS .*?accepted=(\d+) acknowledged=(\d+) .*?target=(\d+)",
        log)
    if "event=TEST_DROP " not in log:
        raise RuntimeError("{0}: configured packet was not dropped; see {1}".format(
            case, log_path))
    if retry_event not in log:
        raise RuntimeError("{0}: expected {1}; see {2}".format(
            case, retry_event, log_path))
    # Compare transport sequence range across the original send and retry.
    sent_event, retry_name, send_node = RETRY_EVENT_NODES[case]
    original = re.search(
        r"node=%d .*?event=%s .*?seq=(\d+) len=(\d+)" %
        (send_node, sent_event), log)
    retransmitted = re.search(
        r"node=%d .*?event=%s .*?seq=(\d+) len=(\d+)" %
        (send_node, retry_name), log)
    if original is None or retransmitted is None or original.groups() != retransmitted.groups():
        raise RuntimeError("{0}: retry changed its transport range; see {1}".format(
            case, log_path))
    if consumed is None or [int(value) for value in consumed.groups()] != [14, 0]:
        raise RuntimeError("{0}: duplicate-safe content check failed; see {1}".format(
            case, log_path))
    if closed is None or [int(value) for value in closed.groups()] != [14, 14, 14]:
        raise RuntimeError("{0}: acknowledged orderly close failed; see {1}".format(
            case, log_path))
    print "PASS: {0} loss recovered with exactly 14 delivered bytes".format(case)


def main():
    parser = argparse.ArgumentParser(description="Project 3 loss recovery")
    parser.add_argument("--case", choices=["all"] + sorted(CASES), default="all")
    parser.add_argument("--topology", default="p3_midreview.topo")
    parser.add_argument("--noise", default="no_noise.txt")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    cases = sorted(CASES) if args.case == "all" else [args.case]
    for case in cases:
        run_case(case, args)


if __name__ == "__main__":
    main()
