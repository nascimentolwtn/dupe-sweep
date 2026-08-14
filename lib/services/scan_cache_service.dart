import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Schema version for the on-disk scan cache. Bumped only if the entry
/// shape changes; a mismatched version on load is treated as "no usable
/// cache" rather than attempting a lossy migration.
const int _kScanCacheVersion = 1;
const String _kScanCacheFileName = 'scan_cache.json';

/// The subset of `PhotoItem` fields cheap/safe to persist across scans.
/// `path` is intentionally excluded (see scan-save-points.md) -- it's cheap
/// to re-fetch live from `AssetEntity.relativePath` and can legitimately
/// change between sessions.
class CachedPhotoData {
  final String? dhash;
  final int createDateTimeMillis;
  final int fileSize;

  const CachedPhotoData({
    this.dhash,
    required this.createDateTimeMillis,
    required this.fileSize,
  });

  Map<String, dynamic> toJson() => {
        'dhash': dhash,
        'createDateTimeMillis': createDateTimeMillis,
        'fileSize': fileSize,
      };

  factory CachedPhotoData.fromJson(Map<String, dynamic> json) {
    return CachedPhotoData(
      dhash: json['dhash'] as String?,
      createDateTimeMillis: json['createDateTimeMillis'] as int,
      fileSize: json['fileSize'] as int,
    );
  }
}

/// Cheap summary of an existing save point, used to drive the "Resume scan"
/// prompt without reconstructing every cached `PhotoItem`.
class ScanCacheSummary {
  final int processedCount;
  final int totalKnownAssets;
  final int updatedAtMillis;

  const ScanCacheSummary({
    required this.processedCount,
    required this.totalKnownAssets,
    required this.updatedAtMillis,
  });
}

/// Durable, incremental save point for `PhotoScannerService.scanAllPhotos`.
///
/// Owns an in-memory map of already-processed assets (keyed by
/// `AssetEntity.id`) plus periodic checkpointing of that map to a JSON file
/// in app-private storage, so an interrupted scan can resume without
/// re-hashing photos already handled. See `.claude/plans/scan-save-points.md`
/// for the full design rationale.
///
/// `recordProcessed` is a synchronous in-memory upsert, safe to call from
/// any completion callback regardless of ordering or concurrency; the
/// actual disk write only happens in [maybeCheckpoint]/[flush], which write
/// to a temp file and rename over the real file so a kill mid-write can
/// never leave a half-written `scan_cache.json` behind.
class ScanCacheService {
  /// Directory the cache file lives in. Injectable for testability;
  /// defaults to the platform app-support directory in production.
  final Directory? _injectedDirectory;

  ScanCacheService({Directory? directory}) : _injectedDirectory = directory;

  final Map<String, CachedPhotoData> _entries = {};
  int _totalKnownAssets = 0;
  int _updatedAtMillis = 0;
  int _entriesSinceLastFlush = 0;
  DateTime? _lastFlushTime;
  bool _loaded = false;

  /// Guards against concurrent [flush] calls. `PhotoScannerService` calls
  /// [maybeCheckpoint] from up to 16 concurrently-running futures per
  /// batch (see `_kScanConcurrency`); since [recordProcessed] is
  /// synchronous, several of those futures can see the checkpoint
  /// threshold crossed in the same tick and all call [flush] before any
  /// of them finishes. Without this guard, concurrent flushes race on the
  /// same `scan_cache.json.tmp` path -- one call's `rename` removes the
  /// temp file out from under another's, surfacing as a
  /// `PathNotFoundException` on real devices (never seen in single-call
  /// unit tests). A caller that arrives mid-flush just awaits the
  /// in-flight write instead of starting a redundant, colliding one; any
  /// entries recorded too late to make that snapshot are picked up by the
  /// next periodic checkpoint or the unconditional flush at scan end, so
  /// this stays safe under the existing "eventually persisted" contract.
  Future<void>? _inFlightFlush;

  /// Read accessor for already-processed data (used by the scanner to skip
  /// work and by resume-summary UI).
  Map<String, CachedPhotoData> get cachedEntries => Map.unmodifiable(_entries);

  /// Whether [load] has already been called on this instance. Callers that
  /// already loaded (e.g. via [peekSummary]) can skip a redundant reload.
  bool get isLoaded => _loaded;

  int get totalKnownAssets => _totalKnownAssets;

  Future<Directory> _resolveDirectory() async {
    if (_injectedDirectory != null) return _injectedDirectory!;
    return getApplicationSupportDirectory();
  }

  Future<File> _cacheFile() async {
    final dir = await _resolveDirectory();
    return File('${dir.path}/$_kScanCacheFileName');
  }

  Future<File> _tempFile() async {
    final dir = await _resolveDirectory();
    return File('${dir.path}/$_kScanCacheFileName.tmp');
  }

