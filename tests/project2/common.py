import os
import sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, ROOT)
from TestSim import TestSim

def setup(topo, noise="no_noise.txt", wait=30, output=None, channels=None):
    # Allow shorter startup waits during quick development tests.
    if wait > 0:
        wait = int(os.environ.get("P2_TEST_WAIT", wait))

    sim = TestSim()
    sim.loadTopo(topo)
    sim.loadNoise(noise)
    sim.bootAll()
    if output is None:
        output = sys.stdout
    if channels is None:
        channels = (sim.COMMAND_CHANNEL, sim.GENERAL_CHANNEL,
                    sim.NEIGHBOR_CHANNEL, sim.ROUTING_CHANNEL,
                    sim.FLOODING_CHANNEL)
    for channel in channels:
        sim.addChannel(channel, output)
    sim.runForSeconds(wait)
    return sim


def dump_routes(sim, nodes):
    for node in nodes:
        sim.routeDMP(node)
        sim.runForSeconds(1)


def routed_ping(sim, source, destination, message, wait=10):
    sim.ping(source, destination, message)
    sim.runForSeconds(wait)