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

/// Runtime registry for source-verified chapter summaries.
///
/// AniList's `chapters` field is metadata, not a guaranteed live chapter
/// total. Once Tsuki has resolved a real source index, this registry becomes
/// the authoritative value used by the UI. The registry is warmed from the
/// tiny on-device chapter summary before runApp, so previously-seen titles can
/// show their verified latest chapter immediately.
abstract final class MangaChapterRegistry {
  static final Map<String, MangaChapterSummary> _summaries =
      <String, MangaChapterSummary>{};

  static MangaChapterSummary? summaryFor(String mangaId) =>
      _summaries[mangaId];

  static int? countFor(String mangaId) => _summaries[mangaId]?.indexCount;

  static double? latestNumberFor(String mangaId) =>
      _summaries[mangaId]?.latestNumber;

  static String? displayLabelFor(String mangaId) =>
      _summaries[mangaId]?.displayLabel;

  static void remember(
    String mangaId,
    int count, {
    double? latestNumber,
  }) {
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
    remember(
      mangaId,
      summary.indexCount,
      latestNumber: summary.latestNumber,
    );
  }

  static void remove(String mangaId) {
    _summaries.remove(mangaId);
  }

  static void clear() {
    _summaries.clear();
  }
}

enum MangaStatus { ongoing, completed, hiatus, cancelled, unknown }

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

  /// Number of canonical entries in the best source-verified local index.
  /// Falls back to metadata only until Tsuki has seen a source index.
  int get chapterCount =>
      MangaChapterRegistry.countFor(id) ?? _metadataChapterCount;

  /// Raw count reported by AniList. This can be 0 or stale for releasing
  /// titles and must never be treated as proof that readable chapters exist.
  int get metadataChapterCount => _metadataChapterCount;

  bool get hasVerifiedChapterSummary =>
      MangaChapterRegistry.summaryFor(id) != null;

  String get chapterDisplayLabel {
    final verified = MangaChapterRegistry.displayLabelFor(id);
    if (verified != null) return verified;
    if (_metadataChapterCount <= 0) return '—';
    // `~` makes the first-ever, not-yet-indexed value explicitly provisional
    // instead of presenting AniList metadata as a verified source total.
    return '~$_metadataChapterCount';
  }

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
