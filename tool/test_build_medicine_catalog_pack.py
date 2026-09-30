import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).with_name("build_medicine_catalog_pack.py")
SPEC = importlib.util.spec_from_file_location("catalog_builder", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class CatalogBuilderTest(unittest.TestCase):
    def test_openfda_compact_aliases_cover_glued_brand_and_composition(self):
        product = builder.transform({
            "product_ndc": "12345-678",
            "product_type": "HUMAN OTC DRUG",
            "finished": True,
            "brand_name": "Montek LC",
            "generic_name": (
                "Montelukast Sodium and Levocetirizine Hydrochloride"
            ),
            "dosage_form": "TABLET",
            "active_ingredients": [
                {"name": "MONTELUKAST SODIUM", "strength": "10 mg/1"},
                {
                    "name": "LEVOCETIRIZINE HYDROCHLORIDE",
                    "strength": "5 mg/1",
                },
            ],
        })
        self.assertIsNotNone(product)
        aliases = set(product["aliases_ocr"])
        self.assertIn("monteklc", aliases)
        self.assertIn("montelukastsodium", aliases)
        self.assertIn("levocetirizinehydrochloride", aliases)
        self.assertIn(
            "montelukastsodiumlevocetirizinehydrochloride",
            aliases,
        )
        self.assertIn("monteklctablet", aliases)
        self.assertIn(
            "monteklcmontelukastsodiumlevocetirizinehydrochloride",
            aliases,
        )
        self.assertIn(
            "monteklcmontelukastsodium10mglevo"
            "cetirizinehydrochloride5mgtablet",
            aliases,
        )

    def test_unbranded_product_never_indexes_form_as_identity(self):
        aliases = set(
            builder.ocr_aliases(
                name="Paracetamol",
                brand="",
                salt="Paracetamol",
                form="Tablet",
                components=[("Paracetamol", "500 mg")],
            )
        )
        self.assertIn("paracetamoltablet", aliases)
        self.assertNotIn("tablet", aliases)

    def test_rxnorm_lotion_parses_brand_salt_strength_and_form(self):
        product = builder.transform_rxnorm_concept(
            "303",
            "SBD",
            "clotrimazole 10 MG/ML Topical Lotion [Candid]",
        )
        self.assertIsNotNone(product)
        self.assertEqual(product["name"], "Candid")
        self.assertEqual(product["brand"], "Candid")
        self.assertEqual(product["salt"].lower(), "clotrimazole")
        self.assertEqual(product["strength"].lower(), "10 mg/ml")
        self.assertEqual(product["form"], "Lotion")
        self.assertIn("clotrimazole10mgml", product["aliases_ocr"])

    def test_rxnorm_combination_keeps_ingredient_strength_alignment(self):
        product = builder.transform_rxnorm_concept(
            "9001",
            "SBD",
            (
                "montelukast sodium 10 MG / "
                "levocetirizine hydrochloride 5 MG Oral Tablet [Montek LC]"
            ),
        )
        self.assertIsNotNone(product)
        self.assertEqual(
            product["salt"].lower(),
            "montelukast sodium + levocetirizine hydrochloride",
        )
        self.assertEqual(product["strength"].lower(), "10 mg + 5 mg")
        self.assertEqual(product["form"], "Tablet")
        self.assertIn(
            "montelukastsodiumlevocetirizinehydrochloride",
            product["aliases_ocr"],
        )

    def test_rxnorm_partial_combination_abstains_from_combined_strength(self):
        brand, salt, strength, form = builder.parse_rxnorm_name(
            "alpha 10 MG / beta Oral Tablet [Combo]"
        )
        self.assertEqual(brand, "Combo")
        self.assertEqual(salt.lower(), "alpha + beta")
        self.assertEqual(strength, "")
        self.assertEqual(form, "Tablet")

    def test_ekacare_indian_brand_maps_form_and_aligned_combination(self):
        product = builder.transform_ekacare_drug({
            "medication_name": "Augmentin 625 Duo Tablet",
            "generic_name": (
                "Amoxycillin (500mg) + Clavulanic Acid (125mg)"
            ),
        })
        self.assertIsNotNone(product)
        self.assertEqual(product["name"], "Augmentin 625 Duo")
        self.assertEqual(product["brand"], "Augmentin 625 Duo")
        self.assertEqual(
            product["salt"].lower(),
            "amoxycillin + clavulanic acid",
        )
        self.assertEqual(product["strength"].lower(), "500mg + 125mg")
        self.assertEqual(product["form"], "Tablet")
        self.assertIn("Augmentin 625 Duo Tablet", product["aliases"])
        self.assertIn("augmentin625duotablet", product["aliases_ocr"])
        self.assertEqual(
            product["source"],
            "public:ekacare_indian_drug_mcqa_mit",
        )

    def test_ekacare_brand_excludes_strength_route_and_form_presentation(self):
        self.assertEqual(
            builder.indian_brand_name("Rapeed 20mg Injection"),
            "Rapeed",
        )
        self.assertEqual(
            builder.indian_brand_name("Linaglip-M 2.5mg/850mg Tablet"),
            "Linaglip-M",
        )
        self.assertEqual(
            builder.indian_brand_name("Winkast-AZ Nasal Spray"),
            "Winkast-AZ",
        )
        self.assertEqual(
            builder.indian_brand_name("Cbinan Vit C Zinc Chewable Tablet"),
            "Cbinan Vit C Zinc",
        )
        # A bare market-variant number is not silently interpreted as a dose.
        self.assertEqual(
            builder.indian_brand_name("Augmentin 625 Duo Tablet"),
            "Augmentin 625 Duo",
        )

    def test_ekacare_never_invents_missing_combination_doses(self):
        product = builder.transform_ekacare_drug({
            "medication_name": "Telcare AM",
            "generic_name": "telmisartan + amlodipine",
        })
        self.assertIsNotNone(product)
        self.assertEqual(product["name"], "Telcare AM")
        self.assertEqual(product["salt"], "telmisartan + amlodipine")
        self.assertEqual(product["strength"], "")
        self.assertEqual(product["form"], "")

    def test_rxnorm_non_clinical_tty_is_rejected(self):
        self.assertIsNone(
            builder.transform_rxnorm_concept(
                "123",
                "IN",
                "paracetamol",
            )
        )


if __name__ == "__main__":
    unittest.main()
