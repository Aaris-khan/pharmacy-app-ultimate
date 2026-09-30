# Aaris Medicine Catalogue — data policy

The shared recognition catalogue is identity assistance, not clinical truth and not inventory authority.

## Allowed sources

Only data with explicit redistribution rights may be mirrored into Aaris catalogue releases. The first automated source is openFDA Drug NDC, whose openFDA distribution is Public Domain / CC0. Source provenance and licence metadata must be retained in every generated manifest.

Do not mirror proprietary medicine databases, scrape sites that prohibit redistribution, or copy full RxNorm monthly/weekly release files without satisfying NLM licensing requirements.

## Safety boundary

Catalogue records may contain product identity only: medicine/trade name, brand, active ingredients, strength, dosage form, manufacturer/labeler, public identifiers, and bounded OCR aliases. They must never provide MFG, EXP, batch, pharmacy quantity, price, supplier, shelf location, or private user data.

A catalogue match is a candidate. Existing physical-pack evidence, contradiction gates, pharmacist review, and the PharmacyController/SQLite transaction remain authoritative.

## Quality meaning

A source record being accepted into the catalogue means its provenance and transformation passed the catalogue pipeline. It does not mean FDA approval, therapeutic suitability, or that the source content was independently verified by Aaris.

## Contributions

New datasets may be added only after recording the source URL, licence/redistribution terms, transformation version, and validation checks. User-confirmed local recognition memory stays on-device and is never silently uploaded to the shared catalogue.
