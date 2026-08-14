import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/photo_group.dart';
import 'models/photo_item.dart';
import 'screens/permission_screen.dart';
import 'screens/scan_progress_screen.dart';
import 'screens/duplicate_review_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const DupesweepApp());
}

class DupesweepApp extends StatelessWidget {
  const DupesweepApp({Key? key}) : super(key: key);

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
  List<PhotoGroup> photoGroups = [];
  bool isScanning = false;
  double scanProgress = 0.0;
  String? scanStatus;

  void startScan() {
    isScanning = true;
    scanProgress = 0.0;
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
    photoGroups.removeWhere((g) => g.photos.length <= 1);

    // A surviving group may have lost its isBest photo to the delete --
    // re-elect one so "Select All Non-Best" never ends up selecting every
    // remaining photo in the group with no keeper spared.
    for (final group in photoGroups) {
      group.ensureBestElected();
    }

    notifyListeners();
  }
}
