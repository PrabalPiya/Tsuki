import 'dart:convert';

enum ImportMatchStatus { matched, needsReview, unmatched, conflict, error }

class ImportedMangaEntry {
  const ImportedMangaEntry({
    required this.source,
    required this.sourceMangaId,
    required this.title,
    required this.aliases,
    required this.rawChapter,
    required this.normalizedChapterNumber,
    this.sourceUrl,
    this.author,
  });

  final String source;
  final String sourceMangaId;
  final String? sourceUrl;
  final String title;
  final List<String> aliases;
  final String? author;
  final String? rawChapter;
  final double? normalizedChapterNumber;

  String get sourceKey => '$source:$sourceMangaId';
}

class MigrationDocument {
  const MigrationDocument({
    required this.createdAt,
    required this.sources,
    required this.entries,
    required this.validationErrors,
  });

  final DateTime createdAt;
  final List<String> sources;
  final List<ImportedMangaEntry> entries;
  final List<String> validationErrors;
}

class MigrationValidationException implements Exception {
  const MigrationValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MigrationValidator {
  const MigrationValidator();

  static const maxBytes = 5 * 1024 * 1024;
  static const maxEntries = 2500;
  static const maxStringLength = 500;

  MigrationDocument decode(String raw) {
    if (utf8.encode(raw).length > maxBytes) {
      throw const MigrationValidationException('Migration file is too large.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const MigrationValidationException('Migration JSON is malformed.');
    }
    if (decoded is! Map) {
      throw const MigrationValidationException(
        'Migration root must be an object.',
      );
    }
    final map = Map<String, dynamic>.from(decoded);
    if (map['format'] != 'tsuki-migration') {
      throw const MigrationValidationException(
        'This is not a Tsuki migration file.',
      );
    }
    if (map['schemaVersion'] != 1) {
      throw MigrationValidationException(
        'Unsupported migration schema version: ${map['schemaVersion']}.',
      );
    }
    final rawEntries = map['entries'];
    if (rawEntries is! List || rawEntries.length > maxEntries) {
      throw const MigrationValidationException(
        'Migration entry count is invalid.',
      );
    }

    final entries = <ImportedMangaEntry>[];
    final errors = <String>[];
    for (var index = 0; index < rawEntries.length; index++) {
      try {
        final rawEntry = rawEntries[index];
        if (rawEntry is! Map) throw const FormatException('not an object');
        entries.add(_entry(Map<String, dynamic>.from(rawEntry)));
      } catch (_) {
        errors.add('Entry ${index + 1} is malformed and was skipped.');
      }
    }
    final sources = (map['sources'] as List? ?? const [])
        .map((value) => value is Map ? value['id'] : value)
        .whereType<String>()
        .where((value) => value.length <= 80)
        .toSet()
        .toList(growable: false);
    return MigrationDocument(
      createdAt:
          DateTime.tryParse(map['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      sources: sources,
      entries: entries,
      validationErrors: errors,
    );
  }

  ImportedMangaEntry _entry(Map<String, dynamic> json) {
    final source = _required(json['source'] ?? json['site'], 80);
    final sourceMangaId = _required(
      json['sourceMangaId'] ?? json['sourceId'],
      200,
    );
    final title = _required(json['title'], 300);
    final sourceUrl = _optional(
      json['sourceUrl'] ?? json['url'],
      maxStringLength,
    );
    if (sourceUrl != null) {
      final uri = Uri.tryParse(sourceUrl);
      if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
        throw const FormatException('invalid URL');
      }
    }
    final aliases = (json['aliases'] as List? ?? const [])
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && value.length <= 300)
        .take(20)
        .toList(growable: false);
    final progress = json['progress'] is Map
        ? Map<String, dynamic>.from(json['progress'] as Map)
        : const <String, dynamic>{};
    final rawChapter = _optional(
      progress['lastReadChapter'] ?? json['lastReadChapter'],
      100,
    );
    return ImportedMangaEntry(
      source: source.toLowerCase(),
      sourceMangaId: sourceMangaId,
      sourceUrl: sourceUrl,
      title: title,
      aliases: aliases,
      author: _optional(json['author'], 200),
      rawChapter: rawChapter,
      normalizedChapterNumber: normalizeChapter(rawChapter),
    );
  }

  static double? normalizeChapter(String? raw) {
    if (raw == null) return null;
    final value = raw.trim().toLowerCase();
    final match =
        RegExp(
          r'^(?:chapter|ch\.?|episode|ep\.?)\s*[:#-]?\s*(\d+(?:\.\d+)?)(?=\s*(?:$|[-:|()]))',
        ).firstMatch(value) ??
        RegExp(r'^(\d+(?:\.\d+)?)$').firstMatch(value);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  String _required(Object? value, int maxLength) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text.length > maxLength) throw const FormatException();
    return text;
  }

  String? _optional(Object? value, int maxLength) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    if (text.length > maxLength) throw const FormatException();
    return text;
  }
}
