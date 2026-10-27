from common import setup

# Loss model: 9 quiet -98 dBm readings, then 3 noisier -70 dBm readings,
# repeating in the trace used to build each mote's TOSSIM noise model.
lossy = setup("p2_line.topo", "lossy_project2.txt", wait=90)
lossy.routeDMP(1)
lossy.ping(1, 4, "lossy-recovery")
lossy.runForSeconds(10)

# Separate clean run: TTL=2 on a three-link route expires at the second relay.
clean = setup("p2_line.topo", "no_noise.txt", wait=30)
clean.injectRoutedPing(1, 4, ttl=2, seq=501)
clean.runForSeconds(10)
