import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/scan_mode.dart';
import '../services/flagged_photo_cache_service.dart';
import '../services/review_cache_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_version.dart';
import '../widgets/gradient_button.dart';
import 'duplicate_review_screen.dart';
import 'flagged_photo_review_screen.dart';
import 'scan_progress_screen.dart';

/// Menu screen shown after permission grant when there's no saved review to
/// resume into. Fork point between the app's scan modes (napkin backlog
/// #8) -- before this screen existed, `PermissionScreen` routed straight
/// into the duplicate-scan flow with no way to reach the newer blurry-photo
/// or large-file modes.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _startScan(BuildContext context, ScanMode mode) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScanProgressScreen(mode: mode),
      ),
    );
  }

  /// Entry point for the "Find Duplicates" button. Checks for a saved
  /// review (see `ReviewCacheService`) first and, if one exists, opens
  /// straight into it -- skipping a rescan entirely -- rather than always
  /// routing through `ScanProgressScreen`'s folder/album picker. This is
  /// what `PermissionScreen` used to do unconditionally on every app
  /// launch; moving it here means restarting the app always lands on this
  /// menu, and resuming a saved review is one tap away instead of forced.
  /// The review screen's "Re-scan" button still routes back through
  /// `ScanProgressScreen` for a fresh scan.
  Future<void> _startDuplicatesFlow(BuildContext context) async {
    final savedGroups = await ReviewCacheService().load();
    if (!context.mounted) return;

    if (savedGroups != null) {
      context.read<AppStateProvider>().loadSavedReview(savedGroups);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const DuplicateReviewScreen(),
        ),
      );
    } else {
      _startScan(context, ScanMode.duplicates);
    }
  }

  /// Same resume-or-scan logic as [_startDuplicatesFlow], for the
  /// blurry-photo finder's own cache file.
  Future<void> _startBlurryFlow(BuildContext context) async {
    final saved = await FlaggedPhotoCacheService.blurry().load();
    if (!context.mounted) return;

    if (saved != null) {
      context.read<AppStateProvider>().loadSavedBlurryPhotos(saved);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FlaggedPhotoReviewScreen.forMode(ScanMode.blurry),
        ),
      );
    } else {
      _startScan(context, ScanMode.blurry);
    }
  }

  /// Same resume-or-scan logic as [_startDuplicatesFlow], for the
  /// large-file finder's own cache file.
  Future<void> _startLargeFilesFlow(BuildContext context) async {
    final saved = await FlaggedPhotoCacheService.largeFiles().load();
    if (!context.mounted) return;

    if (saved != null) {
      context.read<AppStateProvider>().loadSavedLargeFiles(saved);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              FlaggedPhotoReviewScreen.forMode(ScanMode.largeFiles),
        ),
      );
    } else {
      _startScan(context, ScanMode.largeFiles);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DupeSweep')),
      body: Stack(
        children: [
          Padding(
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
                  'What would you like to do?',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 32),
                GradientButton(
                  onPressed: () => _startDuplicatesFlow(context),
                  icon: Icons.filter_none,
                  label: ScanMode.duplicates.menuLabel,
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => _startBlurryFlow(context),
                  icon: const Icon(Icons.blur_on),
                  label: Text(ScanMode.blurry.menuLabel),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => _startLargeFilesFlow(context),
                  icon: const Icon(Icons.sd_storage_outlined),
                  label: Text(ScanMode.largeFiles.menuLabel),
                ),
              ],
            ),
          ),
          // Pinned to the bottom via Positioned (rather than sitting in the
          // centered Column above) so it stays put in the same corner
          // regardless of how much space the menu content above ends up
          // taking. Adds the system nav bar's inset -- same reasoning as
          // SummaryBar/FlaggedPhotoSummaryBar -- so it doesn't render
          // underneath the gesture-nav pill / 3-button nav on real devices,
          // which without this made the label effectively invisible.
          Positioned(
            left: 0,
            right: 0,
            bottom: 12 + MediaQuery.of(context).padding.bottom,
            child: const Center(
              child: Text(
                'v$kAppVersion',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
