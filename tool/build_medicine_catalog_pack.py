#!/usr/bin/env python3
"""Build a licence-safe, identity-only Aaris medicine catalogue release pack."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import time
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

OPENFDA_DOWNLOAD_INDEX = "https://api.fda.gov/download.json"
OPENFDA_SOURCE_URL = "https://open.fda.gov/apis/drug/ndc/"
OPENFDA_LICENSE_URL = "https://open.fda.gov/license/"
RXNORM_FILES_URL = "https://www.nlm.nih.gov/research/umls/rxnorm/docs/rxnormfiles.html"
RXNORM_SOURCE_URL = "https://www.nlm.nih.gov/research/umls/rxnorm/docs/prescribe.html"
RXNORM_DOWNLOAD_HOST = "download.nlm.nih.gov"
MAX_SHARD_RECORDS = 20_000
MAX_SHARD_BYTES = 8 * 1024 * 1024
MAX_RXNORM_ARCHIVE_BYTES = 256 * 1024 * 1024
MIN_RXNORM_CLINICAL_DRUGS = 10_000
MAX_RXNORM_CLINICAL_DRUGS = 100_000


def fetch(url: str, timeout: int = 120, max_bytes: int | None = None) -> bytes:
    if url.startswith("http://download.open.fda.gov/"):
        url = "https://" + url[len("http://") :]
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Aaris-Pharmacy-Catalog-Builder/2"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if max_bytes is not None:
            declared = response.headers.get("Content-Length")
            if declared and int(declared) > max_bytes:
                raise RuntimeError(f"Download is larger than the safety limit: {url}")
            data = response.read(max_bytes + 1)
            if len(data) > max_bytes:
                raise RuntimeError(f"Download exceeded the safety limit: {url}")
            return data
        return response.read()


def clean(value: object, limit: int = 300) -> str:
    if not isinstance(value, str):
        return ""
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit]


def normalize_strength(raw: object) -> str:
    value = clean(raw, 120)
    # openFDA often encodes a unit dose as "650 mg/1". A unitless /1 does not
    # distinguish the product and causes false conflict with pack OCR "650 mg".
    value = re.sub(r"\s*/\s*1\s*$", "", value)
    return value.strip()


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


def _compact_ocr(value: str) -> str:
    # Release data is Latin pharmaceutical terminology. Keep digits because
    # glued OCR frequently binds a dose to the ingredient (e.g. NAME500MG).
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def ocr_aliases(
    *,
    name: str,
    brand: str = "",
    salt: str = "",
    components: list[tuple[str, str]] | None = None,
) -> list[str]:
    """Bounded aliases for OCR that drops spaces/separators.

    These aliases are retrieval hints only. Resolver contradiction gates remain
    authoritative, so a compact alias can nominate a product but cannot by
    itself overwrite scanned strength/form/composition.
    """
    values: list[str] = [name, brand, salt]
    if components:
        for ingredient, strength in components[:6]:
            values.append(ingredient)
            if strength:
                values.append(f"{ingredient}{strength}")
        values.append("".join(ingredient for ingredient, _ in components[:6]))
        if all(strength for _, strength in components[:6]):
            values.append(
                "".join(
                    f"{ingredient}{strength}"
                    for ingredient, strength in components[:6]
                )
            )

    out: list[str] = []
    seen: set[str] = set()
    for value in values:
        compact = _compact_ocr(value)
        if not 4 <= len(compact) <= 160 or compact in seen:
            continue
        seen.add(compact)
        out.append(compact)
        if len(out) >= 24:
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

    active_components: list[tuple[str, str]] = []
    active = row.get("active_ingredients")
    if isinstance(active, list):
        for item in active:
            if not isinstance(item, dict):
                continue
            name = clean(item.get("name"))
            if not name:
                continue
            active_components.append(
                (name, normalize_strength(item.get("strength")))
            )

    ingredient_names = [name for name, _ in active_components]
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
        # Never misalign combination doses. If one active ingredient has no
        # strength, keep the composition but leave the combined strength empty
        # for scan/review rather than assigning another ingredient's dose.
        "strength": (
            " + ".join(strength for _, strength in active_components)
            if active_components
            and all(strength for _, strength in active_components)
            else ""
        ),
        "form": normalize_form(row.get("dosage_form")),
        "manufacturer": clean(row.get("labeler_name")),
        "aliases": aliases,
        "aliases_ocr": ocr_aliases(
            name=name,
            brand=brand,
            salt=salt,
            components=active_components,
        ),
        "barcodes": upcs,
        "source": "public:openfda_ndc_cc0",
        "verified": True,
        # Source provenance is authoritative; product content remains
        # labeler-submitted and is therefore only a moderate prior.
        "prior_weight": 0.58,
    }


def load_openfda() -> tuple[list[dict[str, object]], str]:
    metadata = json.loads(fetch(OPENFDA_DOWNLOAD_INDEX))
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


_RX_STRENGTH = re.compile(
    r"\b\d+(?:\.\d+)?\s*(?:%|mcg|ug|mg|g|gm|ml|l|meq|mmol|mol|unt|unit|units|iu)"
    r"(?:\s*/\s*(?:(?:\d+(?:\.\d+)?\s*)?"
    r"(?:mcg|ug|mg|g|gm|ml|l|dose|actuation|actuat|tablet|capsule|packet|patch|hour|hr|unt|unit|units|iu)))?",
    re.IGNORECASE,
)
_RX_ROUTE_FORM_NOISE = re.compile(
    r"\b(?:oral|topical|ophthalmic|otic|nasal|inhalation|rectal|vaginal|"
    r"sublingual|buccal|transdermal|extended\s+release|delayed\s+release)\b",
    re.IGNORECASE,
)


def parse_rxnorm_name(raw: str) -> tuple[str, str, str, str]:
    """Return brand, salt, aligned strength, coarse form from an RxNorm drug name."""
    term = clean(raw, 600)
    if not term:
        return "", "", "", ""
    brand_match = re.search(r"\[([^\[\]]+)\]\s*$", term)
    brand = clean(brand_match.group(1), 300) if brand_match else ""
    body = re.sub(r"\s*\[[^\[\]]+\]\s*$", "", term).strip()
    form = normalize_form(body)

    raw_parts = [
        part.strip()
        for part in re.split(r"\s+/\s+", body)
        if part.strip()
    ]
    components: list[tuple[str, str]] = []
    complete = True
    for part in raw_parts[:6]:
        match = _RX_STRENGTH.search(part)
        if match is None:
            complete = False
            ingredient = _RX_ROUTE_FORM_NOISE.sub(" ", part)
            ingredient = re.sub(
                r"\b(?:tablet|tablets|capsule|capsules|solution|suspension|"
                r"lotion|cream|ointment|gel|injection|spray|drops|inhaler|"
                r"powder|sachet|packet)\b",
                " ",
                ingredient,
                flags=re.IGNORECASE,
            )
            ingredient = clean(re.sub(r"\s+", " ", ingredient), 300)
            if ingredient:
                components.append((ingredient, ""))
            continue
        ingredient = clean(part[: match.start()], 300)
        strength = clean(match.group(0), 120)
        if not ingredient or not strength:
            complete = False
            continue
        components.append((ingredient, strength))

    if components:
        salt = " + ".join(ingredient for ingredient, _ in components)
        # A combination dose is safe only when every slash-delimited component
        # was parsed. Otherwise preserve salt recall and abstain from dose fill.
        strength = (
            " + ".join(dose for _, dose in components)
            if complete and len(components) == len(raw_parts)
            else ""
        )
        return brand, salt, strength, form

    generic = _RX_ROUTE_FORM_NOISE.sub(" ", body)
    generic = re.sub(
        r"\b(?:tablet|tablets|capsule|capsules|solution|suspension|lotion|"
        r"cream|ointment|gel|injection|spray|drops|inhaler|powder|sachet|packet)\b",
        " ",
        generic,
        flags=re.IGNORECASE,
    )
    generic = re.sub(r"\s+", " ", generic).strip()
    return brand, generic, "", form


def transform_rxnorm_concept(
    rxcui: str,
    tty: str,
    raw_name: str,
) -> dict[str, object] | None:
    rxcui = clean(rxcui, 32)
    tty = clean(tty, 12).upper()
    raw_name = clean(raw_name, 600)
    if not rxcui.isdigit() or tty not in {"SCD", "SBD"} or not raw_name:
        return None

    brand, salt, strength, form = parse_rxnorm_name(raw_name)
    if not salt:
        return None
    name = brand or salt
    salts = [part.strip() for part in salt.split(" + ") if part.strip()]
    strengths = [part.strip() for part in strength.split(" + ") if part.strip()]
    components: list[tuple[str, str]] = []
    for index, ingredient in enumerate(salts[:6]):
        dose = strengths[index] if index < len(strengths) else ""
        components.append((ingredient, dose))

    aliases: list[str] = []
    if raw_name.casefold() not in {name.casefold(), salt.casefold()}:
        aliases.append(raw_name)

    return {
        "op": "upsert",
        "product_id": f"rxnorm:cpc:{rxcui}",
        "name": name,
        "brand": brand,
        "salt": salt,
        "strength": strength,
        "form": form,
        "manufacturer": "",
        "aliases": aliases,
        "aliases_ocr": ocr_aliases(
            name=name,
            brand=brand,
            salt=salt,
            components=components,
        ),
        # RxNorm NDC identifiers are not raw UPC/EAN/GTIN scanner payloads, so
        # they deliberately do not enter the exact-barcode authority lane.
        "barcodes": [],
        "source": "public:rxnorm_cpc_pd",
        "verified": True,
        "prior_weight": 0.66,
    }


def discover_rxnorm_cpc_release() -> tuple[str, str]:
    html = fetch(
        RXNORM_FILES_URL,
        timeout=60,
        max_bytes=2 * 1024 * 1024,
    ).decode("utf-8", errors="strict")
    matches = re.findall(
        r'href=["\']([^"\']*RxNorm_full_prescribe_(\d{8})\.zip)["\']',
        html,
        flags=re.IGNORECASE,
    )
    if not matches:
        raise RuntimeError("Could not locate the current RxNorm CPC monthly archive")

    choices: list[tuple[datetime, str]] = []
    for href, stamp in matches:
        try:
            release = datetime.strptime(stamp, "%m%d%Y")
        except ValueError:
            continue
        url = urllib.parse.urljoin(RXNORM_FILES_URL, href)
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https" or parsed.hostname != RXNORM_DOWNLOAD_HOST:
            continue
        choices.append((release, url))
    if not choices:
        raise RuntimeError("RxNorm CPC archive link failed the HTTPS/host policy")
    release, url = max(choices, key=lambda item: item[0])
    return url, release.date().isoformat()


def load_rxnorm_cpc() -> tuple[list[dict[str, object]], str, str, str]:
    archive_url, release_date = discover_rxnorm_cpc_release()
    archive_bytes = fetch(
        archive_url,
        timeout=180,
        max_bytes=MAX_RXNORM_ARCHIVE_BYTES,
    )
    archive_sha256 = hashlib.sha256(archive_bytes).hexdigest()
    products: dict[str, dict[str, object]] = {}
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        names = [
            name
            for name in archive.namelist()
            if name.upper().endswith("RXNCONSO.RRF")
        ]
        if len(names) != 1:
            raise RuntimeError(
                "RxNorm CPC archive must contain exactly one RXNCONSO.RRF"
            )
        with archive.open(names[0]) as raw_stream:
            for raw_line in io.TextIOWrapper(
                raw_stream,
                encoding="utf-8",
                newline="",
            ):
                fields = raw_line.rstrip("\r\n").split("|")
                if len(fields) < 18:
                    continue
                # RXNCONSO: RXCUI=0, LAT=1, SAB=11, TTY=12, STR=14,
                # SUPPRESS=16. CPC contains MTHSPL too; mirror only NLM's
                # normalized RXNORM SCD/SBD concepts to avoid source ambiguity.
                if (
                    fields[1] != "ENG"
                    or fields[11] != "RXNORM"
                    or fields[12] not in {"SCD", "SBD"}
                    or fields[16] != "N"
                ):
                    continue
                product = transform_rxnorm_concept(
                    fields[0],
                    fields[12],
                    fields[14],
                )
                if product is not None:
                    products[str(product["product_id"])] = product

    if not MIN_RXNORM_CLINICAL_DRUGS <= len(products) <= MAX_RXNORM_CLINICAL_DRUGS:
        raise RuntimeError(
            "RxNorm CPC schema/count sanity check failed: "
            f"{len(products)} clinical drugs"
        )
    return (
        [products[key] for key in sorted(products)],
        release_date,
        archive_url,
        archive_sha256,
    )


def write_pack(
    products: list[dict[str, object]],
    output: Path,
    *,
    sources: list[dict[str, object]],
) -> None:
    if not products:
        raise RuntimeError("No medicine records were produced")
    if len(products) >= 9_000_000:
        raise RuntimeError("Catalogue exceeds revision namespace")
    if not sources or any(
        source.get("redistributable") is not True for source in sources
    ):
        raise RuntimeError(
            "Every catalogue source must be explicitly redistributable"
        )

    # Stable source/product ordering makes release contents auditable apart from
    # the monotonic revision namespace.
    products = sorted(products, key=lambda row: str(row["product_id"]))

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
        "sources": sources,
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
    openfda_products, openfda_export_date = load_openfda()
    (
        rxnorm_products,
        rxnorm_release_date,
        rxnorm_archive_url,
        rxnorm_archive_sha256,
    ) = load_rxnorm_cpc()

    combined: dict[str, dict[str, object]] = {}
    for product in [*openfda_products, *rxnorm_products]:
        combined[str(product["product_id"])] = product

    sources: list[dict[str, object]] = [
        {
            "name": "openFDA Drug NDC",
            "product_source": "public:openfda_ndc_cc0",
            "source_url": OPENFDA_SOURCE_URL,
            "download_index": OPENFDA_DOWNLOAD_INDEX,
            "export_date": openfda_export_date,
            "license": "CC0-1.0 / Public Domain",
            "license_url": OPENFDA_LICENSE_URL,
            "redistributable": True,
            "records": len(openfda_products),
            "quality_note": (
                "NDC content is submitted by labelers and is not FDA verification "
                "or approval. Aaris uses it only as product-identity evidence."
            ),
        },
        {
            "name": "RxNorm Current Prescribable Content",
            "product_source": "public:rxnorm_cpc_pd",
            "source_url": RXNORM_SOURCE_URL,
            "download_index": RXNORM_FILES_URL,
            "archive_url": rxnorm_archive_url,
            "archive_sha256": rxnorm_archive_sha256,
            "export_date": rxnorm_release_date,
            "license": "Public Domain / no licensing restrictions",
            "license_url": RXNORM_SOURCE_URL,
            "redistributable": True,
            "records": len(rxnorm_products),
            "quality_note": (
                "Only active NLM-normalized RXNORM SCD/SBD concepts from the "
                "Current Prescribable Content subset are mirrored. Proprietary "
                "full-RxNorm source vocabularies are excluded."
            ),
        },
    ]
    write_pack(
        list(combined.values()),
        Path(args.output_dir),
        sources=sources,
    )
    print(
        "Built "
        f"{len(combined)} identity records "
        f"({len(openfda_products)} openFDA NDC + "
        f"{len(rxnorm_products)} RxNorm CPC)"
    )


if __name__ == "__main__":
    main()
