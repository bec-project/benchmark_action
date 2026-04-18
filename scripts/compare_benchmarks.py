#!/usr/bin/env python3
"""Compare benchmark JSON files and write a GitHub Actions summary."""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Benchmark:
    """Normalized benchmark result."""

    name: str
    value: float
    unit: str
    metric: str = "value"


@dataclass(frozen=True)
class Comparison:
    """Comparison between one baseline benchmark and one current benchmark."""

    name: str
    baseline: float
    current: float
    delta_percent: float
    unit: str
    metric: str
    regressed: bool


def _read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def _as_float(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    if math.isfinite(result):
        return result
    return None


def _extract_hyperfine(data: dict[str, Any]) -> dict[str, Benchmark]:
    benchmarks: dict[str, Benchmark] = {}
    for result in data.get("results", []):
        if not isinstance(result, dict):
            continue
        name = str(result.get("command") or result.get("name") or "").strip()
        metric = "median"
        value = _as_float(result.get(metric))
        if value is None:
            metric = "mean"
            value = _as_float(result.get(metric))
        if name and value is not None:
            benchmarks[name] = Benchmark(name=name, value=value, unit="s", metric=metric)
    return benchmarks


def _extract_pytest_benchmark(data: dict[str, Any]) -> dict[str, Benchmark]:
    benchmarks: dict[str, Benchmark] = {}
    for benchmark in data.get("benchmarks", []):
        if not isinstance(benchmark, dict):
            continue

        name = str(benchmark.get("fullname") or benchmark.get("name") or "").strip()
        stats = benchmark.get("stats", {})
        value = None
        metric = "median"
        if isinstance(stats, dict):
            value = _as_float(stats.get(metric))
            if value is None:
                metric = "mean"
                value = _as_float(stats.get(metric))
        if name and value is not None:
            benchmarks[name] = Benchmark(name=name, value=value, unit="s", metric=metric)
    return benchmarks


def _extract_simple_mapping(data: dict[str, Any]) -> dict[str, Benchmark]:
    benchmarks: dict[str, Benchmark] = {}

    for name, raw_value in data.items():
        if name in {"version", "context", "commit", "timestamp"}:
            continue

        value = _as_float(raw_value)
        unit = ""
        metric = "value"
        if value is None and isinstance(raw_value, dict):
            value = _as_float(raw_value.get("value"))
            unit = str(raw_value.get("unit") or "")
            metric = str(raw_value.get("metric") or "value")

        if value is not None:
            benchmarks[str(name)] = Benchmark(name=str(name), value=value, unit=unit, metric=metric)

    return benchmarks


def extract_benchmarks(path: Path) -> dict[str, Benchmark]:
    data = _read_json(path)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")

    extractors = (_extract_hyperfine, _extract_pytest_benchmark, _extract_simple_mapping)
    for extractor in extractors:
        benchmarks = extractor(data)
        if benchmarks:
            return benchmarks

    raise ValueError(f"No supported benchmark entries found in {path}")


def compare_benchmarks(
    baseline: dict[str, Benchmark],
    current: dict[str, Benchmark],
    threshold_percent: float,
    higher_is_better: bool,
) -> tuple[list[Comparison], list[str], list[str]]:
    comparisons: list[Comparison] = []
    missing_in_current: list[str] = []
    new_in_current: list[str] = []

    for name, baseline_benchmark in sorted(baseline.items()):
        current_benchmark = current.get(name)
        if current_benchmark is None:
            missing_in_current.append(name)
            continue

        if baseline_benchmark.value == 0:
            delta_percent = 0.0
        else:
            delta_percent = (
                (current_benchmark.value - baseline_benchmark.value)
                / abs(baseline_benchmark.value)
                * 100
            )

        if higher_is_better:
            regressed = delta_percent <= -threshold_percent
        else:
            regressed = delta_percent >= threshold_percent

        comparisons.append(
            Comparison(
                name=name,
                baseline=baseline_benchmark.value,
                current=current_benchmark.value,
                delta_percent=delta_percent,
                unit=current_benchmark.unit or baseline_benchmark.unit,
                metric=current_benchmark.metric,
                regressed=regressed,
            )
        )

    for name in sorted(set(current) - set(baseline)):
        new_in_current.append(name)

    return comparisons, missing_in_current, new_in_current


def _format_value(value: float, unit: str) -> str:
    suffix = f" {unit}" if unit else ""
    return f"{value:.6g}{suffix}"


def write_summary(
    path: Path,
    comparisons: list[Comparison],
    missing_in_current: list[str],
    new_in_current: list[str],
    threshold_percent: float,
    higher_is_better: bool,
    comment_marker: str,
) -> None:
    regressions = [comparison for comparison in comparisons if comparison.regressed]
    direction = "higher is better" if higher_is_better else "lower is better"
    sorted_comparisons = sorted(comparisons, key=lambda comparison: comparison.name)

    lines = [
        comment_marker,
        "## Benchmark comparison",
        "",
        f"Threshold: {threshold_percent:g}% ({direction}).",
        "",
    ]

    if regressions:
        lines.extend(
            [
                f"{len(regressions)} benchmark(s) regressed beyond the configured threshold.",
                "",
                "| Benchmark | Baseline | Current | Change |",
                "| --- | ---: | ---: | ---: |",
            ]
        )
        for comparison in regressions:
            lines.append(
                "| "
                f"{comparison.name} | "
                f"{_format_value(comparison.baseline, comparison.unit)} | "
                f"{_format_value(comparison.current, comparison.unit)} | "
                f"{comparison.delta_percent:+.2f}% |"
            )
    else:
        lines.append("No benchmark regression exceeded the configured threshold.")

    if sorted_comparisons:
        lines.extend(
            [
                "",
                "<details>",
                "<summary>All benchmark results</summary>",
                "",
                "| Benchmark | Baseline | Current | Change | Status |",
                "| --- | ---: | ---: | ---: | --- |",
            ]
        )
        for comparison in sorted_comparisons:
            status = "regressed" if comparison.regressed else "ok"
            lines.append(
                "| "
                f"{comparison.name} | "
                f"{_format_value(comparison.baseline, comparison.unit)} | "
                f"{_format_value(comparison.current, comparison.unit)} | "
                f"{comparison.delta_percent:+.2f}% | "
                f"{status} |"
            )
        lines.extend(["", "</details>"])

    if missing_in_current:
        lines.extend(["", "Missing benchmarks in the current run:"])
        lines.extend(f"- `{name}`" for name in missing_in_current)

    if new_in_current:
        lines.extend(["", "New benchmarks in the current run:"])
        lines.extend(f"- `{name}`" for name in new_in_current)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--current", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--threshold-percent", required=True, type=float)
    parser.add_argument("--higher-is-better", action="store_true")
    parser.add_argument("--comment-marker", default="<!-- bw-benchmark-comment -->")
    args = parser.parse_args()

    baseline = extract_benchmarks(args.baseline)
    current = extract_benchmarks(args.current)
    comparisons, missing_in_current, new_in_current = compare_benchmarks(
        baseline=baseline,
        current=current,
        threshold_percent=args.threshold_percent,
        higher_is_better=args.higher_is_better,
    )

    write_summary(
        path=args.summary,
        comparisons=comparisons,
        missing_in_current=missing_in_current,
        new_in_current=new_in_current,
        threshold_percent=args.threshold_percent,
        higher_is_better=args.higher_is_better,
        comment_marker=args.comment_marker,
    )

    return 1 if any(comparison.regressed for comparison in comparisons) else 0


if __name__ == "__main__":
    raise SystemExit(main())
