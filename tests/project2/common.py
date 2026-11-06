import os
import sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, ROOT)
from TestSim import TestSim

def setup(topo, noise="no_noise.txt", wait=30, output=None, channels=None):
    # Allow shorter startup waits during quick development tests.
    if wait > 0:
        wait = int(os.environ.get("P2_TEST_WAIT", wait))

    sim = TestSim()
    sim.loadTopo(topo)
    sim.loadNoise(noise)
    sim.bootAll()
    if output is None:
        output = sys.stdout
    if channels is None:
        channels = (sim.COMMAND_CHANNEL, sim.GENERAL_CHANNEL,
                    sim.NEIGHBOR_CHANNEL, sim.ROUTING_CHANNEL,
                    sim.FLOODING_CHANNEL)
    for channel in channels:
        sim.addChannel(channel, output)
    sim.runForSeconds(wait)
    return sim


def dump_routes(sim, nodes):
    for node in nodes:
        sim.routeDMP(node)
        sim.runForSeconds(1)


def routed_ping(sim, source, destination, message, wait=10):
    sim.ping(source, destination, message)
    sim.runForSeconds(wait)


# ---------------------------------------------------------------------------
# Compact reporting helper (used by line.py / alternative.py).
#
# Raw TOSSIM output is written to logs/<name>.raw.log (everything), a filtered
# copy without the per-entry "advert to" lines goes to logs/<name>.log, and the
# console only shows a short, self-checking summary (also saved as
# logs/<name>.summary.txt).  Compatible with Python 2 (TOSSIM) and Python 3.
# ---------------------------------------------------------------------------
import re

INF = 16
_HDR = re.compile(r"Node (\d+) routing table")
_ROW = re.compile(r"^(?:\d+:\d+:\d+\.\d+ )?(?:DEBUG \(\d+\): )?(\d+) (\S+) (\S+) (VALID|UNREACHABLE)\s*$")
_FWD = re.compile(r"Node (\d+) Routing Packet - src: (\d+), dest: (\d+), seq: (\d+), next hop: (\d+), cost: (\d+)")


def parse_tables(text):
    """{node: {dest: (nexthop or None, cost, state)}} from routingTableDump output."""
    tabs, cur = {}, None
    for line in text.splitlines():
        m = _HDR.search(line)
        if m:
            cur = int(m.group(1))
            tabs[cur] = {}
            continue
        if cur is None:
            continue
        m = _ROW.match(line.strip())
        if m:
            nh = None if m.group(2) == "-" else int(m.group(2))
            cost = INF if m.group(3) == "INF" else int(m.group(3))
            tabs[cur][int(m.group(1))] = (nh, cost, m.group(4))
        elif not line.strip().startswith("Dest"):
            cur = None
    return tabs


def route(tabs, node, dest):
    """(nexthop, cost) if `node` has a VALID route to `dest`, else None."""
    r = tabs.get(node, {}).get(dest)
    return (r[0], r[1]) if r and r[2] == "VALID" else None


def path_of(log, dest):
    """Forwarding chain 'a->b->c' for packets addressed to `dest`, from Routing Packet log lines."""
    hops = [(int(f[0]), int(f[4])) for f in _FWD.findall(log) if int(f[2]) == dest]
    if not hops:
        return "(none)", 0
    chain = [str(hops[0][0])] + [str(nxt) for _, nxt in hops]
    return "->".join(chain), len(hops)


class _Null(object):
    def write(self, s):
        pass

    def flush(self):
        pass


