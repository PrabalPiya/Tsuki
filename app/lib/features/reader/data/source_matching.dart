import '../../../core/models/manga.dart';

/// Shared helpers used by non-ID-based manga sources.
///
/// The old implementation mostly required exact normalized title matches.
/// That caused many perfectly valid manga to resolve to no source because
/// scanlation sites often use different English/licensed/romanized titles.
class SourceMatching {
  const SourceMatching._();

  static String normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r'''['"`´’‘]'''), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Set<String> tokens(String value) {
    final normalized = normalize(value);

    if (normalized.isEmpty) {
      return const {};
    }

    return normalized
        .split(' ')
        .where((token) => token.length > 1)
        .toSet();
  }

  static double similarity(
    String left,
    String right,
  ) {
    final a = normalize(left);
    final b = normalize(right);

    if (a.isEmpty || b.isEmpty) {
      return 0;
    }

    if (a == b) {
      return 1;
    }

    final shorter =
        a.length <= b.length ? a : b;

    final longer =
        a.length > b.length ? a : b;

    if (shorter.length >= 5 &&
        longer.contains(shorter)) {
      final ratio =
          shorter.length / longer.length;

      if (ratio >= .88) {
        return .97;
      }

      if (ratio >= .72) {
        return .92;
      }
    }

    final aTokens = tokens(a);
    final bTokens = tokens(b);

    final union =
        aTokens.union(bTokens);

    final intersection =
        aTokens.intersection(bTokens);

    final tokenScore = union.isEmpty
        ? 0.0
        : intersection.length /
            union.length;

    final editScore =
        _editSimilarity(a, b);

    return (tokenScore * .65 +
            editScore * .35)
        .clamp(0.0, 1.0);
  }

  static String? bestMatchId(
    Manga canonical,
    List<Manga> candidates, {
    required String sourcePrefix,
    double minimumScore = .86,
    double ambiguityMargin = .035,
  }) {
    if (candidates.isEmpty) {
      return null;
    }

    final expectedNames = <String>{
      canonical.title,
      ...canonical.aliases,
    }.where(
      (value) => value.trim().isNotEmpty,
    );

    String? bestId;
    var bestScore = 0.0;
    var secondScore = 0.0;

    for (final candidate in candidates) {
      final candidateNames = <String>{
        candidate.title,
        ...candidate.aliases,
      }.where(
        (value) => value.trim().isNotEmpty,
      );

      var candidateBest = 0.0;

      for (final expected
          in expectedNames) {
        for (final actual
            in candidateNames) {
          final score =
              similarity(
            expected,
            actual,
          );

          if (score > candidateBest) {
            candidateBest = score;
          }
        }
      }

      if (candidateBest > bestScore) {
        secondScore = bestScore;
        bestScore = candidateBest;

        bestId = candidate.id
            .replaceFirst(
          sourcePrefix,
          '',
        );
      } else if (candidateBest >
          secondScore) {
        secondScore = candidateBest;
      }
    }

    if (bestId == null ||
        bestScore < minimumScore) {
      return null;
    }

    if (secondScore > 0 &&
        bestScore - secondScore <
            ambiguityMargin &&
        bestScore < .97) {
      return null;
    }

    return bestId;
  }

  static double _editSimilarity(
    String a,
    String b,
  ) {
    final distance =
        _levenshtein(a, b);

    final maxLength =
        a.length > b.length
            ? a.length
            : b.length;

    if (maxLength == 0) {
      return 1;
    }

    return 1 -
        distance / maxLength;
  }

  static int _levenshtein(
    String a,
    String b,
  ) {
    if (a == b) {
      return 0;
    }

    if (a.isEmpty) {
      return b.length;
    }

    if (b.isEmpty) {
      return a.length;
    }

    var previous =
        List<int>.generate(
      b.length + 1,
      (index) => index,
    );

    for (var i = 0;
        i < a.length;
        i++) {
      final current =
          List<int>.filled(
        b.length + 1,
        0,
      );

      current[0] = i + 1;

      for (var j = 0;
          j < b.length;
          j++) {
        final insertion =
            current[j] + 1;

        final deletion =
            previous[j + 1] + 1;

        final substitution =
            previous[j] +
                (a.codeUnitAt(i) ==
                        b.codeUnitAt(j)
                    ? 0
                    : 1);

        var value = insertion;

        if (deletion < value) {
          value = deletion;
        }

        if (substitution < value) {
          value = substitution;
        }

        current[j + 1] =
            value;
      }

      previous = current;
    }

    return previous.last;
  }
}