// This is a basic Flutter widget test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// We import the main.dart file which contains MyApp
import 'package:card_detector_app/main.dart';

void main() {
  testWidgets('App builds and shows app bar', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    // This now works because MyApp is defined in lib/main.dart
    await tester.pumpWidget(const MyApp());

    // Wait for all animations and frame-building to settle,
    // especially since CardDetectorPage initializes a camera.
    // We'll pump a few frames to be safe.
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Verify that our app shows the AppBar with the correct title.
    expect(find.text('Card Detector'), findsOneWidget);

    // Verify that the FloatingActionButton (the camera button) is present.
    expect(find.byIcon(Icons.camera), findsOneWidget);
  });
}
