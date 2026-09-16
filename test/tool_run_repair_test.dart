import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/services/tool_run_repair.dart';

ChatMessage _call(String id, List<(String, String)> calls) => ChatMessage(
  id: id,
  role: MessageRole.assistant,
  content: '',
  toolCalls: [
    for (final (cid, name) in calls)
      ToolCallInfo(id: cid, name: name, arguments: const {}),
  ],
);

ChatMessage _result(String callId, {String body = '{"success":true}'}) =>
    ChatMessage(
      id: 'r_$callId',
      role: MessageRole.toolResult,
      content: body,
      toolCallId: callId,
    );

ChatMessage _text(MessageRole role, String s) =>
    ChatMessage(id: 'm_$s', role: role, content: s);

void main() {
  var n = 0;
  String newId() => 'fix_${n++}';
  setUp(() => n = 0);

  group('按 id 配对', () {
    test('两个工具只回来一个：另一个补占位', () {
      final msgs = [
        _text(MessageRole.user, '你看看'),
        _call('a', [('c1', 'glance_screen'), ('c2', 'find_tools')]),
        _result('c1'),
      ];
      expect(hasOrphanToolCalls(msgs), isTrue);

      final fixed = repairOrphanToolCalls(msgs, newId: newId);
      expect(fixed.length, msgs.length + 1);
      expect(fixed.last.toolCallId, 'c2');
      expect(jsonDecode(fixed.last.content)['success'], false);
      expect(jsonDecode(fixed.last.content)['error'], orphanError);
      expect(hasOrphanToolCalls(fixed), isFalse);
    });

    test('结果齐了就一条都不动', () {
      final msgs = [
        _call('a', [('c1', 'x'), ('c2', 'y')]),
        _result('c1'),
        _result('c2'),
        _text(MessageRole.assistant, '好了'),
      ];
      expect(hasOrphanToolCalls(msgs), isFalse);
      expect(repairOrphanToolCalls(msgs, newId: newId), msgs);
    });

    test('结果被别的消息隔开了，也算数', () {
      final msgs = [
        _call('a', [('c1', 'x')]),
        _text(MessageRole.assistant, '我查一下'),
        _result('c1'),
      ];
      expect(hasOrphanToolCalls(msgs), isFalse);
      expect(repairOrphanToolCalls(msgs, newId: newId).length, msgs.length);
    });

    test('占位插在那一组结果后面，不插到别处', () {
      final msgs = [
        _call('a', [('c1', 'x'), ('c2', 'y')]),
        _result('c1'),
        _text(MessageRole.user, '还在吗'),
      ];
      final fixed = repairOrphanToolCalls(msgs, newId: newId);
      expect(fixed[1].toolCallId, 'c1');
      expect(fixed[2].toolCallId, 'c2'); // 补的这条
      expect(fixed[3].content, '还在吗');
    });
  });

  group('id 是空的也要认（Cleo 2026-09-16 那张一直转圈的卡）', () {
    // 流式累积时先建 id 为空的占位，只有分片带了 id 才填上——
    // 有的中转站只在第一个分片给 id，第二个工具就一直是空的。
    // 第一版只按 id 配对，这种调用被整条跳过，于是卡片照样转。
    test('两个空 id 的调用，只回来一条结果：补一条', () {
      final msgs = [
        _call('a', [('', 'glance_screen'), ('', 'find_tools')]),
        _result(''),
      ];
      expect(hasOrphanToolCalls(msgs), isTrue);

      final fixed = repairOrphanToolCalls(msgs, newId: newId);
      expect(fixed.length, 3);
      expect(fixed.last.role, MessageRole.toolResult);
      expect(fixed.last.toolCallId, '');
      expect(jsonDecode(fixed.last.content)['error'], orphanError);
      expect(hasOrphanToolCalls(fixed), isFalse);
    });

    test('空 id 且结果都齐了：不动', () {
      final msgs = [
        _call('a', [('', 'x'), ('', 'y')]),
        _result(''),
        _result(''),
      ];
      expect(hasOrphanToolCalls(msgs), isFalse);
      expect(repairOrphanToolCalls(msgs, newId: newId), msgs);
    });

    test('一个有 id、一个空 id，空的那个缺结果', () {
      final msgs = [
        _call('a', [('c1', 'x'), ('', 'y')]),
        _result('c1'),
      ];
      final fixed = repairOrphanToolCalls(msgs, newId: newId);
      expect(fixed.length, 3);
      expect(fixed.last.toolCallId, '');
    });

    test('一条结果都没有：两个都补', () {
      final msgs = [
        _call('a', [('', 'x'), ('', 'y')]),
      ];
      final fixed = repairOrphanToolCalls(msgs, newId: newId);
      expect(fixed.length, 3);
      expect(hasOrphanToolCalls(fixed), isFalse);
    });
  });

  group('别的情形', () {
    test('没有工具的对话原样返回', () {
      final msgs = [
        _text(MessageRole.user, '在吗'),
        _text(MessageRole.assistant, '在'),
      ];
      expect(hasOrphanToolCalls(msgs), isFalse);
      expect(repairOrphanToolCalls(msgs, newId: newId), msgs);
    });

    test('两轮工具，只有后一轮断了', () {
      final msgs = [
        _call('a', [('c1', 'x')]),
        _result('c1'),
        _call('b', [('c2', 'y')]),
      ];
      final fixed = repairOrphanToolCalls(msgs, newId: newId);
      expect(fixed.length, 4);
      expect(fixed.last.toolCallId, 'c2');
    });

    test('补过一次之后再补是幂等的', () {
      final msgs = [
        _call('a', [('c1', 'x'), ('c2', 'y')]),
        _result('c1'),
      ];
      final once = repairOrphanToolCalls(msgs, newId: newId);
      final twice = repairOrphanToolCalls(once, newId: newId);
      expect(twice.length, once.length);
    });
  });
}
