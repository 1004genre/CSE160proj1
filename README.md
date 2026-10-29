# Introduction
This skeleton code is the basis for the CSE160 network project. Additional documentation
on what is expected will be provided as the school year continues.

# General Information
## Data Structures
There are two data structures included into the project design to help with the
assignment. See dataStructures/interfaces/ for the header information of these
structures.

* **Hashmap** - This is for anything that needs to retrieve a value based on a key.

* **List** - The list is design to have pushfront, pushback capabilities. For the most part,
you can stick with an array or even a QueueC (FIFO) which are more robust.

## General Libraries
/lib/interfaces

* **CommandHandler** - CommandHandler is what interfaces with TOSSIM. Commands are
sent to this function, and based on the parameters passed, an event is fired.
* **SimpleSend** - This is a wrapper of the lower level sender in TinyOS. The features
included is a basic queuing mechanism and some small delays to prevent collisions. Do
not change the delays. You can duplicate SimpleSendC to use a different AM type or
possibly rewire it.
* **Transport** - There is only the interface of Transport included. The actual
implementation of the Transport layer is left to the student as an exercise. For
CSE160 this will be Project 3 so don't worry about it now.

## Noise
/noise/

This is the "noise" of the network. A heavy noised network will cause issues with
packet loss.

* **no_noise.txt** - There should be no packet loss using this model.

## Topography
/topo/

This folder contains a few example topographies of the network and how they are
connected to each other. Be sure to try additional networks when testing your code
since additional ones will be added when grading.

* **long_line.topo** - this topography is a line of 19 motes that have bidirectional
links.
* **example.topo** - A slightly more complex connection

Each line has three values, the source node, the destination node, and the gain.
For now you can keep the gain constant for all of your topographies. A line written
as ```1 2 -53``` denotes a one-way connection from 1 to 2. To make it bidirectional
include also ```2 1 -53```.

# Running Simulations

The following is an example of a simulation script.
```
from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runForSeconds(1);

    # Load the the layout of the network.
    s.loadTopo("long_line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);

    # After sending a ping, simulate a little to prevent collision.
    s.runForSeconds(1);
    s.ping(1, 2, "Hello, World");
    s.runForSeconds(1);

    s.ping(1, 10, "Hi!");
    s.runForSeconds(1);

if __name__ == '__main__':
    main()
```

For Project 1 broadcast flooding, run `python2 pingTest.py`. The `ping`
command is Project 2 routed unicast; `TestSim.floodPing(source, destination,
message)` sends the separate Project 1 flood command. This keeps flooding
available without causing ordinary routed packets to fall back to broadcasts.

# Project 2: Distance Vector Routing

## Build and run

From this project directory, build the TOSSIM application using the TinyOS environment:

```sh
make micaz sim
python2 tests/project2/line.py
```

Run the other reproducible scenarios with `python2 tests/project2/alternative.py`,
`partition.py`, `poison_reverse.py`, `capacity.py`, and
`loss_and_ttl.py`. Run each from the repository root. Each driver creates a fresh
simulation. The drivers add command,
neighbor, flooding, and routing channels to standard output.
Topology and noise files are resolved relative to the repository, so drivers
can also be launched from `tests/project2`.

The required routing metric remains hop count by default. To run the optional
loss-aware comparison, use:

```sh
python2 tests/project2/lossy_metric.py
```

This runs the same 20 pings on the same lossy diamond topology twice: once with
the default hop-count metric and once with the quality-aware metric. It writes
raw debug output to `logs/quality-hop-count.log` and `logs/quality-aware.log`,
then reports delivered pings, received replies, and the selected route. The
metric mode is enabled on each node by the driver; other tests keep hop count.
The comparison prints startup, convergence, and traffic progress while it runs,
and flushes each log periodically. Each metric case runs in a separate Python
process because TOSSIM's event scheduler may stop advancing when a second
simulator is created in the same process. Timed runs now fail with an explicit
error if TOSSIM reports an empty event queue instead of hanging indefinitely.
The quality-aware result also verifies that all five nodes enabled the metric
and that node 1's route cost is at least 16; a cost of 2 means the quality
metric was not confirmed and the script fails instead of reporting a comparison.
See [PROJECT2_DESIGN.md](PROJECT2_DESIGN.md) for the probe, cost, bounds,
failure handling, and interpretation of the previously reported results.

To keep raw output logs, create `logs` and redirect each scenario, for example:

