#!/usr/bin/env python3
"""Runs the parity matrix (specification section 12.5) on the simulators of this Mac.

For every iOS version and device asked for, the script finds or creates a simulator, and for
every appearance and content size puts the simulator in that configuration and runs the UI
test bundle of the host app once; the bundle then runs every layout direction, input and
script. Each cell writes one JSON result under the results directory; `summarize.py` turns
them into `summary.md` and `summary.csv`.

Cells that cannot run are recorded too, with the reason: an iOS version whose runtime this
macOS cannot boot, or a configuration the simulator could not be put in.

Usage: Tools/run-matrix.sh [--os 17.5,18.6,27.0] [--devices "iPhone 15,..."]
           [--appearances light,dark,...] [--sizes XS,L,XXXL,AX5] [--directions ltr,rtl]
           [--inputs software,hardware] [--scripts type,...] [--results DIR] [--jobs N]
           [--timeout MINUTES] [--snapshots all] [--record-reference] [--skip-build] [--keep-booted]
"""
import argparse
import atexit
import concurrent.futures
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading

HOST = pathlib.Path(__file__).resolve().parent.parent
PROJECT = HOST / "App" / "ParityHost.xcodeproj"
DERIVED = HOST / ".derived" / "app"

# The axes of specification section 12.5.
SPEC_OS = ["15.5", "16.4", "17.5", "18.6", "27.0"]
SPEC_DEVICES = ["iPhone SE (3rd generation)", "iPhone 15", "iPhone 15 Pro Max", "iPad (10th generation)"]
SPEC_APPEARANCES = ["light", "dark", "increased-contrast", "reduce-transparency", "bold-text"]
ALL_APPEARANCES = SPEC_APPEARANCES + ["dark-increased-contrast"]
SPEC_SIZES = ["XS", "L", "XXXL", "AX5"]
SPEC_DIRECTIONS = ["ltr", "rtl"]
SPEC_INPUTS = ["software", "hardware"]
SPEC_SCRIPTS = [
    "type", "backspace-select", "backspace-delete", "tap-select", "clear", "submit", "cancel", "text-to-token",
    "token-overflow", "focus-round-trip",
]
SIMCTL_SIZE = {
    "XS": "extra-small", "L": "large", "XXXL": "extra-extra-extra-large",
    "AX5": "accessibility-extra-extra-extra-large",
}

print_lock = threading.Lock()


def log(message):
    with print_lock:
        print(f"[{datetime.datetime.now():%H:%M:%S}] {message}", flush=True)


def run(arguments, check=True, capture=True, env=None, timeout=None):
    return subprocess.run(arguments, check=check, capture_output=capture, text=True, env=env, timeout=timeout)


def simctl(*arguments, check=True, timeout=180):
    return run(["xcrun", "simctl", *arguments], check=check, timeout=timeout)


def slug(text):
    return text.replace(" ", "-").replace("(", "").replace(")", "")


def runtimes():
    """iOS version (major.minor) -> runtime record, for every installed iOS runtime."""
    listed = json.loads(simctl("list", "runtimes", "-j").stdout)["runtimes"]
    found = {}
    for runtime in listed:
        if runtime.get("platform") != "iOS":
            continue
        version = ".".join(runtime["version"].split(".")[:2])
        found[version] = runtime
    return found


def device_types():
    listed = json.loads(simctl("list", "devicetypes", "-j").stdout)["devicetypes"]
    return {entry["name"]: entry["identifier"] for entry in listed}


def simulator(version, device, runtime, types):
    """The UDID of the parity simulator for an iOS version and device type; created on first use."""
    name = f"ztron-parity-{version}-{slug(device)}"
    devices = json.loads(simctl("list", "devices", "-j").stdout)["devices"].get(runtime["identifier"], [])
    for entry in devices:
        if entry["name"] == name and entry.get("isAvailable", True):
            return entry["udid"]
    return simctl("create", name, types[device], runtime["identifier"]).stdout.strip()


