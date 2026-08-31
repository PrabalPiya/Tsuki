abstract final class ChapterIdentity {
  static String? canonicalKey(double? number, String title) {
    if (number != null) {
      if (!number.isFinite || number < 0 || number > 20000) return null;
      final label = number == number.roundToDouble()
          ? number.toInt().toString()
          : number.toString();
      return 'number:$label';
    }

    final normalized = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (normalized.isEmpty) return null;
    final simplified = normalized
        .replaceFirst(RegExp(r'^(?:special|bonus|extra|sidestory)chapter'), '')
        .replaceFirst(RegExp(r'^chapter'), '')
        .replaceAll(RegExp(r'(?:chapter|episode)$'), '')
        .trim();
    return 'special:${simplified.isEmpty ? normalized : simplified}';
  }
}
