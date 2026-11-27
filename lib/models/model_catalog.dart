import 'dart:convert';
import 'package:flutter/services.dart';

/// Fixed built-in catalog for approved models.
/// An entry is downloadable ONLY when verified with complete fields and a valid SHA-256.
class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.name,
    required this.fileName,
    this.description = '',
    this.family = '',
    this.version = '1.0',
    this.url,
    this.sizeBytes,
    this.sha256,
    this.license,
    this.licenseUrl,
    this.quantization = 'Q4_K_M',
    this.ggufVersion = 3,
    this.chatTemplate = 'chatml',
    this.contextLength = 4096,
    this.minRamGb = 4,
    this.recommendedRamGb = 8,
    this.modelStatus = 'available',
    this.verificationStatus = 'verified',
    this.verified = false,
  });

  final String id;
  final String name;
  final String fileName;
  final String description;
  final String family;
  final String version;
  final String? url;
  final int? sizeBytes;
  final String? sha256;
  final String? license;
  final String? licenseUrl;
  final String quantization;
  final int ggufVersion;
  final String chatTemplate;
  final int contextLength;
  final int minRamGb;
  final int recommendedRamGb;
  final String modelStatus;
  final String verificationStatus;
  final bool verified;

  /// Whether the file is directly downloadable via verified public URL and checksum.
  bool get downloadable =>
      verified &&
      url != null &&
      sizeBytes != null &&
      sizeBytes! > 0 &&
      sha256 != null &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256!);

  /// Whether this model requires Hugging Face authentication or local manual import.
  bool get isGated =>
      verificationStatus == 'requiresAuth' || modelStatus == 'gated';

  /// Whether the source and model integrity are officially verified.
  bool get isVerified => verificationStatus == 'verified';

  String get ramRequirementSummary =>
      'الحد الأدنى: ${minRamGb}GB RAM • الموصى به: ${recommendedRamGb}GB RAM';

  factory CatalogEntry.fromJson(Map<String, dynamic> j) => CatalogEntry(
        id: j['id'] as String,
        name: j['name'] as String,
        fileName: j['fileName'] as String,
        description: j['description'] as String? ?? '',
        family: j['family'] as String? ?? '',
        version: j['version'] as String? ?? '1.0',
        url: j['url'] as String?,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt(),
        sha256: j['sha256'] as String?,
        license: j['license'] as String?,
        licenseUrl: j['licenseUrl'] as String?,
        quantization: j['quantization'] as String? ?? 'Q4_K_M',
        ggufVersion: (j['ggufVersion'] as num?)?.toInt() ?? 3,
        chatTemplate: j['chatTemplate'] is Map
            ? ((j['chatTemplate'] as Map)['family'] as String? ?? 'chatml')
            : (j['chatTemplate'] as String? ?? 'chatml'),
        contextLength: (j['contextLength'] as num?)?.toInt() ?? 4096,
        minRamGb: (j['minRamGb'] as num?)?.toInt() ?? 4,
        recommendedRamGb: (j['recommendedRamGb'] as num?)?.toInt() ?? 8,
        modelStatus: j['modelStatus'] as String? ?? 'available',
        verificationStatus: j['verificationStatus'] as String? ?? 'verified',
        verified: j['verified'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'fileName': fileName,
        'description': description,
        'family': family,
        'version': version,
        'url': url,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        'license': license,
        'licenseUrl': licenseUrl,
        'quantization': quantization,
        'ggufVersion': ggufVersion,
        'chatTemplate': chatTemplate,
        'contextLength': contextLength,
        'minRamGb': minRamGb,
        'recommendedRamGb': recommendedRamGb,
        'modelStatus': modelStatus,
        'verificationStatus': verificationStatus,
        'verified': verified,
      };
}

class ModelCatalog {
  ModelCatalog(this.entries);
  final List<CatalogEntry> entries;

  CatalogEntry? findById(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

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
