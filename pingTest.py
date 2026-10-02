from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # # Load the the layout of the network.
    # s.loadTopo("long_line.topo");

    # # Add a noise model to all of the motes.
    # s.loadNoise("no_noise.txt");

    # # Turn on all of the sensors.
    # s.bootAll();

    # # Add the main channels. These channels are declared in includes/channels.h
    # s.addChannel(s.COMMAND_CHANNEL);
    # s.addChannel(s.GENERAL_CHANNEL);
    # s.addChannel(s.NEIGHBOR_CHANNEL);
    # s.addChannel(s.FLOODING_CHANNEL);

    # # After sending a ping, simulate a little to prevent collision.
    # s.runTime(1);
    # s.ping(2, 3, "Hello, World");
    # s.runTime(1);

    # s.ping(1, 10, "Hi!");
    # s.runTime(1); 

#erm


    s.runTime(1)
    s.loadTopo("long_line.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.NEIGHBOR_CHANNEL)
    s.addChannel(s.FLOODING_CHANNEL)

    # Let neighbor beacons populate tables.
    s.runTime(8)

    # Print node 5's neighbor table.
    s.neighborDMP(5)
    s.runTime(1)

    # Node 2 -> node 18 is 16 hops; MAX_TTL is 20 so the request and reply can arrive.
    s.ping(2, 18, "too far")
    s.runTime(15)

    # This is 15 hops and should succeed.
    s.ping(2, 17, "long distance")
    s.runTime(15)

    # Turn off node 4. Its direct neighbors are nodes 3 and 5.
    s.moteOff(4)
    s.runTime(7)  # More than the five-beacon timeout.

    # Dump separately because TestSim reuses its command packet.
    s.neighborDMP(3)
    s.runTime(1)
    s.neighborDMP(5)
    s.runTime(1)


if __name__ == '__main__':
    main()

