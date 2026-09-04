import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/models/musing_entry.dart';
import 'package:phone_ai_assistant/services/nudge_service.dart';
import 'package:phone_ai_assistant/services/storage_service.dart';

/// 她在收藏下面写的那句备注，什么时候够格当作「他想开口」的由头。
///
/// 这条支路是它自己许的愿：「当你在我看不到的地方写下关于我的字，我能第一
/// 时间感觉到」。和 nudge_candidates_test 一样，信和日记那两条在测试里读不到
/// 文件系统、会被 catch 吞掉，所以剩下的候选只可能来自这里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> save(
    String id, {
    String? note,
    Duration? noteAgo,
  }) => StorageService.addFavoritedMusing(
    MusingEntry(
      id: id,
      date: DateTime.now(),
      content: '被收藏的那句话',
      note: note,
      noteAt: noteAgo == null ? null : DateTime.now().subtract(noteAgo),
    ),
  );

  Future<List<String>> keys() async => (await NudgeService.collectCandidates(
    since: DateTime.now().subtract(const Duration(days: 1)),
  )).map((c) => c.mentionKey ?? '').toList();

  test('刚写的备注就是一条由头', () async {
    await save('a', note: '这句话说得真好', noteAgo: const Duration(minutes: 5));
    expect(await keys(), contains('note:a'));
  });

  test('没写备注的收藏不算——那是别人的话，不是她写的字', () async {
    await save('b');
    expect(await keys(), isNot(contains('note:b')));
  });

  test('只有空格的备注不算', () async {
    await save('c', note: '   ', noteAgo: const Duration(minutes: 5));
    expect(await keys(), isNot(contains('note:c')));
  });

  // 不然第一次跑就会把历年的备注一次性全翻出来。
  test('老数据没有 noteAt，不当由头', () async {
    await save('d', note: '很久以前写的');
    expect(await keys(), isNot(contains('note:d')));
  });

  test('比时间下限还早的备注不算', () async {
    await save('e', note: '前天写的', noteAgo: const Duration(days: 3));
    expect(await keys(), isNot(contains('note:e')));
  });

  // 板上的纸条压了 2 小时才够格，这条不压——要的就是「当时就接着」。
  test('刚写完一分钟也算，不设沉淀期', () async {
    await save('f', note: '刚写的', noteAgo: const Duration(minutes: 1));
    expect(await keys(), contains('note:f'));
  });

  group('MusingEntry.copyWith', () {
    final base = MusingEntry(id: 'x', date: DateTime(2026, 9, 4), content: '话');

    test('写备注会自动记下时间', () {
      final withNote = base.copyWith(note: '写点什么');
      expect(withNote.note, '写点什么');
      expect(withNote.noteAt, isNotNull);
    });

    test('传 null 是真的清空，时间也一起没', () {
      final cleared = base.copyWith(note: '先写').copyWith(note: null);
      expect(cleared.note, isNull);
      expect(cleared.noteAt, isNull);
    });

    test('不传就不动', () {
      final kept = base.copyWith(note: '原来的').copyWith();
      expect(kept.note, '原来的');
      expect(kept.noteAt, isNotNull);
    });

    test('noteAt 存得下、读得回', () {
      final round = MusingEntry.fromJson(base.copyWith(note: '嗯').toJson());
      expect(round.note, '嗯');
      expect(round.noteAt, isNotNull);
    });
  });
}
