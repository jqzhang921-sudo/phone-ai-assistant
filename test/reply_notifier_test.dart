import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/services/reply_notifier.dart';

/// 回复写完了，弹不弹通知。
void main() {
  test('人就在这段对话上、App 在前台：不弹，回复就在眼前', () {
    expect(
      ReplyNotifier.shouldNotify(
        onThatConversation: true,
        lifecycle: AppLifecycleState.resumed,
      ),
      isFalse,
    );
  });

  test('发完就回了首页（或者换了一段）：弹', () {
    expect(
      ReplyNotifier.shouldNotify(
        onThatConversation: false,
        lifecycle: AppLifecycleState.resumed,
      ),
      isTrue,
    );
  });

  test('还在这段上，但 App 退到后台了：弹', () {
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
    ]) {
      expect(
        ReplyNotifier.shouldNotify(onThatConversation: true, lifecycle: s),
        isTrue,
        reason: '$s',
      );
    }
  });

  test('通知里那一行：长的截掉，短的原样', () {
    expect(ReplyNotifier.preview('  好  '), '好');
    final long = '字' * 250;
    final p = ReplyNotifier.preview(long);
    expect(p.length, 201);
    expect(p.endsWith('…'), isTrue);
  });
}
