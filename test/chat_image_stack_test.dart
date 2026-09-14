import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/chat_images.dart';
import 'package:phone_ai_assistant/widgets/chat_image_stack.dart';

/// 多张图叠成卡片那一套：翻页按顺序、到头划不动、没拖够要弹回、展开收起
/// 要来回切得动、点开要进全屏。都是手感上的东西，坏了不报错，只会
/// 「怎么划不动了」或者「顺序乱了」。
void main() {
  // 1×1 的真 PNG。解不出来的数据会让 Image 进 errorBuilder，测不到正常路径。
  const png =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

  Future<void> pumpGallery(WidgetTester tester, List<String> images) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: ChatImageGallery(images: images, alignEnd: true)),
        ),
      ),
    );
  }

  Finder stackOf(int total) =>
      find.bySemanticsLabel(RegExp('^第 \\d 张，共 $total 张\$'));

  Future<void> swipe(WidgetTester tester, double dx) async {
    await tester.drag(stackOf(3), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('一张图：不叠、没有展开按钮', (tester) async {
    await pumpGallery(tester, [png]);
    expect(find.textContaining('展开'), findsNothing);
  });

  testWidgets('三张图：叠成一摞，按钮写着张数', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpGallery(tester, [png, png, png]);

    expect(find.text('展开 3'), findsOneWidget);
    expect(find.bySemanticsLabel('第 1 张，共 3 张'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('往左划按顺序往后翻，到最后一张就划不动了', (tester) async {
    // 不循环是 Cleo 要的：循环起来就看不出发照片的顺序了。
    final semantics = tester.ensureSemantics();
    await pumpGallery(tester, [png, png, png]);

    await swipe(tester, -150);
    expect(find.bySemanticsLabel('第 2 张，共 3 张'), findsOneWidget);
    await swipe(tester, -150);
    expect(find.bySemanticsLabel('第 3 张，共 3 张'), findsOneWidget);
    await swipe(tester, -150);
    expect(find.bySemanticsLabel('第 3 张，共 3 张'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('往右划翻回上一张，到第一张也划不动', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpGallery(tester, [png, png, png]);

    await swipe(tester, 150);
    expect(find.bySemanticsLabel('第 1 张，共 3 张'), findsOneWidget);

    await swipe(tester, -150);
    await swipe(tester, -150);
    await swipe(tester, 150);
    expect(find.bySemanticsLabel('第 2 张，共 3 张'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('一次甩得再远也只翻一张', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpGallery(tester, [png, png, png]);

    await swipe(tester, -600);
    expect(find.bySemanticsLabel('第 2 张，共 3 张'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('只拖一点点：弹回来，还是这一张', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpGallery(tester, [png, png, png]);

    // 用慢速拖，免得被当成「甩」。
    await tester.timedDrag(
      stackOf(3),
      const Offset(-20, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('第 1 张，共 3 张'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('展开铺成网格，收起回到一摞', (tester) async {
    await pumpGallery(tester, [png, png, png]);

    await tester.tap(find.text('展开 3'));
    await tester.pumpAndSettle();
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('展开 3'), findsNothing);

    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.text('展开 3'), findsOneWidget);
  });

  testWidgets('点当前那张：进全屏，从这张开始', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpGallery(tester, [png, png, png]);

    await swipe(tester, -150);
    await tester.tap(stackOf(3));
    await tester.pumpAndSettle();

    expect(find.byType(ChatImageViewer), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('清掉的图：显示「图片已清理」，不崩', (tester) async {
    await pumpGallery(tester, [ChatImages.clearedMark, png]);
    expect(find.text('图片已清理'), findsWidgets);
  });
}
