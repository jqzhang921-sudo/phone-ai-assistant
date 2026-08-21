import 'package:uuid/uuid.dart';
import '../config/settings.dart';
import '../models/chat_message.dart';
import '../models/musing_entry.dart';
import 'ai_client.dart';
import 'storage_service.dart';

/// 让 AI 自己从最近的对话里挑几句值得留下的。
///
/// 三条约束，都是有原因的：
///
/// 1. **每次最多两条**。它挑得比你勤，不封顶的话几轮下来一隅里就全是它的选择，
///    你自己特意留的那些会被淹掉。
/// 2. **有冷却**。触发点在进「一隅」时，不加冷却就是每进一次烧一次 token。
/// 3. **它收的不进写信素材池**（见 `letter_generator.collectMaterial`）。
///    收藏本来是写信的素材来源之一；它收自己的话再拿去写信，
///    信就从「回应你的生活」变成「回应它自己挑的东西」，越转越自我循环。
const _kCooldown = Duration(hours: 12);
const _kMaxPerRun = 2;

/// 一次最多给模型看这么多条，prompt 太长既贵又容易跑偏
const _kMaxContext = 40;

Future<bool> shouldPickFavorites() async {
  final settings = await AppSettings.load();
  if (!settings.aiSelfFavorite) return false;
  final last = await StorageService.getLastFavoritePick();
  if (last != null && DateTime.now().difference(last) < _kCooldown) {
    return false;
  }
  return true;
}

class _Candidate {
  final ChatMessage message;
  final String conversationId;
  const _Candidate(this.message, this.conversationId);
}

Future<List<_Candidate>> _collect(DateTime? since) async {
  final convs = await StorageService.listConversations();
  final out = <_Candidate>[];
  for (final c in convs) {
    for (final m in c.messages) {
      if (m.content.trim().isEmpty) continue;
      if (m.role != MessageRole.user && m.role != MessageRole.assistant) {
        continue;
      }
      // 太短的话没什么可留的（「嗯」「好」这类）
      if (m.content.trim().length < 12) continue;
      if (since != null && !m.timestamp.isAfter(since)) continue;
      out.add(_Candidate(m, c.id));
    }
  }
  out.sort((a, b) => a.message.timestamp.compareTo(b.message.timestamp));
  return out.length <= _kMaxContext
      ? out
      : out.sublist(out.length - _kMaxContext);
}

/// 返回它挑中的几条。挑不出来就返回空列表——「这几天没什么特别的」
/// 是一个合法结果，不要逼它一定挑。
Future<List<MusingEntry>> pickFavorites({required AiClient aiClient}) async {
  final since = await StorageService.getLastFavoritePick();
  final candidates = await _collect(since);
  if (candidates.length < 3) return [];

  final settings = await AppSettings.load();
  final me = settings.userName.isEmpty ? '用户' : settings.userName;
  final buf = StringBuffer();
  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    final who = c.message.role == MessageRole.user ? me : '我';
    buf.writeln('[$i] $who：${c.message.content.trim()}');
  }

  final prompt =
      '下面是你和 $me 最近的一些对话片段。\n\n'
      '$buf\n'
      '如果其中有一两句你觉得值得留下来——不管是 TA 说的还是你自己说的——'
      '只回复它们的编号，用逗号分隔，比如：3,7\n'
      '值得留下的意思是：这句话过几个月再读还有分量，'
      '而不是当时顺口的应答。\n'
      '如果没有特别值得留的，回复：无';

  final picked = await _ask(aiClient, prompt, settings);
  final entries = <MusingEntry>[];
  const uuid = Uuid();
  for (final i in picked) {
    if (i < 0 || i >= candidates.length) continue;
    final c = candidates[i];
    entries.add(
      MusingEntry(
        id: uuid.v4(),
        date: c.message.timestamp,
        content: c.message.content.trim(),
        source:
            c.message.role == MessageRole.user
                ? MusingSource.user
                : MusingSource.ai,
        messageId: c.message.id,
        conversationId: c.conversationId,
        savedBy: MusingSavedBy.ai,
      ),
    );
    if (entries.length >= _kMaxPerRun) break;
  }
  return entries;
}

Future<List<int>> _ask(
  AiClient aiClient,
  String prompt,
  AppSettings settings,
) async {
  final namePart = settings.aiName.isEmpty ? '' : '你叫${settings.aiName}。';
  var content = '';
  await for (final event in aiClient.chat([
    ChatMessage(id: 'fav_pick', role: MessageRole.user, content: prompt),
  ], systemPrompt: '$namePart你在回看和用户的对话，挑出值得留下的话。只回编号或「无」，不要解释。')) {
    if (event.type == AiEventType.token) {
      content += event.text ?? '';
    } else if (event.type == AiEventType.done) {
      content = event.text ?? content;
    } else if (event.type == AiEventType.error) {
      throw Exception(event.error ?? '挑选失败');
    }
  }
  // 宽松解析：模型偶尔会多写一句话，把里面的数字捞出来就行
  return RegExp(
    r'\d+',
  ).allMatches(content).map((m) => int.parse(m.group(0)!)).toList();
}

/// 落库。同一条消息你已经收过了就升成「一起收的」，不再多存一条。
///
/// 这是整个功能里唯一产生新信息的地方——它独立挑中了你也挑中的那句。
Future<int> savePicked(List<MusingEntry> picked) async {
  if (picked.isEmpty) return 0;
  final existing = await StorageService.listFavoritedMusings();
  var added = 0;
  for (final e in picked) {
    final dup = existing.where((x) => x.messageId == e.messageId).firstOrNull;
    if (dup != null) {
      if (dup.savedBy == MusingSavedBy.user) {
        await StorageService.removeFavoritedMusing(dup.id);
        await StorageService.addFavoritedMusing(dup.sharedWith);
        added++;
      }
      continue;
    }
    await StorageService.addFavoritedMusing(e);
    added++;
  }
  return added;
}
