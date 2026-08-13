import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
    _startScan();
  }

  Future<void> _startScan() async {
    final provider = context.read<AppStateProvider>();
    provider.startScan();

    try {
      // Run scan in isolate to avoid blocking UI
      final photos = await compute(_scanPhotosInIsolate, null);

      if (mounted) {
        // Group photos by day (simple time clustering for this session)
        final groups = _groupPhotosByDay(photos);
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
    var currentGroup = <PhotoItem>[photos.first];
    var currentDay = _getDateOnly(photos.first.createDateTime);

    for (int i = 1; i < photos.length; i++) {
      final photoDay = _getDateOnly(photos[i].createDateTime);

      if (photoDay == currentDay) {
        currentGroup.add(photos[i]);
      } else {
        groups.add(PhotoGroup(
          id: 'group_$groupIndex',
          photos: currentGroup,
          timestamp: currentDay,
        ));
        groupIndex++;
        currentGroup = [photos[i]];
        currentDay = photoDay;
      }
    }

    groups.add(PhotoGroup(
      id: 'group_$groupIndex',
      photos: currentGroup,
      timestamp: currentDay,
    ));

    return groups;
  }

  DateTime _getDateOnly(DateTime dt) {
    return DateTime(dt.year, dt.month, dt.day);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanning Photos'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Consumer<AppStateProvider>(
              builder: (context, provider, _) {
                return Column(
                  children: [
                    Text(
                      provider.scanStatus ?? 'Initializing scan...',
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
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

Future<List<PhotoItem>> _scanPhotosInIsolate(void _) async {
  return await PhotoScannerService.scanAllPhotos();
}
