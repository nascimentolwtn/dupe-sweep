class PhotoItem {
  final String id;
  final String path;
  final DateTime createDateTime;
  final int fileSize;
  final String? dhash;
  final double? sharpnessScore;
  final double? exposureScore;
  bool isSelected;
  bool isBest;

  PhotoItem({
    required this.id,
    required this.path,
    required this.createDateTime,
    required this.fileSize,
    this.dhash,
    this.sharpnessScore,
    this.exposureScore,
    this.isSelected = false,
    this.isBest = false,
  });

  double get overallScore {
    var score = 0.0;
    if (sharpnessScore != null) score += sharpnessScore! * 0.6;
    if (exposureScore != null) score += exposureScore! * 0.4;
    return score;
  }

  PhotoItem copyWith({
    String? id,
    String? path,
    DateTime? createDateTime,
    int? fileSize,
    String? dhash,
    double? sharpnessScore,
    double? exposureScore,
    bool? isSelected,
    bool? isBest,
  }) {
    return PhotoItem(
      id: id ?? this.id,
      path: path ?? this.path,
      createDateTime: createDateTime ?? this.createDateTime,
      fileSize: fileSize ?? this.fileSize,
      dhash: dhash ?? this.dhash,
      sharpnessScore: sharpnessScore ?? this.sharpnessScore,
      exposureScore: exposureScore ?? this.exposureScore,
      isSelected: isSelected ?? this.isSelected,
      isBest: isBest ?? this.isBest,
    );
  }
}
