// Basic widget test for the minimal meeting example.

import 'package:flutter_test/flutter_test.dart';

import 'package:gravix_cloud_example/main.dart';

void main() {
  testWidgets('renders the meeting lobby', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MeetingApp());

    // Lobby surface is visible with the core fields.
    expect(find.text('Join a meeting'), findsOneWidget);
    expect(find.text('Room id'), findsOneWidget);
    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Join meeting'), findsOneWidget);
  });
}
