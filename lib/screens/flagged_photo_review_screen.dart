import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_item.dart';
import '../models/scan_mode.dart';
import '../theme/app_theme.dart';
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

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, provider, _) {
        final photos = photosSelector(provider);

        return Scaffold(
          appBar: AppBar(title: Text(mode.menuLabel)),
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
                  onDeleted: () =>
                      context.read<AppStateProvider>().refreshSelection(),
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
