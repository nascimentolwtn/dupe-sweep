import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_group.dart';
import '../models/photo_item.dart';
import '../models/scan_mode.dart';
import '../services/blur_scan_service.dart';
import '../services/large_file_scan_service.dart';
import '../services/photo_scanner_service.dart';
import '../services/scan_cache_service.dart';
import '../services/similarity_service.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_button.dart';
import 'duplicate_review_screen.dart';
import 'flagged_photo_review_screen.dart';
import 'home_screen.dart';

class ScanProgressScreen extends StatefulWidget {
  final ScanMode mode;

  const ScanProgressScreen({super.key, required this.mode});

  @override
  State<ScanProgressScreen> createState() => _ScanProgressScreenState();
}

class _ScanProgressScreenState extends State<ScanProgressScreen> {
  final ScanCacheService _cache = ScanCacheService();
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _tickTimer;
  // Snapshot of scan progress, refreshed twice a second by _tickTimer
  // rather than on every scan callback (which can fire many times a
  // second) -- keeps the elapsed/remaining-time estimate updating at a
  // steady cadence instead of jittering with every processed photo.
  double _progressForEstimate = 0.0;
  ScanCacheSummary? _resumeSummary;
  bool _checkingResume = true;
  bool _cancelled = false;
  bool _cancelling = false;
  // Set synchronously as the very first thing _startScan does, before any
  // `await`. provider.isScanning isn't enough on its own to prevent a
  // double-start: it only flips true partway through _startScan (after
  // `await _cache.clear()` on the start-over path), so a second tap
  // landing in that gap would see isScanning still false and start a
  // second concurrent scan sharing the same _cache/_stopwatch/_tickTimer.
  bool _isStarting = false;

  // Album-scoping (napkin backlog #8): defaults to null, which
  // PhotoScannerService.scanAllPhotos treats as "all photos" (its existing
  // behavior). Only offered on a fresh scan, not a resume -- a resumed scan
  // continues whatever album the interrupted run already started against.
  // Duplicates-only: blurry/large-file scans always cover the whole
  // library by design (there's no "keep the best of this album" concept
  // for either).
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _selectedAlbum;
  bool _loadingAlbums = true;

  bool get _isDuplicatesMode => widget.mode == ScanMode.duplicates;

  @override
  void initState() {
    super.initState();
    if (_isDuplicatesMode) {
      _checkForResume();
      _loadAlbums();
    } else {
      // Resume/album-scoping (ScanCacheService-backed) only applies to the
      // duplicate scan -- see PhotoScannerService's cache-backed Phase 2 vs
      // BlurScanService/LargeFileScanService's simpler single-pass scans.
      _checkingResume = false;
      _loadingAlbums = false;
    }
  }

