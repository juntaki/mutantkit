#!/usr/bin/env python3
"""Convert an lcov.info file into SonarCloud's Generic Test Coverage XML
format (https://docs.sonarsource.com/sonarqube-server/latest/analyzing-source-code/test-coverage/generic-test-data/).

Why this exists: SwiftPM's `llvm-cov export -format=lcov` output already
feeds Codecov directly (see ci.yml's `coverage` aggregation job), but
SonarCloud's own Swift analyzer has no first-party lcov importer (see
sonar-project.properties's own long-standing TODO). This produces the one
format Sonar *does* import natively, from the exact same lcov Codecov
already gets -- one coverage measurement, two consumers, not a second
`swift test` run.

Path handling: llvm-cov's `SF:` lines are absolute (e.g.
`/Users/runner/work/mutantkit/mutantkit/Sources/Foo/Bar.swift`). Sonar's
generic format wants a path relative to the project base directory
matching `sonar.sources`/`sonar.tests` (`Sources/Foo/Bar.swift`). A file
is kept only when stripping the given repo-root prefix leaves a path that
itself starts with `Sources/` or `Tests/` -- anchored to the root, not a
bare substring search, because a third-party dependency checked out under
`.build/checkouts/<dep>/Sources/<dep>/...` (e.g. Yams) has its own
`/Sources/` component that a substring match would wrongly mistake for
this project's own `Sources/` root. Everything else -- every dependency
checkout and every SwiftPM-generated file under `.build/` -- is skipped:
none of it is named by `sonar.sources`/`sonar.tests`, so a report entry
for it would be noise Sonar can't place, not a real gap.
"""
from __future__ import annotations

import sys
from pathlib import Path
from xml.sax.saxutils import quoteattr


def relative_sonar_path(absolute_path: str, repo_root: str) -> str | None:
    prefix = repo_root.rstrip("/") + "/"
    if not absolute_path.startswith(prefix):
        return None
    relative = absolute_path[len(prefix) :]
    if relative.startswith("Sources/") or relative.startswith("Tests/"):
        return relative
    return None


def convert(lcov_text: str, repo_root: str) -> str:
    lines = ['<coverage version="1">']
    current_path: str | None = None
    current_hits: dict[int, int] = {}

    def flush() -> None:
        if current_path is None or not current_hits:
            return
        lines.append(f"  <file path={quoteattr(current_path)}>")
        for line_number in sorted(current_hits):
            covered = "true" if current_hits[line_number] > 0 else "false"
            lines.append(f'    <lineToCover lineNumber="{line_number}" covered="{covered}"/>')
        lines.append("  </file>")

    for raw_line in lcov_text.splitlines():
        if raw_line.startswith("SF:"):
            current_path = relative_sonar_path(raw_line[3:], repo_root)
            current_hits = {}
        elif raw_line.startswith("DA:") and current_path is not None:
            parts = raw_line[3:].split(",")
            line_number, hit_count = int(parts[0]), int(parts[1])
            # A line hit by more than one test run (e.g. covered by both a
            # unit and an acceptance profile before merging) already comes
            # pre-summed by `llvm-profdata merge`, so the last DA: for a
            # given line in one SF: block always wins here -- there is
            # never a second, independently-relevant hit count to combine.
            current_hits[line_number] = hit_count
        elif raw_line == "end_of_record":
            flush()
            current_path = None
            current_hits = {}

    lines.append("</coverage>")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(f"usage: {argv[0]} <input lcov.info> <output sonar-coverage.xml> <repo root>", file=sys.stderr)
        return 2
    lcov_path, output_path, repo_root = Path(argv[1]), Path(argv[2]), argv[3]
    output_path.write_text(convert(lcov_path.read_text(encoding="utf-8"), repo_root), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
