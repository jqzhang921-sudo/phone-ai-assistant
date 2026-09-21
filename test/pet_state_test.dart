import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/pet_state.dart';

void main() {
  group('待机姿势跟着时间走', () {
    String at(int h) => idleStickerFor(DateTime(2026, 9, 21, h));

    test('深夜蜷着', () {
      for (final h in [23, 0, 3, 5]) {
        expect(at(h), 'nap', reason: '$h 点');
      }
    });
    test('清早伸懒腰', () {
      for (final h in [6, 8]) {
        expect(at(h), 'stretch', reason: '$h 点');
      }
    });
    test('白天端坐', () {
      for (final h in [9, 12, 18]) {
        expect(at(h), 'sit_up', reason: '$h 点');
      }
    });
    test('晚上趴着', () {
      for (final h in [19, 22]) {
        expect(at(h), 'lying', reason: '$h 点');
      }
    });
    test('每个小时都得有图，不能返回空', () {
      for (var h = 0; h < 24; h++) {
        expect(at(h).trim(), isNotEmpty, reason: '$h 点');
      }
    });
  });

  group('状态决定画哪张', () {
    final noon = DateTime(2026, 9, 21, 12);
    test('写回复时敲键盘', () {
      expect(stickerForMood(PetMood.typing, noon), 'typing');
    });
    test('看屏幕时是另一张', () {
      expect(stickerForMood(PetMood.glancing, noon), 'butterfly');
    });
    test('没事时按时间来', () {
      expect(stickerForMood(PetMood.idle, noon), idleStickerFor(noon));
    });
  });

  group('点它的反应', () {
    test('按顺序轮，不会连着两次同一张', () {
      var last = '';
      for (var i = 0; i < petTapReactions.length * 2; i++) {
        final now = petTapReaction(i);
        expect(now, isNot(last), reason: '第 $i 下');
        last = now;
      }
    });
    test('轮完一圈回到开头', () {
      expect(petTapReaction(0), petTapReaction(petTapReactions.length));
    });
  });

  _blinkTests();

  group('拖到屏幕外面要拉回来', () {
    const pet = Size(72, 72);
    const screen = Size(400, 800);

    test('正常位置不动它', () {
      expect(clampSpot(const Offset(100, 200), pet, screen),
          const Offset(100, 200));
    });

    test('往左拖过头：只许露出一点点', () {
      final at = clampSpot(const Offset(-500, 300), pet, screen);
      expect(at.dx, -16);
    });

    test('往右拖过头：同样只露一点点', () {
      final at = clampSpot(const Offset(9999, 300), pet, screen);
      expect(at.dx, screen.width - pet.width + 16);
    });

    test('上下不许露出去——露出去就点不到了', () {
      final top = clampSpot(const Offset(100, -999), pet, screen);
      expect(top.dy, 0);
      final bottom = clampSpot(const Offset(100, 9999), pet, screen);
      expect(bottom.dy, screen.height - pet.height);
    });

    test('避开刘海和手势条', () {
      const safe = EdgeInsets.only(top: 48, bottom: 24);
      final top = clampSpot(const Offset(100, 0), pet, screen, safe: safe);
      expect(top.dy, 48);
      final bottom = clampSpot(const Offset(100, 9999), pet, screen, safe: safe);
      expect(bottom.dy, screen.height - 24 - pet.height);
    });

    test('屏幕比猫还小也不崩', () {
      final at = clampSpot(const Offset(10, 10), pet, const Size(40, 40));
      expect(at.dx.isFinite, isTrue);
      expect(at.dy.isFinite, isTrue);
    });
  });
}

void _blinkTests() {
  group('眨眼', () {
    tearDown(() => PetBlink.have = {});

    test('只有备了闭眼帧的姿势才眨', () {
      PetBlink.have = {'sit_up'};
      expect(PetBlink.has('sit_up'), isTrue);
      // ⚠️ 没有闭眼帧就别眨：拿别的姿势顶替看起来是猫跳了一下。
      expect(PetBlink.has('lying'), isFalse);
    });

    test('闭眼帧的文件名约定', () {
      expect(PetBlink.assetFor('sit_up'), 'assets/stickers/mochi_sit_up_blink.png');
    });

    test('间隔在 3 到 7 秒之间绕，且不会连着两次一样', () {
      var last = Duration.zero;
      for (var i = 0; i < 12; i++) {
        final g = blinkGap(i);
        expect(g.inMilliseconds, inInclusiveRange(3000, 7000), reason: '第 $i 次');
        expect(g, isNot(last), reason: '第 $i 次和上一次一样长');
        last = g;
      }
    });

    test('闭眼那一下是真猫的量级', () {
      expect(blinkHold.inMilliseconds, inInclusiveRange(80, 200));
    });
  });
}