class Scenario(object):
    def __init__(self, name, topo, noise="no_noise.txt", settle=30):
        self.name, self.topo, self.noise, self.settle = name, topo, noise, settle
        self.checks, self.fails, self.lines = 0, 0, []
        logdir = os.path.join(ROOT, "logs")
        if not os.path.isdir(logdir):
            os.makedirs(logdir)
        self.raw_path = os.path.join(logdir, name + ".raw.log")
        self.log_path = os.path.join(logdir, name + ".log")
        self.sum_path = os.path.join(logdir, name + ".summary.txt")
        self.raw = open(self.raw_path, "w")
        self._real, sys.stdout = sys.stdout, _Null()      # silence TestSim's chatty prints
        self.sim = TestSim()
        self.sim.loadTopo(topo)
        self.sim.loadNoise(noise)
        self.sim.bootAll()
        for ch in (self.sim.ROUTING_CHANNEL, self.sim.NEIGHBOR_CHANNEL, self.sim.FLOODING_CHANNEL):
            self.sim.addChannel(ch, self.raw)
        self.sim.runForSeconds(0)

    # ---- output -----------------------------------------------------------
    def say(self, text=""):
        self.lines.append(text)
        self._real.write(text + "\n")
        self._real.flush()

    def header(self, title, plan, expect):
        links, gains = [], set()
        with open(os.path.join(ROOT, "topo", self.topo)) as f:
            n = int(f.readline())
            for ln in f:
                p = ln.split()
                if len(p) == 3:
                    links.append("%s>%s" % (p[0], p[1]))
                    gains.add(p[2])
        boots = ", ".join("%d@%.1fs" % (i, 1.333 * i) for i in range(1, n + 1))
        self.say("=== %s ===" % title)
        self.say("Topology: %s, %d nodes, directed links: %s (gain %s dB)" % (
            self.topo, n, " ".join(links), "/".join(sorted(gains))))
        self.say("Noise   : %s" % self.noise)
        self.say("Boot    : %s (node i boots at 1.333*i s)" % boots)
        for p in plan:
            self.say("Plan    : " + p)
        for e in expect:
            self.say("Expect  : " + e)
        self.say("--- run (simulated time) ---")

    # ---- simulation helpers ----------------------------------------------
    def now(self):
        return self.sim.t.time() / float(self.sim.t.ticksPerSecond())

    def run(self, seconds):
        self.sim.runForSeconds(seconds)
        self.raw.flush()

    def mark(self):
        self.raw.flush()
        return os.path.getsize(self.raw_path)

    def since(self, pos):
        self.raw.flush()
        with open(self.raw_path) as f:
            f.seek(pos)
            return f.read()

    def tables(self, nodes):
        pos = self.mark()
        # Process each dump before issuing the next command.
        for n in nodes:
            self.sim.routeDMP(n)
            self.run(1)
        return parse_tables(self.since(pos))
    
    def ping(self, src, dst, label, wait=10):
        self.say("t=%5.1fs  command: ping %d -> %d (\"%s\"), wait %ds" % (self.now(), src, dst, label, wait))
        pos = self.mark()
        self.sim.ping(src, dst, label)
        self.run(wait)
        return self.since(pos)

    def cut(self, a, b):
        self.say("t=%5.1fs  command: remove link %d<->%d (both directions; nodes stay up)" % (self.now(), a, b))
        self.sim.removeLink(a, b)
        self.sim.removeLink(b, a)

    def heal(self, a, b):
        self.say("t=%5.1fs  command: restore link %d<->%d (both directions)" % (self.now(), a, b))
        self.sim.addLink(a, b)
        self.sim.addLink(b, a)

    def expect(self, cond, text, got=""):
        self.checks += 1
        if not cond:
            self.fails += 1
        self.say("  [%s] %s%s" % ("PASS" if cond else "FAIL", text, "" if cond else "  (got: %s)" % got))
        return cond

    def finish(self):
        self.raw.flush()
        self.raw.close()
        kept = 0
        with open(self.raw_path) as src, open(self.log_path, "w") as dst:
            for ln in src:
                if " advert to " not in ln:           # drop the per-entry advertisement chatter
                    dst.write(ln)
                    kept += 1
        self.say("--- result ---")
        self.say("%s: %d/%d checks passed. Logs: logs/%s.log (filtered, %d lines), logs/%s.raw.log (full)" % (
            self.name, self.checks - self.fails, self.checks, self.name, kept, self.name))
        with open(self.sum_path, "w") as f:
            f.write("\n".join(self.lines) + "\n")
        sys.stdout = self._real
        return self.fails