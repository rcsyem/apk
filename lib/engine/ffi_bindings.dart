import 'dart:ffi';
import 'package:ffi/ffi.dart';

typedef _LoadN = Int32 Function(Pointer<Utf8>, Int32, Int32, Pointer<Pointer<Void>>, Pointer<Utf8>, Int32);
typedef _LoadD = int Function(Pointer<Utf8>, int, int, Pointer<Pointer<Void>>, Pointer<Utf8>, int);
typedef _StartN = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>, Int32, Float, Int32, Pointer<Utf8>, Int32);
typedef _StartD = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>, int, double, int, Pointer<Utf8>, int);
typedef _NextN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Int32, Pointer<Int32>);
typedef _NextD = int Function(Pointer<Void>, Pointer<Uint8>, int, int, Pointer<Int32>);
typedef _ResultN = Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Utf8>, Int32);
typedef _ResultD = int Function(Pointer<Void>, Pointer<Int32>, Pointer<Utf8>, int);
typedef _VoidEngineN = Void Function(Pointer<Void>);
typedef _VoidEngineD = void Function(Pointer<Void>);
typedef _StatsN = Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>);
typedef _StatsD = int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>);
typedef _CountN = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>, Int32);
typedef _CountD = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>, int);
typedef _VersionN = Pointer<Utf8> Function();
typedef _VersionD = Pointer<Utf8> Function();

/// Result codes mirror native/include/lai_bridge.h.
class Lai {
  static const ok = 0, errFile = 1, errModel = 2, errContext = 3, errArgs = 4;
  static const errTemplate = 5, errTokenize = 6, errPromptTooLong = 7;
  static const errDecode = 8, errBusy = 9, errInternal = 10;
  static const nextInvalid = -1, nextTimeout = 0, nextPiece = 1, nextDone = 2, nextSmallBuffer = 3;
}

class LaiBindings {
  LaiBindings(DynamicLibrary lib)
      : load = lib.lookupFunction<_LoadN, _LoadD>('lai_load'),
        start = lib.lookupFunction<_StartN, _StartD>('lai_generate_start'),
        next = lib.lookupFunction<_NextN, _NextD>('lai_next'),
        result = lib.lookupFunction<_ResultN, _ResultD>('lai_result'),
        stop = lib.lookupFunction<_VoidEngineN, _VoidEngineD>('lai_stop'),
        stats = lib.lookupFunction<_StatsN, _StatsD>('lai_stats'),
        countTokens = lib.lookupFunction<_CountN, _CountD>('lai_count_prompt_tokens'),
        free = lib.lookupFunction<_VoidEngineN, _VoidEngineD>('lai_free'),
        version = lib.lookupFunction<_VersionN, _VersionD>('lai_version');

  final _LoadD load;
  final _StartD start;
  final _NextD next;
  final _ResultD result;
  final _VoidEngineD stop;
  final _StatsD stats;
  final _CountD countTokens;
  final _VoidEngineD free;
  final _VersionD version;
}
