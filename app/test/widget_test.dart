import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/app.dart';

void main() {
  test('app widget is TsukiApp', () {
    expect(const TsukiApp(), isA<Widget>());
  });
}