```sh
mkdir -p logs
python2 tests/project2/line.py > logs/line.log 2>&1
```

Repeat with each scenario's filename. Run
`python2 pingTest.py > logs/flooding.log 2>&1` to capture the Project 1 flood.

Every topology lists directed radio links. Intended links list both directions.
Nodes boot at TOSSIM time `1333 * nodeID`; the test helper waits in simulated
seconds using `ticksPerSecond()`. Startup waits are 30 seconds, or 60 seconds
for the 20-node packet-capacity case. Link-failure tests wait 20 seconds after
a change: the neighbor timeout is 5 seconds, followed by staged DV exchanges.
The lossy test waits 90 seconds before checking routes, and the TTL test injects
a TTL-2 ping over the 3-hop line.

## Routing constants and capacities

* Hop-count metric; `DV_INFINITY = 16`. Finite costs are 0 through 15.
* The route table has 256 statically allocated destination slots (IDs 0-255).
  The neighbor table has 32 slots; excess neighbors are logged and ignored.
* The packet remains 28 bytes, including the 8-byte network header. A DV
  payload has a count byte and at most 9 destination/cost pairs. Larger vectors
  are serialized into successive packets; queue-full pages are retried.
* Neighbor discovery sends beacons every 1 second after a randomized initial
  delay, expires a neighbor after 5 missed periods, and confirms bidirectional
  reachability with a beacon, acknowledgment, and confirmation exchange.
* Learned route freshness is per destination. A learned route expires after
  300 seconds without an update, enough for a full staged advertisement round
  at the configured neighbor and route-table capacities. An unreachable entry
  is advertised for 1200 seconds (multiple complete rounds at the configured
  capacity). Initial routing timer startup is randomized.
* DV uses a separate one-hop AM type and stages one recipient-specific page
  every 250 ms. A new advertisement round starts after the previous round
  completes. Routing advertisements are never forwarded. Poison reverse sets
  a destination's advertised cost to 16 for the neighbor selected as next hop.
* Equal costs retain the currently valid next hop. A route from the current
  next hop may increase or become unreachable; a worse route from another
  neighbor cannot replace a valid route.
* Optional loss-aware mode estimates each outbound link's delivery quality
  from sequence-matched acknowledgments to periodic neighbor beacons. It
  converts an EWMA delivery estimate into a positive, scaled ETX link cost,
  adds that cost to advertised route costs, and uses 255 as infinity. This mode
  has independent bounded-cost and poison-reverse behavior; it is not enabled
  in the required hop-count tests.

The SimpleSend queue and pool each hold 20 messages per sender component.
Ordinary pings and replies use AM type 6 and unicast next-hop sends. The
Project 1 duplicate cache is used only by broadcast flooding. Forwarded packets
preserve their end-to-end header and lose one TTL at each intermediate node.

## Required scenario expectations

* `line.py`: node 1 reaches node 4 through 2 at cost 3; the reply follows
  routed unicast back through 3.
* `alternative.py`: node 1 reaches 4 through 2 at cost 2, changes to a
  cost-3 path through 3 after both 2-4 directions are removed, and returns
  to cost 2 after restoration.
* `partition.py`: node 1 drops the ping to 4 after the 2-3 cut converges,
  then routes it after restoration.
* `poison_reverse.py`: node 1 logs cost 16 for destination 4 to neighbor 2,
  and finite cost 3 to neighbor 3.
* `capacity.py`: the 20-node star has diameter 2 and requires multiple DV
  packets; node 2 learns and pings node 20 from a later page.
* `loss_and_ttl.py`: routes recover under the lossy noise model. A TTL-2 packet
  expires at an intermediate node on the three-link path without a reply; it
  also stops node 2 and checks the resulting route loss.
* `lossy_metric.py`: repeats identical traffic in hop-count and quality-aware
  modes on `p2_quality.topo` with `lossy_project2.txt`, then reports the
  delivered-packet and reply counts for comparison. The topology offers a
  two-hop weaker path and a three-hop stronger alternative.

The drivers print routing logs; compare those logs with the expectations above.
Run them in the course TinyOS/TOSSIM environment and save the observed logs
with the submission.
`TestSim.injectRoutedPing` compensates for its test packet being delivered to
the source as a received frame, so the source does not consume an extra TTL
relative to the requested value. The design and discussion PDFs are included
beside their Markdown sources.
