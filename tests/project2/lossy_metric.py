import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
LOG_DIR = os.path.join(ROOT, "logs")
PING_COUNT = 20
PING_INTERVAL = 2
STARTUP_WAIT = 30
METRIC_CONVERGENCE_WAIT = 10
PROGRESS_INTERVAL = 5


def report_progress(message, output):
    print(message)
    sys.stdout.flush()
    output.flush()


def advance(sim, seconds, label, output):
    remaining = seconds
    while remaining > 0:
        interval = min(PROGRESS_INTERVAL, remaining)
        sim.runForSeconds(interval)
        remaining -= interval
        report_progress("%s: %d/%d simulated seconds" %
                        (label, seconds - remaining, seconds), output)


def run_simulation(quality_metric, log_path):
    if not os.path.isdir(LOG_DIR):
        os.makedirs(LOG_DIR)

    from common import setup

    output = open(log_path, "w")
    try:
        report_progress("Starting %s run; log: %s" %
                        ("quality-aware" if quality_metric else "hop-count",
                         log_path), output)
        sim = setup("p2_quality.topo", noise="lossy_project2.txt",
                    wait=0, output=output,
                    channels=("neighbor", "routing"))
        advance(sim, STARTUP_WAIT, "Startup and route convergence", output)
        if quality_metric:
            for node in range(1, 6):
                sim.setRoutingMetric(node, True)
            advance(sim, METRIC_CONVERGENCE_WAIT,
                    "Quality metric convergence", output)
        sim.neighborDMP(1)
        sim.runForSeconds(1)
        output.flush()

        for sequence in range(PING_COUNT):
            sim.ping(1, 4, "quality-test-%02d" % sequence)
            sim.runForSeconds(PING_INTERVAL)
            if (sequence + 1) % 5 == 0:
                report_progress("Ping traffic %d/%d complete" %
                                (sequence + 1, PING_COUNT), output)

        advance(sim, 5, "Waiting for final replies", output)
        sim.routeDMP(1)
        sim.runForSeconds(1)
        report_progress("Finished simulation; parsing results", output)
    finally:
        output.close()


def parse_result(quality_metric, log_name):
    log_path = os.path.join(LOG_DIR, log_name)
    with open(log_path, "r") as log_file:
        log = log_file.read()

    delivered = len(re.findall(r"Node 4 delivered ping from 1 seq \d+", log))
    replies = len(re.findall(r"Node 1 received ping reply from 4 seq \d+", log))
    routes = re.findall(r"DEBUG \(1\): 4 (\d+) (\d+) VALID", log)
    if not routes:
        raise RuntimeError("No valid route to node 4 found in %s" % log_path)
    next_hop = int(routes[-1][0])
    cost = int(routes[-1][1])

    return {
        "mode": "quality-aware" if quality_metric else "hop-count",
        "delivered": delivered,
        "replies": replies,
        "next_hop": next_hop,
        "cost": cost,
        "log": log_path,
    }


def run_case(quality_metric, log_name):
    log_path = os.path.join(LOG_DIR, log_name)
    mode = "quality" if quality_metric else "hop"
    command = [sys.executable, os.path.abspath(__file__),
               "--run-case", mode, log_path]
    return_code = subprocess.call(command)
    if return_code != 0:
        raise RuntimeError("%s simulation process failed with exit code %d; "
                           "see %s" %
                           (mode, return_code, log_path))
    return parse_result(quality_metric, log_name)


def print_result(result):
    print("%s: destination 4 via %s, metric cost %s; "
          "%d/%d pings delivered, %d/%d replies received; log: %s" %
          (result["mode"], result["next_hop"], result["cost"],
           result["delivered"], PING_COUNT, result["replies"], PING_COUNT,
           result["log"]))


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--run-case":
        if sys.argv[2] not in ("hop", "quality"):
            raise ValueError("Unknown metric case: %s" % sys.argv[2])
        run_simulation(sys.argv[2] == "quality", sys.argv[3])
        return

    print("Comparing the same 20 pings, topology, and lossy noise trace.")
    baseline = run_case(False, "quality-hop-count.log")
    metric = run_case(True, "quality-aware.log")
    print_result(baseline)
    print_result(metric)
    print("Delivery difference (quality-aware minus hop-count): %d/%d" %
          (metric["delivered"] - baseline["delivered"], PING_COUNT))
    print("Reply difference (quality-aware minus hop-count): %d/%d" %
          (metric["replies"] - baseline["replies"], PING_COUNT))


if __name__ == "__main__":
    main()
