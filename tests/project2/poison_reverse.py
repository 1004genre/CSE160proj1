from common import dump_routes, routed_ping, setup


def main():
    sim = setup("p2_poison.topo")
    dump_routes(sim, [1, 2, 3, 4, 5])
    routed_ping(sim, 1, 4, "poison-reverse")


if __name__ == "__main__":
    main()
