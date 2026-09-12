import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'medicine.dart';
import 'tracking.dart';

const pharmacyBackupSchema = 'aaris.pharmacy.backup.v2';
const legacyPharmacyBackupSchema = 'aaris.pharmacy.backup.v1';
const maxBackupCharacters = 12000000;
const _backupIntegrityPrefix = 'sha256:';

class PharmacyBackup {
  const PharmacyBackup({
    required this.createdAt,
    required this.sourceRevision,
    required this.settings,
    required this.records,
    required this.sales,
    required this.soldValue,
    required this.unknownSold,
  });

  final DateTime createdAt;
  final int sourceRevision;
  final WarningSettings settings;
  final Map<String, Medicine> records;
  final Map<String, SaleEvent> sales;
  final int soldValue;
  final int unknownSold;

  Map<String, dynamic> _canonicalPayload() {
    final medicines = records.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    final saleEvents = sales.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    return <String, dynamic>{
      'createdAt': createdAt.toIso8601String(),
      'sourceRevision': sourceRevision,
      'settings': settings.toJson(),
      'medicines': medicines.map((record) => record.toJson()).toList(),
      'sales': saleEvents.map((sale) => sale.toJson()).toList(),
      'soldValue': soldValue,
      'unknownSold': unknownSold,
    };
  }

  String _integrityDigest(Map<String, dynamic> payload) => sha256
      .convert(utf8.encode(jsonEncode(payload)))
      .toString();

  /// Version 2 adds a deterministic SHA-256 integrity proof over validated,
  /// canonical pharmacy facts. This detects truncation/accidental edits before
  /// restore. It is deliberately not described as an authenticity signature:
  /// there is no secret key and legacy v1 files remain importable.
  String encode() {
    final payload = _canonicalPayload();
    final integrity = '$_backupIntegrityPrefix${_integrityDigest(payload)}';
    return const JsonEncoder.withIndent('  ').convert({
      'schema': pharmacyBackupSchema,
      'integrity': integrity,
      ...payload,
    });
  }

  String get fileName =>
      'Aaris_Pharmacy_Backup_${dateText(createdAt)}.aaris.json';

  factory PharmacyBackup.parse(String input) {
    var text = input.trim().replaceFirst('\uFEFF', '');
    if (text.length > maxBackupCharacters) {
      throw const FormatException(
        'Backup is too large. Split imports or use a newer full backup.',
      );
    }
    if (text.startsWith('```')) {
      final firstLine = text.indexOf('\n');
      final end = text.lastIndexOf('```');
      if (firstLine < 0 || end <= firstLine) {
        throw const FormatException('The backup code block is incomplete.');
      }
      text = text.substring(firstLine + 1, end).trim();
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Choose a complete Aaris Pharmacy backup.');
    }

    final schema = decoded['schema'];
    final current = schema == pharmacyBackupSchema;
    final legacy = schema == legacyPharmacyBackupSchema;
    if (!current && !legacy) {
      throw const FormatException(
        'This is not a supported Aaris Pharmacy backup.',
      );
    }
    const payloadFields = {
      'createdAt',
      'sourceRevision',
      'settings',
      'medicines',
      'sales',
      'soldValue',
      'unknownSold',
    };
    final allowed = <String>{
      'schema',
      ...payloadFields,
      if (current) 'integrity',
    };
    if (decoded.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException(
        'This backup contains an unsupported field.',
      );
    }
    final integrity = decoded['integrity'];
    if (current &&
        (integrity is! String ||
            !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(integrity))) {
      throw const FormatException(
        'Backup integrity proof is missing or invalid.',
      );
    }

    final createdRaw = decoded['createdAt'];
    final createdAt = createdRaw is String
        ? DateTime.tryParse(createdRaw)
        : null;
    final revision = decoded['sourceRevision'];
    final medicinesRaw = decoded['medicines'];
    final salesRaw = decoded['sales'];
    final soldValue = decoded['soldValue'];
    final unknownSold = decoded['unknownSold'];
    if (createdAt == null ||
        revision is! int ||
        revision < 0 ||
        medicinesRaw is! List ||
        medicinesRaw.length > 50000 ||
        salesRaw is! List ||
        salesRaw.length > 200000 ||
        soldValue is! int ||
        soldValue < 0 ||
        soldValue > maxExactPaise ||
        unknownSold is! int ||
        unknownSold < 0) {
      throw const FormatException('The backup metadata is invalid.');
    }
    final settingsRaw = decoded['settings'];
    if (settingsRaw is! Map) {
      throw const FormatException('Backup settings are missing.');
    }
    final parsedSettings = WarningSettings.fromJson(
      Map<String, dynamic>.from(settingsRaw),
    );
    final records = <String, Medicine>{};
    for (var index = 0; index < medicinesRaw.length; index++) {
      final raw = medicinesRaw[index];
      if (raw is! Map) {
        throw FormatException('Medicine ${index + 1} is invalid.');
      }
      if (raw.keys.any((key) => !Medicine.storedFields.contains(key))) {
        throw FormatException(
          'Medicine ${index + 1} contains an unsupported field.',
        );
      }
      final record = Medicine.fromJson(Map<String, dynamic>.from(raw));
      if (records.containsKey(record.id)) {
        throw FormatException('Medicine ${index + 1} repeats an existing ID.');
      }
      records[record.id] = record;
    }
    final sales = <String, SaleEvent>{};
    for (var index = 0; index < salesRaw.length; index++) {
      final raw = salesRaw[index];
      if (raw is! Map) {
        throw FormatException('Sale ${index + 1} is invalid.');
      }
      if (raw.keys.any((key) => !SaleEvent.storedFields.contains(key))) {
        throw FormatException(
          'Sale ${index + 1} contains an unsupported field.',
        );
      }
      final sale = SaleEvent.fromJson(Map<String, dynamic>.from(raw));
      if (sales.containsKey(sale.id)) {
        throw FormatException('Sale ${index + 1} repeats an existing ID.');
      }
      if (!records.containsKey(sale.stockId)) {
        throw FormatException(
          'Sale ${index + 1} points to a missing stock entry.',
        );
      }
      sales[sale.id] = sale;
    }

    final backup = PharmacyBackup(
      createdAt: createdAt,
      sourceRevision: revision,
      settings: parsedSettings,
      records: Map.unmodifiable(records),
      sales: Map.unmodifiable(sales),
      soldValue: soldValue,
      unknownSold: unknownSold,
    );
    if (current) {
      final payload = backup._canonicalPayload();
      final expected =
          '$_backupIntegrityPrefix${backup._integrityDigest(payload)}';
      if (integrity != expected) {
        throw const FormatException(
          'Backup integrity check failed. The file is incomplete or has changed.',
        );
      }
    }
    return backup;
  }
}

class BackupReview {
  const BackupReview({required this.backup, required this.currentRevision});
  final PharmacyBackup backup;
  final int currentRevision;

  int get activeMedicines =>
      backup.records.values.where((record) => !record.archived).length;
  int get removedMedicines =>
      backup.records.values.where((record) => record.archived).length;
  int get sales => backup.sales.length;
}