def boot(udid):
    state = json.loads(simctl("list", "devices", "-j").stdout)
    booted = any(entry["udid"] == udid and entry["state"] == "Booted" for entries in state["devices"].values() for entry in entries)
    if not booted:
        simctl("boot", udid, check=False)
    simctl("bootstatus", udid, "-b", timeout=600)


def configure(udid, appearance, size):
    """Puts a booted simulator in one appearance and content size. The host app verifies it."""
    dark = appearance in ("dark", "dark-increased-contrast")
    contrast = appearance in ("increased-contrast", "dark-increased-contrast")
    simctl("ui", udid, "appearance", "dark" if dark else "light")
    simctl("ui", udid, "increase_contrast", "enabled" if contrast else "disabled")
    simctl("ui", udid, "content_size", SIMCTL_SIZE[size])
    # Reduce Transparency and Bold Text have no simctl switch: they are accessibility
    # preferences of the simulated device, read by every process when it starts.
    def preference(key, enabled):
        simctl("spawn", udid, "defaults", "write", "com.apple.Accessibility", key, "-bool", "YES" if enabled else "NO")
    preference("EnhancedBackgroundContrastEnabled", appearance == "reduce-transparency")
    preference("EnhancedTextLegibilityEnabled", appearance == "bold-text")
    for notification in ("com.apple.accessibility.cache.enhance.background.contrast", "com.apple.accessibility.cache.enhance.text.legibility"):
        simctl("spawn", udid, "notifyutil", "-p", notification, check=False)


