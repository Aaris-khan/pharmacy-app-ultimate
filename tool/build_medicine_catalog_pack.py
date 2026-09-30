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
EKACARE_DATASET_ID = "ekacare/indian_drug_mcqa"
EKACARE_API_URL = f"https://huggingface.co/api/datasets/{EKACARE_DATASET_ID}"
EKACARE_SOURCE_URL = f"https://huggingface.co/datasets/{EKACARE_DATASET_ID}"
EKACARE_LICENSE_URL = EKACARE_SOURCE_URL
MAX_SHARD_RECORDS = 20_000
MAX_SHARD_BYTES = 8 * 1024 * 1024
MAX_RXNORM_ARCHIVE_BYTES = 256 * 1024 * 1024
MIN_RXNORM_CLINICAL_DRUGS = 10_000
MAX_RXNORM_CLINICAL_DRUGS = 100_000
MAX_EKACARE_PARQUET_BYTES = 5 * 1024 * 1024
MIN_EKACARE_SOURCE_ROWS = 500
MAX_EKACARE_SOURCE_ROWS = 10_000


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
    form: str = "",
    components: list[tuple[str, str]] | None = None,
) -> list[str]:
    """Bounded aliases for OCR that drops spaces/separators.

    In addition to individual identity fields, include a few complete
    front-panel surfaces such as BRAND+INGREDIENT+DOSE+FORM. Camera OCR often
    flattens exactly that layout into one token. These aliases only nominate
    catalogue candidates; the app resolver still requires independent
    strength/form/composition agreement before canonical auto-fill.
    """
    values: list[str] = [name, brand, salt]
    identity = brand or name
    if form:
        values.append(f"{name}{form}")
        if brand:
            values.append(f"{brand}{form}")

    if components:
        bounded = components[:6]
        for ingredient, strength in bounded:
            values.append(ingredient)
            if strength:
                values.append(f"{ingredient}{strength}")

        ingredients = "".join(ingredient for ingredient, _ in bounded)
        values.append(ingredients)
        complete_doses = all(strength for _, strength in bounded)
        dosed = (
            "".join(f"{ingredient}{strength}" for ingredient, strength in bounded)
            if complete_doses
            else ""
        )
        if dosed:
            values.append(dosed)

        if identity:
            values.append(f"{identity}{ingredients}")
            if form:
                values.append(f"{identity}{ingredients}{form}")
            if dosed:
                values.append(f"{identity}{dosed}")
                if form:
                    values.append(f"{identity}{dosed}{form}")

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


_INDIAN_FORM_PRESENTATION = re.compile(
    r"\b(?:soft\s+gel(?:atin)?\s+capsules?|softgels?|tablets?|capsules?|"
    r"syrups?|suspensions?|solutions?|injections?|injectables?|creams?|"
    r"ointments?|gels?|lotions?|drops?|sprays?|inhalers?|powders?|sachets?)\b",
    re.IGNORECASE,
)
_INDIAN_DOSE_PRESENTATION = re.compile(
    r"\b\d+(?:\.\d+)?\s*(?:mcg|ug|mg|gm|g|meq|mmol|iu|i\.u\.|units?)"
    r"(?:\s*/\s*\d+(?:\.\d+)?\s*(?:mcg|ug|mg|gm|g|ml|meq|mmol|iu|i\.u\.|units?)){0,5}\b",
    re.IGNORECASE,
)
_INDIAN_ROUTE_PRESENTATION = re.compile(
    r"\b(?:oral|nasal|topical|ophthalmic|otic|inhalation|rectal|vaginal)\b",
    re.IGNORECASE,
)
_INDIAN_FORM_MODIFIER = re.compile(
    r"\b(?:chewable|dispersible|orodispersible|effervescent|sublingual)\b",
    re.IGNORECASE,
)


def indian_brand_name(raw: object) -> str:
    """Separate trade identity from obvious dose/form presentation.

    Unit-bearing strengths and route/form words are presentation metadata and
    stay available through the full-name alias. Bare numbers and suffixes such
    as "625 Duo", "AM" or "ER" are retained because they may identify an Indian
    market variant and the dataset does not prove they are dosage fields.
    """
    value = clean(raw, 300)
    if not value:
        return ""
    # Keep the complete source name as an alias elsewhere, but do not let
    # presentation metadata masquerade as the trade-name field. Unit-bearing
    # strengths are safe to remove; bare numbers (for example "625 Duo") are
    # deliberately retained because they can be part of an Indian market
    # variant name and the dataset does not provide enough evidence to split it.
    value = _INDIAN_DOSE_PRESENTATION.sub(" ", value)
    value = _INDIAN_FORM_PRESENTATION.sub(" ", value)
    value = _INDIAN_ROUTE_PRESENTATION.sub(" ", value)
    value = _INDIAN_FORM_MODIFIER.sub(" ", value)
    return clean(re.sub(r"\s+", " ", value), 300)