  Future<void> _loadAlbums() async {
    try {
      final albums = await PhotoScannerService.getAlbumList();
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _loadingAlbums = false;
      });
    } catch (e) {
      debugPrint('[ScanProgress] Error loading albums: $e');
      if (mounted) setState(() => _loadingAlbums = false);
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  void _startTiming() {
    _stopwatch
      ..reset()
      ..start();
    _progressForEstimate = 0.0;
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {
        _progressForEstimate = context.read<AppStateProvider>().scanProgress;
      });
    });
  }

  void _stopTiming() {
    _stopwatch.stop();
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Elapsed time plus a rough remaining-time estimate extrapolated from
  /// elapsed/progress. Needs a couple seconds of real progress before the
  /// extrapolation is stable enough to show.
  String _elapsedAndEstimateLabel(double progress) {
    final elapsed = _stopwatch.elapsed;
    final elapsedStr = _formatDuration(elapsed);
    if (progress <= 0.02 || elapsed.inSeconds < 2) {
      return 'Elapsed $elapsedStr · Estimating time remaining…';
    }
    final totalEstimate = elapsed * (1 / progress);
    final remaining = totalEstimate - elapsed;
    if (remaining.isNegative) {
      return 'Elapsed $elapsedStr';
    }
    return 'Elapsed $elapsedStr · About ${_formatDuration(remaining)} remaining';
  }

  Future<void> _checkForResume() async {
    final summary = await _cache.peekSummary();

    // peekSummary() already returns null for a genuinely empty/nonexistent
    // cache, so its non-null result alone means real cached work exists.
    // This used to additionally require processedCount < totalKnownAssets
    // as a "not already complete" safety net -- but totalKnownAssets is
    // just whatever candidate count the interrupted run last stored, and
    // if the live photo library shrinks afterward (the user deletes
    // photos before relaunching), a stale/smaller totalKnownAssets could
    // make that comparison false and silently suppress a perfectly usable
    // resume offer, discarding real completed hashing work for no reason.
    if (!mounted) return;
    setState(() {
      _resumeSummary = summary;
      _checkingResume = false;
    });
  }

  Future<void> _confirmStartOver() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text(
          'This discards progress from the interrupted scan and rescans '
          'your entire photo library from the beginning.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Start Over'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _startScan(resume: false);
    }
  }

  Future<void> _startScan({bool resume = true}) async {
    if (_isStarting) return;
    _isStarting = true;
    try {
      await _startScanInner(resume: resume);
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _startScanInner({required bool resume}) async {
    switch (widget.mode) {
      case ScanMode.duplicates:
        await _runDuplicateScan(resume: resume);
      case ScanMode.blurry:
        await _runBlurScan();
      case ScanMode.largeFiles:
        await _runLargeFileScan();
    }
  }

  Future<void> _runDuplicateScan({required bool resume}) async {
    final provider = context.read<AppStateProvider>();

    if (!resume) {
      await _cache.clear();
      if (mounted) {
        setState(() {
          _resumeSummary = null;
        });
      }
    }

    setState(() {
      _cancelled = false;
      _cancelling = false;
    });
    provider.startScan();
    _startTiming();

    try {
      // Run scan on main thread to avoid isolate platform channel issues
      final photos = await PhotoScannerService.scanAllPhotos(
        cache: _cache,
        isCancelled: () => _cancelled,
        album: _selectedAlbum,
        onProgress: (current, total, phase) {
          provider.updateProgress(current / total, '$phase: $current/$total');
        },
      );
      debugPrint('[SCAN] Found ${photos.length} photos');

      final withHash =
          photos.where((p) => p.dhash != null && p.dhash!.isNotEmpty).length;
      debugPrint('[SCAN] Computed hashes for $withHash photos');

      if (photos.isNotEmpty) {
        debugPrint(
            '[SCAN] First photo: ${photos.first.id}, hash: ${photos.first.dhash?.substring(0, 8)}...');
      }

      // Final unconditional checkpoint: covers the case where the last
      // partial batch never hit maybeCheckpoint's threshold.
      await _cache.flush();

      if (mounted) {
        // Group photos by rolling time window, then sub-group by hash similarity.
        final groups = buildPhotoGroups(photos);
        debugPrint('[SCAN] Created ${groups.length} groups');
        for (final g in groups) {
          debugPrint(
              '[GROUP] ${g.id}: ${g.photos.length} photos (type: ${g.groupType})');
        }
        provider.finishScan(groups);
        _stopTiming();

        // A finished scan shouldn't leave behind a "resume" prompt next
        // launch -- the cache only bridges an interrupted scan.
        await _cache.clear();

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => const DuplicateReviewScreen(),
            ),
          );
        }
      }
    } on ScanCancelledException {
      debugPrint('[SCAN] Cancelled by user');
      provider.cancelScan();
      _stopTiming();
      // The scanner already flushed the cache before throwing, so re-check
      // for a resumable save point rather than assuming none exists.
      await _checkForResume();
      if (mounted) {
        setState(() {
          _cancelled = false;
          _cancelling = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Scan cancelled')),
        );
      }
    } catch (e) {
      debugPrint('Error during scan: $e');
      provider.cancelScan();
      _stopTiming();
      // scanAllPhotos now rethrows instead of swallowing real failures, so
      // this path no longer runs after the cache/checkpoint has been
      // cleared -- any progress the failed run made (periodic checkpoints
      // during hashing) is still on disk. Re-check so the user is offered
      // resume rather than being silently pushed into a full rescan.
      await _checkForResume();
      if (mounted) {
        setState(() {
          _cancelled = false;
          _cancelling = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan error: $e')),
        );
      }
    }
  }

  Future<void> _runBlurScan() async {
    final provider = context.read<AppStateProvider>();
    setState(() {
      _cancelled = false;
      _cancelling = false;
    });
    provider.startScan();
    _startTiming();

    try {
      final photos = await BlurScanService.scanBlurryPhotos(
        isCancelled: () => _cancelled,
        onProgress: (current, total) {
          provider.updateProgress(
            total == 0 ? 0 : current / total,
            'Checking sharpness: $current/$total',
          );
        },
      );
      debugPrint('[BlurScan] Flagged ${photos.length} blurry photos');

      if (mounted) {
        provider.finishBlurScan(photos);
        _stopTiming();
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => FlaggedPhotoReviewScreen.forMode(ScanMode.blurry),
          ),
        );
      }
    } on ScanCancelledException {
      debugPrint('[BlurScan] Cancelled by user');
      provider.cancelScan();
      _stopTiming();
      if (mounted) {
        setState(() {
          _cancelled = false;
          _cancelling = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Scan cancelled')),
        );
      }
    } catch (e) {
      debugPrint('Error during blur scan: $e');
      provider.cancelScan();
      _stopTiming();
      if (mounted) {
        setState(() {
          _cancelled = false;
          _cancelling = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan error: $e')),
        );
      }
    }
  }

  Future<void> _runLargeFileScan() async {
    final provider = context.read<AppStateProvider>();
    setState(() {
      _cancelled = false;
      _cancelling = false;
    });
    provider.startScan();
    _startTiming();

    try {
      final photos = await LargeFileScanService.scanLargeFiles(
        isCancelled: () => _cancelled,
        onProgress: (current, total) {
          provider.updateProgress(
            total == 0 ? 0 : current / total,
            'Checking file sizes: $current/$total',
          );
        },
      );
      debugPrint('[LargeFileScan] Flagged ${photos.length} large files');

      if (mounted) {
        provider.finishLargeFileScan(photos);
        _stopTiming();
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) =>
                FlaggedPhotoReviewScreen.forMode(ScanMode.largeFiles),
          ),
        );
      }
    } on ScanCancelledException {
      debugPrint('[LargeFileScan] Cancelled by user');
      provider.cancelScan();
      _stopTiming();
      if (mounted) {
        setState(() {
          _cancelled = false;
          _cancelling = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Scan cancelled')),
        );
      }
    } catch (e) {
      debugPrint('Error during large-file scan: $e');
      provider.cancelScan();
      _stopTiming();
      if (mounted) {
        setState(() {
          _cancelled = false;
          _cancelling = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan error: $e')),
        );
      }
    }
  }

  void _cancelScan() {
    setState(() {
      _cancelled = true;
      _cancelling = true;
    });
  }

  /// Every route that lands here does so via `pushReplacement` (a fresh
  /// scan from `HomeScreen`'s buttons is the only exception, but going
  /// through `HomeScreen` again is harmless there too) -- so `Navigator.
  /// pop` has nothing left to pop to on the resume-into-saved-review path
  /// (`PermissionScreen` -> `DuplicateReviewScreen` -> here via "Re-scan"),
  /// which otherwise strands the user on this screen with no way back to
  /// the mode-select menu, even after force-killing the app. Clears the
  /// whole stack rather than pushing, so repeated visits don't pile up
  /// HomeScreen copies underneath.
  void _goHome() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mode.appBarTitle),
        // Hidden mid-scan: this screen's async scan methods check `mounted`
        // before touching state, so navigating away while one is in flight
        // would silently strand `provider.isScanning` at true instead of
        // ever reaching finishScan/cancelScan. `_cancelScan` is the correct
        // way off this screen while scanning.
        leading: provider.isScanning
            ? null
            : IconButton(
                icon: const Icon(Icons.home),
                tooltip: 'Home',
                onPressed: _goHome,
              ),
      ),
      body: provider.isScanning
          ? Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text(
                    provider.scanStatus ?? 'Scanning...',
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: provider.scanProgress,
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${(provider.scanProgress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _elapsedAndEstimateLabel(_progressForEstimate),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextButton.icon(
                    onPressed: _cancelling ? null : _cancelScan,
                    icon: const Icon(Icons.close),
                    label: Text(_cancelling ? 'Cancelling...' : 'Cancel'),
                  ),
                ],
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                // Ready-to-scan content (icon, description, album dropdown,
                // resume/start buttons) was in a plain centered Column with
                // no scroll wrapper -- fine most of the time, but a long
                // album name list, larger system font scaling, or a short
                // landscape viewport can push it past the available height
                // and clip the Start Scan button with no way to reach it.
                // ConstrainedBox keeps the Column vertically centered when
                // everything fits, and only turns scrollable once it
                // doesn't.
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ShaderMask(
                          shaderCallback: (bounds) =>
                              AppColors.accentGradient.createShader(bounds),
                          child: const Icon(
                            Icons.diamond_outlined,
                            size: 64,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Ready to Scan',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _resumeSummary != null
                              ? 'A previous scan was interrupted. You can resume '
                                  'where it left off or start over.'
                              : widget.mode.readyDescription,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 32),
                        if (_isDuplicatesMode &&
                            _resumeSummary == null &&
                            !_loadingAlbums &&
                            _albums.isNotEmpty) ...[
                          DropdownButtonFormField<AssetPathEntity?>(
                            initialValue: _selectedAlbum,
                            // Without this, the dropdown button's Row (selected
                            // item + arrow icon) sizes to its content's intrinsic
                            // width instead of the available width -- so the
                            // DropdownMenuItem children's `overflow:
                            // TextOverflow.ellipsis` never has a width constraint
                            // to actually clip against, and a long album name
                            // pushes the Row past the field's bounds (Flutter's
                            // debug-mode "RIGHT OVERFLOWED BY N PIXELS" banner).
                            // isExpanded makes the button and its items fill the
                            // field's width so ellipsis has something to clip to.
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Album',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              const DropdownMenuItem<AssetPathEntity?>(
                                value: null,
                                child: Text(
                                  'All Photos',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ..._albums.map(
                                (a) => DropdownMenuItem<AssetPathEntity?>(
                                  value: a,
                                  child: Text(a.name,
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ),
                            ],
                            onChanged: (value) =>
                                setState(() => _selectedAlbum = value),
                          ),
                          const SizedBox(height: 20),
                        ],
                        if (_checkingResume)
                          const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else if (_resumeSummary != null) ...[
                          GradientButton(
                            onPressed: () => _startScan(resume: true),
                            icon: Icons.play_arrow,
                            label:
                                'Resume scan (${_resumeSummary!.processedCount}/'
                                '${_resumeSummary!.totalKnownAssets} done)',
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _confirmStartOver,
                            child: const Text('Start over'),
                          ),
                        ] else
                          GradientButton(
                            onPressed: () => _startScan(),
                            icon: Icons.search,
                            label: 'Start Scan',
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Build review groups from a sorted photo list: cluster by rolling time
/// window via [SimilarityService.clusterByTime], then sub-group each
/// cluster by perceptual hash similarity via
/// [SimilarityService.groupBySimilarity]. Top-level (no State/BuildContext
/// dependency) so it can be unit-tested directly.
///
/// Clusters/sub-groups of exactly one photo are dropped: there's nothing to
/// compare a lone photo against, so it can never be a "which one do I keep"
/// decision for the review screen -- matching `python-mvp1`'s reference
/// behavior (`cluster_by_time`/`split_by_similarity` both filter to
/// `len > 1`), which the Dart port had drifted from.
List<PhotoGroup> buildPhotoGroups(List<PhotoItem> photos) {
  final groups = <PhotoGroup>[];
  int groupIndex = 0;

  final clusters = SimilarityService.clusterByTime(photos);

  for (final cluster in clusters) {
    if (cluster.length == 1) continue;

    final photoHashes = {
      for (final p in cluster)
        if (p.dhash != null && p.dhash!.isNotEmpty) p.id: p.dhash!,
    };

    final subGroups = SimilarityService.groupBySimilarity(
      cluster,
      photoHashes: photoHashes,
    );

    for (final subGroup in subGroups) {
      if (subGroup.length == 1) continue;

      final group = PhotoGroup(
        id: 'group_$groupIndex',
        photos: subGroup,
        timestamp: subGroup.first.createDateTime,
        groupType: 'hash',
      );
      // Stopgap "best" pick: largest file size, already fetched for every
      // photo during Phase 1 metadata, zero extra cost. Without marking
      // *some* photo isBest, `PhotoGroup.selectAllNonBest()` (the "Select
      // All Non-Best" button) selects literally every photo in the group,
      // including the one you'd want to keep -- real sharpness/exposure
      // scoring (`ScoringService`, already implemented but not wired into
      // the scan pipeline) is the proper fix and remains a separate
      // backlog item; this only prevents the dangerous "select everything"
      // behavior in the meantime. Shared with `AppStateProvider.
      // removeDeletedPhotos`, which re-runs this after a group loses its
      // isBest photo to deletion.
      group.ensureBestElected();

      groups.add(group);
      groupIndex++;
    }
  }

  return groups;
}
