from common import dump_routes, routed_ping, setup


def main():
    sim = setup("p2_capacity.topo", wait=60)
    dump_routes(sim, [1, 2, 10, 20])
    routed_ping(sim, 2, 20, "later-advertisement-page")


if __name__ == "__main__":
    main()
