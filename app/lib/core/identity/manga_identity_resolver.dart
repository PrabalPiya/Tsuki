import '../models/manga.dart';

enum MatchConfidence { known, high, medium, low }

class MangaIdentityMatch {
  const MangaIdentityMatch({
    required this.confidence,
    required this.score,
    required this.reasons,
  });

  final MatchConfidence confidence;
  final double score;
  final List<String> reasons;

  bool get canMerge =>
      confidence == MatchConfidence.known || confidence == MatchConfidence.high;
}

/// Central conservative identity matcher shared by search, imports and source
/// linking. Fuzzy similarity is only supporting evidence; it never merges a
/// work when format or edition markers conflict.
class MangaIdentityResolver {
  const MangaIdentityResolver();

  static String normalizeTitle(String value) => value
      .toLowerCase()
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  MangaIdentityMatch compare(Manga left, Manga right) {
    final reasons = <String>[];
    if (_knownIdMatch(left, right)) {
      return const MangaIdentityMatch(
        confidence: MatchConfidence.known,
        score: 1,
        reasons: ['known provider or source identifier'],
      );
    }

    if (_knownIdConflict(left, right)) {
      return const MangaIdentityMatch(
        confidence: MatchConfidence.low,
        score: 0,
        reasons: ['conflicting canonical provider identifier'],
      );
    }

    if (_formatConflict(left, right) || _editionConflict(left, right)) {
      return const MangaIdentityMatch(
        confidence: MatchConfidence.low,
        score: 0,
        reasons: ['format or edition conflict'],
      );
    }

    final leftTitles = _titles(left);
    final rightTitles = _titles(right);
    final exact = leftTitles.intersection(rightTitles).isNotEmpty;
    var score = exact
        ? .76
        : _bestTokenSimilarity(leftTitles, rightTitles) * .58;
    if (exact) reasons.add('exact normalized title or alias');

    if (left.startYear != null && right.startYear != null) {
      if ((left.startYear! - right.startYear!).abs() > 1) {
        return const MangaIdentityMatch(
          confidence: MatchConfidence.low,
          score: 0,
          reasons: ['release year conflict'],
        );
      }
      score += .1;
      reasons.add('compatible release year');
    }

    if (left.format != MangaFormat.unknown &&
        right.format != MangaFormat.unknown &&
        left.format == right.format) {
      score += .08;
      reasons.add('same format');
    }

    final leftAuthors = left.authors.map(normalizeTitle).toSet();
    final rightAuthors = right.authors.map(normalizeTitle).toSet();
    if (leftAuthors.isNotEmpty &&
        rightAuthors.isNotEmpty &&
        leftAuthors.intersection(rightAuthors).isNotEmpty) {
      score += .1;
      reasons.add('same author');
    }

    score = score.clamp(0, 1);
    final confidence = exact && score >= .75
        ? MatchConfidence.high
        : score >= .62
        ? MatchConfidence.medium
        : MatchConfidence.low;
    return MangaIdentityMatch(
      confidence: confidence,
      score: score,
      reasons: reasons,
    );
  }

  Manga merge(Manga preferred, Manga fallback) {
    final preferredIsAniList = preferred.anilistId != null;
    final primary = preferredIsAniList || fallback.anilistId == null
        ? preferred
        : fallback;
    final secondary = identical(primary, preferred) ? fallback : preferred;
    final aliases = <String>{
      primary.title,
      secondary.title,
      ...primary.aliases,
      ...secondary.aliases,
    }.where((value) => value.trim().isNotEmpty).toList(growable: false);

    return primary.copyWith(
      anilistId: primary.anilistId ?? secondary.anilistId,
      malId: primary.malId ?? secondary.malId,
      kitsuId: primary.kitsuId ?? secondary.kitsuId,
      mangaDexId: primary.mangaDexId ?? secondary.mangaDexId,
      metadataProviderIds: {
        ...secondary.allMetadataProviderIds,
        ...primary.allMetadataProviderIds,
      },
      sourceMappings: {
        ...secondary.allSourceMappings,
        ...primary.allSourceMappings,
      },
      aliases: aliases,
      authors: <String>{...primary.authors, ...secondary.authors}.toList(),
      coverUrl: primary.coverUrl.isNotEmpty
          ? primary.coverUrl
          : secondary.coverUrl,
      synopsis:
          primary.synopsis.isNotEmpty &&
              primary.synopsis != 'Synopsis unavailable.'
          ? primary.synopsis
          : secondary.synopsis,
      startYear: primary.startYear ?? secondary.startYear,
      format: primary.format != MangaFormat.unknown
          ? primary.format
          : secondary.format,
      isAdult: primary.isAdult || secondary.isAdult,
      genres: <String>{...primary.genres, ...secondary.genres}.toList(),
      chapterCount: primary.metadataChapterCount > 0
          ? primary.metadataChapterCount
          : secondary.metadataChapterCount,
    );
  }

