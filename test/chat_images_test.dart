import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/services/chat_images.dart';

/// 图从对话 JSON 里拆出去这件事，改写的是整段聊天记录——拆错一次就是丢图，
/// 或者文件一直瘦不下来。这几条钉住「哪些拆、哪些清、拆了以后还读得回来」。
void main() {
  late Directory tmp;
  final now = DateTime(2026, 9, 14, 12);
  final png = base64Encode([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 1, 2, 3]);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('chat_images_test');
    ChatImages.dirPath = tmp.path;
  });

  tearDown(() async {
    ChatImages.dirPath = null;
    await tmp.delete(recursive: true);
  });

  Map<String, dynamic> convOf(List<ChatMessage> messages) =>
      jsonDecode(
            jsonEncode({
              'id': 'c',
              'messages': [for (final m in messages) m.toJson()],
            }),
          )
          as Map<String, dynamic>;

  List<ChatMessage> messagesOf(Map<String, dynamic> conv) => [
    for (final m in conv['messages'] as List)
      ChatMessage.fromJson(m as Map<String, dynamic>),
  ];

  ChatMessage withImages(String id, Duration ago, List<String> images) =>
      ChatMessage(
        id: id,
        role: MessageRole.user,
        content: '看',
        timestamp: now.subtract(ago),
        images: images,
      );

  test('老的内联图：30 天内的拆成文件，更早的直接清掉', () {
    final conv = convOf([
      withImages('old', const Duration(days: 40), [png]),
      withImages('new', const Duration(days: 2), [png, png]),
    ]);

    expect(ChatImages.migrateInline(conv, dirPath: tmp.path, now: now), 3);

    final messages = messagesOf(conv);
    expect(messages[0].images, [ChatImages.clearedMark]);
    expect(messages[1].images.every(ChatImages.isFileRef), isTrue);
    expect(ChatImages.base64Of(messages[1].images[1]), png);
  });

  test('拆出来的文件，修改时间跟着消息走', () {
    // 不跟的话，sweep 会以为这些图全是今天发的，又得再存 30 天。
    final conv = convOf([
      withImages('m', const Duration(days: 10), [png]),
    ]);
    ChatImages.migrateInline(conv, dirPath: tmp.path, now: now);

    final file = ChatImages.fileOf(messagesOf(conv).single.images.single)!;
    final expected = now.subtract(const Duration(days: 10));
    expect(
      file.lastModifiedSync().difference(expected).inSeconds.abs(),
      lessThan(2),
    );
  });

  test('拆过一次再读：什么都不动', () {
    // 每次读盘都会过一遍 migrateInline，第二次必须是 0，
    // 不然每次点进对话都要多存一次盘。
    final conv = convOf([
      withImages('m', const Duration(days: 1), [png]),
    ]);
    ChatImages.migrateInline(conv, dirPath: tmp.path, now: now);
    expect(ChatImages.migrateInline(conv, dirPath: tmp.path, now: now), 0);
  });

  test('发给模型：清掉的、文件没了的不带，老的内联图照旧', () {
    expect(ChatImages.base64Of(ChatImages.clearedMark), isNull);
    expect(ChatImages.base64Of('file:gone.img'), isNull);
    expect(ChatImages.base64Of(png), png);
  });

  test('save 存下来的读得回来', () async {
    final ref = await ChatImages.save(base64Decode(png));
    expect(ChatImages.isFileRef(ref), isTrue);
    expect(ChatImages.base64Of(ref), png);
  });

  test('sweep 只删超过 30 天的', () async {
    final oldRef = await ChatImages.save([1, 2, 3]);
    final newRef = await ChatImages.save([4, 5, 6]);
    ChatImages.fileOf(
      oldRef,
    )!.setLastModifiedSync(now.subtract(const Duration(days: 31)));
    ChatImages.fileOf(
      newRef,
    )!.setLastModifiedSync(now.subtract(const Duration(days: 1)));

    expect(await ChatImages.sweep(now: now), 1);
    expect(ChatImages.fileOf(oldRef), isNull);
    expect(ChatImages.fileOf(newRef), isNotNull);
  });
}
