import 'package:ecosathi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('EcoSathi app loads splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const EcoSathiApp());

    expect(find.text('EcoSathi'), findsOneWidget);
    expect(find.text('Smart Waste Management'), findsOneWidget);
  });

  testWidgets('Map screen exposes live location tracking UI', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MapScreen()));

    expect(find.text('Live Location Map'), findsAtLeastNWidgets(1));
    expect(find.text('Current location auto-detected'), findsOneWidget);
  });
}
