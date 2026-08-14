import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_button.dart';
import 'scan_progress_screen.dart';

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({Key? key}) : super(key: key);

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _hasPermission = false;
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
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const ScanProgressScreen(),
          ),
        );
      }
      return;
    }

    if (mounted) {
      setState(() {
        _hasPermission = status.isGranted;
        _checking = false;
      });
    }
  }

  Future<void> _requestPermission() async {
    final status = await Permission.photos.request();
    setState(() {
      _hasPermission = status.isGranted;
    });

    if (status.isGranted || status.isLimited) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const ScanProgressScreen(),
          ),
        );
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
