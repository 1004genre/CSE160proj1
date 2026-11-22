#!/usr/bin/env python
"""Project 3 TOSSIM runner and wrappers for test commands.

Command target contract:
  cmdTestServer is delivered to serverAddress.
  cmdTestClient and cmdClientClose are delivered to clientAddress.
  Consumer pause/resume commands are delivered to serverAddress and identify
  (serverAddress, listenPort, clientAddress, sourcePort).

The wrappers adapt these named operations to the starter TestSim method names.
"""
import argparse
import os
import re

from TestSim import TestSim


class Project3Run(object):
    def __init__(self, topology="p3_midreview.topo", noise="no_noise.txt"):
        self.sim = TestSim()
        self.expectedTransfers = {}
        log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
        if not os.path.isdir(log_dir):
            os.makedirs(log_dir)
        self.logPath = os.path.join(log_dir, "project3-run.log")
        self.output = open(self.logPath, "w")
        self.sim.loadTopo(topology)
        self.sim.loadNoise(noise)
        self.sim.bootAll()
        for channel in (self.sim.COMMAND_CHANNEL, self.sim.NEIGHBOR_CHANNEL,
                        self.sim.ROUTING_CHANNEL, self.sim.TRANSPORT_CHANNEL):
            self.sim.addChannel(channel, self.output)
        self.sim.runForSeconds(30)

    def cmdTestServer(self, serverAddress, listenPort):
        self.sim.testServer(serverAddress, listenPort)

    def cmdTestClient(self, clientAddress, serverAddress, srcPort, destPort,
                      transferBytes):
        key = (clientAddress, serverAddress, srcPort, destPort)
        self.expectedTransfers[key] = transferBytes
        self.sim.testClient(clientAddress, serverAddress, srcPort, destPort,
                            transferBytes)

    def cmdClientClose(self, clientAddress, serverAddress, srcPort, destPort):
        self.sim.closeTestClient(clientAddress, serverAddress, srcPort, destPort)

    def cmdTestConsumerPause(self, serverAddress, listenPort, clientAddress,
                             sourcePort):
        self.sim.pauseTestConsumer(serverAddress, listenPort, clientAddress,
                                   sourcePort)

    def cmdTestConsumerResume(self, serverAddress, listenPort, clientAddress,
                              sourcePort):
        self.sim.resumeTestConsumer(serverAddress, listenPort, clientAddress,
                                    sourcePort)

    def runForSeconds(self, seconds):
        self.sim.runForSeconds(seconds)

    def verifyTransfer(self, clientAddress, serverAddress, srcPort, destPort):
        key = (clientAddress, serverAddress, srcPort, destPort)
        if key not in self.expectedTransfers:
            raise ValueError("No expected transfer length is recorded for {0}".format(key))
        expected = self.expectedTransfers[key]
        self.output.flush()
        with open(self.logPath, "r") as log_file:
            log = log_file.read()
        endpoint = re.escape("{0}:{1} -> {2}:{3}".format(
            clientAddress, srcPort, serverAddress, destPort))
        server = re.search(
            r"TCP server connection " + endpoint +
            r" closed after (\d+) bytes; mismatches (\d+)", log)
        client = re.search(
            r"TCP client " + endpoint +
            r" close succeeded: accepted (\d+) acknowledged (\d+) of (\d+)",
            log)
        # Length and mismatch checks complement the byte pattern's 256-byte period.
        if (server is None or int(server.group(1)) != expected or
                int(server.group(2)) != 0):
            raise RuntimeError(
                "Receiver length/content check failed for expected {0} bytes; see {1}".format(
                    expected, self.logPath))
        if (client is None or
                [int(value) for value in client.groups()] !=
                [expected, expected, expected]):
            raise RuntimeError(
                "Client acceptance/acknowledgment check failed for {0} bytes; see {1}".format(
                    expected, self.logPath))
        return expected


def main():
    parser = argparse.ArgumentParser(description="Run the Project 3 TOSSIM demo")
    parser.add_argument("--topology", default="p3_midreview.topo")
    parser.add_argument("--noise", default="no_noise.txt")
    args = parser.parse_args()

    runner = Project3Run(args.topology, args.noise)
    runner.cmdTestServer(3, 80)
    runner.runForSeconds(1)
    runner.cmdTestClient(1, 3, 81, 80, 300)
    runner.runForSeconds(5)
    runner.cmdTestConsumerPause(3, 80, 1, 81)
    runner.runForSeconds(10)
    runner.cmdTestConsumerResume(3, 80, 1, 81)
    runner.runForSeconds(5)
    runner.cmdClientClose(1, 3, 81, 80)
    runner.runForSeconds(40)
    runner.verifyTransfer(1, 3, 81, 80)
    print "Verified 300 bytes accepted, acknowledged, and consumed with zero mismatches."
    print "Detailed TOSSIM output: {0}".format(runner.logPath)
    runner.output.close()


if __name__ == "__main__":
    main()
