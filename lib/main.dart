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
}
