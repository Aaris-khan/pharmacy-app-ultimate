# Aaris Medicine Catalogue — data policy

The shared recognition catalogue is identity assistance, not clinical truth and not inventory authority.

## Allowed sources

Only data with explicit redistribution rights may be mirrored into Aaris catalogue releases. Source provenance and licence metadata must be retained in every generated manifest.

Automated mirrored sources are deliberately narrow:

- **openFDA Drug NDC** — openFDA distributes the data under Public Domain / CC0. It contributes labeler-submitted product identity, ingredients, strength, dosage form, labeler and public UPC fields.
- **NLM RxNorm Current Prescribable Content (CPC)** — NLM explicitly publishes this subset with no licensing restrictions and as public-domain content. Aaris mirrors only active NLM-normalized `SAB=RXNORM` Semantic Clinical Drug / Semantic Branded Drug concepts (`SCD` / `SBD`) from CPC.

Do not mirror proprietary medicine databases, scrape sites that prohibit redistribution, or copy the full RxNorm monthly/weekly release. Full RxNorm includes third-party source vocabularies with different licence terms; CPC is a separate deliberately redistributable subset.

## Safety boundary

Catalogue records may contain product identity only: medicine/trade name, brand, active ingredients, strength, dosage form, manufacturer/labeler, public identifiers, and bounded OCR aliases. They must never provide MFG, EXP, batch, pharmacy quantity, price, supplier, shelf location, or private user data.

A catalogue match is a candidate. Existing physical-pack evidence, contradiction gates, pharmacist review, and the PharmacyController/SQLite transaction remain authoritative.

Compact OCR aliases (for example, a brand or multi-word ingredient with spaces removed) are retrieval hints only. They can nominate a candidate but cannot bypass strength/form/composition contradiction gates.

When Online Search is enabled, the verified GitHub Release mirror is queried first. OCR/query text is sent to live public providers only when the mirror has no strong match.

## Quality meaning

A source record being accepted into the catalogue means its provenance and transformation passed the catalogue pipeline. It does not mean FDA approval, therapeutic suitability, or that the source content was independently verified by Aaris.

## Contributions

New datasets may be added only after recording the source URL, licence/redistribution terms, transformation version, and validation checks. A public website being searchable does **not** imply permission to clone or redistribute its database. India-specific or commercial catalogues must therefore remain excluded from mirrored Releases until their redistribution terms are explicit and compatible.

The shared catalogue must be built from sourced records, not AI-invented medicine facts. New Aaris-owned records require a reviewable provenance trail (source, observed identity fields, licence basis, transform version, validation result) before publication.

User-confirmed local recognition memory stays on-device and is never silently uploaded to the shared catalogue.

## Retrieval policy

Online retrieval is multi-signal rather than first-hit. Brand/name, composition, strength and dosage form may all contribute to ranking. Dosage-form words such as Tablet, Capsule, Cream or Lotion are retained as discriminating evidence, but generic form words are never used as the primary public-API probe.

For noisy OCR, Aaris may issue a small bounded set of independent identity probes and fuse the returned candidates. A single token match cannot override contradictory strength, form or multi-ingredient composition evidence.
