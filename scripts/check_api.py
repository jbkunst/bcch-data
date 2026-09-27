#!/usr/bin/env python3
"""Validate a local or published bcch-data static API using only Python stdlib."""

from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import date
from pathlib import Path
from typing import Any
from urllib.parse import urljoin
from urllib.request import Request, urlopen


class ApiError(RuntimeError):
    pass


class ApiSource:
    def __init__(self, root: str) -> None:
        self.remote = root.startswith(("http://", "https://"))
        self.root = root.rstrip("/") + "/" if self.remote else str(Path(root))

    def read_json(self, relative_path: str) -> Any:
        try:
            if self.remote:
                url = urljoin(self.root, relative_path)
                request = Request(url, headers={"User-Agent": "bcch-data-validator/1"})
                with urlopen(request, timeout=30) as response:
                    return json.load(response)
            path = Path(self.root, relative_path)
            with path.open(encoding="utf-8") as stream:
                return json.load(stream)
        except (OSError, ValueError) as error:
            raise ApiError(f"Cannot read {relative_path}: {error}") from error


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ApiError(message)


def valid_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def validate_series(series_id: str, entry: dict[str, Any], payload: Any) -> None:
    require(isinstance(payload, dict), f"{series_id}: payload must be an object")
    require(payload.get("series_id") == series_id, f"{series_id}: wrong series_id")
    require(payload.get("name") == entry.get("name"), f"{series_id}: name mismatch")
    require(
        payload.get("frequency") == entry.get("frequency"),
        f"{series_id}: frequency mismatch",
    )
    require(payload.get("source") == "Banco Central de Chile", f"{series_id}: bad source")

    observations = payload.get("observations")
    require(isinstance(observations, list) and observations, f"{series_id}: no observations")

    dates: list[str] = []
    for index, observation in enumerate(observations):
        require(isinstance(observation, dict), f"{series_id}[{index}]: invalid observation")
        observation_date = observation.get("date")
        require(isinstance(observation_date, str), f"{series_id}[{index}]: invalid date")
        try:
            date.fromisoformat(observation_date)
        except ValueError as error:
            raise ApiError(f"{series_id}[{index}]: invalid ISO date") from error
        require(valid_number(observation.get("value")), f"{series_id}[{index}]: invalid value")
        dates.append(observation_date)

    require(dates == sorted(dates), f"{series_id}: observations are not ordered")
    require(len(dates) == len(set(dates)), f"{series_id}: duplicate dates")
    require(entry.get("observation_count") == len(dates), f"{series_id}: count mismatch")
    require(entry.get("last_observation") == dates[-1], f"{series_id}: manifest last date mismatch")
    require(payload.get("last_observation") == dates[-1], f"{series_id}: payload last date mismatch")


def validate(root: str) -> tuple[int, int, int]:
    source = ApiSource(root)
    manifest = source.read_json("manifest.json")
    require(isinstance(manifest, dict), "manifest.json must contain an object")
    series = manifest.get("series")
    require(isinstance(series, dict) and series, "manifest series must be a non-empty object")
    require(manifest.get("series_count") == len(series), "manifest series_count mismatch")
    require(manifest.get("indicators_path") == "indicators.json", "unexpected indicators_path")

    payloads: dict[str, dict[str, Any]] = {}
    observation_count = 0
    expected_paths: set[str] = set()
    for series_id, entry in series.items():
        require(isinstance(entry, dict), f"{series_id}: manifest entry must be an object")
        expected_path = f"series/{series_id}.json"
        require(entry.get("path") == expected_path, f"{series_id}: unexpected path")
        require(entry.get("status") == "ok", f"{series_id}: status is not ok")
        payload = source.read_json(expected_path)
        validate_series(series_id, entry, payload)
        payloads[series_id] = payload
        observation_count += entry["observation_count"]
        expected_paths.add(expected_path)

    if not source.remote:
        actual_paths = {
            path.relative_to(Path(source.root)).as_posix()
            for path in Path(source.root, "series").glob("*.json")
        }
        require(actual_paths == expected_paths, "local series files do not match the manifest")

    indicators_payload = source.read_json("indicators.json")
    require(isinstance(indicators_payload, dict), "indicators.json must contain an object")
    indicators = indicators_payload.get("indicators")
    require(isinstance(indicators, list), "indicators must be a list")
    require(
        indicators_payload.get("indicator_count") == len(indicators)
        == manifest.get("indicator_count"),
        "indicator_count mismatch",
    )

    indicator_ids: set[str] = set()
    for indicator in indicators:
        require(isinstance(indicator, dict), "indicator must be an object")
        indicator_id = indicator.get("id")
        require(isinstance(indicator_id, str) and indicator_id, "indicator has no id")
        require(indicator_id not in indicator_ids, f"duplicate indicator id: {indicator_id}")
        indicator_ids.add(indicator_id)
        series_id = indicator.get("series_id")
        require(series_id in payloads, f"{indicator_id}: unknown series_id")
        latest = payloads[series_id]["observations"][-1]
        require(indicator.get("reference_date") == latest["date"], f"{indicator_id}: stale date")
        require(indicator.get("value") == latest["value"], f"{indicator_id}: stale value")
        for field in ("name", "unit", "display_value", "period"):
            require(
                isinstance(indicator.get(field), str) and bool(indicator[field]),
                f"{indicator_id}: invalid {field}",
            )

    return len(series), observation_count, len(indicators)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "root",
        nargs="?",
        default="api/v1",
        help="Local api/v1 directory or published API base URL",
    )
    args = parser.parse_args()
    try:
        series_count, observation_count, indicator_count = validate(args.root)
    except ApiError as error:
        print(f"API validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "API valid: "
        f"{series_count} series, {observation_count} observations, "
        f"{indicator_count} indicators ({args.root})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
