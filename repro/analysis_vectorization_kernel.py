from __future__ import annotations

import json
import math
import statistics
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, timedelta

import numpy as np

EVENTS = 100_000
OBSERVATIONS = 150_000
EXCLUDED_OBSERVATIONS = 25_000
DAY_COUNT = 3_653
ROUNDS = 24
WARMUPS = 2
BASE_DATE = date(2016, 1, 1)


@dataclass(frozen=True, slots=True)
class Event:
    event_id: int
    grouping_date: date


@dataclass(frozen=True, slots=True)
class Observation:
    observation_id: int
    event_id: int
    excluded: bool


def build_fixture() -> tuple[tuple[Event, ...], tuple[Observation, ...]]:
    events = tuple(
        Event(
            event_id=index,
            grouping_date=BASE_DATE + timedelta(days=(DAY_COUNT * index) // EVENTS),
        )
        for index in range(EVENTS)
    )
    observations = tuple(
        Observation(
            observation_id=index,
            event_id=index % EVENTS,
            excluded=index < EXCLUDED_OBSERVATIONS,
        )
        for index in range(OBSERVATIONS)
    )
    return events, observations


def reference_like(
    events: tuple[Event, ...], observations: tuple[Observation, ...]
) -> dict[str, int]:
    grouped: dict[int, list[Observation]] = defaultdict(list)
    for row in observations:
        grouped[row.event_id].append(row)
    _unused_observations_by_event = {
        key: tuple(sorted(rows, key=lambda row: str(row.observation_id)))
        for key, rows in grouped.items()
    }

    event_rows = {row.event_id: row for row in events}
    values: dict[str, int] = defaultdict(int)
    for row in observations:
        if row.excluded:
            continue
        event = event_rows[row.event_id]
        values[event.grouping_date.isoformat()] += 1
    return dict(values)


def optimized_python(
    events: tuple[Event, ...], observations: tuple[Observation, ...]
) -> dict[str, int]:
    event_rows = {row.event_id: row for row in events}
    values: dict[str, int] = defaultdict(int)
    for row in observations:
        if row.excluded:
            continue
        event = event_rows[row.event_id]
        values[event.grouping_date.isoformat()] += 1
    return dict(values)


def vectorized_numpy(
    events: tuple[Event, ...], observations: tuple[Observation, ...]
) -> dict[str, int]:
    date_values = sorted({row.grouping_date for row in events})
    date_to_code = {value: index for index, value in enumerate(date_values)}
    labels = tuple(value.isoformat() for value in date_values)
    event_codes = {
        row.event_id: date_to_code[row.grouping_date]
        for row in events
    }
    codes = np.fromiter(
        (
            event_codes[row.event_id] if not row.excluded else -1
            for row in observations
        ),
        dtype=np.int32,
        count=len(observations),
    )
    eligible = codes[codes >= 0]
    counts = np.bincount(eligible, minlength=len(labels))
    return {
        labels[index]: int(count)
        for index, count in enumerate(counts)
        if count > 0
    }


def p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]


def summary(values: list[float]) -> dict[str, float | int]:
    return {
        "runs": len(values),
        "minimum_seconds": min(values),
        "median_seconds": statistics.median(values),
        "mean_seconds": statistics.fmean(values),
        "p95_seconds": p95(values),
        "stdev_seconds": statistics.stdev(values),
    }


def timed(function, events, observations) -> tuple[float, dict[str, int]]:
    start = time.perf_counter()
    result = function(events, observations)
    return time.perf_counter() - start, result


def comparison(reference: dict[str, float | int], candidate: dict[str, float | int]) -> dict[str, float]:
    reference_median = float(reference["median_seconds"])
    candidate_median = float(candidate["median_seconds"])
    gain = reference_median - candidate_median
    return {
        "median_absolute_gain_seconds": gain,
        "median_reduction_fraction": gain / reference_median,
        "speedup_factor": reference_median / candidate_median,
    }


def main() -> int:
    events, observations = build_fixture()
    functions = {
        "reference_like": reference_like,
        "optimized_python": optimized_python,
        "numpy": vectorized_numpy,
    }
    orders = (
        ("reference_like", "optimized_python", "numpy"),
        ("optimized_python", "numpy", "reference_like"),
        ("numpy", "reference_like", "optimized_python"),
        ("reference_like", "numpy", "optimized_python"),
        ("numpy", "optimized_python", "reference_like"),
        ("optimized_python", "reference_like", "numpy"),
    )

    for index in range(WARMUPS):
        for name in orders[index % len(orders)]:
            functions[name](events, observations)

    timings = {name: [] for name in functions}
    last_results: dict[str, dict[str, int]] = {}
    execution_order: list[list[str]] = []
    for index in range(ROUNDS):
        order = orders[index % len(orders)]
        execution_order.append(list(order))
        for name in order:
            elapsed, result = timed(functions[name], events, observations)
            timings[name].append(elapsed)
            last_results[name] = result

    equal = (
        last_results["reference_like"]
        == last_results["optimized_python"]
        == last_results["numpy"]
    )
    summaries = {name: summary(values) for name, values in timings.items()}
    output = {
        "schema_version": 1,
        "scope": "SANITIZED_VECTOR_AGGREGATION_KERNEL_ONLY",
        "fixture": {
            "events": EVENTS,
            "observations": OBSERVATIONS,
            "excluded_observations": EXCLUDED_OBSERVATIONS,
            "days": DAY_COUNT,
        },
        "numpy_version": np.__version__,
        "rounds": ROUNDS,
        "warmups": WARMUPS,
        "execution_order": execution_order,
        "outputs_equal": equal,
        "summaries": summaries,
        "comparisons": {
            "optimized_python_vs_reference_like": comparison(
                summaries["reference_like"], summaries["optimized_python"]
            ),
            "numpy_vs_reference_like": comparison(
                summaries["reference_like"], summaries["numpy"]
            ),
            "numpy_vs_optimized_python": comparison(
                summaries["optimized_python"], summaries["numpy"]
            ),
        },
        "claim_boundary": (
            "Synthetic kernel diagnostic only. This is not private application, "
            "canonical-contract, packaging, or acceptance evidence."
        ),
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0 if equal else 2


if __name__ == "__main__":
    raise SystemExit(main())
