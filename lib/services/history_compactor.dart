import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import 'ai_client.dart';

// ── 阈值 ─────────────────────────────────────────────
// 放一起方便调。数的是消息条数（工具调用和结果也算），不是 token。

/// 未压缩的消息超过这个数才动手。
///
/// 和 [_kKeepRecent] 的**差值**才是每次折叠多少条。差值太小，压缩就跑得又勤
/// 又不划算——每次都要一次 API 调用，却只折走几条。所以抬 [_kKeepRecent] 时
/// 这里得跟着抬，把差值维持在 30~35。
const _kCompactThreshold = 80;

/// 压缩后保留多少条原文。
///
/// 2026-08-24 从 30 抬到 45。
///
/// 「压缩完它突然性情大变」的根子在这儿，不在摘要的措辞。人设给的是**抽象规则**
/// （「像发微信一样短」），留下来的原文给的是**实例**——几十条它实际怎么答的
/// 样本。对模型来说实例比规则强得多。压缩那一下把样本整批抽走，它就退回自己的
/// 出厂习惯：更长、更助手腔、更爱加 emoji。
///
/// 这也是为什么用户的感受是「**突然**」：它不是慢慢变冷，是在压缩那一刻断层式
/// 地变。渐变才该去查摘要，断层要查的是这个数。
///
/// 代价是稳态上下文大了约一半。但这一段跨轮次逐字节不变，吃得到 prompt 缓存
/// （见 ai_client 里 _attachMemory 的注释），命中时便宜一个数量级。
const _kKeepRecent = 45;

/// 摘要本身的长度上限。摘要要是无限长，等于没压。
const _kSummaryMaxChars = 500;

/// 该压了吗？
bool needsCompaction(Conversation conv) =>
    conv.messages.length - conv.summarizedCount > _kCompactThreshold;

/// 把早期消息折进摘要。改动直接写在 [conv] 上，调用方负责落盘。
///
/// 返回是否真的压了。
///
/// 为什么要压：现在每一轮都把完整历史重发一遍，同一段对话越聊越贵——聊到后面
/// 发一句「嗯」也要重传两万 token。这是二次增长，跟缓存命中率无关，命中的部分
/// 照样计费，只是单价低些。压缩把上下文钉在一个大致固定的规模上。
Future<bool> compactHistory({
  required Conversation conv,
  required AiClient aiClient,
}) async {
  if (!needsCompaction(conv)) return false;

  final cutoff = _findCutoff(conv);
  if (cutoff <= conv.summarizedCount) return false;

  final chunk = conv.messages.sublist(conv.summarizedCount, cutoff);
  final transcript = _transcribe(chunk);
  if (transcript.trim().isEmpty) {
    // 这一段全是工具调用之类，没有可读内容，直接跳过不生成摘要
    conv.summarizedCount = cutoff;
    return true;
  }

  final prompt = StringBuffer();
  if (conv.summary != null && conv.summary!.isNotEmpty) {
    prompt.writeln('这是你们更早对话的摘要：\n${conv.summary}\n');
    prompt.writeln('接下来这段是后续发生的对话：\n$transcript\n');
    prompt.writeln('把两者合并成一份新的摘要。');
  } else {
    prompt.writeln('这是你和用户的一段对话：\n$transcript\n');
    prompt.writeln('把它压成一份摘要。');
  }
  prompt.writeln('''
- 保留：TA 说过的事实（在做什么、在意什么、提过的人和事）、你们达成的共识、
  你答应过的事、以及情绪上的关键时刻。
- 也记一句你们说话的样子：话多长、多随意、TA 爱用哪些词、哪些话题上 TA 会多说
  几句。事实忘了还能用工具翻回来，语气翻不回来——被折叠的原文里，这是最容易
  跟着一起消失的东西。
- 丢掉：寒暄、重复的话、工具调用的过程细节。
- 用第三人称陈述，别写成对话稿，也别加标题和分点。
- 不超过 $_kSummaryMaxChars 字。这是给你自己看的备忘，不是给用户看的文章。''');

  try {
    final text = await _run(aiClient, prompt.toString());
    if (text == null || text.isEmpty) return false;

    conv.summary =
        text.length > _kSummaryMaxChars * 2
            ? text.substring(0, _kSummaryMaxChars * 2)
            : text;
    conv.summarizedCount = cutoff;
    debugPrint(
      '[compactor] 已压缩前 $cutoff 条，剩 ${conv.messages.length - cutoff} 条原文',
    );
    return true;
  } catch (e) {
    debugPrint('[compactor] 压缩失败，这次跳过：$e');
    return false;
  }
}

/// 切点必须落在一条 user 消息上。
///
/// 从中间随便切会把 assistant 的 tool_calls 和它的结果拆散，剩下的孤儿会被
/// 服务端判非法（这个坑之前踩过）。往前退到最近的一条用户消息，整组一起保留。
int _findCutoff(Conversation conv) {
  var i = conv.messages.length - _kKeepRecent;
  while (i > conv.summarizedCount) {
    if (conv.messages[i].role == MessageRole.user) return i;
    i--;
  }
  return conv.summarizedCount;
}

String _transcribe(List<ChatMessage> messages) {
  final buf = StringBuffer();
  for (final m in messages) {
    if (m.role != MessageRole.user && m.role != MessageRole.assistant) continue;
    final text = m.content.trim();
    if (text.isEmpty) continue;
    buf.writeln('${m.role == MessageRole.user ? 'TA' : '你'}：$text');
  }
  return buf.toString();
}

Future<String?> _run(AiClient aiClient, String prompt) async {
  final messages = [
    ChatMessage(id: 'compact', role: MessageRole.user, content: prompt),
  ];
  var content = '';
  await for (final event in aiClient.chat(
    messages,
    systemPrompt: '你在整理自己和用户的对话记录，压成一份备忘。只输出摘要正文。',
  )) {
    if (event.type == AiEventType.token) {
      content += event.text ?? '';
    } else if (event.type == AiEventType.done) {
      content = event.text ?? content;
    } else if (event.type == AiEventType.error) {
      throw Exception(event.error ?? '生成失败');
    }
  }
  return content.trim().isEmpty ? null : content.trim();
}
