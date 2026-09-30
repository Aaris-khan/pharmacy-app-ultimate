#!/usr/bin/env python3
"""Build a licence-safe, identity-only Aaris medicine catalogue release pack."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import time
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

DOWNLOAD_INDEX = "https://api.fda.gov/download.json"
SOURCE_URL = "https://open.fda.gov/apis/drug/ndc/"
LICENSE_URL = "https://open.fda.gov/license/"
MAX_SHARD_RECORDS = 20_000
MAX_SHARD_BYTES = 8 * 1024 * 1024


def fetch(url: str, timeout: int = 120) -> bytes:
    if url.startswith("http://download.open.fda.gov/"):
        url = "https://" + url[len("http://") :]
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Aaris-Pharmacy-Catalog-Builder/1"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def clean(value: object, limit: int = 300) -> str:
    if not isinstance(value, str):
        return ""
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit]


def strings(value: object, limit: int = 24) -> list[str]:
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in value:
        text = clean(item, 160)
        key = text.casefold()
        if text and key not in seen:
            seen.add(key)
            out.append(text)
        if len(out) >= limit:
            break
    return out


def normalize_form(raw: object) -> str:
    value = clean(raw, 100).casefold()
    rules = (
        ("tablet", "Tablet"),
        ("caplet", "Tablet"),
        ("capsule", "Capsule"),
        ("syrup", "Syrup"),
        ("suspension", "Suspension"),
        ("solution", "Solution"),
        ("inject", "Injection"),
        ("cream", "Cream"),
        ("ointment", "Ointment"),
        ("gel", "Gel"),
        ("lotion", "Lotion"),
        ("drop", "Drops"),
        ("spray", "Spray"),
        ("inhal", "Inhaler"),
        ("powder", "Powder"),
        ("sachet", "Sachet"),
        ("packet", "Sachet"),
    )
    for needle, canonical in rules:
        if needle in value:
            return canonical
    return "Other" if value else ""


def ndc_product_id(row: dict[str, object]) -> str:
    value = clean(row.get("product_ndc"), 60).lower()
    value = re.sub(r"[^a-z0-9.-]+", "-", value).strip("-")
    return f"openfda:ndc:{value}" if value else ""


def transform(row: dict[str, object]) -> dict[str, object] | None:
    product_type = clean(row.get("product_type"), 100).upper()
    if product_type and "HUMAN" not in product_type:
        return None
    if row.get("finished") is False:
        return None

    product_id = ndc_product_id(row)
    if not product_id:
        return None

    brand = clean(row.get("brand_name"))
    brand_base = clean(row.get("brand_name_base"))
    generic = clean(row.get("generic_name"))

    ingredient_names: list[str] = []
    strengths: list[str] = []
    active = row.get("active_ingredients")
    if isinstance(active, list):
        for item in active:
            if not isinstance(item, dict):
                continue
            name = clean(item.get("name"))
            strength = clean(item.get("strength"), 120)
            if name:
                ingredient_names.append(name)
            if strength:
                strengths.append(strength)

    salt = " + ".join(ingredient_names) if ingredient_names else generic
    name = brand or brand_base or generic or salt
    if not name:
        return None

    aliases: list[str] = []
    for value in (brand_base,):
        if value and value.casefold() not in {name.casefold(), brand.casefold()}:
            aliases.append(value)

    openfda = row.get("openfda")
    upcs: list[str] = []
    if isinstance(openfda, dict):
        upcs = strings(openfda.get("upc"), 12)
    upcs = [
        value
        for value in upcs
        if 4 <= len(re.sub(r"\D", "", value)) <= 18
    ]

    return {
        "op": "upsert",
        "product_id": product_id,
        "name": name,
        "brand": brand,
        "salt": salt,
        "strength": " + ".join(strengths),
        "form": normalize_form(row.get("dosage_form")),
        "manufacturer": clean(row.get("labeler_name")),
        "aliases": aliases,
        "aliases_ocr": [],
        "barcodes": upcs,
        "source": "public:openfda_ndc_cc0",
        "verified": True,
        # Source provenance is authoritative; product content remains
        # labeler-submitted and is therefore only a moderate prior.
        "prior_weight": 0.58,
    }


def load_openfda() -> tuple[list[dict[str, object]], str]:
    metadata = json.loads(fetch(DOWNLOAD_INDEX))
    endpoint = metadata["results"]["drug"]["ndc"]
    partitions = endpoint.get("partitions", [])
    export_date = clean(endpoint.get("export_date"), 40)
    if not partitions:
        raise RuntimeError("openFDA NDC download index has no partitions")

    products: dict[str, dict[str, object]] = {}
    for partition in partitions:
        url = partition.get("file")
        if not isinstance(url, str) or not url:
            raise RuntimeError("openFDA NDC partition is missing its URL")
        archive_bytes = fetch(url)
        with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
            json_names = [
                name for name in archive.namelist() if name.lower().endswith(".json")
            ]
            if not json_names:
                raise RuntimeError(f"No JSON payload in {url}")
            for name in json_names:
                with archive.open(name) as stream:
                    payload = json.load(stream)
                for raw in payload.get("results", []):
                    if not isinstance(raw, dict):
                        continue
                    product = transform(raw)
                    if product is not None:
                        products[str(product["product_id"])] = product
    return [products[key] for key in sorted(products)], export_date


def write_pack(
    products: list[dict[str, object]],
    output: Path,
    export_date: str,
) -> None:
    if not products:
        raise RuntimeError("No medicine records were produced")
    if len(products) >= 9_000_000:
        raise RuntimeError("Catalogue exceeds revision namespace")

    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("aaris-medicine-catalog-*.jsonl"):
        old.unlink()
    manifest_path = output / "aaris-medicine-catalog.manifest.json"
    if manifest_path.exists():
        manifest_path.unlink()

    base_revision = int(time.time()) * 10_000_000
    shards: list[dict[str, object]] = []
    current: list[bytes] = []
    current_bytes = 0
    first_revision = 0
    last_revision = 0

    def flush() -> None:
        nonlocal current, current_bytes, first_revision, last_revision
        if not current:
            return
        index = len(shards) + 1
        name = f"aaris-medicine-catalog-{index:04d}.jsonl"
        data = b"".join(current)
        path = output / name
        path.write_bytes(data)
        shards.append(
            {
                "name": name,
                "sha256": hashlib.sha256(data).hexdigest(),
                "bytes": len(data),
                "records": len(current),
                "first_revision": first_revision,
                "last_revision": last_revision,
            }
        )
        current = []
        current_bytes = 0
        first_revision = 0
        last_revision = 0

    for index, product in enumerate(products, start=1):
        revision = base_revision + index
        row = dict(product)
        row["rev"] = revision
        encoded = (
            json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        if len(encoded) > MAX_SHARD_BYTES:
            raise RuntimeError(f"Single catalogue record is too large: {row['product_id']}")
        if current and (
            len(current) >= MAX_SHARD_RECORDS
            or current_bytes + len(encoded) > MAX_SHARD_BYTES
        ):
            flush()
        if not current:
            first_revision = revision
        current.append(encoded)
        current_bytes += len(encoded)
        last_revision = revision
    flush()

    manifest = {
        "schema": 1,
        "kind": "aaris-medicine-catalog",
        "mode": "snapshot",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "sources": [
            {
                "name": "openFDA Drug NDC",
                "product_source": "public:openfda_ndc_cc0",
                "source_url": SOURCE_URL,
                "download_index": DOWNLOAD_INDEX,
                "export_date": export_date,
                "license": "CC0-1.0 / Public Domain",
                "license_url": LICENSE_URL,
                "redistributable": True,
                "quality_note": (
                    "NDC content is submitted by labelers and is not FDA verification "
                    "or approval. Aaris uses it only as product-identity evidence."
                ),
            }
        ],
        "records": len(products),
        "shards": shards,
    }
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        default="build/medicine-catalog",
        help="Directory for the manifest and JSONL shards",
    )
    args = parser.parse_args()
    products, export_date = load_openfda()
    write_pack(products, Path(args.output_dir), export_date)
    print(f"Built {len(products)} identity records from openFDA NDC")


if __name__ == "__main__":
    main()
