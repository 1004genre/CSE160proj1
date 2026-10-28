from common import setup

s = setup("p2_alternative.topo", wait=30)
s.routeDMP(1)
s.ping(1, 4, "via-2")
s.runForSeconds(3)
s.removeLink(2, 4)
s.removeLink(4, 2)
s.runForSeconds(20)  # allow the 5-second neighbor timeout and DV exchanges
s.routeDMP(1)
s.ping(1, 4, "via-3")
s.runForSeconds(5)
s.addLink(2, 4)
s.addLink(4, 2)
s.runForSeconds(20)
s.routeDMP(1)
s.ping(1, 4, "restored")
s.runForSeconds(10)
