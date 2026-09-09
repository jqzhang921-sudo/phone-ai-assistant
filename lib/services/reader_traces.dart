import 'package:flutter/foundation.dart';

import '../models/reading_note.dart';
import 'reading_note_store.dart';
import 'weread_service.dart';

/// 他自己在这本书里留下的东西：划线、想法、摘录、随笔。
///
/// ## 为什么单独有这么一个东西
///
/// 「AI 没读过这本书」这件事，最好的解法从来不是让它去查资料——查回来的是
/// 营销简介和别人的概括。**他读过。他划过、写过。那些才是关于这本书最可靠
/// 的一手材料**，而且天然就是他想聊的那些地方。
///
/// 但 2026-09-09 之前，这些东西一条都没送到模型面前：
///
/// - `WereadService.fetchThoughts()` —— **写完了，一次都没被调用过**
/// - 划线 —— 只在**空对话**时插一条 assistant 气泡。它不进 system prompt，
///   聊长了会被 `history_compactor` 折进摘要，他自己还能长按删掉。也就是说
///   **越往后聊，AI 手里的材料越少**——而讨论恰恰是越往后越深
/// - 第三页的摘录和随笔 —— 只在那一页显示，从不进讨论
///
/// 所以这里做的事就一件：把三处材料收齐、去重、按预算截断，拼成一段常驻的
/// system prompt。常驻是关键——它得活过历史压缩。
///
/// ## 为什么要去重
///
/// 第三页「一键导入微信读书划线」存下来的摘录，和这里从接口拉回来的划线，
/// 是**同一批句子**。不去重的话每条都会出现两遍，白烧一倍 token，还让模型
/// 以为这句他划了两次、格外在意。
///
/// ## 为什么要预算
///
/// 划得多的书有几百条划线。全塞进 system prompt 有两个后果：挤掉人设和历史，
/// 以及——按 8/17 查 token 那次的结论——**system prompt 一变，DeepSeek 的
/// KV cache 整段作废**。所以宁可给它四十条，也不要给它三百条。
class ReaderTraces {
  /// 他划的（已经和第三页导入的摘录合并去重）。
  final List<String> highlights;

  /// 他在微信读书里写的想法/书评。
  final List<String> thoughts;

  /// 第三页里他自己写的、注明了是这本书的随笔。
  final List<String> essays;

  /// 截断**之前**一共多少条划线。要写进提示词里告诉模型它看到的不全。
  final int highlightTotal;

  const ReaderTraces({
    this.highlights = const [],
    this.thoughts = const [],
    this.essays = const [],
    this.highlightTotal = 0,
  });

  bool get isEmpty =>
      highlights.isEmpty && thoughts.isEmpty && essays.isEmpty;

  /// 单条上限。极少数划线是整段甚至整页。
  static const _kMaxLineChars = 150;

  /// 划线最多给几条。
  ///
  /// 四十条约两千字。再多的边际收益很低——模型不会因为看了三百条就更懂这本
  /// 书，只会更容易从里面挑一句演绎。
  static const _kMaxHighlights = 40;

  /// 他自己写的东西，每类最多几条。比划线少，因为通常本来就少；
  /// 真有人写了五十条读感，前十五条也够定调了。
  static const _kMaxOwnEntries = 15;

  /// 整段的字数预算。
  static const _kMaxChars = 2400;

  /// 拼成塞进 system prompt 的那一段。什么都没有就返回 null。
  ///
  /// 这一段和 `BookLookup` 那一段的护栏**不一样**，别照抄：
  /// 那边防的是「拿着简介装读过」，这边防的是**回音壁**——
  /// 把他划过的句子原样念回去，看着像读过，其实一句新东西都没有。
  String? asPromptBlock() {
    if (isEmpty) return null;

    final b = StringBuffer();
    b.writeln('---');
    b.writeln('下面是用户自己在这本书里留下的东西。**这是你手上最可靠的材料**——');
    b.writeln('它不是简介，是他真的读到那儿、停下来、划下或者写下的。');

    if (thoughts.isNotEmpty) {
      b.writeln();
      b.writeln('他读的时候写下的想法：');
      for (final t in thoughts) {
        b.writeln('- $t');
      }
    }

    if (essays.isNotEmpty) {
      b.writeln();
      b.writeln('他在随笔里写到这本书：');
      for (final e in essays) {
        b.writeln('- $e');
      }
    }

    if (highlights.isNotEmpty) {
      b.writeln();
      final more =
          highlightTotal > highlights.length
              ? '（一共 $highlightTotal 条，这里是其中 ${highlights.length} 条）'
              : '';
      b.writeln('他划下的句子$more：');
      for (final h in highlights) {
        b.writeln('- $h');
      }
    }

    b.writeln();
    b.writeln(
      '**别把这些原样念回给他。** 他知道自己划了什么、写了什么，'
      '复述一遍只会让这段对话显得很懂、其实一句新东西都没有。'
      '正确的用法是挑其中一条往下走：说说你从这句里看出什么、'
      '它和另一条之间是不是有张力、或者你不同意他写的那句想法。',
    );
    b.writeln(
      '**划线只说明他在那儿停过，不说明他为什么停。** 理由是他的，不是你的——'
      '想知道就问一句，别替他把理由写出来再当成他的意思。',
    );
    b.writeln(
      '这些也**不等于你读过这本书**。他划的是他在意的那些句子，'
      '书里别的地方你依然没读过——不要拿这几条去拼整本书的情节。',
    );
    b.writeln('---');
    return b.toString();
  }

