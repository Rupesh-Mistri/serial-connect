import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_connect/screens/flasher_screen.dart';

void main() {
  testWidgets('FlasherScreen UI smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FlasherScreen(),
      ),
    );

    expect(find.text('Microcontroller Flasher & Monitor'), findsOneWidget);
    expect(find.text('Target Microcontroller Board'), findsOneWidget);
    expect(find.text('📁 Select .bin/.hex'), findsOneWidget);
    expect(find.text('⚡ Convert .cpp/.ino'), findsOneWidget);
    expect(find.text('Serial Terminal Monitor'), findsOneWidget);
  });
}
