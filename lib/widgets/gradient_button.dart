import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Pill-shaped primary CTA filled with the cyan-to-violet accent gradient
/// (matches the app icon). Used for the app's main calls to action --
/// granting permission, starting/resuming a scan.
class GradientButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  const GradientButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;

    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppColors.accentGradient,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: AppColors.bgTop),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.bgTop,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
