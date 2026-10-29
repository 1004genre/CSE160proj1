from TestSim import TestSim


def main():
    sim = TestSim()
    sim.loadTopo("long_line.topo")
    sim.loadNoise("no_noise.txt")
    sim.bootAll()
    sim.addChannel(sim.COMMAND_CHANNEL)
    sim.addChannel(sim.NEIGHBOR_CHANNEL)
    sim.addChannel(sim.FLOODING_CHANNEL)
    sim.runForSeconds(8)
    sim.floodPing(1, 10, "Project 1 broadcast flooding")
    sim.runForSeconds(15)


if __name__ == "__main__":
    main()
