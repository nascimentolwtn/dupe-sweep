import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/photo_group.dart';
import 'models/photo_item.dart';
import 'models/scan_mode.dart';
import 'screens/permission_screen.dart';
import 'services/flagged_photo_cache_service.dart';
import 'services/review_cache_service.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const DupesweepApp());
}

class DupesweepApp extends StatelessWidget {
  const DupesweepApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppStateProvider()),
      ],
      child: MaterialApp(
        title: 'DupeSweep',
        theme: buildAppTheme(),
        home: const PermissionScreen(),
      ),
    );
  }
}

class AppStateProvider extends ChangeNotifier {
  // Injectable for testability (mirrors ScanCacheService's pattern); defaults
  // to the real on-disk service in production.
  final ReviewCacheService _reviewCache;
  final FlaggedPhotoCacheService _blurryCache;
  final FlaggedPhotoCacheService _largeFilesCache;

  AppStateProvider({
    ReviewCacheService? reviewCache,
    FlaggedPhotoCacheService? blurryCache,
    FlaggedPhotoCacheService? largeFilesCache,
  })  : _reviewCache = reviewCache ?? ReviewCacheService(),
        _blurryCache = blurryCache ?? FlaggedPhotoCacheService.blurry(),
        _largeFilesCache =
            largeFilesCache ?? FlaggedPhotoCacheService.largeFiles();

  /// The most recently kicked-off review-list save, if any. Production
  /// callers never await this -- a save failure isn't worth blocking or
  /// erroring the UI over (see [ReviewCacheService.save]'s own error
  /// handling) -- but tests need a deterministic way to know a fire-and-
  /// forget save has actually finished landing on disk before asserting
  /// against it, since real file I/O doesn't reliably settle within
  /// `pumpEventQueue()`'s microtask/timer draining the way pure-Dart
  /// futures do.
  @visibleForTesting
  Future<void>? debugLastReviewSave;

  // Same fire-and-forget/test-visibility pattern as [debugLastReviewSave],
  // for the flat blurry/large-file lists' own cache files.
  @visibleForTesting
  Future<void>? debugLastBlurrySave;

  @visibleForTesting
  Future<void>? debugLastLargeFilesSave;

  List<PhotoGroup> photoGroups = [];
  bool isScanning = false;
  double scanProgress = 0.0;
  String? scanStatus;

  // Flat, independently-flagged results for the large-file finder (napkin
  // backlog #8) -- deliberately NOT PhotoGroups: there's no "keep the best,
  // delete the rest" comparison for these, each photo/video is judged on
  // its own. Persisted via [_largeFilesCache], same resume-on-restart
  // purpose as [photoGroups]/[_reviewCache].
  List<PhotoItem> largeFiles = [];

  void finishLargeFileScan(List<PhotoItem> photos) {
    largeFiles = photos;
    isScanning = false;
    // Fire-and-forget: a save failure just means next launch falls back to
    // a full rescan, not something worth blocking/erroring the UI over.
    debugLastLargeFilesSave = _largeFilesCache.save(largeFiles);
    notifyListeners();
  }

  // Flat, independently-flagged results for the blurry-photo detector
  // (napkin backlog #8) -- same "no best-photo comparison" shape as
  // [largeFiles], and likewise persisted via [_blurryCache].
  List<PhotoItem> blurryPhotos = [];

  void finishBlurScan(List<PhotoItem> photos) {
    blurryPhotos = photos;
    isScanning = false;
    debugLastBlurrySave = _blurryCache.save(blurryPhotos);
    notifyListeners();
  }

  /// Restores a previously-saved blurry-photo list (see
  /// [FlaggedPhotoCacheService.blurry]) so `HomeScreen`'s "Find Blurry
  /// Photos" button can skip straight to reviewing instead of forcing a
  /// rescan -- mirrors [loadSavedReview] for the duplicate-scan flow.
  void loadSavedBlurryPhotos(List<PhotoItem> photos) {
    blurryPhotos = photos;
    isScanning = false;
    notifyListeners();
  }

  /// Same as [loadSavedBlurryPhotos], for the large-file finder.
  void loadSavedLargeFiles(List<PhotoItem> photos) {
    largeFiles = photos;
    isScanning = false;
    notifyListeners();
  }

  /// Same purpose as [refreshSelection] but for the flat blurry/large-file
  /// lists: also re-persists the (already in-place-mutated, see
  /// `FlaggedPhotoSummaryBar._performDeletion`) list to disk so a later
  /// resume never re-shows an already-deleted photo. Doesn't share code
  /// with [removeDeletedPhotos] -- that method also prunes/re-elects a
  /// "best" photo per group, a concept these flat lists don't have.
  void refreshFlaggedSelection(ScanMode mode) {
    switch (mode) {
      case ScanMode.blurry:
        debugLastBlurrySave = _blurryCache.save(blurryPhotos);
      case ScanMode.largeFiles:
        debugLastLargeFilesSave = _largeFilesCache.save(largeFiles);
      case ScanMode.duplicates:
        break;
    }
    notifyListeners();
  }

