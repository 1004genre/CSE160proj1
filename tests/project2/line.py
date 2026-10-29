from common import dump_routes, routed_ping, setup


def main():
    sim = setup("p2_line.topo")
    dump_routes(sim, [1, 2, 3, 4])
    routed_ping(sim, 1, 4, "line-forward")
    routed_ping(sim, 4, 1, "line-reply")


if __name__ == "__main__":
    main()
