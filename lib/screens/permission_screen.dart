import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../services/review_cache_service.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_button.dart';
import 'duplicate_review_screen.dart';
import 'home_screen.dart';

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final status = await Permission.photos.status;

    if (status.isGranted || status.isLimited) {
      if (mounted) {
        await _navigateAfterPermissionGranted();
      }
      return;
    }

    if (mounted) {
      setState(() {
        _checking = false;
      });
    }
  }

  /// Routes to the review screen directly if a saved review list exists
  /// (see `ReviewCacheService`/`AppStateProvider.loadSavedReview`) so the
  /// user isn't forced through a full rescan when nothing's changed since
  /// last time; otherwise falls back to the normal scan flow. A "Re-scan"
  /// button is always available from the review screen if a fresh scan is
  /// wanted instead.
  Future<void> _navigateAfterPermissionGranted() async {
    final savedGroups = await ReviewCacheService().load();
    if (!mounted) return;

    if (savedGroups != null) {
      context.read<AppStateProvider>().loadSavedReview(savedGroups);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const DuplicateReviewScreen(),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const HomeScreen(),
        ),
      );
    }
  }

  Future<void> _requestPermission() async {
    // Requested together: `Permission.videos` is only needed for the
    // large-file finder (napkin backlog #8) to see video assets alongside
    // photos, but `Permission.photos` remains the gate for the rest of the
    // app -- a denied `Permission.videos` just means large-file results
    // won't include videos, not that the whole permission flow fails.
    final statuses = await [Permission.photos, Permission.videos].request();
    final status = statuses[Permission.photos] ?? PermissionStatus.denied;
    // Missing here previously (present on every other branch in this
    // method and in _checkPermission): backing out of the app while the
    // system permission dialog is showing, then returning, could hit this
    // setState after the widget was disposed.
    if (!mounted) return;

    if (status.isGranted || status.isLimited) {
      if (mounted) {
        await _navigateAfterPermissionGranted();
      }
    } else if (status.isDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permission denied')),
        );
      }
    } else if (status.isPermanentlyDenied) {
      if (mounted) {
        openAppSettings();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('DupeSweep'),
      ),
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
              'Find & Review Duplicate Photos',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'DupeSweep scans your phone\'s photos to find potential duplicates and burst shots. You control which photos to delete.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 32),
            GradientButton(
              onPressed: _requestPermission,
              icon: Icons.check,
              label: 'Grant Photo Access',
            ),
            const SizedBox(height: 16),
            const Text(
              'This permission is needed to scan and delete photos on your device.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
