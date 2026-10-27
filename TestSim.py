#ANDES Lab - University of California, Merced
#! /usr/bin/python
import sys
from TOSSIM import *
from CommandMsg import *
from packet import *

class TestSim:
    CMD_PING = 0
    CMD_NEIGHBOR_DUMP = 1
    CMD_ROUTE_DUMP = 3

    COMMAND_CHANNEL = "command"
    GENERAL_CHANNEL = "general"
    NEIGHBOR_CHANNEL = "neighbor"
    FLOODING_CHANNEL = "flooding"
    ROUTING_CHANNEL = "routing"
    TRANSPORT_CHANNEL = "transport"
    HASHMAP_CHANNEL = "hashmap"

    def __init__(self):
        self.moteids = []
        self.numMote = 0
        self.t = Tossim([])
        self.r = self.t.radio()
        self.msg = CommandMsg()
        self.pkt = self.t.newPacket()
        self.pkt.setType(self.msg.get_amType())

    def loadTopo(self, topoFile):
        print 'Creating Topo!'
        f = open('topo/' + topoFile, 'r')
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
        noise = open('noise/' + noiseFile, 'r')
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
    def runForSeconds(self, seconds):
        deadline = self.t.time() + int(seconds * self.t.ticksPerSecond())
        while self.t.time() < deadline:
            self.t.runNextEvent()

    def removeLink(self, source, destination):
        self.r.remove(source, destination)

    def addLink(self, source, destination, gain=-54.0):
        self.r.add(source, destination, gain)

    def sendCMD(self, commandID, destination, payloadString):
        self.msg.set_dest(destination)
        self.msg.set_id(commandID)
        self.msg.setString_payload(payloadString)
        self.pkt.setData(self.msg.data)
        self.pkt.setDestination(destination)
        self.pkt.deliver(destination, self.t.time() + 5)

    def ping(self, source, destination, message):
        self.sendCMD(self.CMD_PING, source, '{0}{1}'.format(chr(destination), message))

    def neighborDMP(self, destination):
        self.sendCMD(self.CMD_NEIGHBOR_DUMP, destination, 'neighbor command')

    def routeDMP(self, destination):
        self.sendCMD(self.CMD_ROUTE_DUMP, destination, 'routing command')

    # Inject an IP packet at its source with a test TTL.
    def injectRoutedPing(self, source, destination, ttl, seq=500):
        message = pack()
        message.set_dest(destination)
        message.set_src(source)
        message.set_seq(seq)
        message.set_TTL(ttl)
        message.set_protocol(0)
        message.set_payload([0] * 20)
        packet = self.t.newPacket()
        packet.setType(message.get_amType())
        packet.setData(message.data)
        packet.setDestination(source)
        packet.deliver(source, self.t.time() + 5)

    def addChannel(self, channelName, out=sys.stdout):
        print 'Adding Channel', channelName
        self.t.addChannel(channelName, out)

if __name__ == '__main__':
    s = TestSim()
    s.runForSeconds(1)
    s.loadTopo('long_line.topo')
    s.loadNoise('no_noise.txt')
    s.bootAll()
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.runForSeconds(20)
    s.ping(1, 10, 'Project 2 routed ping')
    s.runForSeconds(30)
