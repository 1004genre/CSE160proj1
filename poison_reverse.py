from common import setup

# A=1 reaches D=4 via B=2 at cost 3; C=3 is a different neighbor.
# Inspect Node 1's "advert to 2" and "advert to 3" log lines for dest 4.
s = setup("p2_poison.topo", wait=30)
s.routeDMP(1)
s.routeDMP(2)
s.routeDMP(3)
s.runForSeconds(1)
