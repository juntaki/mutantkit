#!/usr/bin/env python3
"""Compare ordinary, incremental-batch, and wave MutantKit reports.

Classification and integrity are gates. Metadata such as result origin,
confirmation evidence, and test-attempt traces is reported when present; pass
--strict-metadata to make those differences fail too.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


@dataclass(frozen=True)
class ResultView:
    mutation_id: str
    outcome: str
    origin: str | None
    attempts: Any
    confirmation: Any


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Could not read {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{path} does not contain a JSON object")
    return value


def mutation_id(result: dict[str, Any]) -> str:
    point = result.get("point")
    if isinstance(point, dict) and isinstance(point.get("id"), str):
        return point["id"]
    if isinstance(result.get("id"), str):
        return result["id"]
    raise ValueError("result has no mutation ID")


def confirmation_signature(result: dict[str, Any]) -> dict[str, bool]:
    evidence = result.get("evidence")
    if not isinstance(evidence, dict):
        evidence = {}
    return {
        "crash": evidence.get("crashConfirmation") is not None,
        "timeout": evidence.get("timeoutConfirmation") is not None,
        "durationRecorded": result.get("confirmationDurationSeconds") is not None,
    }


def attempts_signature(result: dict[str, Any]) -> Any:
    if "testAttempts" in result:
        return result["testAttempts"]
    evidence = result.get("evidence")
    if isinstance(evidence, dict) and "testAttempts" in evidence:
        return evidence["testAttempts"]
    return None


def index_results(report: dict[str, Any], label: str) -> dict[str, ResultView]:
    raw_results = report.get("results")
    if not isinstance(raw_results, list):
        raise SystemExit(f"{label}: report.results is missing or is not an array")

    indexed: dict[str, ResultView] = {}
    for raw in raw_results:
        if not isinstance(raw, dict):
            raise SystemExit(f"{label}: report contains a non-object result")
        try:
            identifier = mutation_id(raw)
        except ValueError as error:
            raise SystemExit(f"{label}: {error}") from error
        if identifier in indexed:
            raise SystemExit(f"{label}: duplicate result for {identifier}")
        outcome = raw.get("outcome")
        if not isinstance(outcome, str):
            raise SystemExit(f"{label}: {identifier} has no string outcome")
        origin = raw.get("origin") if isinstance(raw.get("origin"), str) else None
        indexed[identifier] = ResultView(
            mutation_id=identifier,
            outcome=outcome,
            origin=origin,
            attempts=attempts_signature(raw),
            confirmation=confirmation_signature(raw),
        )
    return indexed


def integrity_violations(report: dict[str, Any]) -> list[str]:
    integrity = report.get("integrity")
    if not isinstance(integrity, dict):
        return ["integrity object missing"]
    violations = integrity.get("violations")
    if not isinstance(violations, list):
        return ["integrity.violations missing"]
    rendered: list[str] = []
    for violation in violations:
        if isinstance(violation, dict):
            kind = violation.get("kind", "unknown")
            detail = violation.get("detail", "")
            rendered.append(f"{kind}: {detail}")
        else:
            rendered.append(str(violation))
    return rendered


def batch_summary(report: dict[str, Any]) -> dict[str, Any] | None:
    value = report.get("batchExecution")
    return value if isinstance(value, dict) else None


def load_allowlist(paths: Iterable[Path], inline: Iterable[str]) -> set[str]:
    allowed = set(inline)
    for path in paths:
        value = load_json(path)
        entries = value.get("mutationIDs", value)
        if isinstance(entries, list) and all(isinstance(item, str) for item in entries):
            allowed.update(entries)
        else:
            raise SystemExit(
                f"{path}: allow-list must be a JSON string array or an object with mutationIDs"
            )
    return allowed


def compare(
    reference: dict[str, ResultView],
    candidate: dict[str, ResultView],
    candidate_label: str,
    allowed: set[str],
) -> tuple[list[str], list[str]]:
    classification_errors: list[str] = []
    metadata_differences: list[str] = []
    all_ids = sorted(set(reference) | set(candidate))

    for identifier in all_ids:
        left = reference.get(identifier)
        right = candidate.get(identifier)
        if left is None:
            message = f"{identifier}: extra in {candidate_label} ({right.outcome})"
            if identifier not in allowed:
                classification_errors.append(message)
            continue
        if right is None:
            message = f"{identifier}: missing from {candidate_label} (reference {left.outcome})"
            if identifier not in allowed:
                classification_errors.append(message)
            continue
        if left.outcome != right.outcome and identifier not in allowed:
            classification_errors.append(
                f"{identifier}: {left.outcome} -> {right.outcome} in {candidate_label}"
            )
        if left.origin != right.origin:
            metadata_differences.append(
                f"{identifier}: origin {left.origin!r} -> {right.origin!r} in {candidate_label}"
            )
        if left.confirmation != right.confirmation:
            metadata_differences.append(
                f"{identifier}: confirmation {left.confirmation} -> {right.confirmation} in {candidate_label}"
            )
        if left.attempts != right.attempts:
            metadata_differences.append(
                f"{identifier}: test-attempt trace differs in {candidate_label}"
            )

    return classification_errors, metadata_differences


def print_report_summary(label: str, report: dict[str, Any], indexed: dict[str, ResultView]) -> None:
    counts: dict[str, int] = {}
    for result in indexed.values():
        counts[result.outcome] = counts.get(result.outcome, 0) + 1
    print(f"\n[{label}]")
    print(f"results: {len(indexed)}")
    print("outcomes: " + ", ".join(f"{key}={counts[key]}" for key in sorted(counts)))
    batch = batch_summary(report)
    if batch is None:
        print("batchExecution: none")
    else:
        fields = [
            f"batchCount={batch.get('batchCount')}",
            f"totalConfigurations={batch.get('totalConfigurations')}",
            f"averageConfigurationsPerBatch={batch.get('averageConfigurationsPerBatch')}",
            f"batchDurations={len(batch.get('batchDurations', [])) if isinstance(batch.get('batchDurations'), list) else 'n/a'}",
        ]
        print("batchExecution: " + ", ".join(fields))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ordinary", type=Path, help="ordinary batching report")
    parser.add_argument("incremental", type=Path, help="incremental batching report")
    parser.add_argument("wave", type=Path, help="wave early-kill report")
    parser.add_argument(
        "--allow-difference",
        action="append",
        default=[],
        metavar="MUTATION_ID",
        help="explicitly allow a classification difference for one MutationID",
    )
    parser.add_argument(
        "--allow-file",
        action="append",
        default=[],
        type=Path,
        help="JSON array (or {mutationIDs:[...]}) of allowed MutationIDs",
    )
    parser.add_argument(
        "--strict-metadata",
        action="store_true",
        help="also fail on origin, confirmation, or test-attempt differences",
    )
    args = parser.parse_args()

    reports = {
        "ordinary": load_json(args.ordinary),
        "incremental": load_json(args.incremental),
        "wave": load_json(args.wave),
    }
    indexed = {label: index_results(report, label) for label, report in reports.items()}
    allowed = load_allowlist(args.allow_file, args.allow_difference)

    failed = False
    for label in ("ordinary", "incremental", "wave"):
        print_report_summary(label, reports[label], indexed[label])
        violations = integrity_violations(reports[label])
        if violations:
            failed = True
            print("integrity violations:")
            for violation in violations:
                print(f"  - {violation}")

    for candidate_label in ("incremental", "wave"):
        errors, metadata = compare(
            indexed["ordinary"], indexed[candidate_label], candidate_label, allowed
        )
        print(f"\n[ordinary vs {candidate_label}]")
        if errors:
            failed = True
            print("classification mismatches:")
            for error in errors:
                print(f"  - {error}")
        else:
            print("classification: identical")
        if metadata:
            print("metadata differences:")
            for difference in metadata:
                print(f"  - {difference}")
            if args.strict_metadata:
                failed = True
        else:
            print("metadata: identical (for fields present in both reports)")

    if allowed:
        print("\nallowed MutationIDs: " + ", ".join(sorted(allowed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
