from common import dump_routes, routed_ping, setup


def main():
    sim = setup("p2_line_lossy.topo", noise="lossy_project2.txt", wait=90)
    dump_routes(sim, [1, 2, 3, 4])
    routed_ping(sim, 1, 4, "lossy-route")

    sim.injectRoutedPing(1, 4, 2)
    sim.runForSeconds(10)

    # Test neighbor expiry by removing both directions of each link around
    # node 2 while leaving the motes and their simulator timers running.
    sim.removeLink(1, 2)
    sim.removeLink(2, 1)
    sim.removeLink(2, 3)
    sim.removeLink(3, 2)
    sim.runForSeconds(20)
    dump_routes(sim, [1, 4])
    routed_ping(sim, 1, 4, "partitioned")


if __name__ == "__main__":
    main()
