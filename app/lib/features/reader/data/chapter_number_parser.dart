class ChapterNumberParser {
  const ChapterNumberParser._();

  /// Parses ONLY explicit human-facing chapter labels.
  ///
  /// Supported examples:
  ///
  /// Chapter 12
  /// Chapter 12.5
  /// Ch. 12
  /// Act. 15.5
  /// Part 32.5
  /// Lesson 36
  /// Episode 10
  /// Ep. 10
  /// #455
  /// 455
  ///
  /// It intentionally never parses arbitrary numbers
  /// from URLs, UUIDs, database IDs or timestamps.
  static double? parseVisibleLabel(
    String raw, {
    bool allowPlainNumber = false,
  }) {
    final text = raw
        .replaceAll(
          RegExp(r'\s+'),
          ' ',
        )
        .trim();

    if (text.isEmpty) {
      return null;
    }

    final patterns = <RegExp>[
      RegExp(
        r'\bchapter\s*(?:no\.?\s*)?#?\s*(\d+(?:\.\d+)?)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\bch\.?\s*#?\s*(\d+(?:\.\d+)?)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\bact\.?\s*#?\s*(\d+(?:\.\d+)?)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\bpart\s*#?\s*(\d+(?:\.\d+)?)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\blesson\s*#?\s*(\d+(?:\.\d+)?)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\bepisode\s*#?\s*(\d+(?:\.\d+)?)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\bep\.?\s*#?\s*(\d+(?:\.\d+)?)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'^\s*#\s*(\d+(?:\.\d+)?)\b',
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match =
          pattern.firstMatch(text);

      if (match == null) {
        continue;
      }

      final number =
          double.tryParse(
        match.group(1) ?? '',
      );

      if (_valid(number)) {
        return number;
      }
    }

    if (allowPlainNumber) {
      final plain =
          RegExp(
        r'^\s*(\d+(?:\.\d+)?)\s*$',
      ).firstMatch(text);

      final number =
          double.tryParse(
        plain?.group(1) ?? '',
      );

      if (_valid(number)) {
        return number;
      }
    }

    return null;
  }

  static bool _valid(
    double? value,
  ) {
    if (value == null ||
        !value.isFinite ||
        value < 0) {
      return false;
    }

    /*
     * This is only a corruption guard.
     *
     * Do NOT limit against AniList chapterCount.
     *
     * Manga can legitimately exceed 1000 chapters.
     */
    return value <= 20000;
  }

  static String label(
    double value,
  ) {
    return value ==
            value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
}