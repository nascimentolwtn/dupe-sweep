import 'package:flutter/material.dart';

/// "Midnight Gem" palette: matches the faceted diamond app icon
/// (near-black indigo ground, cyan-to-violet accent, mint marks the
/// keeper photo).
class AppColors {
  AppColors._();

  static const bgTop = Color(0xFF0A0912);
  static const bgBottom = Color(0xFF050409);
  static const surface = Color(0xFF15121F);
  static const surfaceElevated = Color(0xFF1D1930);
  static const border = Color(0x1FFFFFFF);

  static const accentCyan = Color(0xFF4FD1FF);
  static const accentViolet = Color(0xFF6E46FF);
  static const accentBest = Color(0xFF7CFFC4);
  static const danger = Color(0xFFD64545);

  static const textPrimary = Color(0xFFF3F2FA);
  static const textSecondary = Color(0xFF9A93B3);

  static const accentGradient = LinearGradient(
    colors: [accentCyan, accentViolet],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.accentViolet,
    brightness: Brightness.dark,
    primary: AppColors.accentCyan,
    secondary: AppColors.accentViolet,
    surface: AppColors.surface,
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.bgTop,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bgTop,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
    ),
    textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: AppColors.textPrimary,
          displayColor: AppColors.textPrimary,
        ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      margin: const EdgeInsets.all(8),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.surfaceElevated,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.accentCyan),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accentCyan,
      linearTrackColor: AppColors.surfaceElevated,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceElevated,
      contentTextStyle: TextStyle(color: AppColors.textPrimary),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceElevated,
      labelStyle: const TextStyle(color: AppColors.textPrimary),
      side: BorderSide.none,
    ),
  );
}
