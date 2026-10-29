import os
import sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, ROOT)
from TestSim import TestSim

def setup(topo, noise="no_noise.txt", wait=30):
    # Allow shorter startup waits during quick development tests.
    wait = int(os.environ.get("P2_TEST_WAIT", wait))

    sim = TestSim()
    sim.loadTopo(topo)
    sim.loadNoise(noise)
    sim.bootAll()
    sim.addChannel(sim.COMMAND_CHANNEL)
    sim.addChannel(sim.GENERAL_CHANNEL)
    sim.addChannel(sim.NEIGHBOR_CHANNEL)
    sim.addChannel(sim.ROUTING_CHANNEL)
    sim.addChannel(sim.FLOODING_CHANNEL)
    sim.runForSeconds(wait)
    return sim