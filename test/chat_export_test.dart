import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/services/chat_export.dart';

ChatMessage _m(MessageRole role, String content, {String? thinking}) =>
    ChatMessage(
      id: 'x${content.hashCode}',
      role: role,
      content: content,
      timestamp: DateTime(2026, 9, 7, 21, 0),
      thinking: thinking,
    );

void main() {
  final at = DateTime(2026, 9, 7);

  test('抬头有书名、作者、日期', () {
    final out = ChatExport.format([
      _m(MessageRole.user, '你读过这本书吗'),
    ], bookTitle: '金枝玉叶', bookAuthor: '余耕', exportedAt: at);
    expect(out, startsWith('《金枝玉叶》\n余耕\n2026-09-07'));
  });

  test('没有作者就不留空行', () {
    final out = ChatExport.format([
      _m(MessageRole.user, '在'),
    ], bookTitle: '白夜行', exportedAt: at);
    expect(out, startsWith('《白夜行》\n2026-09-07'));
    expect(out, isNot(contains('\n\n2026')));
  });

  test('谁说的用「我 / AI」，不用 App 里的名字', () {
    final out = ChatExport.format([
      _m(MessageRole.user, '甲'),
      _m(MessageRole.assistant, '乙'),
    ], bookTitle: 'B', exportedAt: at);
    expect(out, contains('我：甲'));
    expect(out, contains('AI：乙'));
  });

  // 思考是给她看「它为什么这么问」的，不是讨论内容。导出给别人看的时候
  // 混进去会把真正说的话冲淡一倍。
  test('思考过程不导出', () {
    final out = ChatExport.format([
      _m(MessageRole.assistant, '正文', thinking: '我在想用户是不是在回避'),
    ], bookTitle: 'B', exportedAt: at);
    expect(out, contains('正文'));
    expect(out, isNot(contains('回避')));
  });

  // 工具调用那几条 content 是空的，不跳过就是一排「AI：」空行。
  test('空内容的消息跳过', () {
    final out = ChatExport.format([
      _m(MessageRole.assistant, '   '),
      _m(MessageRole.user, '真话'),
    ], bookTitle: 'B', exportedAt: at);
    expect(out, contains('我：真话'));
    expect(out, isNot(contains('AI：')));
  });

  test('一条都没有就返回空串，让界面能拦住', () {
    expect(
      ChatExport.format([], bookTitle: 'B', exportedAt: at),
      isEmpty,
    );
    expect(
      ChatExport.format([
        _m(MessageRole.assistant, ''),
      ], bookTitle: 'B', exportedAt: at),
      isEmpty,
    );
  });

  test('顺序照原样，不重排', () {
    final out = ChatExport.format([
      _m(MessageRole.assistant, '先'),
      _m(MessageRole.user, '后'),
    ], bookTitle: 'B', exportedAt: at);
    expect(out.indexOf('先'), lessThan(out.indexOf('后')));
  });

  test('月份日期补零', () {
    final out = ChatExport.format([
      _m(MessageRole.user, 'x'),
    ], bookTitle: 'B', exportedAt: DateTime(2026, 1, 3));
    expect(out, contains('2026-01-03'));
  });
}
