class MangaChapterSummary {
  const MangaChapterSummary({
    required this.indexCount,
    required this.latestNumber,
  });

  final int indexCount;
  final double? latestNumber;

  String get displayLabel {
    final value = latestNumber;
    if (value == null) return '$indexCount';
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
}

abstract final class MangaChapterRegistry {
  static final Map<String, MangaChapterSummary> _summaries =
      <String, MangaChapterSummary>{};

  static MangaChapterSummary? summaryFor(String mangaId) => _summaries[mangaId];

  static bool _useful(MangaChapterSummary? summary) =>
      summary != null &&
      (summary.latestNumber != null || summary.indexCount > 0);

  static int? countFor(String mangaId) {
    final summary = _summaries[mangaId];
    return _useful(summary) ? summary!.indexCount : null;
  }

  static double? latestNumberFor(String mangaId) =>
      _summaries[mangaId]?.latestNumber;

  static String? displayLabelFor(String mangaId) {
    final summary = _summaries[mangaId];
    return _useful(summary) ? summary!.displayLabel : null;
  }

  static void remember(String mangaId, int count, {double? latestNumber}) {
    if (mangaId.trim().isEmpty || count < 0) return;
    if (latestNumber != null &&
        (!latestNumber.isFinite || latestNumber < 0 || latestNumber > 20000)) {
      latestNumber = null;
    }
    _summaries[mangaId] = MangaChapterSummary(
      indexCount: count,
      latestNumber: latestNumber,
    );
  }

  static void rememberSummary(String mangaId, MangaChapterSummary summary) {
    remember(mangaId, summary.indexCount, latestNumber: summary.latestNumber);
  }

  static void remove(String mangaId) => _summaries.remove(mangaId);
  static void clear() => _summaries.clear();
}

enum MangaStatus {
  ongoing,
  completed,
  hiatus,
  cancelled,
  notYetReleased,
  unknown,
}

enum MangaFormat { manga, oneShot, novel, unknown }

class Manga {
  const Manga({
    required this.id,
    required this.title,
    required this.coverUrl,
    required this.synopsis,
    required this.status,
    required int chapterCount,
    this.anilistId,
    this.malId,
    this.mangaDexId,
    this.rating,
    this.isAdult = false,
    this.aliases = const [],
    this.format = MangaFormat.unknown,
    this.countryCode,
    this.startYear,
    this.volumeCount = 0,
    this.genres = const [],
    this.popularity,
  }) : _metadataChapterCount = chapterCount;

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
  final int _metadataChapterCount;
  final bool isAdult;
  final MangaFormat format;
  final String? countryCode;
  final int? startYear;
  final int volumeCount;
  final List<String> genres;
  final int? popularity;

  int get chapterCount =>
      MangaChapterRegistry.countFor(id) ?? _metadataChapterCount;

  int get metadataChapterCount => _metadataChapterCount;

  bool get hasVerifiedChapterSummary =>
      MangaChapterRegistry.displayLabelFor(id) != null;

  String get chapterDisplayLabel {
    final verified = MangaChapterRegistry.displayLabelFor(id);
    if (verified != null) return verified;
    if (_metadataChapterCount <= 0) return '—';
    return '~$_metadataChapterCount';
  }

  String get ratingLabel {
    final value = rating;
    return value == null ? 'Unrated' : value.toStringAsFixed(1);
  }

  String get statusLabel => switch (status) {
    MangaStatus.ongoing => 'Ongoing',
    MangaStatus.completed => 'Completed',
    MangaStatus.hiatus => 'Hiatus',
    MangaStatus.cancelled => 'Cancelled',
    MangaStatus.notYetReleased => 'Upcoming',
    MangaStatus.unknown => 'Unknown',
  };

  String get formatLabel => switch (format) {
    MangaFormat.manga => 'Manga',
    MangaFormat.oneShot => 'One-shot',
    MangaFormat.novel => 'Novel',
    MangaFormat.unknown => 'Manga',
  };

  String get countryLabel => switch (countryCode?.toUpperCase()) {
    'JP' => 'Japan',
    'KR' => 'Korea',
    'CN' => 'China',
    'TW' => 'Taiwan',
    final value when value != null && value.isNotEmpty => value,
    _ => 'Unknown',
  };

  String get compactIdentityLabel {
    final parts = <String>[formatLabel];
    final country = countryCode?.trim();
    if (country != null && country.isNotEmpty) parts.add(countryLabel);
    if (startYear != null) parts.add(startYear.toString());
    return parts.join(' • ');
  }

  String get volumeLabel => volumeCount > 0 ? '$volumeCount vol' : '— vol';

  String get popularityLabel {
    final value = popularity;
    if (value == null || value <= 0) return '—';
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return value.toString();
  }

  List<String> get displayGenres => genres.take(3).toList(growable: false);

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
    chapterCount: chapterCount ?? _metadataChapterCount,
    isAdult: isAdult,
    format: format,
    countryCode: countryCode,
    startYear: startYear,
    volumeCount: volumeCount,
    genres: genres,
    popularity: popularity,
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
    'chapterCount': _metadataChapterCount,
    'isAdult': isAdult,
    'format': format.name,
    'countryCode': countryCode,
    'startYear': startYear,
    'volumeCount': volumeCount,
    'genres': genres,
    'popularity': popularity,
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
    format: MangaFormat.values.firstWhere(
      (f) => f.name == json['format'],
      orElse: () => MangaFormat.unknown,
    ),
    countryCode: json['countryCode'] as String?,
    startYear: (json['startYear'] as num?)?.toInt(),
    volumeCount: (json['volumeCount'] as num?)?.toInt() ?? 0,
    genres: List<String>.from(json['genres'] as List? ?? const []),
    popularity: (json['popularity'] as num?)?.toInt(),
  );
}
