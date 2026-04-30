import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/features/hybrid_webview/presentation/widgets/permission_chip.dart';

void main() {
  group('PermissionChip Widget Tests', () {
    testWidgets('renders correctly when granted is true', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PermissionChip(label: 'Camera', granted: true),
          ),
        ),
      );

      final chipFinder = find.byType(Chip);
      expect(chipFinder, findsOneWidget);
      
      final labelFinder = find.text('Camera');
      expect(labelFinder, findsOneWidget);

      final iconFinder = find.byIcon(Icons.check_circle);
      expect(iconFinder, findsOneWidget);

      final chip = tester.widget<Chip>(chipFinder);
      expect(chip.backgroundColor, Colors.green.withValues(alpha: 0.1));
    });

    testWidgets('renders correctly when granted is false', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PermissionChip(label: 'Location', granted: false),
          ),
        ),
      );

      final chipFinder = find.byType(Chip);
      expect(chipFinder, findsOneWidget);

      final iconFinder = find.byIcon(Icons.cancel);
      expect(iconFinder, findsOneWidget);

      final chip = tester.widget<Chip>(chipFinder);
      expect(chip.backgroundColor, Colors.red.withValues(alpha: 0.1));
    });
  });
}
