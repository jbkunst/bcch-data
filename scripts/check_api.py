#!/usr/bin/env python3
"""Validate a local or published bcch-data static API using only Python stdlib."""

from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import date, datetime
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


def parse_iso_date(value: Any, field: str, *, nullable: bool = False) -> date | None:
    if value is None and nullable:
        return None
    require(isinstance(value, str), f"{field}: expected an ISO date")
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise ApiError(f"{field}: invalid ISO date") from error


def parse_iso_timestamp(value: Any, field: str) -> datetime:
    require(isinstance(value, str), f"{field}: expected an ISO timestamp")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ApiError(f"{field}: invalid ISO timestamp") from error


def validate_catalog(source: ApiSource, manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    catalog_path = manifest.get("catalog_path")
    require(catalog_path == "catalog.json", "unexpected catalog_path")
    payload = source.read_json(catalog_path)
    require(isinstance(payload, dict), "catalog.json must contain an object")
    require(payload.get("schema_version") == 1, "unsupported catalog schema_version")
    parse_iso_timestamp(payload.get("updated_at"), "catalog.updated_at")
    require(
        payload.get("updated_at") == manifest.get("catalog_updated_at"),
        "manifest catalog_updated_at mismatch",
    )

    records = payload.get("series")
    require(isinstance(records, list) and records, "catalog series must be a non-empty list")
    require(payload.get("series_count") == len(records), "catalog series_count mismatch")
    require(
        manifest.get("catalog_series_count") == len(records),
        "manifest catalog_series_count mismatch",
    )

    required_fields = {
        "series_id", "frequency", "spanish_title", "english_title",
        "first_observation", "last_observation", "updated_at", "created_at",
        "display_name", "measure", "unit", "adjustment", "source",
        "enrichment_version",
    }
    catalog: dict[str, dict[str, Any]] = {}
    enrichment_versions: set[int] = set()
    for index, record in enumerate(records):
        label = f"catalog series[{index}]"
        require(isinstance(record, dict), f"{label}: expected an object")
        require(set(record) == required_fields, f"{label}: unexpected fields")
        series_id = record.get("series_id")
        require(isinstance(series_id, str) and series_id, f"{label}: invalid series_id")
        require(series_id not in catalog, f"catalog: duplicate series_id {series_id}")
        for field in ("frequency", "spanish_title", "english_title", "display_name"):
            require(
                isinstance(record.get(field), str) and bool(record[field]),
                f"{series_id}: invalid {field}",
            )
        for field in ("measure", "unit", "adjustment", "source"):
            value = record.get(field)
            require(value is None or isinstance(value, str), f"{series_id}: invalid {field}")

        first = parse_iso_date(
            record.get("first_observation"),
            f"{series_id}.first_observation",
            nullable=True,
        )
        last = parse_iso_date(
            record.get("last_observation"),
            f"{series_id}.last_observation",
            nullable=True,
        )
        if first is not None and last is not None:
            require(first <= last, f"{series_id}: observation range is reversed")
        parse_iso_date(record.get("updated_at"), f"{series_id}.updated_at")
        parse_iso_date(record.get("created_at"), f"{series_id}.created_at")

        version = record.get("enrichment_version")
        require(isinstance(version, int) and version > 0, f"{series_id}: invalid enrichment_version")
        enrichment_versions.add(version)
        catalog[series_id] = record

    require(len(enrichment_versions) == 1, "catalog mixes enrichment versions")
    return catalog


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


def validate(root: str) -> tuple[int, int, int, int]:
    source = ApiSource(root)
    manifest = source.read_json("manifest.json")
    require(isinstance(manifest, dict), "manifest.json must contain an object")
    require(manifest.get("schema_version") == 1, "unsupported manifest schema_version")
    parse_iso_timestamp(manifest.get("updated_at"), "manifest.updated_at")
    parse_iso_timestamp(manifest.get("catalog_updated_at"), "manifest.catalog_updated_at")
    catalog = validate_catalog(source, manifest)
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
        require(series_id in catalog, f"{series_id}: missing from catalog")
        require(
            entry.get("frequency") == catalog[series_id].get("frequency"),
            f"{series_id}: catalog frequency mismatch",
        )
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

    return len(catalog), len(series), observation_count, len(indicators)


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
        catalog_count, series_count, observation_count, indicator_count = validate(args.root)
    except ApiError as error:
        print(f"API validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "API valid: "
        f"{catalog_count} catalog entries, {series_count} cached series, "
        f"{observation_count} observations, "
        f"{indicator_count} indicators ({args.root})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
