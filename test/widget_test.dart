// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:pc_remote_server/main.dart';

void main() {
  testWidgets('renders combined server and client shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(const PCRemoteApp());

    expect(find.text('Client Area'), findsOneWidget);
    expect(find.text('Trackpad'), findsOneWidget);
    expect(find.text('Clipboard'), findsOneWidget);
  });
}
