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

  test('两个工具只回来一个：另一个补占位', () {
    // Cleo 2026-09-16 撞到的那一幕：看屏幕回来了，find_tools 没有。
    final msgs = [
      _text(MessageRole.user, '你看看'),
      _call('a', [('c1', 'glance_screen'), ('c2', 'find_tools')]),
      _result('c1'),
    ];
    expect(hasOrphanToolCalls(msgs), isTrue);

    final fixed = repairOrphanToolCalls(msgs, newId: newId);
    expect(fixed.length, msgs.length + 1);
    final added = fixed.last;
    expect(added.role, MessageRole.toolResult);
    expect(added.toolCallId, 'c2');
    expect(jsonDecode(added.content)['success'], false);
    expect(jsonDecode(added.content)['error'], orphanError);
    // 补完就不再是孤儿
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
    // 模型在两次调用之间说了句话——只看紧邻的话会把真结果当成没有。
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
    expect(fixed[0].toolCalls!.length, 2);
    expect(fixed[1].toolCallId, 'c1');
    expect(fixed[2].toolCallId, 'c2'); // 补的这条
    expect(fixed[3].content, '还在吗'); // 用户那句还在后面
  });

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
}
