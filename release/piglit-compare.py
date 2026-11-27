#!/usr/bin/env python3
"""Compare piglit results with expectation files, and fail if there are new failures.

Usage: piglit-compare.py RESULTS_DIR [--fails FILE]... [--flakes FILE]... [--skips FILE]...
                         [--list-out FILE]

RESULTS_DIR is a "piglit run" results directory (results.json, .bz2, .gz or .xz).
--fails: expected failures, deqp-runner format as in Mesa's CI ("test name,Fail", also Crash,
         Timeout; the test name is piglit's, with "@" between the groups, e.g.
         "spec@!opengl 1.0@rasterpos"). Subtests are "test@subtest".
--flakes, --skips: one regular expression per line (searched in the test name, ignoring case,
         as deqp-runner and "piglit run -x" do); results of matching tests are ignored.
Lines starting with "#" and empty lines are ignored in all these files.

A failure (fail, crash, timeout, incomplete, dmesg-fail) is new if the test is not in the
expected failures, or is there with another status (e.g. a crash where a failure is expected),
and doesn't match a flake or skip. The subtests of a test are checked only if the expected
failures list some of its subtests (Mesa's lists give the failing subtests of a test as well).
Expected failures that pass are listed, but don't fail the comparison.

Exit status: 0 without new failures, 1 with new failures, 2 on error.
"""

import argparse
import bz2
import collections
import gzip
import json
import lzma
import os
import re
import sys

BAD = {"fail", "crash", "timeout", "incomplete", "dmesg-fail"}
# deqp-runner statuses in Mesa's expectation files, as piglit statuses
STATUS = {"fail": "fail", "crash": "crash", "timeout": "timeout",
          "expectedfail": "fail", "dmesg-fail": "dmesg-fail"}


class Error(Exception):
    pass


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                yield line


def read_results(results_dir):
    for name in ("results.json", "results.json.bz2", "results.json.gz", "results.json.xz"):
        path = os.path.join(results_dir, name)
        if os.path.exists(path):
            opener = {"bz2": bz2.open, "gz": gzip.open, "xz": lzma.open}.get(
                name.rsplit(".", 1)[-1], open)
            with opener(path, "rt", encoding="utf-8") as f:
                return json.load(f)
    raise Error("no results.json[.bz2|.gz|.xz] in %s" % results_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("results")
    parser.add_argument("--fails", action="append", default=[])
    parser.add_argument("--flakes", action="append", default=[])
    parser.add_argument("--skips", action="append", default=[])
    parser.add_argument("--list-out", help="write every test and its status to this file")
    args = parser.parse_args()

    expected = {}
    for path in args.fails:
        for line in read_lines(path):
            name, _, status = line.rpartition(",")
            if not name:
                raise Error("%s: bad line %r" % (path, line))
            expected[name.lower()] = STATUS.get(status.strip().lower(), status.strip().lower())
    ignore = [re.compile(r, re.IGNORECASE)
              for path in args.flakes + args.skips for r in read_lines(path)]
    # tests whose subtests are listed
    with_subtests = set()
    for name in expected:
        parent = name.rpartition("@")[0]
        while parent:
            with_subtests.add(parent)
            parent = parent.rpartition("@")[0]

    results = read_results(args.results)
    tests = results.get("tests", {})
    counts = collections.Counter()
    new, fixed, ignored, as_expected = [], [], [], []
    listing = []

    def check(name, status):
        if status in BAD:
            if any(r.search(name) for r in ignore):
                ignored.append((name, status))
            elif expected.get(name) != status:
                new.append((name, status, expected.get(name)))
            else:
                as_expected.append(name)
        elif name in expected and status in ("pass", "warn"):
            fixed.append((name, status, expected[name]))

    for name, test in sorted(tests.items()):
        name = name.lower()
        status = test.get("result", "notrun")
        counts[status] += 1
        listing.append("%s,%s" % (name, status))
        check(name, status)
        if name in with_subtests:
            for sub, substatus in sorted(test.get("subtests", {}).items()):
                check("%s@%s" % (name, sub.lower()), substatus)

    if args.list_out:
        with open(args.list_out, "w", encoding="utf-8") as f:
            f.write("\n".join(listing) + "\n")

    total = sum(counts.values())
    print("%d tests: %s" % (total, ", ".join(
        "%d %s" % (n, s) for s, n in sorted(counts.items(), key=lambda kv: -kv[1]))))
    if results.get("time_elapsed"):
        t = results["time_elapsed"]
        print("time: %.0f s" % (t.get("end", 0) - t.get("start", 0)))
    print("expected failures: %d listed, %d failed as expected"
          % (len(expected), len(as_expected)))
    if ignored:
        print("%d failures ignored (flakes/skips):" % len(ignored))
        for name, status in ignored:
            print("  %s,%s" % (name, status))
    if fixed:
        print("%d expected failures passed (not an error):" % len(fixed))
        for name, status, exp in fixed:
            print("  %s: %s, expected %s" % (name, status, exp))
    if new:
        print("%d NEW failures:" % len(new))
        for name, status, exp in new:
            print("  %s,%s%s" % (name, status.capitalize(),
                                 "" if exp is None else " (expected %s)" % exp))
        return 1
    print("no new failures")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Error, OSError, ValueError) as e:
        print("Error: %s" % e, file=sys.stderr)
        sys.exit(2)
