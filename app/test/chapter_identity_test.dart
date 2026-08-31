import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/identity/chapter_identity.dart';

void main() {
  test('numbered chapters use one stable numeric identity', () {
    expect(ChapterIdentity.canonicalKey(12, 'Chapter 12'), 'number:12');
    expect(ChapterIdentity.canonicalKey(12.5, 'Ch. 12.5'), 'number:12.5');
  });

  test('harmless special labels do not create duplicate chapters', () {
    expect(
      ChapterIdentity.canonicalKey(null, 'Special Chapter: The Beginning'),
      ChapterIdentity.canonicalKey(null, 'The Beginning'),
    );
    expect(
      ChapterIdentity.canonicalKey(null, 'Side Story Chapter 2'),
      ChapterIdentity.canonicalKey(null, 'Chapter 2'),
    );
  });

  test('ambiguous generic specials remain distinct', () {
    expect(
      ChapterIdentity.canonicalKey(null, 'Bonus Chapter'),
      isNot(ChapterIdentity.canonicalKey(null, 'Extra Chapter')),
    );
  });
}
