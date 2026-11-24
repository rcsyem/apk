import 'dart:convert';
import 'package:flutter/services.dart';

/// Fixed built-in catalog (no model browsing in the MVP).
/// An entry is downloadable ONLY when every verification field is present.
class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.name,
    required this.fileName,
    this.url,
    this.sizeBytes,
    this.sha256,
    this.license,
    this.verified = false,
  });
  final String id;
  final String name;
  final String fileName;
  final String? url;
  final int? sizeBytes;
  final String? sha256;
  final String? license;
  final bool verified;

  bool get downloadable =>
      verified &&
      url != null &&
      sizeBytes != null &&
      sizeBytes! > 0 &&
      sha256 != null &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256!);

  factory CatalogEntry.fromJson(Map<String, dynamic> j) => CatalogEntry(
        id: j['id'] as String,
        name: j['name'] as String,
        fileName: j['fileName'] as String,
        url: j['url'] as String?,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt(),
        sha256: j['sha256'] as String?,
        license: j['license'] as String?,
        verified: j['verified'] == true,
      );
}

class ModelCatalog {
  ModelCatalog(this.entries);
  final List<CatalogEntry> entries;

  static ModelCatalog parse(String jsonText) {
    final m = jsonDecode(jsonText) as Map<String, dynamic>;
    return ModelCatalog([
      for (final e in (m['models'] as List<dynamic>))
        CatalogEntry.fromJson(e as Map<String, dynamic>)
    ]);
  }

  static Future<ModelCatalog> loadFromAssets() async =>
      parse(await rootBundle.loadString('assets/model_catalog.json'));
}
