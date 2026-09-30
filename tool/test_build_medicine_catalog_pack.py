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
