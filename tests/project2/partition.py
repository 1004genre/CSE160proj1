from common import dump_routes, routed_ping, setup


def main():
    sim = setup("p2_line.topo")
    dump_routes(sim, [1, 4])
    sim.removeLink(2, 3)
    sim.removeLink(3, 2)
    sim.runForSeconds(20)
    dump_routes(sim, [1, 2, 3, 4])
    routed_ping(sim, 1, 4, "partitioned")
    sim.addLink(2, 3)
    sim.addLink(3, 2)
    sim.runForSeconds(20)
    dump_routes(sim, [1, 4])
    routed_ping(sim, 1, 4, "restored")


if __name__ == "__main__":
    main()
