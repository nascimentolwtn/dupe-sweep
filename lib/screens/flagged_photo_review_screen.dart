import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_item.dart';
import '../models/scan_mode.dart';
import '../services/large_file_scan_service.dart';
import '../theme/app_theme.dart';
import '../utils/byte_formatter.dart';
import '../widgets/flagged_photo_list.dart';
import 'scan_progress_screen.dart';

/// Shared review screen for the app's two flat, independently-flagged scan
/// results (blurry photos, large files) -- unlike `DuplicateReviewScreen`,
/// there's no group/"best photo" comparison here, just a flat list each
/// photo is judged on its own in. Parameterized by [mode] (drives the
/// title and which `AppStateProvider` list/re-scan route to use) and
/// [subtitleBuilder] (the one thing that actually differs between the two:
/// a sharpness score line for blurry photos, a file-size line for large
/// files).
class FlaggedPhotoReviewScreen extends StatelessWidget {
  final ScanMode mode;
  final List<PhotoItem> Function(AppStateProvider provider) photosSelector;
  final String Function(PhotoItem photo) subtitleBuilder;
  final String emptyMessage;

  const FlaggedPhotoReviewScreen({
    super.key,
    required this.mode,
    required this.photosSelector,
    required this.subtitleBuilder,
    required this.emptyMessage,
  });

  /// The mode-specific config (which list, subtitle text, empty-state
  /// copy) used to be duplicated between `ScanProgressScreen` (built after
  /// a fresh scan finishes) and `HomeScreen` (built when resuming a saved
  /// list, skipping the scan entirely) -- factored here so both routes to
  /// this screen stay in sync automatically.
  factory FlaggedPhotoReviewScreen.forMode(ScanMode mode) {
    switch (mode) {
      case ScanMode.blurry:
        return FlaggedPhotoReviewScreen(
          mode: ScanMode.blurry,
          photosSelector: (p) => p.blurryPhotos,
          subtitleBuilder: (photo) {
            final sharpness =
                ((photo.sharpnessScore ?? 0) * 100).toStringAsFixed(0);
            final exposure = photo.exposureScore;
            // exposureScore is only populated by the newer scan code
            // path -- omit the clause entirely for photos scored before
            // this field existed rather than showing a misleading 0%.
            if (exposure == null) return 'Sharpness: $sharpness%';
            return 'Sharpness: $sharpness% · Exposure: '
                '${(exposure * 100).toStringAsFixed(0)}%';
          },
          emptyMessage: 'No blurry photos found.',
        );
      case ScanMode.largeFiles:
        return FlaggedPhotoReviewScreen(
          mode: ScanMode.largeFiles,
          photosSelector: (p) => p.largeFiles,
          subtitleBuilder: (photo) => ByteFormatter.format(photo.fileSize),
          emptyMessage: 'No large files found (nothing over '
              '${LargeFileScanService.kMinFileSizeBytes ~/ (1024 * 1024)}MB).',
        );
      case ScanMode.duplicates:
        throw ArgumentError(
          'FlaggedPhotoReviewScreen has no config for ScanMode.duplicates '
          '-- use DuplicateReviewScreen instead.',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, provider, _) {
        final photos = photosSelector(provider);

        return Scaffold(
          appBar: AppBar(
            title: Text(
              photos.isEmpty
                  ? mode.menuLabel
                  : '${mode.menuLabel} (${photos.length})',
            ),
          ),
          body: photos.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text(
                      emptyMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                )
              : FlaggedPhotoList(
                  photos: photos,
                  subtitleBuilder: subtitleBuilder,
                  onSelectionChanged: () =>
                      context.read<AppStateProvider>().refreshSelection(),
                ),
          bottomNavigationBar: photos.isEmpty
              ? null
              : FlaggedPhotoSummaryBar(
                  photos: photos,
                  onDeleted: () => context
                      .read<AppStateProvider>()
                      .refreshFlaggedSelection(mode),
                  onRescan: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => ScanProgressScreen(mode: mode),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
