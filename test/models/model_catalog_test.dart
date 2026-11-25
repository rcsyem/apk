import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/models/model_catalog.dart';

void main() {
  group('ModelCatalog & CatalogEntry Tests', () {
    test('parses the approved 5-model catalog from JSON file', () async {
      final file = File('assets/model_catalog.json');
      expect(await file.exists(), isTrue);
      final catalog = ModelCatalog.parse(await file.readAsString());

      expect(catalog.entries.length, 5);

      final rightnow = catalog.findById('rightnow-arabic-0.5b-turbo-q4_k_m');
      expect(rightnow, isNotNull);
      expect(rightnow!.name, contains('RightNow-Arabic'));
      expect(rightnow.downloadable, isTrue);
      expect(rightnow.minRamGb, 2);
      expect(rightnow.quantization, 'Q4_K_M');
      expect(rightnow.sha256, isNotNull);
      expect(rightnow.sha256!.length, 64);

      final qwen06 = catalog.findById('qwen3-0.6b-q4_k_m');
      expect(qwen06, isNotNull);
      expect(qwen06!.downloadable, isTrue);
      expect(qwen06.family, 'Qwen3');

      final qwen17 = catalog.findById('qwen3-1.7b-q4_k_m');
      expect(qwen17, isNotNull);
      expect(qwen17!.downloadable, isTrue);

      final qwen4b = catalog.findById('qwen3-4b-q4_k_m');
      expect(qwen4b, isNotNull);
      expect(qwen4b!.downloadable, isTrue);
      expect(qwen4b.minRamGb, 6);
      expect(qwen4b.recommendedRamGb, 8);

      final jais = catalog.findById('jais-2-8b-chat-q4_k_m');
      expect(jais, isNotNull);
      expect(jais!.name, contains('Jais-2-8B-Chat'));
      expect(jais.isGated, isTrue);
      expect(jais.downloadable, isFalse); // Gated model has no unauthenticated public URL or SHA-256 yet
      expect(jais.recommendedRamGb, 16);
    });

    test('validates downloadability requirements strictly', () {
      const validEntry = CatalogEntry(
        id: 'test',
        name: 'Test',
        fileName: 'test.gguf',
        url: 'https://example.com/test.gguf',
        sizeBytes: 1000,
        sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        verified: true,
      );
      expect(validEntry.downloadable, isTrue);

      const unverified = CatalogEntry(
        id: 'test',
        name: 'Test',
        fileName: 'test.gguf',
        url: 'https://example.com/test.gguf',
        sizeBytes: 1000,
        sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        verified: false,
      );
      expect(unverified.downloadable, isFalse);

      const badHash = CatalogEntry(
        id: 'test',
        name: 'Test',
        fileName: 'test.gguf',
        url: 'https://example.com/test.gguf',
        sizeBytes: 1000,
        sha256: 'short-hash',
        verified: true,
      );
      expect(badHash.downloadable, isFalse);
    });
  });
}
