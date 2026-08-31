import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/features/migration/data/migration_models.dart';

void main() {
  const validator = MigrationValidator();

  test('accepts version one and normalizes decimal chapter progress', () {
    final document = validator.decode(
      jsonEncode({
        'format': 'tsuki-migration',
        'schemaVersion': 1,
        'createdAt': '2026-08-28T00:00:00Z',
        'sources': [
          {'id': 'mangadex'},
        ],
        'entries': [
          {
            'source': 'mangadex',
            'sourceMangaId': 'abc',
            'sourceUrl': 'https://mangadex.org/title/abc',
            'title': 'Solo Leveling',
            'progress': {'lastReadChapter': 'Ch. 72.5'},
          },
        ],
      }),
    );
    expect(document.entries.single.normalizedChapterNumber, 72.5);
    expect(document.entries.single.rawChapter, 'Ch. 72.5');
  });

  test('preserves special progress without inventing a number', () {
    expect(MigrationValidator.normalizeChapter('Prologue'), isNull);
    expect(MigrationValidator.normalizeChapter('Extra'), isNull);
    expect(MigrationValidator.normalizeChapter('Episode 22'), 22);
  });

  test('normalizes labelled progress with chapter titles conservatively', () {
    expect(MigrationValidator.normalizeChapter('Chapter 72 - Return'), 72);
    expect(MigrationValidator.normalizeChapter('Ch. 50.1: Aftermath'), 50.1);
    expect(MigrationValidator.normalizeChapter('Episode #22 (Finale)'), 22);
    expect(MigrationValidator.normalizeChapter('Latest update 99'), isNull);
  });

  test('rejects invalid JSON and unsupported schema versions', () {
    expect(
      () => validator.decode('{bad'),
      throwsA(isA<MigrationValidationException>()),
    );
    expect(
      () => validator.decode(
        jsonEncode({
          'format': 'tsuki-migration',
          'schemaVersion': 2,
          'entries': [],
        }),
      ),
      throwsA(isA<MigrationValidationException>()),
    );
  });

  test('one malformed entry does not abort valid entries', () {
    final document = validator.decode(
      jsonEncode({
        'format': 'tsuki-migration',
        'schemaVersion': 1,
        'entries': [
          {'source': 'comick', 'sourceMangaId': 'ok', 'title': 'Valid'},
          {'source': 'comick', 'title': 'Missing id'},
        ],
      }),
    );
    expect(document.entries, hasLength(1));
    expect(document.validationErrors, hasLength(1));
  });
}
