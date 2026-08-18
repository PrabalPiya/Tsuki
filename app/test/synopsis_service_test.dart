import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/features/search/data/metadata_provider.dart';

void main() {
  test('synopsis removes markup and remains concise', () {
    const service = DeterministicSynopsisService();
    final value = service.summarize(
      '<b>A courier crosses the city.</b> A hidden letter changes the route. The storm closes in. A fourth sentence adds tone. A fifth sentence must not appear.',
    );
    expect(value, contains('courier'));
    expect(value, isNot(contains('<b>')));
    expect(RegExp(r'[.!?]').allMatches(value).length, lessThanOrEqualTo(4));
  });
}
