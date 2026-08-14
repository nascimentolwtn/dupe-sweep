import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_group.dart';
import '../models/photo_item.dart';
import '../services/photo_scanner_service.dart';
import '../services/scan_cache_service.dart';
import '../services/similarity_service.dart';
import 'duplicate_review_screen.dart';

class ScanProgressScreen extends StatefulWidget {
  const ScanProgressScreen({Key? key}) : super(key: key);

  @override
  State<ScanProgressScreen> createState() => _ScanProgressScreenState();
}

class _ScanProgressScreenState extends State<ScanProgressScreen> {
  final ScanCacheService _cache = ScanCacheService();
  ScanCacheSummary? _resumeSummary;
  bool _checkingResume = true;
  bool _cancelled = false;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _checkForResume();
  }

  Future<void> _checkForResume() async {
    final summary = await _cache.peekSummary();

    // A save point that's already complete (nothing left to resume)
    // shouldn't normally be reachable -- a completed scan clears its own
    // cache -- but treat it defensively the same as "no save point".
    final usable = (summary != null &&
            summary.totalKnownAssets > 0 &&
            summary.processedCount < summary.totalKnownAssets)
        ? summary
        : null;

    if (!mounted) return;
    setState(() {
      _resumeSummary = usable;
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

    try {
      // Run scan on main thread to avoid isolate platform channel issues
      final photos = await PhotoScannerService.scanAllPhotos(
        cache: _cache,
        isCancelled: () => _cancelled,
        onProgress: (current, total, phase) {
          provider.updateProgress(current / total, '$phase: $current/$total');
        },
      );
      print('[SCAN] Found ${photos.length} photos');

      final withHash =
          photos.where((p) => p.dhash != null && p.dhash!.isNotEmpty).length;
      print('[SCAN] Computed hashes for $withHash photos');

      if (photos.isNotEmpty) {
        print(
            '[SCAN] First photo: ${photos.first.id}, hash: ${photos.first.dhash?.substring(0, 8)}...');
      }

      // Final unconditional checkpoint: covers the case where the last
      // partial batch never hit maybeCheckpoint's threshold.
      await _cache.flush();

      if (mounted) {
        // Group photos by rolling time window, then sub-group by hash similarity.
        final groups = buildPhotoGroups(photos);
        print('[SCAN] Created ${groups.length} groups');
        for (final g in groups) {
          print(
              '[GROUP] ${g.id}: ${g.photos.length} photos (type: ${g.groupType})');
        }
        provider.finishScan(groups);

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
      print('[SCAN] Cancelled by user');
      provider.cancelScan();
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
      print('Error during scan: $e');
      provider.cancelScan();
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

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan for Duplicates'),
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
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: provider.scanProgress,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${(provider.scanProgress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: Colors.grey),
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
          : Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.photo_library,
                    size: 64,
                    color: Colors.blue,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Ready to Scan',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _resumeSummary != null
                        ? 'A previous scan was interrupted. You can resume '
                            'where it left off or start over.'
                        : 'Tap the button below to scan your photo library for duplicates.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  if (_checkingResume)
                    const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (_resumeSummary != null) ...[
                    ElevatedButton.icon(
                      onPressed: () => _startScan(resume: true),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        'Resume scan (${_resumeSummary!.processedCount}/'
                        '${_resumeSummary!.totalKnownAssets} done)',
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _confirmStartOver,
                      child: const Text('Start over'),
                    ),
                  ] else
                    ElevatedButton.icon(
                      onPressed: () => _startScan(),
                      icon: const Icon(Icons.search),
                      label: const Text('Start Scan'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                    ),
                ],
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

      // Stopgap "best" pick: largest file size, already fetched for every
      // photo during Phase 1 metadata, zero extra cost. Without marking
      // *some* photo isBest, `PhotoGroup.selectAllNonBest()` (the "Select
      // All Non-Best" button) selects literally every photo in the group,
      // including the one you'd want to keep -- real sharpness/exposure
      // scoring (`ScoringService`, already implemented but not wired into
      // the scan pipeline) is the proper fix and remains a separate
      // backlog item; this only prevents the dangerous "select everything"
      // behavior in the meantime.
      subGroup.reduce((a, b) => b.fileSize > a.fileSize ? b : a).isBest = true;

      groups.add(PhotoGroup(
        id: 'group_$groupIndex',
        photos: subGroup,
        timestamp: subGroup.first.createDateTime,
        groupType: 'hash',
      ));
      groupIndex++;
    }
  }

  return groups;
}