def build(scratch):
    log("building the host app and its UI tests")
    logfile = scratch / "build.log"
    with open(logfile, "w") as output:
        result = subprocess.run(
            ["xcodebuild", "build-for-testing", "-project", str(PROJECT), "-scheme", "ParityHost",
             "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(DERIVED)],
            stdout=output, stderr=subprocess.STDOUT,
        )
    if result.returncode != 0:
        sys.exit(f"the build failed, see {logfile}")


def test_run_file(scratch):
    """The .xctestrun file of a private copy of the built products.

    A run takes minutes to hours. It measures the build it started with, even if the project
    is built again meanwhile: the products are copied under `scratch` and the tests run from
    the copy, which is removed when the script exits.
    """
    products = DERIVED / "Build" / "Products"
    if not list(products.glob("*.xctestrun")):
        sys.exit("no .xctestrun file: build first (drop --skip-build)")
    frozen = scratch / f"products-{os.getpid()}"
    shutil.rmtree(frozen, ignore_errors=True)
    shutil.copytree(products, frozen, symlinks=True)
    atexit.register(shutil.rmtree, frozen, ignore_errors=True)
    return sorted(frozen.glob("*.xctestrun"), key=lambda path: path.stat().st_mtime)[-1]


def write_not_runnable(results, version, device, appearance, size, options, reason, only_missing=False):
    """Records every cell of a configuration that could not run, with the reason.

    With `only_missing`, cells that already have a result keep it: a run that was cut short
    compared some cells before it stopped.
    """
    for direction in options.directions:
        for keyboard in options.inputs:
            for script in options.scripts:
                path = results / f"ios-{version}" / slug(device) / appearance / size / direction / keyboard / f"{script}.json"
                if only_missing and path.exists():
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps({
                    "cell": {"os": version, "device": device, "appearance": appearance, "contentSize": size,
                             "direction": direction, "input": keyboard, "script": script},
                    "status": "not-runnable", "reason": reason, "checkpoints": [], "failures": [],
                    "toleratedDeviations": [], "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                }, indent=2, sort_keys=True) + "\n")


def run_device(version, device, runtime, types, options, results, scratch, xctestrun):
    label = f"iOS {version} / {device}"
    try:
        udid = simulator(version, device, runtime, types)
        boot(udid)
    except subprocess.SubprocessError as error:
        reason = f"the simulator could not be created or booted: {getattr(error, 'stderr', '') or error}".strip()
        log(f"{label}: {reason}")
        for appearance in options.appearances:
            for size in options.sizes:
                write_not_runnable(results, version, device, appearance, size, options, reason)
        return
    work = scratch / f"{version}-{slug(device)}"
    if "hardware" in options.inputs:
        # The first hardware key on a simulator raises a system alert that fails the test that
        # typed it. Get it over with before the cells that count.
        work.mkdir(parents=True, exist_ok=True)
        with open(work / "prepare-hardware-keyboard.log", "w") as output:
            subprocess.run(
                ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-destination", f"id={udid}",
                 "-only-testing:ParityHostUITests/ParityMatrixUITests/testPrepareHardwareKeyboard",
                 "-derivedDataPath", str(work / "derived"), "-collect-test-diagnostics", "never"],
                stdout=output, stderr=subprocess.STDOUT,
            )
    for appearance in options.appearances:
        for size in options.sizes:
            started = datetime.datetime.now()
            configuration = f"{label} / {appearance} / {size}"
            try:
                configure(udid, appearance, size)
            except subprocess.SubprocessError as error:
                write_not_runnable(results, version, device, appearance, size, options, f"the simulator refused the configuration: {error}")
                log(f"{configuration}: not runnable, the simulator refused the configuration")
                continue
            run_directory = work / f"{appearance}-{size}"
            shutil.rmtree(run_directory, ignore_errors=True)
            run_directory.mkdir(parents=True)
            environment = dict(os.environ)
            environment.update({
                "TEST_RUNNER_ZTRON_PARITY_RESULTS": str(results),
                "TEST_RUNNER_ZTRON_PARITY_SCRATCH": str(run_directory),
                "TEST_RUNNER_ZTRON_PARITY_OS": version,
                "TEST_RUNNER_ZTRON_PARITY_DEVICE": device,
                "TEST_RUNNER_ZTRON_PARITY_APPEARANCE": appearance,
                "TEST_RUNNER_ZTRON_PARITY_CONTENT_SIZE": size,
                "TEST_RUNNER_ZTRON_PARITY_DIRECTIONS": ",".join(options.directions),
                "TEST_RUNNER_ZTRON_PARITY_INPUTS": ",".join(options.inputs),
                "TEST_RUNNER_ZTRON_PARITY_SCRIPTS": ",".join(options.scripts),
            })
            if options.snapshots == "all":
                environment["TEST_RUNNER_ZTRON_PARITY_SNAPSHOTS"] = "all"
            if options.record_reference:
                environment["TEST_RUNNER_ZTRON_PARITY_REFERENCE_SNAPSHOTS"] = str(HOST / "ReferenceSnapshots")
            with open(run_directory / "xcodebuild.log", "w") as output:
                process = subprocess.Popen(
                    ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-destination", f"id={udid}",
                     "-only-testing:ParityHostUITests/ParityMatrixUITests/testMatrix", "-resultBundlePath", str(run_directory / "result.xcresult"),
                     "-derivedDataPath", str(work / "derived"),
                     # A failing cell is a result, not a crash: no diagnostics to gather.
                     "-collect-test-diagnostics", "never"],
                    stdout=output, stderr=subprocess.STDOUT, env=environment,
                )
                try:
                    process.wait(timeout=options.timeout * 60)
                except subprocess.TimeoutExpired:
                    # Now and then the app stops reporting itself idle and XCUITest waits a
                    # minute before every event. What was compared until then is kept.
                    process.terminate()
                    process.wait()
                result = process
            seconds = (datetime.datetime.now() - started).total_seconds()
            summary = "no cell ran"
            for line in (run_directory / "xcodebuild.log").read_text(errors="replace").splitlines():
                if "ZTRON_PARITY:" in line:
                    summary = line.split("ZTRON_PARITY:", 1)[1].strip()
            if summary == "no cell ran":
                # The bundle stopped before it reported: what it compared until then stands,
                # and the cells it did not reach are recorded as not run.
                reason = (f"the UI test bundle stopped before it reached this cell (xcodebuild exit {result.returncode}), "
                          f"see {run_directory / 'xcodebuild.log'}")
                write_not_runnable(results, version, device, appearance, size, options, reason, only_missing=True)
                summary = "the UI test bundle stopped before it finished"
            log(f"{configuration}: {summary} ({seconds:.0f} s)")
    if not options.keep_booted:
        simctl("shutdown", udid, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    def csv(default):
        return {"type": lambda text: [part.strip() for part in text.split(",") if part.strip()], "default": default}
    parser.add_argument("--os", **csv(SPEC_OS), help="iOS versions (major.minor)")
    parser.add_argument("--devices", **csv(SPEC_DEVICES))
    parser.add_argument("--appearances", **csv(SPEC_APPEARANCES), help=f"any of {','.join(ALL_APPEARANCES)}")
    parser.add_argument("--sizes", **csv(SPEC_SIZES))
    parser.add_argument("--directions", **csv(SPEC_DIRECTIONS))
    parser.add_argument("--inputs", **csv(SPEC_INPUTS))
    parser.add_argument("--scripts", **csv(SPEC_SCRIPTS))
    parser.add_argument("--results", default=str(HOST / "Results"))
    parser.add_argument("--jobs", type=int, default=1, help="simulators run side by side")
    parser.add_argument("--timeout", type=float, default=15, help="minutes one appearance and content size may take")
    parser.add_argument("--snapshots", choices=["failing", "all"], default="failing")
    parser.add_argument("--record-reference", action="store_true", help="also write the reference snapshots to ReferenceSnapshots/")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--keep-booted", action="store_true")
    options = parser.parse_args()

    for name, values, known in (("appearance", options.appearances, ALL_APPEARANCES), ("size", options.sizes, SPEC_SIZES),
                                ("direction", options.directions, SPEC_DIRECTIONS), ("input", options.inputs, SPEC_INPUTS),
                                ("script", options.scripts, SPEC_SCRIPTS)):
        unknown = [value for value in values if value not in known]
        if unknown:
            sys.exit(f"unknown {name}: {', '.join(unknown)} (known: {', '.join(known)})")

    results = pathlib.Path(options.results).resolve()
    results.mkdir(parents=True, exist_ok=True)
    scratch = HOST / ".derived" / "matrix"
    scratch.mkdir(parents=True, exist_ok=True)
    installed = runtimes()
    types = device_types()

    jobs = []
    for version in options.os:
        runtime = installed.get(version)
        reason = None
        if runtime is None:
            reason = f"no iOS {version} simulator runtime is installed on this Mac"
            # Say what is known about the nearest runtime of the same major version.
            for other, record in sorted(installed.items()):
                if other.split(".")[0] == version.split(".")[0] and not record.get("isAvailable", False):
                    reason += f"; iOS {other} is installed, but: {record.get('availabilityError', 'it is not available')}"
        elif not runtime.get("isAvailable", False):
            reason = runtime.get("availabilityError") or f"the iOS {version} simulator runtime is not available on this macOS"
        for device in options.devices:
            if reason is None and device not in types:
                reason_for_device = f"this Xcode has no simulator device type named {device}"
            else:
                reason_for_device = reason
            if reason_for_device:
                log(f"iOS {version} / {device}: not runnable here: {reason_for_device}")
                for appearance in options.appearances:
                    for size in options.sizes:
                        write_not_runnable(results, version, device, appearance, size, options, reason_for_device)
            else:
                jobs.append((version, device, runtime))

    if jobs:
        if not options.skip_build:
            build(scratch)
        xctestrun = test_run_file(scratch)
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, options.jobs)) as pool:
            futures = [pool.submit(run_device, version, device, runtime, types, options, results, scratch, xctestrun)
                       for version, device, runtime in jobs]
            for future in futures:
                future.result()

    summarize = pathlib.Path(__file__).resolve().parent / "summarize.py"
    subprocess.run([sys.executable, str(summarize), str(results)], check=False)


if __name__ == "__main__":
    main()
