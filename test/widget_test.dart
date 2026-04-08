import 'package:flutter_test/flutter_test.dart';
import 'package:orcax/main.dart';

void main() {
  testWidgets('App renders with Fogged branding', (WidgetTester tester) async {
    await tester.pumpWidget(const FoggedApp());
    expect(find.text('FOGGED'), findsOneWidget);
    expect(find.text('CONNECT'), findsOneWidget);
  });
}