  bool _knownIdMatch(Manga left, Manga right) {
    bool overlaps(Map<String, String> a, Map<String, String> b) =>
        a.entries.any((entry) => b[entry.key] == entry.value);
    return left.id == right.id ||
        overlaps(left.allMetadataProviderIds, right.allMetadataProviderIds) ||
        overlaps(left.allSourceMappings, right.allSourceMappings);
  }

  bool _knownIdConflict(Manga left, Manga right) {
    const canonicalProviders = <String>{
      'anilist',
      'mal',
      'kitsu',
      'mangadex',
      'webtoon',
    };
    final leftIds = {
      ...left.allMetadataProviderIds,
      if (left.mangaDexId != null) 'mangadex': left.mangaDexId!,
    };
    final rightIds = {
      ...right.allMetadataProviderIds,
      if (right.mangaDexId != null) 'mangadex': right.mangaDexId!,
    };
    return canonicalProviders.any((provider) {
      final leftId = leftIds[provider]?.trim();
      final rightId = rightIds[provider]?.trim();
      return leftId != null &&
          leftId.isNotEmpty &&
          rightId != null &&
          rightId.isNotEmpty &&
          leftId != rightId;
    });
  }

  bool _formatConflict(Manga left, Manga right) {
    final a = left.format;
    final b = right.format;
    return a != MangaFormat.unknown && b != MangaFormat.unknown && a != b;
  }

  bool _editionConflict(Manga left, Manga right) {
    const markers = <String>{
      'remake',
      'colored',
      'colour',
      'one shot',
      'oneshot',
      'light novel',
      'novel',
      'sequel',
      'spin off',
      'adaptation',
    };
    final a = normalizeTitle(left.title).split(' ').toSet();
    final b = normalizeTitle(right.title).split(' ').toSet();
    for (final marker in markers) {
      final words = marker.split(' ');
      final inA = words.every(a.contains);
      final inB = words.every(b.contains);
      if (inA != inB) return true;
    }
    return false;
  }

  Set<String> _titles(Manga manga) {
    final values = <String>{};
    for (final raw in <String>{manga.title, ...manga.aliases}) {
      final normalized = normalizeTitle(raw);
      if (normalized.isEmpty) continue;
      values.add(normalized);
      var decorated = normalized;
      for (var pass = 0; pass < 4; pass++) {
        final stripped = decorated
            .replaceFirst(RegExp(r'^read\s+'), '')
            .replaceFirst(
              RegExp(
                r'\s+(?:mangakakalot|demonic scans?|mangadex|mangakatana|asura scans?|weeb central)$',
              ),
              '',
            )
            .replaceFirst(
              RegExp(
                r'\s+(?:completed|ongoing|official(?:\s+translation)?|english(?:\s+translation)?|manga(?:\s+online)?|manhwa|manhua|webtoon|comic)$',
              ),
              '',
            );
        if (stripped == decorated) break;
        decorated = stripped;
        if (decorated.isNotEmpty) values.add(decorated);
      }
    }
    values.remove('');
    return values;
  }

  double _bestTokenSimilarity(Set<String> left, Set<String> right) {
    var best = 0.0;
    for (final a in left) {
      for (final b in right) {
        final x = a.split(' ').toSet();
        final y = b.split(' ').toSet();
        if (x.isEmpty || y.isEmpty) continue;
        final score = x.intersection(y).length / x.union(y).length;
        if (score > best) best = score;
      }
    }
    return best;
  }
}