  /// Loads `scan_cache.json` (if present) into the in-memory map. Any parse
  /// failure, malformed shape, or `version` mismatch is treated as an empty
  /// cache -- logged, never thrown -- so a corrupt file can never crash the
  /// scan screen.
  Future<void> load() async {
    _entries.clear();
    _totalKnownAssets = 0;
    _updatedAtMillis = 0;
    _entriesSinceLastFlush = 0;
    _lastFlushTime = DateTime.now();
    _loaded = true;

    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;

      final contents = await file.readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic>) {
        print('[ScanCache] Cache file is not a JSON object, ignoring.');
        return;
      }

      final version = decoded['version'];
      if (version != _kScanCacheVersion) {
        print('[ScanCache] Cache version mismatch ($version), ignoring.');
        return;
      }

      final entries = decoded['entries'];
      if (entries is! Map<String, dynamic>) {
        print('[ScanCache] Cache entries missing/invalid, ignoring.');
        return;
      }

      for (final entry in entries.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        try {
          _entries[entry.key] = CachedPhotoData.fromJson(value);
        } catch (e) {
          print('[ScanCache] Skipping malformed entry ${entry.key}: $e');
        }
      }

      _totalKnownAssets =
          (decoded['totalKnownAssets'] as int?) ?? _entries.length;
      _updatedAtMillis = (decoded['updatedAtMillis'] as int?) ?? 0;

      print('[ScanCache] Loaded ${_entries.length} cached entries.');
    } catch (e) {
      print('[ScanCache] Failed to load cache, starting fresh: $e');
      _entries.clear();
      _totalKnownAssets = 0;
      _updatedAtMillis = 0;
    }
  }

  /// Records how many assets the current live scan knows about, so
  /// checkpoints/summaries report an up-to-date total even if the library
  /// changed since the last save point.
  void setTotalKnownAssets(int count) {
    _totalKnownAssets = count;
  }

  /// In-memory upsert of one processed asset. Cheap and safe to call from
  /// any completion callback (sequential loop body, `Future.wait` batch
  /// callback, isolate result listener) regardless of ordering.
  void recordProcessed(String assetId, CachedPhotoData data) {
    _entries[assetId] = data;
    _entriesSinceLastFlush++;
  }

  /// Flushes the in-memory map to disk if either `everyN` new entries have
  /// accumulated since the last flush, or `everyDuration` wall-clock time
  /// has elapsed -- whichever comes first. Cheap no-op check otherwise.
  Future<void> maybeCheckpoint({
    int everyN = 100,
    Duration everyDuration = const Duration(seconds: 5),
  }) async {
    final lastFlush = _lastFlushTime;
    final elapsed = lastFlush == null
        ? everyDuration
        : DateTime.now().difference(lastFlush);

    if (_entriesSinceLastFlush >= everyN || elapsed >= everyDuration) {
      await flush();
    }
  }

  /// Unconditional write-temp-then-rename of the whole in-memory map to
  /// disk. Safe to call concurrently -- see [_inFlightFlush].
  Future<void> flush() {
    final inFlight = _inFlightFlush;
    if (inFlight != null) return inFlight;

    final future = _doFlush();
    _inFlightFlush = future;
    return future.whenComplete(() {
      _inFlightFlush = null;
    });
  }

  Future<void> _doFlush() async {
    _updatedAtMillis = DateTime.now().millisecondsSinceEpoch;

    final payload = {
      'version': _kScanCacheVersion,
      'totalKnownAssets': _totalKnownAssets,
      'updatedAtMillis': _updatedAtMillis,
      'entries': {
        for (final entry in _entries.entries) entry.key: entry.value.toJson(),
      },
    };

    try {
      final dir = await _resolveDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final tempFile = await _tempFile();
      await tempFile.writeAsString(jsonEncode(payload), flush: true);

      final targetFile = await _cacheFile();
      await tempFile.rename(targetFile.path);

      _entriesSinceLastFlush = 0;
      _lastFlushTime = DateTime.now();
    } catch (e) {
      print('[ScanCache] Failed to write cache checkpoint: $e');
    }
  }

  /// Deletes the cache file (and resets in-memory state). Used by
  /// "Start over" and by successful scan completion -- a finished scan
  /// shouldn't leave behind a "resume" prompt next launch.
  Future<void> clear() async {
    _entries.clear();
    _totalKnownAssets = 0;
    _updatedAtMillis = 0;
    _entriesSinceLastFlush = 0;
    _lastFlushTime = DateTime.now();
    _loaded = true;

    try {
      final file = await _cacheFile();
      if (await file.exists()) {
        await file.delete();
      }
      final tempFile = await _tempFile();
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (e) {
      print('[ScanCache] Failed to delete cache file: $e');
    }
  }

  /// Cheap read for the UI resume prompt. Returns `null` if no usable cache
  /// exists. Reuses [load] internally -- reading a few thousand small JSON
  /// entries is fast, no need for a separate lightweight parse path unless
  /// profiling later says otherwise.
  Future<ScanCacheSummary?> peekSummary() async {
    await load();
    if (_entries.isEmpty) return null;
    return ScanCacheSummary(
      processedCount: _entries.length,
      totalKnownAssets: _totalKnownAssets,
      updatedAtMillis: _updatedAtMillis,
    );
  }
}
