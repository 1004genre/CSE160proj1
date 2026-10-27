from common import setup

# 20-node star: diameter 2 (< INFINITY), 20 destinations, vector requires 3 pages.
s = setup("p2_capacity.topo", wait=60)
s.routeDMP(2)
s.runForSeconds(1)
# Node 2 must have learned destinations 11..20 from later advertisement pages.
s.ping(2, 20, "later-page")
s.runForSeconds(10)
