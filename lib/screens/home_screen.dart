import 'package:flutter/material.dart';
import '../models/scan_mode.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_button.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DupeSweep')),
      body: Padding(
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
              onPressed: () => _startScan(context, ScanMode.duplicates),
              icon: Icons.filter_none,
              label: ScanMode.duplicates.menuLabel,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _startScan(context, ScanMode.blurry),
              icon: const Icon(Icons.blur_on),
              label: Text(ScanMode.blurry.menuLabel),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => _startScan(context, ScanMode.largeFiles),
              icon: const Icon(Icons.sd_storage_outlined),
              label: Text(ScanMode.largeFiles.menuLabel),
            ),
          ],
        ),
      ),
    );
  }
}
