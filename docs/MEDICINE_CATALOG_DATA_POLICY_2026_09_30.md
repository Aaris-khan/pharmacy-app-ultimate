# Aaris Medicine Catalogue — data policy

The shared recognition catalogue is identity assistance, not clinical truth and not inventory authority.

## Allowed sources

Only data with explicit redistribution rights may be mirrored into Aaris catalogue releases. Source provenance and licence metadata must be retained in every generated manifest.

Automated mirrored sources are deliberately narrow:

- **openFDA Drug NDC** — openFDA distributes the data under Public Domain / CC0. It contributes labeler-submitted product identity, ingredients, strength, dosage form, labeler and public UPC fields.
- **NLM RxNorm Current Prescribable Content (CPC)** — NLM explicitly publishes this subset with no licensing restrictions and as public-domain content. Aaris mirrors only active NLM-normalized `SAB=RXNORM` Semantic Clinical Drug / Semantic Branded Drug concepts (`SCD` / `SBD`) from CPC.
- **Eka Care Indian Drug MCQA** — the publisher explicitly releases this Indian branded-medication dataset under the MIT licence. Aaris imports only `medication_name` → `generic_name` identity facts from an immutable Hugging Face revision. Repeated question variants for the same trade name must agree on generic composition; conflicting mappings are dropped instead of guessed.

Do not mirror proprietary medicine databases, scrape sites that prohibit redistribution, or assume that a third-party repository licence covers data scraped from another commercial source. A source must itself state redistribution terms and have reviewable provenance before entering the runtime trust list. Do not copy the full RxNorm monthly/weekly release. Full RxNorm includes third-party source vocabularies with different licence terms; CPC is a separate deliberately redistributable subset.

## Safety boundary

Catalogue records may contain product identity only: medicine/trade name, brand, active ingredients, strength, dosage form, manufacturer/labeler, public identifiers, and bounded OCR aliases. They must never provide MFG, EXP, batch, pharmacy quantity, price, supplier, shelf location, or private user data.

A catalogue match is a candidate. Existing physical-pack evidence, contradiction gates, pharmacist review, and the PharmacyController/SQLite transaction remain authoritative.

Compact OCR aliases (for example, a brand or multi-word ingredient with spaces removed) are retrieval hints only. They can nominate a candidate but cannot bypass strength/form/composition contradiction gates.

When Online Search is enabled, the verified GitHub Release mirror is queried first. OCR/query text is sent to live public providers only when the mirror has no strong match.

## Quality meaning

A source record being accepted into the catalogue means its provenance and transformation passed the catalogue pipeline. It does not mean FDA approval, therapeutic suitability, or that the source content was independently verified by Aaris.

## Contributions

New datasets may be added only after recording the source URL, licence/redistribution terms, immutable source revision/checksum, transformation version, and validation checks. User-confirmed local recognition memory stays on-device and is never silently uploaded to the shared catalogue.
