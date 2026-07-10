import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/main.dart';

void main() {
  testWidgets('App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const PhoneAiApp());
    await tester.pump();
    expect(find.text('手机 AI 助手'), findsOneWidget);
  });
}
