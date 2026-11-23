#ANDES Lab - University of California, Merced
#! /usr/bin/python
import os
import sys
from TOSSIM import *
from CommandMsg import *
from packet import *

class TestSim:
    CMD_PING = 0
    CMD_NEIGHBOR_DUMP = 1
    CMD_ROUTE_DUMP = 3
    CMD_FLOOD_PING = 7
    CMD_ROUTING_METRIC = 8
    CMD_TEST_CLIENT = 4
    CMD_TEST_SERVER = 5
    CMD_CLIENT_CLOSE = 10
    CMD_TEST_CONSUMER_PAUSE = 11
    CMD_TEST_CONSUMER_RESUME = 12
    CMD_TEST_TRANSPORT_DROP = 13
    TEST_DROP_ANY_DATA = 254
    TEST_DROP_SEQUENCE = 0
    TEST_DROP_ACKNOWLEDGMENT = 1

    COMMAND_CHANNEL = "command"
    GENERAL_CHANNEL = "general"
    NEIGHBOR_CHANNEL = "neighbor"
    FLOODING_CHANNEL = "flooding"
    ROUTING_CHANNEL = "routing"
    TRANSPORT_CHANNEL = "transport"
    # Test harness subscribes separately to concise Project3TGen events.
    PROJECT3_TGEN_CHANNEL = "Project3TGen"
    HASHMAP_CHANNEL = "hashmap"

    def __init__(self, seed=1):
        self.moteids = []
        self.numMote = 0
        self.t = Tossim([])
        # Fix simulator randomness by default; callers can select another seed.
        self.t.randomSeed(seed)
        self.r = self.t.radio()
        self.msg = CommandMsg()
        self.pkt = self.t.newPacket()
        self.pkt.setType(self.msg.get_amType())

    def loadTopo(self, topoFile):
        print 'Creating Topo!'
        topoPath = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                'topo', topoFile)
        f = open(topoPath, 'r')
        self.numMote = int(f.readline())
        print 'Number of Motes', self.numMote
        for line in f:
            s = line.split()
            if s:
                source = int(s[0])
                destination = int(s[1])
                gain = float(s[2])
                print ' ', source, destination, gain
                self.r.add(source, destination, gain)
                if source not in self.moteids:
                    self.moteids.append(source)
                if destination not in self.moteids:
                    self.moteids.append(destination)
        f.close()

    def loadNoise(self, noiseFile):
        if self.numMote == 0:
            print 'Create a topo first'
            return
        noisePath = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 'noise', noiseFile)
        noise = open(noisePath, 'r')
        for line in noise:
            value = line.strip()
            if value:
                for mote in self.moteids:
                    self.t.getNode(mote).addNoiseTraceReading(int(value))
        noise.close()
        for mote in self.moteids:
            print 'Creating noise model for', mote
            self.t.getNode(mote).createNoiseModel()

    def bootNode(self, nodeID):
        if self.numMote == 0:
            print 'Create a topo first'
            return
        self.t.getNode(nodeID).bootAtTime(1333 * nodeID)

    def bootAll(self):
        for mote in sorted(self.moteids):
            self.bootNode(mote)

    def moteOff(self, nodeID):
        self.t.getNode(nodeID).turnOff()

    def moteOn(self, nodeID):
        self.t.getNode(nodeID).turnOn()

    def run(self, ticks):
        for unused in range(ticks):
            self.t.runNextEvent()

    # Advance in simulated seconds rather than counting a fixed number of events.
    def runTime(self, seconds):
        deadline = self.t.time() + int(seconds * self.t.ticksPerSecond())
        while self.t.time() < deadline:
            if not self.t.runNextEvent():
                raise RuntimeError(
                    'TOSSIM has no pending events before the requested '
                    'simulated-time deadline')

    def removeLink(self, source, destination):
        self.r.remove(source, destination)

    def addLink(self, source, destination, gain=-54.0):
        self.r.add(source, destination, gain)

    def sendCMD(self, commandID, destination, payloadString):
        max_payload_length = self.msg.numElements_payload(0) - 1
        if len(payloadString) > max_payload_length:
            raise ValueError(
                'Command payload must be at most {0} bytes including its '
                'null terminator'.format(max_payload_length + 1))
        self.msg.set_dest(destination)
        self.msg.set_id(commandID)
        self.msg.setString_payload(payloadString)
        self.pkt.setData(self.msg.data)
        self.pkt.setDestination(destination)
        self.pkt.deliver(destination, self.t.time() + 5)

    def ping(self, source, destination, message):
        self.sendCMD(self.CMD_PING, source, '{0}{1}'.format(chr(destination), message))

    def floodPing(self, source, destination, message):
        self.sendCMD(self.CMD_FLOOD_PING, source,
                     '{0}{1}'.format(chr(destination), message))

    def setRoutingMetric(self, nodeID, qualityEnabled):
        self.sendCMD(self.CMD_ROUTING_METRIC, nodeID,
                     chr(1 if qualityEnabled else 0))

    def testServer(self, serverAddress, listenPort):
        if not 1 <= listenPort <= 255:
            raise ValueError('TCP listen port must be between 1 and 255')
        payload = self._encode16(serverAddress) + chr(listenPort)
        self.sendCMD(self.CMD_TEST_SERVER, serverAddress, payload)

    def testClient(self, clientAddress, serverAddress, sourcePort,
                   destinationPort, transferBytes):
        if not 1 <= sourcePort <= 255 or not 1 <= destinationPort <= 255:
            raise ValueError('TCP ports must be between 1 and 255')
        if not 1 <= transferBytes <= 1024:
            raise ValueError('Project 3 transfer must be between 1 and 1024 bytes')
        payload = (self._encode16(clientAddress) +
                   self._encode16(serverAddress) +
                   chr(sourcePort) + chr(destinationPort) +
                   self._encode16(transferBytes))
        self.sendCMD(self.CMD_TEST_CLIENT, clientAddress, payload)

    def closeTestClient(self, clientAddress, serverAddress, sourcePort,
                        destinationPort):
        if not 1 <= sourcePort <= 255 or not 1 <= destinationPort <= 255:
            raise ValueError('TCP ports must be between 1 and 255')
        payload = (self._encode16(clientAddress) +
                   self._encode16(serverAddress) +
                   chr(sourcePort) + chr(destinationPort))
        self.sendCMD(self.CMD_CLIENT_CLOSE, clientAddress, payload)

    # The server command target owns the consumer for this full connection tuple.
    def pauseTestConsumer(self, serverAddress, listenPort, clientAddress,
                          sourcePort):
        if not 1 <= listenPort <= 255 or not 1 <= sourcePort <= 255:
            raise ValueError('TCP ports must be between 1 and 255')
        payload = (self._encode16(serverAddress) + chr(listenPort) +
                   self._encode16(clientAddress) + chr(sourcePort))
        self.sendCMD(self.CMD_TEST_CONSUMER_PAUSE, serverAddress, payload)

    def resumeTestConsumer(self, serverAddress, listenPort, clientAddress,
                           sourcePort):
        if not 1 <= listenPort <= 255 or not 1 <= sourcePort <= 255:
            raise ValueError('TCP ports must be between 1 and 255')
        payload = (self._encode16(serverAddress) + chr(listenPort) +
                   self._encode16(clientAddress) + chr(sourcePort))
        self.sendCMD(self.CMD_TEST_CONSUMER_RESUME, serverAddress, payload)

    # Configure one intermediate-node drop by connection tuple and sequence field.
    def dropTransportPacket(self, nodeAddress, sourceAddress,
                            destinationAddress, sourcePort, destinationPort,
                            kind, field, value, occurrence=1):
        if not 1 <= sourcePort <= 255 or not 1 <= destinationPort <= 255:
            raise ValueError('TCP ports must be between 1 and 255')
        if kind not in (0, 1, 2, 3, 4, self.TEST_DROP_ANY_DATA):
            raise ValueError('Use a TCP control code or TEST_DROP_ANY_DATA')
        if field not in (self.TEST_DROP_SEQUENCE,
                         self.TEST_DROP_ACKNOWLEDGMENT):
            raise ValueError('Drop field must be sequence or acknowledgment')
        if not 1 <= occurrence <= 65535:
            raise ValueError('Drop occurrence must be between 1 and 65535')
        payload = (self._encode16(sourceAddress) +
                   self._encode16(destinationAddress) +
                   chr(sourcePort) + chr(destinationPort) + chr(kind) +
                   chr(field) + self._encode16(value) +
                   self._encode16(occurrence))
        self.sendCMD(self.CMD_TEST_TRANSPORT_DROP, nodeAddress, payload)

    def _encode16(self, value):
        if not 0 <= value <= 65535:
            raise ValueError('TCP address/length must fit in 16 bits')
        return chr((value >> 8) & 0xff) + chr(value & 0xff)

    def neighborDMP(self, destination):
        self.sendCMD(self.CMD_NEIGHBOR_DUMP, destination, 'neighbor command')

    def routeDMP(self, destination):
        self.sendCMD(self.CMD_ROUTE_DUMP, destination, 'routing command')

    # The injected frame is processed as received by the source, so add one
    # to compensate for the source's normal forwarding decrement.
    def injectRoutedPing(self, source, destination, ttl, seq=500):
        if ttl < 1 or ttl > 14:
            raise ValueError('TTL must be between 1 and 14')
        # Build the compact 7-byte header directly; packet.py may be stale until MIG runs.
        wire = (self._encode16(destination) + self._encode16(source) +
                self._encode16(seq) + chr(((ttl + 1) << 4) | 0) +
                ('\x00' * 22))
        packet = self.t.newPacket()
        packet.setType(pack.get_amType())
        packet.setData(wire)
        packet.setDestination(source)
        packet.deliver(source, self.t.time() + 5)

    def addChannel(self, channelName, out=sys.stdout):
        print 'Adding Channel', channelName
        self.t.addChannel(channelName, out)

if __name__ == '__main__':
    s = TestSim()
    s.loadTopo('long_line.topo')
    s.loadNoise('no_noise.txt')
    s.bootAll()
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.runTime(20)
    s.ping(1, 10, 'Project 2 routed ping')
    s.runTime(30)
