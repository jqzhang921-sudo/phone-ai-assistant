import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/services/nudge_scheduler.dart';

void main() {
  /// 切回前台那道防抖。不是怕它话多（门槛管那个），是怕掉帧：
  /// 每次都要读信、日记、对话列表，全在主 isolate 上，而复制个验证码
  /// 切出去再回来就是一次 resumed。
  group('前台检查的防抖', () {
    final now = DateTime(2026, 9, 4, 15);

    test('没跑过就跑', () {
      expect(NudgeScheduler.shouldRunLocally(now, null), isTrue);
    });

    test('刚跑完不重跑', () {
      expect(
        NudgeScheduler.shouldRunLocally(
          now,
          now.subtract(const Duration(minutes: 5)),
        ),
        isFalse,
      );
    });

    test('隔了半小时可以再跑', () {
      expect(
        NudgeScheduler.shouldRunLocally(
          now,
          now.subtract(const Duration(minutes: 30)),
        ),
        isTrue,
      );
    });
  });
}
