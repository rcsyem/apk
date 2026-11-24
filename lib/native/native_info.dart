import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

class MemorySnapshot {
  const MemorySnapshot({
    required this.totalBytes,
    required this.availableBytes,
    required this.thresholdBytes,
    required this.lowMemory,
  });
  final int totalBytes;
  final int availableBytes;
  /// Android's low-memory threshold (ActivityManager.MemoryInfo.threshold); 0 if unknown.
  final int thresholdBytes;
  final bool lowMemory;
}

/// Native Android integration surface. Abstract so logic can be tested with fakes.
abstract class NativeInfo {
  Future<MemorySnapshot> memorySnapshot();
  Future<int?> freeStorageBytes(String path);
  Future<int?> processRssBytes();
  /// ComponentCallbacks2 trim levels forwarded from the Activity.
  Stream<int> get trimMemoryLevels;
}

class AndroidNativeInfo implements NativeInfo {
  AndroidNativeInfo() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'trimMemory' && call.arguments is int) {
        _trim.add(call.arguments as int);
      }
    });
  }
  static const MethodChannel _ch = MethodChannel('app.localai/native');
  final StreamController<int> _trim = StreamController<int>.broadcast();

  @override
  Stream<int> get trimMemoryLevels => _trim.stream;

  @override
  Future<MemorySnapshot> memorySnapshot() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('memoryInfo');
      if (m != null) {
        return MemorySnapshot(
          totalBytes: (m['total'] as num).toInt(),
          availableBytes: (m['avail'] as num).toInt(),
          thresholdBytes: (m['threshold'] as num?)?.toInt() ?? 0,
          lowMemory: m['low'] == true,
        );
      }
    } catch (_) {/* fall back to /proc/meminfo */}
    return procMemInfoSnapshot();
  }

  @override
  Future<int?> freeStorageBytes(String path) async {
    try {
      final v = await _ch.invokeMethod<num>('freeStorage', {'path': path});
      return v?.toInt();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> processRssBytes() async {
    try {
      return parseVmRssBytes(await File('/proc/self/status').readAsString());
    } catch (_) {
      return null;
    }
  }
}

/// Parses /proc/meminfo text. Values there are in kB.
MemorySnapshot parseMemInfo(String text) {
  int kb(String key) {
    final m = RegExp('^$key:\\s+(\\d+)\\s*kB', multiLine: true).firstMatch(text);
    return m == null ? 0 : int.parse(m.group(1)!) * 1024;
  }
  final total = kb('MemTotal');
  var avail = kb('MemAvailable');
  if (avail == 0) avail = kb('MemFree') + kb('Cached');
  return MemorySnapshot(totalBytes: total, availableBytes: avail, thresholdBytes: 0, lowMemory: false);
}

int? parseVmRssBytes(String statusText) {
  final m = RegExp(r'^VmRSS:\s+(\d+)\s*kB', multiLine: true).firstMatch(statusText);
  return m == null ? null : int.parse(m.group(1)!) * 1024;
}

Future<MemorySnapshot> procMemInfoSnapshot() async =>
    parseMemInfo(await File('/proc/meminfo').readAsString());
