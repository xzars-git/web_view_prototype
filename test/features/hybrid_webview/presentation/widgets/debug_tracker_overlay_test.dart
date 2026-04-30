import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_view_prototype/features/hybrid_webview/presentation/widgets/debug_tracker_overlay.dart';

void main() {
  group('DebugTrackerOverlay Widget Tests', () {
    testWidgets('renders log entries correctly', (WidgetTester tester) async {
      final logs = ['Log 1', 'Log 2', 'Log 3'];
      
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DebugTrackerOverlay(logs: logs),
          ),
        ),
      );

      expect(find.text('DEBUG TRACKER'), findsOneWidget);
      expect(find.text('Log 1'), findsOneWidget);
      expect(find.text('Log 2'), findsOneWidget);
      expect(find.text('Log 3'), findsOneWidget);
    });

    testWidgets('renders empty state correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DebugTrackerOverlay(logs: []),
          ),
        ),
      );

      expect(find.text('DEBUG TRACKER'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
      
      final listView = tester.widget<ListView>(find.byType(ListView));
      // In ListView.builder, itemCount is used.
      final builder = listView.childrenDelegate as SliverChildBuilderDelegate;
      expect(builder.childCount, 0);
    });

    testWidgets('copy button is present', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DebugTrackerOverlay(logs: ['test log']),
          ),
        ),
      );

      expect(find.text('COPY'), findsOneWidget);
      expect(find.byIcon(Icons.content_copy), findsOneWidget);
    });
  });
}