  void startScan() {
    isScanning = true;
    scanProgress = 0.0;
    // Without this, the scanning screen briefly shows the PREVIOUS scan's
    // last status text (e.g. "Checking for duplicates: 450/450") until the
    // new scan's first onProgress callback fires -- confusing, since those
    // numbers have nothing to do with the scan that just started. Falls
    // back to ScanProgressScreen's generic "Scanning..." label until real
    // progress comes in.
    scanStatus = null;
    notifyListeners();
  }

  void updateProgress(double progress, String status) {
    scanProgress = progress;
    scanStatus = status;
    notifyListeners();
  }

  void finishScan(List<PhotoGroup> groups) {
    photoGroups = groups;
    isScanning = false;
    // Fire-and-forget: a save failure just means next launch falls back to
    // a full rescan, not something worth blocking/erroring the UI over.
    debugLastReviewSave = _reviewCache.save(photoGroups);
    notifyListeners();
  }

  /// Restores a previously-saved review list (see [ReviewCacheService]) so
  /// the app can skip straight to reviewing on launch instead of forcing a
  /// full rescan when nothing has changed since last time.
  void loadSavedReview(List<PhotoGroup> groups) {
    photoGroups = groups;
    isScanning = false;
    notifyListeners();
  }

  /// User-initiated cancel: stop showing the scanning UI without setting
  /// `photoGroups`, since no grouping was ever computed for a cancelled run.
  void cancelScan() {
    isScanning = false;
    notifyListeners();
  }

  /// `PhotoItem.isSelected`/`PhotoGroup` selection state is mutated
  /// directly (not through this provider) by `PhotoGroupCard`'s thumbnail
  /// checkboxes, `PhotoFullscreenViewer`'s mark-for-deletion toggle, and
  /// the "Select All Non-Best"/"Clear" buttons -- each of those already
  /// calls its own local `setState()` for its own widget's visuals, but
  /// that doesn't reach `SummaryBar`, a sibling widget with no ancestor
  /// relationship to any of them. Call this after any such mutation so the
  /// `Consumer<AppStateProvider>` wrapping the whole review screen (and
  /// therefore `SummaryBar`) rebuilds and picks up the new selection count.
  void refreshSelection() {
    notifyListeners();
  }

  /// One-shot signal for the review screen: after a delete removes a
  /// group from the list, this holds the id of the group immediately
  /// before it (in the pre-removal order) that's still around -- so
  /// PhotoGroupCard can auto-expand that neighbor and the user picks up
  /// right where they were reviewing instead of having to scroll back and
  /// re-find their place after a group vanishes out from under them.
  /// "One-shot" because PhotoGroupCard only reacts to this becoming true
  /// on a rising edge (see its didUpdateWidget) -- it's safe to leave set
  /// between deletes; it just won't re-trigger for the same group twice,
  /// and the next delete overwrites it with a fresh target anyway.
  String? pendingExpandGroupId;

  /// Removes successfully-deleted photos from every group, then drops any
  /// group that's left with 1 or 0 photos -- same "nothing to compare"
  /// rule the scan itself applies when first building groups, since a
  /// group can end up a singleton after its duplicates are deleted just
  /// as easily as it can start out that way.
  void removeDeletedPhotos(Set<String> deletedIds) {
    if (deletedIds.isEmpty) return;

    for (final group in photoGroups) {
      group.photos.removeWhere((p) => deletedIds.contains(p.id));
    }

    // Walk the pre-removal order once: for every group about to disappear,
    // remember the most recent still-surviving group seen before it. If
    // several groups vanish in one delete, this ends up pointing at the
    // neighbor of the last (bottom-most) one -- the closest match to
    // "where the user was" when multiple groups are affected at once.
    String? neighborToExpand;
    String? lastSurvivingId;
    for (final group in photoGroups) {
      if (group.photos.length > 1) {
        lastSurvivingId = group.id;
      } else {
        neighborToExpand = lastSurvivingId;
      }
    }
    pendingExpandGroupId = neighborToExpand;

    photoGroups.removeWhere((g) => g.photos.length <= 1);

    // A surviving group may have lost its isBest photo to the delete --
    // re-elect one so "Select All Non-Best" never ends up selecting every
    // remaining photo in the group with no keeper spared.
    for (final group in photoGroups) {
      group.ensureBestElected();
    }

    // Keep the saved copy in sync so a later restart never resumes into
    // already-deleted photos.
    debugLastReviewSave = _reviewCache.save(photoGroups);

    notifyListeners();
  }
}
