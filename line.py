from common import setup

s = setup("p2_line.topo", wait=30)
s.routeDMP(1)
s.routeDMP(4)
s.runForSeconds(1)
s.ping(1, 4, "line")
s.runForSeconds(10)
