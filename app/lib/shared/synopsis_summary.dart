String summarizeSynopsis(String text) {
  final cleaned = text
      .replaceAll(
        RegExp(
          r'<br\s*/?>',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(r'<[^>]*>'),
        ' ',
      )
      .replaceAll(
        RegExp(r'\s+'),
        ' ',
      )
      .trim();

  if (cleaned.isEmpty) {
    return 'No synopsis available.';
  }

  /*
   * Keep the same summary everywhere in the app.
   *
   * The goal is to make the complete summary short enough
   * for the Details page while Discover can simply preview
   * the first 4 lines of exactly this same text.
   */
  const maxCharacters = 430;
  const maxSentences = 4;

  if (cleaned.length <= maxCharacters) {
    return cleaned;
  }

  final sentences = cleaned
      .split(
        RegExp(r'(?<=[.!?])\s+'),
      )
      .map(
        (sentence) => sentence.trim(),
      )
      .where(
        (sentence) => sentence.isNotEmpty,
      )
      .toList();

  final selected = <String>[];
  var characterCount = 0;

  for (final sentence in sentences) {
    if (selected.length >= maxSentences) {
      break;
    }

    final extraLength =
        sentence.length +
        (selected.isEmpty ? 0 : 1);

    if (characterCount + extraLength >
        maxCharacters) {
      break;
    }

    selected.add(sentence);
    characterCount += extraLength;
  }

  if (selected.isNotEmpty) {
    return selected.join(' ');
  }

  /*
   * Some sources can provide one extremely long sentence.
   * In that case, shorten at a word boundary.
   */
  final words = cleaned.split(' ');

  final buffer = StringBuffer();

  for (final word in words) {
    final candidate = buffer.isEmpty
        ? word
        : '${buffer.toString()} $word';

    if (candidate.length >
        maxCharacters) {
      break;
    }

    if (buffer.isNotEmpty) {
      buffer.write(' ');
    }

    buffer.write(word);
  }

  var result = buffer.toString().trim();

  /*
   * Prefer ending at the last full sentence if it is
   * reasonably close to the end of the shortened text.
   */
  final punctuation =
      RegExp(r'[.!?]')
          .allMatches(result)
          .toList();

  if (punctuation.isNotEmpty) {
    final last =
        punctuation.last.end;

    if (last >= result.length * .65) {
      result = result
          .substring(0, last)
          .trim();
    }
  }

  if (result.isEmpty) {
    return 'No synopsis available.';
  }

  return result;
}