enum MangaStatus { ongoing, completed, hiatus, cancelled, unknown }

class Manga {
  const Manga({
    required this.id,
    required this.title,
    required this.coverUrl,
    required this.synopsis,
    required this.status,
    required this.chapterCount,
    this.anilistId,
    this.malId,
    this.mangaDexId,
    this.rating,
    this.isAdult = false,
    this.aliases = const [],
  });
  final String id;
  final int? anilistId;
  final int? malId;
  final String? mangaDexId;
  final String title;
  final List<String> aliases;
  final String coverUrl;
  final String synopsis;
  final MangaStatus status;
  final double? rating;
  final int chapterCount;
  final bool isAdult;

  String get ratingLabel {
    final value = rating;
    return value == null ? 'Unrated' : value.toStringAsFixed(1);
  }

  String get statusLabel => switch (status) {
    MangaStatus.ongoing => 'Ongoing',
    MangaStatus.completed => 'Completed',
    MangaStatus.hiatus => 'On hiatus',
    MangaStatus.cancelled => 'Cancelled',
    MangaStatus.unknown => 'Unknown',
  };
  Manga copyWith({String? mangaDexId, int? chapterCount}) => Manga(
    id: id,
    anilistId: anilistId,
    malId: malId,
    mangaDexId: mangaDexId ?? this.mangaDexId,
    title: title,
    aliases: aliases,
    coverUrl: coverUrl,
    synopsis: synopsis,
    status: status,
    rating: rating,
    chapterCount: chapterCount ?? this.chapterCount,
    isAdult: isAdult,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'anilistId': anilistId,
    'malId': malId,
    'mangaDexId': mangaDexId,
    'title': title,
    'aliases': aliases,
    'coverUrl': coverUrl,
    'synopsis': synopsis,
    'status': status.name,
    'rating': rating,
    'chapterCount': chapterCount,
    'isAdult': isAdult,
  };
  factory Manga.fromJson(Map<String, dynamic> json) => Manga(
    id: json['id'] as String,
    anilistId: json['anilistId'] as int?,
    malId: json['malId'] as int?,
    mangaDexId: json['mangaDexId'] as String?,
    title: json['title'] as String,
    aliases: List<String>.from(json['aliases'] as List? ?? const []),
    coverUrl: json['coverUrl'] as String? ?? '',
    synopsis: json['synopsis'] as String? ?? '',
    status: MangaStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => MangaStatus.unknown,
    ),
    rating: (json['rating'] as num?)?.toDouble(),
    chapterCount: json['chapterCount'] as int? ?? 0,
    isAdult: json['isAdult'] as bool? ?? false,
  );
}
