from common import setup

def main():
    s = setup("p2_alternative.topo", wait=30)
    s.routeDMP(1)
    s.runTime(1)
    s.ping(1, 4, "via-2")
    s.runTime(3)
    s.removeLink(2, 4)
    s.removeLink(4, 2)
    s.runTime(20)
    s.routeDMP(1)
    s.runTime(1)
    s.ping(1, 4, "via-3")
    s.runTime(5)
    s.addLink(2, 4)
    s.addLink(4, 2)
    s.runTime(20)
    s.routeDMP(1)
    s.runTime(1)
    s.ping(1, 4, "restored")
    s.runTime(10)


if __name__ == "__main__":
    main()
