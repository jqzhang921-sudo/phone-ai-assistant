import 'storage_service.dart';

/// 读取最近几篇日记，拼成一段"近期记忆"文字，附加到聊天的 system prompt 里。
/// 这样 AI 才真的"知道"自己写过日记、写了什么，而不是凭空声称记得。
/// 没有日记时返回空字符串（调用方应跳过拼接）。
Future<String> buildMemoryContext({int maxEntries = 3}) async {
  final entries = await StorageService.listDiaryEntries();
  if (entries.isEmpty) return '';

  final recent = entries.take(maxEntries).toList();
  final buf = StringBuffer();
  buf.writeln('## 你自己写下的近期日记（仅供你参考，不是要背诵给用户听）');
  for (final e in recent) {
    buf.writeln('- ${e.dateKey}：${e.content}');
  }
  buf.writeln();
  buf.writeln(
    '如果用户问起"记不记得"某件事、"有没有写日记"之类的问题，'
    '可以参考上面的内容如实回答；上面没提到的事，就如实说不记得，不要编造。',
  );
  return buf.toString();
}
