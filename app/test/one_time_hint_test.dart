import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsuki/shared/widgets/one_time_hint.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('hint is dismissible and only appears once', (tester) async {
    const hint = OneTimeHint(
      id: 'test_gesture',
      icon: Icons.swipe_rounded,
      text: 'Swipe to continue',
    );

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: hint)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Swipe to continue'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('Swipe to continue'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: hint)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Swipe to continue'), findsNothing);
  });
}
