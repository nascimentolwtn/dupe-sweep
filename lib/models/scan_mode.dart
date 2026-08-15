/// Which kind of scan `ScanProgressScreen` should run and which review
/// screen it should route to on completion. Introduced alongside the
/// home/menu screen (napkin backlog #8) so duplicate detection, blurry-photo
/// detection, and large-file finding can share one scan-progress UI instead
/// of three near-identical screens.
enum ScanMode {
  duplicates,
  blurry,
  largeFiles;

  String get menuLabel {
    switch (this) {
      case ScanMode.duplicates:
        return 'Find Duplicates';
      case ScanMode.blurry:
        return 'Find Blurry Photos';
      case ScanMode.largeFiles:
        return 'Find Large Files';
    }
  }

  String get appBarTitle {
    switch (this) {
      case ScanMode.duplicates:
        return 'Scan for Duplicates';
      case ScanMode.blurry:
        return 'Scan for Blurry Photos';
      case ScanMode.largeFiles:
        return 'Scan for Large Files';
    }
  }

  String get readyDescription {
    switch (this) {
      case ScanMode.duplicates:
        return 'Tap the button below to scan your photo library for '
            'duplicates.';
      case ScanMode.blurry:
        return 'Tap the button below to scan your photo library for '
            'blurry or out-of-focus photos.';
      case ScanMode.largeFiles:
        return 'Tap the button below to scan your photo and video library '
            'for the largest files taking up space.';
    }
  }
}
