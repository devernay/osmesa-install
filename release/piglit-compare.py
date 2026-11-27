#!/usr/bin/env python3
"""Compare piglit results with expectation files; fail on regressions.

Usage: piglit-compare.py RESULTS_DIR [--fails FILE]... [--ours FILE]...
                         [--flakes FILE]... [--skips FILE]... [--min-pass N]
                         [--list-out FILE]

RESULTS_DIR is a "piglit run" results directory (results.json or
results.json.bz2).

--fails: expected failures, deqp-runner format as in Mesa's CI
    ("test name,Fail", also Crash, Timeout). The test name is piglit's, with
    "@" between the groups, e.g. "spec@!opengl 1.0@rasterpos". Subtests are
    "test@subtest".
--ours: like --fails, for our own expectations (osmesa-fails*.txt): one of
    them that passes is an error too, so that these lists don't go stale and
    hide a later regression of the same test. (Mesa's lists, given with
    --fails, can't be edited here: their unexpected passes are only listed.)
    The status may give alternatives, e.g. "Crash|Fail", for a test whose
    failure varies from run to run.
--flakes, --skips: one regular expression per line, searched in the test
    name, ignoring case, as deqp-runner and "piglit run -x" do. Results of
    matching tests are ignored.
--min-pass: fail if fewer tests pass, e.g. if a regression makes tests skip
    (piglit reports a test that can't get its context as skipped).
Lines starting with "#" and empty lines are ignored in all these files.

A failure (fail, crash, timeout, incomplete, dmesg-fail) is new if the test
is not in the expected failures, or is there with another status (e.g. a
crash where a failure is expected), and doesn't match a flake or skip. The
subtests of a test are checked only if the expected failures list some of its
subtests, as Mesa's lists do for the failing subtests: a test listed without
subtests is only checked as a whole.

Exit status: 0 without regressions, 1 with regressions, 2 on error.
"""

import argparse
import bz2
import collections
import json
import os
import re
import sys

BAD = {"fail", "crash", "timeout", "incomplete", "dmesg-fail"}
# deqp-runner statuses in Mesa's expectation files, as piglit statuses
STATUS = {"fail": "fail", "crash": "crash", "timeout": "timeout",
          "expectedfail": "fail", "dmesg-fail": "dmesg-fail"}


class Error(Exception):
    """A bad input file."""


def read_lines(path):
    """Yields the lines of PATH, without comments and empty lines."""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                yield line


def read_expected(paths):
    """Returns {lowercase test name: expected statuses} from expectation files.

    The status may give alternatives, e.g. "Crash|Fail", for a test whose
    failure varies from run to run (only in our own files).
    """
    expected = {}
    for path in paths:
        for line in read_lines(path):
            name, _, status = line.rpartition(",")
            if not name:
                raise Error("%s: bad line %r" % (path, line))
            expected[name.lower()] = "|".join(
                STATUS.get(s, s) for s in status.strip().lower().split("|"))
    return expected


def read_results(results_dir):
    """Returns the parsed results.json[.bz2] of a piglit results directory."""
    for name, opener in (("results.json", open),
                         ("results.json.bz2", bz2.open)):
        path = os.path.join(results_dir, name)
        if os.path.exists(path):
            with opener(path, "rt", encoding="utf-8") as f:
                return json.load(f)
    raise Error("no results.json[.bz2] in %s" % results_dir)