def _identity_key(raw: object) -> str:
    return re.sub(r"[^a-z0-9]+", "", clean(raw, 600).casefold())


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
            form=normalize_form(row.get("dosage_form")),
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


def _parse_ekacare_generic(
    raw: object,
) -> tuple[str, str, list[tuple[str, str]]]:
    """Return salt, aligned strength and components without inventing doses."""
    value = clean(raw, 600)
    if not value:
        return "", "", []
    parts = [
        clean(part, 300)
        for part in re.split(r"\s*\+\s*", value)
        if clean(part, 300)
    ][:6]
    components: list[tuple[str, str]] = []
    complete = bool(parts)
    for part in parts:
        ingredient = part
        strength = ""
        wrapped = re.search(r"\(([^()]*)\)\s*$", part)
        if wrapped is not None:
            candidate = normalize_strength(wrapped.group(1))
            if _RX_STRENGTH.fullmatch(candidate):
                strength = candidate
                ingredient = clean(part[: wrapped.start()], 300)
        if not ingredient:
            complete = False
            continue
        if not strength:
            complete = False
        components.append((ingredient, strength))
    salt = " + ".join(ingredient for ingredient, _ in components)
    strength = (
        " + ".join(dose for _, dose in components)
        if complete and len(components) == len(parts)
        else ""
    )
    return salt, strength, components


def transform_ekacare_drug(
    row: dict[str, object],
) -> dict[str, object] | None:
    """Transform one MIT-licensed Eka Care Indian brand mapping."""
    medication_name = clean(row.get("medication_name"), 300)
    generic_name = clean(row.get("generic_name"), 600)
    if not medication_name or not generic_name:
        return None

    brand = indian_brand_name(medication_name) or medication_name
    salt, strength, components = _parse_ekacare_generic(generic_name)
    if not salt:
        return None
    form = normalize_form(medication_name)
    if form == "Other":
        # Here the raw string is a product name, not a dedicated dosage-form
        # field. "Other" would falsely claim that an unprinted form was
        # observed, so absence stays unknown and cannot contradict pack OCR.
        form = ""
    fingerprint = hashlib.sha256(
        f"{_identity_key(medication_name)}|{_identity_key(salt)}".encode("utf-8")
    ).hexdigest()[:24]

    aliases = []
    if medication_name.casefold() != brand.casefold():
        aliases.append(medication_name)

    return {
        "op": "upsert",
        "product_id": f"ekacare:indian-mcqa:{fingerprint}",
        "name": brand,
        "brand": brand,
        "salt": salt,
        "strength": strength,
        "form": form,
        "manufacturer": "",
        "aliases": aliases,
        "aliases_ocr": ocr_aliases(
            name=brand,
            brand=brand,
            salt=salt,
            form=form,
            components=components,
        ),
        "barcodes": [],
        "source": "public:ekacare_indian_drug_mcqa_mit",
        "verified": True,
        # Useful Indian-market identity evidence, but not a regulator-maintained
        # product registry. Public sources still require three independent scan
        # channels before canonical lock in the app.
        "prior_weight": 0.60,
    }


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
            form=form,
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


