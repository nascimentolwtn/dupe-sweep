import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/permission_screen.dart';
import 'screens/scan_progress_screen.dart';
import 'screens/duplicate_review_screen.dart';

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
        theme: ThemeData(
          primarySwatch: Colors.blue,
          useMaterial3: true,
        ),
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
}

class PhotoGroup {
  final String id;
  final List<PhotoItem> photos;
  final DateTime timestamp;

  PhotoGroup({
    required this.id,
    required this.photos,
    required this.timestamp,
  });
}

class PhotoItem {
  final String id;
  final String path;
  final DateTime createDateTime;
  final int fileSize;
  bool isSelected;

  PhotoItem({
    required this.id,
    required this.path,
    required this.createDateTime,
    required this.fileSize,
    this.isSelected = false,
  });
}
