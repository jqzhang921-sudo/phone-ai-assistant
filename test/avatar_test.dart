import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/avatar_store.dart';
import 'package:phone_ai_assistant/services/chat_images.dart';
import 'package:phone_ai_assistant/services/phone_tools/avatar_tool.dart';

/// 它能自己换头像，所以「换回上一张」必须靠得住——随手发张截图被它换上了，
/// 得退得回来。这几条钉住历史、持久化，和工具的几条失败路径。
void main() {
  late Directory tmp;
  final store = AvatarStore.instance;
  final defaultEncode = AvatarStore.encode;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('avatar_test');
    AvatarStore.dirPath = '${tmp.path}/avatars';
    ChatImages.dirPath = '${tmp.path}/chat_images';
    // 插件调不到原生那边，测试里原样返回。
    AvatarStore.encode = (bytes) async => bytes;
    store.clearCache();
    AvatarTool.currentConversationId = 'c1';
    AvatarTool.latestUserImages = null;
  });

  tearDown(() async {
    AvatarStore.dirPath = null;
    ChatImages.dirPath = null;
    AvatarStore.encode = defaultEncode;
    AvatarTool.currentConversationId = null;
    AvatarTool.latestUserImages = null;
    await tmp.delete(recursive: true);
  });

  List<int> img(int n) => List.filled(8, n);
  List<int>? current(String id) => store.currentFile(id)?.readAsBytesSync();

  group('AvatarStore', () {
    test('换两张再一张张退：回到默认，再退就没有了', () async {
      await store.setFromBytes('c1', img(1));
      await store.setFromBytes('c1', img(2));
      expect(current('c1'), img(2));

      expect(await store.revert('c1'), isTrue);
      expect(current('c1'), img(1));
      expect(await store.revert('c1'), isTrue);
      expect(current('c1'), isNull);
      expect(await store.revert('c1'), isFalse);
    });

    test('每段对话各记各的', () async {
      await store.setFromBytes('c1', img(1));
      expect(current('c1'), img(1));
      await store.load('c2');
      expect(current('c2'), isNull);
    });

    test('重启以后从盘上读回来', () async {
      await store.setFromBytes('c1', img(3));
      store.clearCache();
      expect(current('c1'), isNull);
      await store.load('c1');
      expect(current('c1'), img(3));
    });

    test('历史最多留 10 张，更早的文件删掉', () async {
      for (var i = 0; i < 12; i++) {
        await store.setFromBytes('c1', img(i));
      }
      final files =
          Directory(
            AvatarStore.dirPath!,
          ).listSync().where((f) => f.path.endsWith('.img')).toList();
      expect(files, hasLength(AvatarStore.maxHistory));
      expect(current('c1'), img(11));
    });

    test('恢复默认：历史清空、文件删掉', () async {
      await store.setFromBytes('c1', img(1));
      await store.setFromBytes('c1', img(2));
      await store.reset('c1');
      expect(current('c1'), isNull);
      expect(store.hasCustom('c1'), isFalse);
      final left = Directory(
        AvatarStore.dirPath!,
      ).listSync().where((f) => f.path.endsWith('.img'));
      expect(left, isEmpty);
    });

    test('缩图失败：存原图，照样换上', () async {
      AvatarStore.encode = (_) async => throw StateError('原生那边不支持');
      await store.setFromBytes('c1', img(5));
      expect(current('c1'), img(5));
    });
  });

  group('AvatarTool', () {
    test('把 TA 最近发的图换成头像；不填 which 是最后一张，填了按顺序数', () async {
      final first = await ChatImages.save(img(7));
      final second = await ChatImages.save(img(8));
      AvatarTool.latestUserImages = () => [first, second];

      var result = await AvatarTool.execute({'action': 'use_latest_image'});
      expect(result['success'], isTrue);
      expect(current('c1'), img(8));

      result = await AvatarTool.execute({
        'action': 'use_latest_image',
        'which': 1,
      });
      expect(result['success'], isTrue);
      expect(current('c1'), img(7));
    });

    test('老数据里的内联 base64 图也能用', () async {
      AvatarTool.latestUserImages = () => [base64Encode(img(9))];
      final result = await AvatarTool.execute({'action': 'use_latest_image'});
      expect(result['success'], isTrue);
      expect(current('c1'), img(9));
    });

    test('换不了的几种：没发过图、图清掉了、第几张越界、不知道哪段对话', () async {
      expect(
        (await AvatarTool.execute({'action': 'use_latest_image'}))['success'],
        isFalse,
      );

      AvatarTool.latestUserImages = () => [ChatImages.clearedMark];
      expect(
        (await AvatarTool.execute({'action': 'use_latest_image'}))['success'],
        isFalse,
      );

      final ref = await ChatImages.save(img(1));
      AvatarTool.latestUserImages = () => [ref];
      expect(
        (await AvatarTool.execute({
          'action': 'use_latest_image',
          'which': 2,
        }))['success'],
        isFalse,
      );

      AvatarTool.currentConversationId = null;
      expect(
        (await AvatarTool.execute({'action': 'use_latest_image'}))['success'],
        isFalse,
      );
      expect(current('c1'), isNull);
    });

    test('revert：换回上一张，退到头了告诉它没有了', () async {
      await store.setFromBytes('c1', img(1));
      await store.setFromBytes('c1', img(2));

      expect(
        (await AvatarTool.execute({'action': 'revert'}))['success'],
        isTrue,
      );
      expect(current('c1'), img(1));
      expect(
        (await AvatarTool.execute({'action': 'revert'}))['success'],
        isTrue,
      );
      expect(
        (await AvatarTool.execute({'action': 'revert'}))['success'],
        isFalse,
      );
    });
  });

  group('你自己的头像', () {
    test('全局一张，和它在各段对话里的头像互不影响', () async {
      await store.setFromBytes(AvatarStore.userKey, img(1));
      await store.setFromBytes('c1', img(2));

      expect(current(AvatarStore.userKey), img(1));
      expect(current('c1'), img(2));

      await store.reset('c1');
      expect(current(AvatarStore.userKey), img(1));
    });

    test('它的换头像工具碰不到你的头像', () async {
      await store.setFromBytes(AvatarStore.userKey, img(1));
      final ref = await ChatImages.save(img(9));
      AvatarTool.latestUserImages = () => [ref];

      await AvatarTool.execute({'action': 'use_latest_image'});
      await AvatarTool.execute({'action': 'revert'});
      await AvatarTool.execute({'action': 'revert'});

      expect(current(AvatarStore.userKey), img(1));
    });
  });
}