def load_ekacare_indian_drugs(
) -> tuple[list[dict[str, object]], str, str, str, int]:
    """Load one reviewed revision of Eka Care's MIT Indian brand dataset.

    The Hugging Face API is used only to resolve the current immutable revision
    and verify that the dataset still declares MIT before any payload is read.
    """
    metadata = json.loads(
        fetch(EKACARE_API_URL, timeout=60, max_bytes=2 * 1024 * 1024)
    )
    if not isinstance(metadata, dict):
        raise RuntimeError("Eka Care dataset metadata is invalid")
    revision = clean(metadata.get("sha"), 80)
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("Eka Care dataset revision is missing")

    card = metadata.get("cardData")
    declared_license = ""
    if isinstance(card, dict):
        declared_license = clean(card.get("license"), 80).casefold()
    if not declared_license:
        tags = metadata.get("tags")
        if isinstance(tags, list):
            for tag in tags:
                value = clean(tag, 100)
                if value.casefold().startswith("license:"):
                    declared_license = value.split(":", 1)[1].strip().casefold()
                    break
    if declared_license != "mit":
        raise RuntimeError(
            "Eka Care dataset no longer declares the audited MIT license"
        )

    siblings = metadata.get("siblings")
    if not isinstance(siblings, list):
        raise RuntimeError("Eka Care dataset file list is missing")
    parquet_paths = []
    for item in siblings:
        if not isinstance(item, dict):
            continue
        filename = clean(item.get("rfilename"), 300)
        if re.fullmatch(r"data/test-\d{5}-of-\d{5}\.parquet", filename):
            parquet_paths.append(filename)
    if len(parquet_paths) != 1:
        raise RuntimeError(
            "Eka Care dataset must expose exactly one reviewed test parquet"
        )

    quoted_path = urllib.parse.quote(parquet_paths[0], safe="/")
    download_url = (
        f"https://huggingface.co/datasets/{EKACARE_DATASET_ID}/resolve/"
        f"{revision}/{quoted_path}?download=true"
    )
    parquet_bytes = fetch(
        download_url,
        timeout=90,
        max_bytes=MAX_EKACARE_PARQUET_BYTES,
    )
    parquet_sha256 = hashlib.sha256(parquet_bytes).hexdigest()

    try:
        import pyarrow.parquet as parquet
    except ImportError as error:
        raise RuntimeError(
            "pyarrow is required only for the audited Eka Care parquet source"
        ) from error

    table = parquet.read_table(
        io.BytesIO(parquet_bytes),
        columns=["medication_name", "generic_name"],
    )
    rows = table.to_pylist()
    if not MIN_EKACARE_SOURCE_ROWS <= len(rows) <= MAX_EKACARE_SOURCE_ROWS:
        raise RuntimeError(
            f"Eka Care row-count sanity check failed: {len(rows)} rows"
        )

    # Duplicate MCQ variants for the same trade name are expected. Require them
    # to agree on the generic composition; if the source contains contradictory
    # mappings for one product name, exclude that identity instead of guessing.
    normalized_salts: dict[str, str] = {}
    ambiguous: set[str] = set()
    staged: list[tuple[str, dict[str, object]]] = []
    for raw in rows:
        if not isinstance(raw, dict):
            continue
        product = transform_ekacare_drug(raw)
        if product is None:
            continue
        medicine_key = _identity_key(raw.get("medication_name"))
        salt_key = _identity_key(product["salt"])
        previous = normalized_salts.get(medicine_key)
        if previous is not None and previous != salt_key:
            ambiguous.add(medicine_key)
        else:
            normalized_salts[medicine_key] = salt_key
        staged.append((medicine_key, product))

    products: dict[str, dict[str, object]] = {}
    for medicine_key, product in staged:
        if not medicine_key or medicine_key in ambiguous:
            continue
        products[str(product["product_id"])] = product

    if len(products) < 300:
        raise RuntimeError(
            f"Eka Care produced too few unambiguous products: {len(products)}"
        )
    return (
        [products[key] for key in sorted(products)],
        revision,
        download_url,
        parquet_sha256,
        len(rows),
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
    (
        ekacare_products,
        ekacare_revision,
        ekacare_download_url,
        ekacare_parquet_sha256,
        ekacare_source_rows,
    ) = load_ekacare_indian_drugs()

    combined: dict[str, dict[str, object]] = {}
    for product in [*openfda_products, *rxnorm_products, *ekacare_products]:
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
        {
            "name": "Eka Care Indian Drug MCQA",
            "product_source": "public:ekacare_indian_drug_mcqa_mit",
            "source_url": EKACARE_SOURCE_URL,
            "download_index": EKACARE_API_URL,
            "archive_url": ekacare_download_url,
            "archive_sha256": ekacare_parquet_sha256,
            "export_date": ekacare_revision,
            "license": "MIT",
            "license_url": EKACARE_LICENSE_URL,
            "redistributable": True,
            "records": len(ekacare_products),
            "source_rows": ekacare_source_rows,
            "quality_note": (
                "Indian brand-to-generic mappings from the dataset's immutable "
                "MIT-licensed revision. Duplicate question variants must agree "
                "on composition; contradictory trade-name mappings are excluded. "
                "Used only for recognition identity, never clinical advice."
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
        f"{len(rxnorm_products)} RxNorm CPC + "
        f"{len(ekacare_products)} Eka Care Indian brands)"
    )


if __name__ == "__main__":
    main()
