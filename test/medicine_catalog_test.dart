import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/medicine_discovery.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/medicine_catalog_service.dart';

void main() {
  test('openFDA mapping prefills identity fields only', () {
    final hits = OpenFdaNdcProvider.parseResults(
      [
        {
          'brand_name': 'Dolo',
          'generic_name': 'Paracetamol',
          'labeler_name': 'Micro Labs',
          'dosage_form': 'TABLET',
          'product_ndc': '12345-678',
          'active_ingredients': [
            {'name': 'PARACETAMOL', 'strength': '650 mg/1'},
          ],
        },
      ],
      queryText: 'Dolo 650',
      barcode: '8900000000000',
    );

    expect(hits, hasLength(1));
    final seed = hits.single.seed;
    expect(seed.name, 'Dolo');
    expect(seed.brand, 'Dolo');
    expect(seed.salt, 'PARACETAMOL');
    expect(seed.strength, '650 mg');
    expect(seed.form, 'Tablet');
    expect(seed.manufacturer, 'Micro Labs');
    expect(seed.barcode, isEmpty);
    expect(seed.source, 'openFDA NDC');
  });

  test('openFDA combination strength abstains when one component dose is missing', () {
    final seed = OpenFdaNdcProvider.parseResults(
      [
        {
          'brand_name': 'Combo',
          'generic_name': 'Alpha and Beta',
          'dosage_form': 'TABLET',
          'active_ingredients': [
            {'name': 'ALPHA', 'strength': '10 mg/1'},
            {'name': 'BETA', 'strength': ''},
          ],
        },
      ],
      queryText: 'Combo alpha beta',
      barcode: '',
    ).single.seed;

    expect(seed.salt, 'ALPHA + BETA');
    expect(seed.strength, isEmpty);
  });

  test('exact catalog barcode is carried into the review draft', () {
    final hits = OpenFdaNdcProvider.parseResults(
      [
        {
          'brand_name': 'ExampleMed',
          'generic_name': 'Example ingredient',
          'dosage_form': 'CAPSULE',
          'active_ingredients': [
            {'name': 'EXAMPLE INGREDIENT', 'strength': '20 mg/1'},
          ],
        },
      ],
      queryText: 'ExampleMed 20',
      barcode: '0123456789012',
      barcodeExact: true,
    );

    expect(hits.single.seed.barcode, '0123456789012');
    expect(hits.single.score, 1);
  });

  test('RxNorm concept is split into brand salt strength and form', () {
    final hits = RxNormProvider.parseResults(
      [
        {
          'rxcui': '123',
          'rank': '1',
          'score': '12.5',
          'name': 'paracetamol 650 MG Oral Tablet [Dolo]',
        },
      ],
      queryText: 'Dolo 650 tablet',
    );

    expect(hits, hasLength(1));
    final seed = hits.single.seed;
    expect(seed.name, 'Dolo');
    expect(seed.brand, 'Dolo');
    expect(seed.salt.toLowerCase(), 'paracetamol');
    expect(seed.strength.toLowerCase(), '650 mg');
    expect(seed.form, 'Tablet');
    expect(seed.source, 'RxNorm');
  });

  test('RxNorm preserves suspension and solution as distinct dosage forms', () {
    final suspension = RxNormProvider.parseResults(
      [
        {
          'rxcui': '201',
          'rank': '1',
          'score': '10',
          'name': 'amoxicillin 250 MG/5 ML Oral Suspension [Example A]',
        },
      ],
      queryText: 'amoxicillin suspension',
    ).single.seed;
    final solution = RxNormProvider.parseResults(
      [
        {
          'rxcui': '202',
          'rank': '1',
          'score': '10',
          'name': 'cetirizine 1 MG/ML Oral Solution [Example B]',
        },
      ],
      queryText: 'cetirizine solution',
    ).single.seed;

    expect(suspension.form, 'Suspension');
    expect(suspension.strength.toLowerCase(), '250 mg/5 ml');
    expect(solution.form, 'Solution');
    expect(solution.strength.toLowerCase(), '1 mg/ml');
  });

  test('RxNorm uses shared dosage-form vocabulary including lotion', () {
    final seed = RxNormProvider.parseResults(
      [
        {
          'rxcui': '303',
          'rank': '1',
          'score': '11',
          'name': 'clotrimazole 10 MG/ML Topical Lotion [Candid]',
        },
      ],
      queryText: 'Candid clotrimazole lotion',
    ).single.seed;

    expect(seed.name, 'Candid');
    expect(seed.brand, 'Candid');
    expect(seed.salt.toLowerCase(), 'clotrimazole');
    expect(seed.strength.toLowerCase(), '10 mg/ml');
    expect(seed.form, 'Lotion');
  });

  test('scan ranking treats explicit percent concentration as equivalent', () async {
    final provider = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Candid',
          brand: 'Candid',
          salt: 'Clotrimazole',
          strength: '10 mg/mL',
          form: 'Lotion',
        ),
        score: .86,
        provider: 'normalized-concentration',
      ),
    ]);
    final service = MedicineCatalogService(providers: [provider]);
    addTearDown(service.close);

    final results = await service.searchScan(
      text:
          'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1% w/v\nLOTION',
      evidence: const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 303,
          quality: .98,
          text:
              'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1% w/v\nLOTION',
        ),
      ],
    );

    expect(results, hasLength(1));
    expect(results.single.reason, contains('Scan agrees'));
    expect(results.single.reason, contains('strength'));
    expect(results.single.seed.form, 'Lotion');
  });

  test('RxNorm preserves aligned multi-ingredient composition and doses', () {
    final seed = RxNormProvider.parseResults(
      [
        {
          'rxcui': '9001',
          'rank': '1',
          'score': '12',
          'name':
              'montelukast sodium 10 MG / levocetirizine hydrochloride 5 MG Oral Tablet [Montek LC]',
        },
      ],
      queryText: 'Montek LC montelukast levocetirizine 10 mg 5 mg',
    ).single.seed;

    expect(seed.name, 'Montek LC');
    expect(seed.brand, 'Montek LC');
    expect(
      seed.salt.toLowerCase(),
      'montelukast sodium + levocetirizine hydrochloride',
    );
    expect(seed.strength.toLowerCase(), '10 mg + 5 mg');
    expect(seed.form, 'Tablet');
  });

  test('RxNorm keeps both salts but abstains if one combination dose is absent', () {
    final seed = RxNormProvider.parseResults(
      [
        {
          'rxcui': '9002',
          'rank': '1',
          'score': '12',
          'name': 'alpha 10 MG / beta Oral Tablet [Combo]',
        },
      ],
      queryText: 'Combo alpha beta 10 mg',
    ).single.seed;

    expect(seed.salt.toLowerCase(), 'alpha + beta');
    expect(seed.strength, isEmpty);
    expect(seed.form, 'Tablet');
  });

  test('scan-aware catalogue ranking demotes conflicting strength and form', () async {
    final provider = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Candid',
          brand: 'Candid',
          salt: 'Clotrimazole',
          strength: '2%',
          form: 'Cream',
        ),
        score: .95,
        provider: 'lexical-wrong',
      ),
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Candid',
          brand: 'Candid',
          salt: 'Clotrimazole',
          strength: '1%',
          form: 'Lotion',
        ),
        score: .72,
        provider: 'scan-correct',
      ),
    ]);
    final service = MedicineCatalogService(providers: [provider]);
    addTearDown(service.close);

    final results = await service.searchScan(
      text: 'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1%\nLOTION',
      evidence: const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 1,
          quality: .98,
          text:
              'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1%\nLOTION',
        ),
      ],
    );

    expect(results, hasLength(2));
    expect(results.first.provider, 'scan-correct');
    expect(results.first.seed.form, 'Lotion');
    expect(results.first.reason, contains('Scan agrees'));
    expect(provider.lastText, contains('candid'));
    expect(provider.lastText, contains('clotrimazole'));
    expect(provider.lastText, contains('lotion'));
  });

  test('catalog service repairs fragmented and glued OCR before lookup', () async {
    final provider = _FakeProvider(const <MedicineCatalogCandidate>[]);
    final service = MedicineCatalogService(providers: [provider]);
    addTearDown(service.close);

    await service.search(
      text: 'D O L O\nMontelukastSodium10mg\n6 5 0 mg\nTABLETS',
    );

    expect(provider.lastText, contains('dolo'));
    expect(provider.lastText, contains('montelukastsodium 10 mg'));
    expect(provider.lastText, contains('650 mg'));
    expect(provider.lastText, isNot(contains('tablets')));
  });

  test('catalog service deduplicates identity and keeps stronger result', () async {
    final weak = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
        score: .72,
        provider: 'weak',
      ),
    ]);
    final strong = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
        score: .94,
        provider: 'strong',
      ),
    ]);
    final service = MedicineCatalogService(providers: [weak, strong]);
    addTearDown(service.close);

    final results = await service.search(text: 'Dolo 650');
    expect(results, hasLength(1));
    expect(results.single.provider, 'strong');
    expect(results.single.score, .94);
  });

  test('catalog service coalesces and caches repeated scan lookups', () async {
    final provider = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(name: 'Dolo', strength: '650 mg'),
        score: .94,
        provider: 'cache-test',
      ),
    ]);
    final service = MedicineCatalogService(providers: [provider]);
    addTearDown(service.close);

    final first = service.search(text: 'Dolo 650');
    final second = service.search(text: 'Dolo 650');
    await Future.wait([first, second]);
    await service.search(text: 'Dolo 650');

    expect(provider.calls, 1);
  });

  test('release-first search does not leak a strong mirrored query to fallback', () async {
    final release = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
        score: .94,
        provider: 'release',
      ),
    ]);
    final fallback = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(name: 'Other'),
        score: .99,
        provider: 'network',
      ),
    ]);
    final service = MedicineCatalogService(
      providers: [release, fallback],
      releaseFirst: true,
    );
    addTearDown(service.close);

    final results = await service.search(text: 'Dolo 650');
    expect(results.single.seed.name, 'Dolo');
    expect(release.calls, 1);
    expect(fallback.calls, 0);
  });

  test('release-first search uses public fallback when mirror evidence is weak', () async {
    final release = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(name: 'Dolo'),
        score: .72,
        provider: 'release',
      ),
    ]);
    final fallback = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Dolo',
          brand: 'Dolo',
          salt: 'Paracetamol',
          strength: '650 mg',
          form: 'Tablet',
        ),
        score: .95,
        provider: 'network',
      ),
    ]);
    final service = MedicineCatalogService(
      providers: [release, fallback],
      releaseFirst: true,
    );
    addTearDown(service.close);

    final results = await service.search(text: 'Dolo 650');
    expect(results.first.score, .95);
    expect(release.calls, 1);
    expect(fallback.calls, 1);
  });

  test('scan-aware release gate falls back on strength or form conflict', () async {
    final release = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Candid',
          brand: 'Candid',
          salt: 'Clotrimazole',
          strength: '2%',
          form: 'Cream',
        ),
        score: .96,
        provider: 'release',
      ),
    ]);
    final fallback = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Candid',
          brand: 'Candid',
          salt: 'Clotrimazole',
          strength: '1%',
          form: 'Lotion',
        ),
        score: .84,
        provider: 'network',
      ),
    ]);
    final service = MedicineCatalogService(
      providers: [release, fallback],
      releaseFirst: true,
    );
    addTearDown(service.close);

    final results = await service.searchScan(
      text: 'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1%\nLOTION',
      evidence: const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 1,
          quality: .98,
          text:
              'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1%\nLOTION',
        ),
      ],
    );

    expect(release.calls, 1);
    expect(fallback.calls, 1);
    expect(results.first.provider, 'network');
    expect(results.first.seed.strength, '1%');
    expect(results.first.seed.form, 'Lotion');
  });

  test('scan-aware release gate keeps coherent mirrored match private', () async {
    final release = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Candid',
          brand: 'Candid',
          salt: 'Clotrimazole',
          strength: '1%',
          form: 'Lotion',
        ),
        score: .94,
        provider: 'release',
      ),
    ]);
    final fallback = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(name: 'Other'),
        score: .99,
        provider: 'network',
      ),
    ]);
    final service = MedicineCatalogService(
      providers: [release, fallback],
      releaseFirst: true,
    );
    addTearDown(service.close);

    final results = await service.searchScan(
      text: 'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1%\nLOTION',
      evidence: const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 2,
          quality: .98,
          text:
              'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1%\nLOTION',
        ),
      ],
    );

    expect(results.first.provider, 'release');
    expect(release.calls, 1);
    expect(fallback.calls, 0);
    expect(results.first.reason, contains('Scan agrees'));
  });

  test('scan-aware release mirror receives a bounded query lattice', () async {
    final release = _FakeScanAwareProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(
          name: 'Candid',
          brand: 'Candid',
          salt: 'Clotrimazole',
          strength: '1%',
          form: 'Lotion',
        ),
        score: .94,
        provider: 'release-lattice',
      ),
    ]);
    final fallback = _FakeProvider([
      const MedicineCatalogCandidate(
        seed: MedicineDraftSeed(name: 'Wrong fallback'),
        score: .99,
        provider: 'network',
      ),
    ]);
    final service = MedicineCatalogService(
      providers: <MedicineCatalogProvider>[release, fallback],
      releaseFirst: true,
    );
    addTearDown(service.close);

    final results = await service.searchScan(
      text:
          'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1% w/v\nCANDIDLOTION\nB.No AB12 MRP 98',
      evidence: const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          sequence: 41,
          quality: .98,
          text:
              'PRODUCT NAME CANDID\nACTIVE INGREDIENT CLOTRIMAZOLE 1% w/v\nCANDIDLOTION\nB.No AB12 MRP 98',
        ),
      ],
    );

    expect(results, isNotEmpty);
    expect(results.first.seed.name, 'Candid');
    expect(results.first.seed.salt, 'Clotrimazole');
    expect(results.first.seed.form, 'Lotion');
    expect(release.scanCalls, 1);
    expect(release.genericCalls, 0);
    expect(release.lastEvidence, isNotEmpty);
    expect(
      release.lastEvidence.any(
        (frame) => frame.text.toLowerCase().contains('candidlotion'),
      ),
      isTrue,
    );
    expect(release.lastQueries.length, greaterThanOrEqualTo(3));
    expect(
      release.lastQueries.any(
        (value) => value.toLowerCase().contains('candid'),
      ),
      isTrue,
    );
    expect(
      release.lastQueries.any(
        (value) => value.toLowerCase().contains('clotrimazole'),
      ),
      isTrue,
    );
    expect(
      release.lastQueries.any(
        (value) => value.toLowerCase().contains('lotion'),
      ),
      isTrue,
    );
    // A coherent mirrored answer stays private; extra OCR views are not sent
    // to the live fallback provider.
    expect(fallback.calls, 0);
  });

  test(
    'unique physical pack proof promotes missing catalogue salt without self-proof',
    () async {
      final provider = _FakeProvider([
        const MedicineCatalogCandidate(
          seed: MedicineDraftSeed(
            name: 'Candid',
            brand: 'Candid',
            salt: 'Clotrimazole',
            strength: '10 mg/mL',
            form: 'Lotion',
          ),
          score: .72,
          provider: 'release-identity',
        ),
      ]);
      final service = MedicineCatalogService(providers: [provider]);
      addTearDown(service.close);

      const scanText = 'PRODUCT NAME CANDID\n1% w/v\nLOTION';
      final results = await service.searchScan(
        text: scanText,
        evidence: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 71,
            quality: .99,
            text: scanText,
          ),
        ],
      );

      expect(results, hasLength(1));
      expect(results.single.seed.salt, 'Clotrimazole');
      expect(results.single.score, greaterThanOrEqualTo(.94));
      expect(results.single.reason, startsWith('Scan agrees:'));
      expect(results.single.reason, contains('brand'));
      expect(results.single.reason, contains('strength'));
      expect(results.single.reason, contains('form'));
      expect(
        results.single.reason.split(',').any(
          (part) => part.trim() == 'salt',
        ),
        isFalse,
      );
    },
  );

  test(
    'same-brand sibling salts stay ambiguous when pack lacks salt evidence',
    () async {
      final release = _FakeProvider([
        const MedicineCatalogCandidate(
          seed: MedicineDraftSeed(
            name: 'Examplex',
            brand: 'Examplex',
            salt: 'Alpha Salt',
            strength: '10 mg',
            form: 'Tablet',
          ),
          score: .72,
          provider: 'release-alpha',
        ),
        const MedicineCatalogCandidate(
          seed: MedicineDraftSeed(
            name: 'Examplex',
            brand: 'Examplex',
            salt: 'Beta Salt',
            strength: '10 mg',
            form: 'Tablet',
          ),
          score: .71,
          provider: 'release-beta',
        ),
      ]);
      final fallback = _FakeProvider([
        const MedicineCatalogCandidate(
          seed: MedicineDraftSeed(name: 'Public fallback'),
          score: .91,
          provider: 'network',
        ),
      ]);
      final service = MedicineCatalogService(
        providers: [release, fallback],
        releaseFirst: true,
      );
      addTearDown(service.close);

      const scanText = 'PRODUCT NAME EXAMPLEX\n10 mg\nTABLETS';
      final results = await service.searchScan(
        text: scanText,
        evidence: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 72,
            quality: .99,
            text: scanText,
          ),
        ],
      );

      expect(release.calls, 1);
      expect(fallback.calls, 1);
      expect(results, isNotEmpty);
      expect(
        results
            .where((candidate) => candidate.provider.startsWith('release-'))
            .every((candidate) => candidate.score < .90),
        isTrue,
      );
    },
  );

}

class _FakeProvider implements MedicineCatalogProvider {
  _FakeProvider(this.results);

  final List<MedicineCatalogCandidate> results;
  int calls = 0;
  String lastText = '';

  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    calls++;
    lastText = text;
    return results;
  }
}


class _FakeScanAwareProvider implements MedicineScanAwareCatalogProvider {
  _FakeScanAwareProvider(this.results);

  final List<MedicineCatalogCandidate> results;
  int genericCalls = 0;
  int scanCalls = 0;
  List<String> lastQueries = const <String>[];
  List<MedicineFrameEvidence> lastEvidence =
      const <MedicineFrameEvidence>[];

  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    genericCalls++;
    return results;
  }

  @override
  Future<List<MedicineCatalogCandidate>> searchScanEvidence({
    required String barcode,
    required List<String> queries,
    required List<MedicineFrameEvidence> evidence,
    required int limit,
  }) async {
    scanCalls++;
    lastQueries = List<String>.unmodifiable(queries);
    lastEvidence = List<MedicineFrameEvidence>.unmodifiable(evidence);
    return results;
  }
}