  /// 把三处材料收齐。
  ///
  /// 任何一处失败都只是少一块，不抛也不挡住开聊——和 `BookLookup` 一个原则。
  /// 没配微信读书 key 的时候整个网络那一半直接跳过，第三页那一半照常。
  static Future<ReaderTraces> gather({
    required String bookTitle,
    String? wereadBookId,
  }) async {
    final wereadHighlights = <String>[];
    final wereadThoughts = <String>[];

    if (wereadBookId != null &&
        wereadBookId.isNotEmpty &&
        await WereadService.hasKey) {
      // 两个接口互不依赖，一起发——串起来等于把开聊前的等待翻倍。
      final results = await Future.wait([
        WereadService.highlightLines(wereadBookId),
        WereadService.thoughtLines(wereadBookId),
      ]);
      wereadHighlights.addAll(results[0]);
      wereadThoughts.addAll(results[1]);
    }

    final notes = await ReadingNoteStore.list();
    final want = _norm(bookTitle);
    final localQuotes = <String>[];
    final localEssays = <String>[];
    for (final n in notes) {
      if (_norm(n.bookTitle ?? '') != want) continue;
      if (n.kind == ReadingNoteKind.quote) {
        localQuotes.add(n.content);
      } else {
        localEssays.add(n.content);
      }
    }

    return build(
      wereadHighlights: wereadHighlights,
      wereadThoughts: wereadThoughts,
      localQuotes: localQuotes,
      localEssays: localEssays,
    );
  }

  /// 去重 + 分预算，这一段是纯的。
  ///
  /// 从 [gather] 里拆出来是为了能不碰 SharedPreferences 和 secure storage
  /// 就测——合并和截断才是这里唯一会出错的地方，而它出错的样子（多一份重复、
  /// 或者把他写的想法挤掉）在真机上根本看不出来。
  @visibleForTesting
  static ReaderTraces build({
    List<String> wereadHighlights = const [],
    List<String> wereadThoughts = const [],
    List<String> localQuotes = const [],
    List<String> localEssays = const [],
  }) {
    // 划线和「导入的摘录」是同一批句子，合并去重。接口那边排在前面：
    // 它是当前状态，第三页那份是某次导入的快照，可能已经删了几条。
    final mergedHighlights = _dedupe([...wereadHighlights, ...localQuotes]);

    var budget = _kMaxChars;
    int left() => budget;
    void spend(int used) => budget -= used;

    // 他自己写的先拿预算——那是他的判断，比划线珍贵得多。
    final thoughts = _take(
      _dedupe(wereadThoughts),
      _kMaxOwnEntries,
      left,
      spend,
    );
    final essays = _take(_dedupe(localEssays), _kMaxOwnEntries, left, spend);
    final highlights = _take(mergedHighlights, _kMaxHighlights, left, spend);

    return ReaderTraces(
      highlights: highlights,
      thoughts: thoughts,
      essays: essays,
      highlightTotal: mergedHighlights.length,
    );
  }

  /// 按条数和字数双重上限取前几条，顺带把过长的单条截断。
  static List<String> _take(
    List<String> src,
    int maxCount,
    int Function() budget,
    void Function(int used) spend,
  ) {
    final out = <String>[];
    for (final raw in src) {
      if (out.length >= maxCount) break;
      if (budget() <= 0) break;
      var line = raw;
      if (line.length > _kMaxLineChars) {
        line = '${line.substring(0, _kMaxLineChars)}…';
      }
      out.add(line);
      spend(line.length);
    }
    return out;
  }

  /// 去重 + 去空。比的是压掉空白之后的全文——同一句被划两次，
  /// 两边的换行和缩进未必一样。
  static List<String> _dedupe(List<String> src) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in src) {
      final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      if (!seen.add(text)) continue;
      out.add(text);
    }
    return out;
  }

  /// 书名对比：用户在第三页写「《秋园》」、书架里存的是「秋园」，得算同一本。
  static String _norm(String s) =>
      s.replaceAll(RegExp(r'[《》「」『』""“”\s]'), '').trim().toLowerCase();
}
