import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/screens/days_screen.dart';

/// 日历横滑翻月的方向。
///
/// 这条测的是一件**上手才发现得了**的事：手势埋在 widget 里，方向反了
/// 编译没问题、analyze 没问题、跑起来也不报错，只有真拿手指划一下才知道
/// 它和头顶的箭头是拧着的。所以把判断抽出来单独钉住。
///
/// 约定：`primaryVelocity` 向右为正；向右滑 =「把纸往右推，露出左边那张」
/// = 上一个月 = 头顶左边那个箭头。
void main() {
  group('横滑翻月', () {
    test('向右滑是上一个月——和左箭头同一件事', () {
      expect(monthDeltaFromSwipe(600), -1);
    });

    test('向左滑是下一个月', () {
      expect(monthDeltaFromSwipe(-600), 1);
    });

    test('轻轻一碰不翻页', () {
      expect(monthDeltaFromSwipe(0), 0);
      expect(monthDeltaFromSwipe(120), 0);
      expect(monthDeltaFromSwipe(-120), 0);
    });

    test('刚好卡在门槛上不算', () {
      expect(monthDeltaFromSwipe(200), 0);
      expect(monthDeltaFromSwipe(-200), 0);
    });

    test('两个方向对称', () {
      for (final v in [250.0, 600.0, 4000.0]) {
        expect(monthDeltaFromSwipe(v), -monthDeltaFromSwipe(-v));
      }
    });
  });
}
