class ChapterNumberParser {
  const ChapterNumberParser._();

  /// Parses only explicit human-facing chapter labels.
  ///
  /// Supported examples include:
  /// Chapter 12, Chapter: 12, Chapter - 12, Chap 12, Ch. 12,
  /// Act 15.5, Part 32.5, Lesson 36, Episode 10, Ep. 10, #455 and,
  /// when [allowPlainNumber] is true, a label containing only `455`.
  ///
  /// It intentionally never pulls arbitrary numbers from URLs, UUIDs,
  /// timestamps, database ids, or mixed free-form text.
  static double? parseVisibleLabel(
    String raw, {
    bool allowPlainNumber = false,
  }) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;

    const number = r'(\d+(?:\.\d+)?)';
    const separator = r'\s*(?:no\.?\s*)?(?:#|:|-)?\s*';

    final patterns = <RegExp>[
      RegExp(
        r'\b(?:chapter|chap|ch\.?)' + separator + number + r'\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\bact\.?' + separator + number + r'\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\bpart' + separator + number + r'\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\blesson' + separator + number + r'\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(?:episode|ep\.?)' + separator + number + r'\b',
        caseSensitive: false,
      ),
      RegExp(
        r'^\s*#\s*' + number + r'\b',
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final parsed = double.tryParse(match.group(1) ?? '');
      if (_valid(parsed)) return parsed;
    }

    if (allowPlainNumber) {
      final plain = RegExp(
        r'^\s*(\d+(?:\.\d+)?)\s*$',
      ).firstMatch(text);
      final parsed = double.tryParse(plain?.group(1) ?? '');
      if (_valid(parsed)) return parsed;
    }

    return null;
  }

  static bool _valid(double? value) {
    if (value == null || !value.isFinite || value < 0) return false;
    // Corruption guard only. Long-running manga can legitimately exceed 1000.
    return value <= 20000;
  }

  static String label(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}