class Comparison:
    """The results of every test, sorted against the expectations."""

    def __init__(self, expected, ours, ignore):
        self.expected = dict(expected, **ours)
        self.ours = set(ours)
        self.ignore = ignore
        self.counts = collections.Counter()
        self.new, self.fixed, self.ignored, self.as_expected = [], [], [], []
        self.listing = []
        # tests whose subtests are listed
        self.with_subtests = set()
        for name in self.expected:
            parent = name.rpartition("@")[0]
            while parent:
                self.with_subtests.add(parent)
                parent = parent.rpartition("@")[0]

    def check(self, name, status):
        """Sorts the result of one test or subtest."""
        exp = self.expected.get(name)
        if status in BAD:
            if any(r.search(name) for r in self.ignore):
                self.ignored.append((name, status))
            elif exp is None or status not in exp.split("|"):
                if exp is not None and name in self.ours:
                    # e.g. a crash that became Mesa's expected failure: our entry is stale
                    self.fixed.append((name, status, exp))
                self.new.append((name, status, exp))
            else:
                self.as_expected.append(name)
        elif exp is not None and status in ("pass", "warn"):
            self.fixed.append((name, status, exp))

    def add(self, name, test):
        """Sorts the result of a test of results.json, and its subtests."""
        name = name.lower()
        status = test.get("result", "notrun")
        self.counts[status] += 1
        self.listing.append("%s,%s" % (name, status))
        self.check(name, status)
        if name in self.with_subtests:
            for sub, substatus in sorted(test.get("subtests", {}).items()):
                if sub != "__type__":
                    self.check("%s@%s" % (name, sub.lower()), substatus)


def report(comp, results, min_pass):
    """Prints the comparison, and returns the exit status."""
    total = sum(comp.counts.values())
    print("%d tests: %s" % (total, ", ".join(
        "%d %s" % (n, s) for s, n in comp.counts.most_common())))
    if results.get("time_elapsed"):
        t = results["time_elapsed"]
        print("time: %.0f s" % (t.get("end", 0) - t.get("start", 0)))
    print("expected failures: %d listed, %d failed as expected"
          % (len(comp.expected), len(comp.as_expected)))
    if comp.ignored:
        print("%d failures ignored (flakes/skips):" % len(comp.ignored))
        for name, status in comp.ignored:
            print("  %s,%s" % (name, status))
    stale = [f for f in comp.fixed if f[0] in comp.ours]
    if len(comp.fixed) > len(stale):
        print("%d of Mesa's expected failures passed (not an error):"
              % (len(comp.fixed) - len(stale)))
        for name, status, exp in comp.fixed:
            if name not in comp.ours:
                print("  %s: %s, expected %s" % (name, status, exp))
    status = 0
    if stale:
        print("%d of OUR expected failures passed: remove them from"
              " osmesa-fails*.txt:" % len(stale))
        for name, result, exp in stale:
            print("  %s: %s, expected %s" % (name, result, exp))
        status = 1
    passed = comp.counts["pass"]
    if min_pass is not None and passed < min_pass:
        print("only %d tests passed, at least %d expected (tests that"
              " skip instead of passing?)" % (passed, min_pass))
        status = 1
    if comp.new:
        print("%d NEW failures:" % len(comp.new))
        for name, result, exp in comp.new:
            print("  %s,%s%s" % (name, result.capitalize(),
                                 "" if exp is None
                                 else " (expected %s)" % exp))
        status = 1
    if status == 0:
        print("no new failures")
    return status


def main():
    """Parses the arguments, compares, and returns the exit status."""
    parser = argparse.ArgumentParser(
        description=(__doc__ or "").split("\n", 1)[0])
    parser.add_argument("results")
    parser.add_argument("--fails", action="append", default=[])
    parser.add_argument("--ours", action="append", default=[])
    parser.add_argument("--flakes", action="append", default=[])
    parser.add_argument("--skips", action="append", default=[])
    parser.add_argument("--min-pass", type=int)
    parser.add_argument("--list-out",
                        help="write every test and its status to this file")
    args = parser.parse_args()

    try:
        ignore = [re.compile(r, re.IGNORECASE)
                  for path in args.flakes + args.skips
                  for r in read_lines(path)]
    except re.error as e:
        raise Error("bad regular expression: %s" % e) from e
    comp = Comparison(read_expected(args.fails), read_expected(args.ours),
                      ignore)
    results = read_results(args.results)
    for name, test in sorted(results.get("tests", {}).items()):
        comp.add(name, test)
    if args.list_out:
        with open(args.list_out, "w", encoding="utf-8") as f:
            f.write("\n".join(comp.listing) + "\n")
    return report(comp, results, args.min_pass)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Error, OSError, ValueError, EOFError) as e:
        print("Error: %s" % e, file=sys.stderr)
        sys.exit(2)
