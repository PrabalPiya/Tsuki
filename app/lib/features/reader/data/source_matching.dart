import '../../../core/models/manga.dart';

/// Shared conservative title matching for sources without stable external IDs.
class SourceMatching {
  const SourceMatching._();

  static String normalize(String value) {
    var normalized = value
        .toLowerCase()
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r'''['"`´’‘]'''), '')
        .replaceAll(RegExp(r'[àáâãäåāăą]'), 'a')
        .replaceAll(RegExp(r'[çćč]'), 'c')
        .replaceAll(RegExp(r'[ďð]'), 'd')
        .replaceAll(RegExp(r'[èéêëēĕėęě]'), 'e')
        .replaceAll(RegExp(r'[ìíîïī]'), 'i')
        .replaceAll(RegExp(r'[ñńň]'), 'n')
        .replaceAll(RegExp(r'[òóôõöøō]'), 'o')
        .replaceAll(RegExp(r'[řŕ]'), 'r')
        .replaceAll(RegExp(r'[šśş]'), 's')
        .replaceAll(RegExp(r'[ùúûüū]'), 'u')
        .replaceAll(RegExp(r'[ýÿ]'), 'y')
        .replaceAll(RegExp(r'[žźż]'), 'z')
        .replaceAll('æ', 'ae')
        .replaceAll('œ', 'oe')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(\d+)(?:st|nd|rd|th)\b'),
      (match) => match.group(1)!,
    );
    const romanNumbers = <String, String>{
      'ii': '2',
      'iii': '3',
      'iv': '4',
      'v': '5',
      'vi': '6',
      'vii': '7',
      'viii': '8',
      'ix': '9',
      'x': '10',
    };
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(?:ii|iii|iv|v|vi|vii|viii|ix|x)\b'),
      (match) => romanNumbers[match.group(0)]!,
    );
    normalized = normalized
        .replaceAll(RegExp(r'\bseason\s+(ii|two)\b'), 'season 2')
        .replaceAll(RegExp(r'\bseason\s+(iii|three)\b'), 'season 3')
        .replaceAll(RegExp(r'\bseason\s+(iv|four)\b'), 'season 4')
        .replaceAll(RegExp(r'\b(ii|two)\s+season\b'), 'season 2')
        .replaceAll(RegExp(r'\b(iii|three)\s+season\b'), 'season 3')
        .replaceAll(RegExp(r'\b(iv|four)\s+season\b'), 'season 4');
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(\d+)\s+season\b'),
      (match) => 'season ${match.group(1)}',
    );
    return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Ordered, bounded searches covering harmless source-title decorations.
  static List<String> searchQueries(Manga manga, {int maximum = 8}) {
    final queries = <String>[];
    final seen = <String>{};
    void add(String value) {
      final cleaned = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      final key = normalize(cleaned);
      if (cleaned.length >= 2 && key.isNotEmpty && seen.add(key)) {
        queries.add(cleaned);
      }
    }

    for (final title in <String>{manga.title, ...manga.aliases}) {
      add(title);
      add(_stripHarmlessDecoration(title));
      add(
        title.replaceFirst(
          RegExp(r'^\s*(?:the|a|an)\s+', caseSensitive: false),
          '',
        ),
      );
      if (queries.length >= maximum) break;
    }
    return queries.take(maximum).toList(growable: false);
  }

  static Set<String> tokens(String value) {
    final normalized = normalize(value);
    if (normalized.isEmpty) return const {};
    return normalized.split(' ').where((token) => token.length > 1).toSet();
  }

  static double similarity(String left, String right) {
    var best = 0.0;
    for (final a in _variants(left)) {
      for (final b in _variants(right)) {
        if (!_compatible(a, b)) continue;
        final score = _normalizedSimilarity(a, b);
        if (score > best) best = score;
      }
    }
    return best;
  }

  static double _normalizedSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;

    final shorter = a.length <= b.length ? a : b;
    final longer = a.length > b.length ? a : b;
    if (shorter.length >= 5 && longer.contains(shorter)) {
      final ratio = shorter.length / longer.length;
      if (ratio >= .88) return .97;
      if (ratio >= .72) return .92;
    }

    final aTokens = tokens(a);
    final bTokens = tokens(b);
    final union = aTokens.union(bTokens);
    final intersection = aTokens.intersection(bTokens);
    final tokenScore = union.isEmpty ? 0.0 : intersection.length / union.length;
    final shorterTokenCount = aTokens.length < bTokens.length
        ? aTokens.length
        : bTokens.length;
    final containmentScore = shorterTokenCount == 0
        ? 0.0
        : intersection.length / shorterTokenCount;
    final editScore = _editSimilarity(a, b);
    return (tokenScore * .45 + containmentScore * .25 + editScore * .30).clamp(
      0.0,
      1.0,
    );
  }

  static String? bestMatchId(
    Manga canonical,
    List<Manga> candidates, {
    required String sourcePrefix,
    double minimumScore = .86,
    double ambiguityMargin = .035,
  }) {
    if (candidates.isEmpty) return null;
    final expectedNames = <String>{
      canonical.title,
      ...canonical.aliases,
    }.where((value) => value.trim().isNotEmpty);

    String? bestId;
    var bestScore = 0.0;
    var secondScore = 0.0;
    for (final candidate in candidates) {
      final candidateNames = <String>{
        candidate.title,
        ...candidate.aliases,
      }.where((value) => value.trim().isNotEmpty);
      var candidateBest = 0.0;
      for (final expected in expectedNames) {
        for (final actual in candidateNames) {
          final score = similarity(expected, actual);
          if (score > candidateBest) candidateBest = score;
        }
      }
      if (candidateBest > bestScore) {
        secondScore = bestScore;
        bestScore = candidateBest;
        bestId = candidate.id.replaceFirst(sourcePrefix, '');
      } else if (candidateBest > secondScore) {
        secondScore = candidateBest;
      }
    }

    if (bestId == null || bestScore < minimumScore) return null;
    if (secondScore > 0 && bestScore - secondScore < ambiguityMargin) {
      return null;
    }
    return bestId;
  }

  static Set<String> _variants(String value) {
    final result = <String>{};
    void add(String raw) {
      final normalized = normalize(raw);
      if (normalized.isEmpty) return;
      result.add(normalized);
      result.add(normalized.replaceFirst(RegExp(r'^(?:the|a|an)\s+'), ''));
      result.add(
        normalized.replaceFirst(
          RegExp(
            r'\s+(?:official(?:\s+translation)?|english|manga|manhwa|manhua|webtoon|comic)$',
          ),
          '',
        ),
      );
    }

    add(value);
    add(_stripHarmlessDecoration(value));
    result.remove('');
    return result;
  }

  static String _stripHarmlessDecoration(String value) => value
      .replaceAll(
        RegExp(
          r'\s*[\[(](?:official(?:\s+translation)?|english|manga|manhwa|manhua|webtoon|comic)[\])]\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'\s+(?:official(?:\s+translation)?|english\s+translation)$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  static bool _compatible(String left, String right) {
    const protectedMarkers = <String>{
      'remake',
      'colored',
      'colour',
      'oneshot',
      'novel',
      'sequel',
      'spinoff',
    };
    final a = left.replaceAll(' ', '');
    final b = right.replaceAll(' ', '');
    for (final marker in protectedMarkers) {
      if (a.contains(marker) != b.contains(marker)) return false;
    }
    final leftNumbers = RegExp(r'\b\d+\b')
        .allMatches(left)
        .map((match) => match.group(0)!)
        .toSet();
    final rightNumbers = RegExp(r'\b\d+\b')
        .allMatches(right)
        .map((match) => match.group(0)!)
        .toSet();
    return leftNumbers.length == rightNumbers.length &&
        leftNumbers.containsAll(rightNumbers);
  }

  static double _editSimilarity(String a, String b) {
    final distance = _levenshtein(a, b);
    final maxLength = a.length > b.length ? a.length : b.length;
    return maxLength == 0 ? 1 : 1 - distance / maxLength;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var previous = List<int>.generate(b.length + 1, (index) => index);
    for (var i = 0; i < a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final insertion = current[j] + 1;
        final deletion = previous[j + 1] + 1;
        final substitution =
            previous[j] + (a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1);
        current[j + 1] = insertion < deletion
            ? (insertion < substitution ? insertion : substitution)
            : (deletion < substitution ? deletion : substitution);
      }
      previous = current;
    }
    return previous.last;
  }
}
