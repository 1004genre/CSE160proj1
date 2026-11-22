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

from TestSim import TestSim


class Project3Run(object):
    def __init__(self, topology="p3_midreview.topo", noise="no_noise.txt"):
        self.sim = TestSim()
        self.sim.loadTopo(topology)
        self.sim.loadNoise(noise)
        self.sim.bootAll()
        for channel in (self.sim.COMMAND_CHANNEL, self.sim.NEIGHBOR_CHANNEL,
                        self.sim.ROUTING_CHANNEL, self.sim.TRANSPORT_CHANNEL):
            self.sim.addChannel(channel)
        self.sim.runForSeconds(30)

    def cmdTestServer(self, serverAddress, listenPort):
        self.sim.testServer(serverAddress, listenPort)

    def cmdTestClient(self, clientAddress, serverAddress, srcPort, destPort,
                      transferBytes):
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


if __name__ == "__main__":
    main()
