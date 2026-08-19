import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/features/reader/data/chapter_number_parser.dart';

void main() {
  test('parses explicit chapter label variants', () {
    expect(ChapterNumberParser.parseVisibleLabel('Chapter 12'), 12);
    expect(ChapterNumberParser.parseVisibleLabel('Chapter: 12.5'), 12.5);
    expect(ChapterNumberParser.parseVisibleLabel('Chapter - 13'), 13);
    expect(ChapterNumberParser.parseVisibleLabel('Chap 14'), 14);
    expect(ChapterNumberParser.parseVisibleLabel('Ch. #15'), 15);
    expect(ChapterNumberParser.parseVisibleLabel('Episode 16'), 16);
  });

  test('does not mistake arbitrary ids or dates for chapter numbers', () {
    expect(
      ChapterNumberParser.parseVisibleLabel('uploaded 2026-08-19'),
      isNull,
    );
    expect(ChapterNumberParser.parseVisibleLabel('series id 123456'), isNull);
    expect(
      ChapterNumberParser.parseVisibleLabel('123', allowPlainNumber: false),
      isNull,
    );
    expect(
      ChapterNumberParser.parseVisibleLabel('123', allowPlainNumber: true),
      123,
    );
  });
}
