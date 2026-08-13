import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_group.dart';
import '../models/photo_item.dart';
import '../services/photo_scanner_service.dart';
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

      final withHash = photos.where((p) => p.dhash != null && p.dhash!.isNotEmpty).length;
      print('[SCAN] Computed hashes for $withHash photos');

      if (photos.isNotEmpty) {
        print('[SCAN] First photo: ${photos.first.id}, hash: ${photos.first.dhash?.substring(0, 8)}...');
      }

      if (mounted) {
        // Group photos by day (simple time clustering for this session)
        final groups = _groupPhotosByDay(photos);
        print('[SCAN] Created ${groups.length} groups');
        for (final g in groups) {
          print('[GROUP] ${g.id}: ${g.photos.length} photos (type: ${g.groupType})');
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

  List<PhotoGroup> _groupPhotosByDay(List<PhotoItem> photos) {
    if (photos.isEmpty) return [];

    final groups = <PhotoGroup>[];
    int groupIndex = 0;
    var currentDayPhotos = <PhotoItem>[photos.first];
    var currentDay = _getDateOnly(photos.first.createDateTime);

    for (int i = 1; i < photos.length; i++) {
      final photoDay = _getDateOnly(photos[i].createDateTime);

      if (photoDay == currentDay) {
        currentDayPhotos.add(photos[i]);
      } else {
        // Sub-group current day's photos by hash similarity
        _addHashGroups(groups, currentDayPhotos, currentDay, groupIndex);
        groupIndex += currentDayPhotos.length ~/ 2 + 1; // Reserve IDs

        currentDayPhotos = [photos[i]];
        currentDay = photoDay;
      }
    }

    // Sub-group last day's photos
    _addHashGroups(groups, currentDayPhotos, currentDay, groupIndex);

    return groups;
  }

  void _addHashGroups(
    List<PhotoGroup> groups,
    List<PhotoItem> dayPhotos,
    DateTime day,
    int startingIndex,
  ) {
    if (dayPhotos.isEmpty) return;

    // If only one photo, add it as a single group
    if (dayPhotos.length == 1) {
      groups.add(PhotoGroup(
        id: 'group_$startingIndex',
        photos: dayPhotos,
        timestamp: day,
      ));
      return;
    }

    // Group by hash similarity (Hamming distance <= 10)
    final used = <String>{};
    int subIndex = 0;

    for (final photo in dayPhotos) {
      if (used.contains(photo.id)) continue;

      final subGroup = <PhotoItem>[photo];
      used.add(photo.id);

      if (photo.dhash != null && photo.dhash!.isNotEmpty) {
        for (final other in dayPhotos) {
          if (used.contains(other.id)) continue;
          if (other.dhash == null || other.dhash!.isEmpty) continue;

          final distance = _hammingDistance(photo.dhash!, other.dhash!);
          if (distance <= 10) {
            subGroup.add(other);
            used.add(other.id);
          }
        }
      }

      groups.add(PhotoGroup(
        id: 'group_${startingIndex}_$subIndex',
        photos: subGroup,
        timestamp: day,
        groupType: subGroup.length > 1 ? 'hash' : 'single',
      ));
      subIndex++;
    }
  }

  int _hammingDistance(String hash1, String hash2) {
    if (hash1.length != hash2.length) return 999;
    int distance = 0;
    for (int i = 0; i < hash1.length; i++) {
      if (hash1[i] != hash2[i]) distance++;
    }
    return distance;
  }

  DateTime _getDateOnly(DateTime dt) {
    return DateTime(dt.year, dt.month, dt.day);
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
