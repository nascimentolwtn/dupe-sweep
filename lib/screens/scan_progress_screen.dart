import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_group.dart';
import '../models/photo_item.dart';
import '../services/photo_scanner_service.dart';
import '../services/similarity_service.dart';
import 'duplicate_review_screen.dart';

class ScanProgressScreen extends StatefulWidget {
  const ScanProgressScreen({Key? key}) : super(key: key);

  @override
  State<ScanProgressScreen> createState() => _ScanProgressScreenState();
}

class _ScanProgressScreenState extends State<ScanProgressScreen> {
  @override
  void initState() {
    super.initState();
  }

  Future<void> _startScan() async {
    final provider = context.read<AppStateProvider>();
    provider.startScan();

    try {
      // Run scan on main thread to avoid isolate platform channel issues
      final photos = await PhotoScannerService.scanAllPhotos(
        onProgress: (current, total) {
          provider.updateProgress(current / total, 'Scanning: $current/$total');
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

      if (mounted) {
        // Group photos by rolling time window, then sub-group by hash similarity.
        final groups = buildPhotoGroups(photos);
        print('[SCAN] Created ${groups.length} groups');
        for (final g in groups) {
          print(
              '[GROUP] ${g.id}: ${g.photos.length} photos (type: ${g.groupType})');
        }
        provider.finishScan(groups);

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => const DuplicateReviewScreen(),
            ),
          );
        }
      }
    } catch (e) {
      print('Error during scan: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan error: $e')),
        );
      }
    }
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
                  const Text(
                    'Tap the button below to scan your photo library for duplicates.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: _startScan,
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
List<PhotoGroup> buildPhotoGroups(List<PhotoItem> photos) {
  final groups = <PhotoGroup>[];
  int groupIndex = 0;

  final clusters = SimilarityService.clusterByTime(photos);

  for (final cluster in clusters) {
    if (cluster.length == 1) {
      groups.add(PhotoGroup(
        id: 'group_$groupIndex',
        photos: cluster,
        timestamp: cluster.first.createDateTime,
      ));
      groupIndex++;
      continue;
    }

    final photoHashes = {
      for (final p in cluster)
        if (p.dhash != null && p.dhash!.isNotEmpty) p.id: p.dhash!,
    };

    final subGroups = SimilarityService.groupBySimilarity(
      cluster,
      photoHashes: photoHashes,
    );

    for (final subGroup in subGroups) {
      groups.add(PhotoGroup(
        id: 'group_$groupIndex',
        photos: subGroup,
        timestamp: subGroup.first.createDateTime,
        groupType: subGroup.length > 1 ? 'hash' : 'single',
      ));
      groupIndex++;
    }
  }

  return groups;
}
