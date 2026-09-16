import 'package:flutter_test/flutter_test.dart';
import 'package:live_capsule/live_capsule.dart';
import 'package:phone_ai_assistant/services/capsule_texts.dart';
import 'package:phone_ai_assistant/services/notify_name.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假的原生侧：记下每次调用，并能装成「这台机器不支持」。
class _Fake {
  _Fake({this.supported = true});
  final bool supported;
  final calls = <(String, Map<String, dynamic>)>[];
  bool showFails = false;

  Future<bool> invoke(String method, Map<String, dynamic> args) async {
    calls.add((method, args));
    return switch (method) {
      'supported' => supported,
      'show' => !showFails,
      _ => true,
    };
  }

  List<String> get methods => [for (final c in calls) c.$1];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final real = LiveCapsule.invoke;
  late _Fake fake;
  void use(_Fake f) {
    fake = f;
    LiveCapsule.invoke = f.invoke;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    use(_Fake());
  });

  tearDown(() => LiveCapsule.invoke = real);

  group('亮了就一定收', () {
    test('做完了收', () async {
      final r = await Capsule.whileReplying(() async => 42);
      expect(r, 42);
      expect(fake.methods, ['supported', 'show', 'end']);
    });

    test('中途抛异常也收', () async {
      await expectLater(
        Capsule.whileGlancing(() async => throw StateError('炸了')),
        throwsStateError,
      );
      expect(fake.methods.last, 'end');
    });

    test('不支持就整条路不走，也不用收', () async {
      use(_Fake(supported: false));
      final r = await Capsule.whileReplying(() async => 1);
      expect(r, 1);
      expect(fake.methods, ['supported']);
    });

    test('亮不出来（系统拒了）也不去收', () async {
      final f = _Fake()..showFails = true;
      use(f);
      await Capsule.whileReplying(() async => 1);
      expect(f.methods, ['supported', 'show']);
    });
  });

  group('胶囊里写什么', () {
    test('两件事用不同的 id，不会互相顶掉', () {
      expect(LiveCapsule.replyId, isNot(LiveCapsule.glanceId));
    });

    test('挖孔那几个字很短', () {
      expect(Capsule.replyShort.length, lessThanOrEqualTo(4));
      expect(Capsule.glanceShort.length, lessThanOrEqualTo(4));
    });

    test('标题用她填的备注', () async {
      await NotifyName.setRemark('小八');
      await Capsule.whileReplying(() async {});
      final show = fake.calls.firstWhere((c) => c.$1 == 'show');
      expect(show.$2['title'], '小八');
      expect(show.$2['text'], Capsule.replyText);
      expect(show.$2['short'], Capsule.replyShort);
    });

    test('没填备注就用 Nook', () async {
      await Capsule.whileGlancing(() async {});
      final show = fake.calls.firstWhere((c) => c.$1 == 'show');
      expect(show.$2['title'], 'Nook');
      expect(show.$2['id'], LiveCapsule.glanceId);
    });
  });
}
