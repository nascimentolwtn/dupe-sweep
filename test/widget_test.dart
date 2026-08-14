// Smoke test for the app's actual entry point. The stock Flutter template
// this file started as (`MyApp` counter demo) referenced a class that
// doesn't exist in this project and never compiled.
//
// PermissionScreen (the app's home widget) calls Permission.photos.status
// in initState, which goes over a platform MethodChannel -- with no real
// Android engine in a widget test, that call needs mocking or it throws.
// Mocking it to return "denied" exercises a real, deterministic path: the
// initial "Grant Photo Access" screen renders instead of auto-navigating
// away.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dupesweep/main.dart';

void main() {
  const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'checkPermissionStatus') {
        return 0; // PermissionStatus.denied
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

  testWidgets('DupesweepApp launches to the Grant Photo Access screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(const DupesweepApp());
    await tester.pumpAndSettle();

    expect(find.text('Find & Review Duplicate Photos'), findsOneWidget);
    expect(find.text('Grant Photo Access'), findsOneWidget);
  });
}
