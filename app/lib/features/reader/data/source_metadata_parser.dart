import 'package:html/dom.dart';

import '../../../core/models/manga.dart';

abstract final class SourceMetadataParser {
  static String text(Document document, List<String> selectors) {
    for (final selector in selectors) {
      final value = document
          .querySelector(selector)
          ?.text
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }

  static String attribute(
    Document document,
    List<String> selectors,
    List<String> attributes,
  ) {
    for (final selector in selectors) {
      final element = document.querySelector(selector);
      for (final attribute in attributes) {
        final value = element?.attributes[attribute]?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return '';
  }

  static MangaStatus status(String raw) {
    final match = RegExp(
      r'\b(?:status|state)\s*:?\s*(ongoing|completed|complete|hiatus|cancelled|canceled|dropped|axed)\b',
      caseSensitive: false,
    ).firstMatch(raw.replaceAll(RegExp(r'\s+'), ' '));
    return switch (match?.group(1)?.toLowerCase()) {
      'ongoing' => MangaStatus.ongoing,
      'completed' || 'complete' => MangaStatus.completed,
      'hiatus' => MangaStatus.hiatus,
      'cancelled' || 'canceled' || 'dropped' || 'axed' => MangaStatus.cancelled,
      _ => MangaStatus.unknown,
    };
  }

  static List<String> labelledValues(String raw, List<String> labels) {
    final values = <String>{};
    for (final label in labels) {
      final match = RegExp(
        '(?:^|\\n)\\s*${RegExp.escape(label)}\\s*:?\\s*([^\\n]+)',
        caseSensitive: false,
      ).firstMatch(raw);
      if (match == null) continue;
      values.addAll(
        match
            .group(1)!
            .split(RegExp(r'[,;/|]'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty),
      );
    }
    return values.toList(growable: false);
  }
}
