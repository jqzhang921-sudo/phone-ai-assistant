import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:uuid/uuid.dart';

/// 它在每段对话里的头像，带「换回上一张」的历史。
///
/// ## 为什么按对话记
///
/// Mu5e 和沐是两段对话、两个人设。2026-09-15 之前两边都是同一只猫，
/// 从首页到聊天页长得一模一样，只能靠名字分。
///
/// ## 为什么单独存一份，不直接指向聊天里那张图
///
/// 聊天图片 30 天后会被 [ChatImages.sweep] 清掉。头像要是只记着那张图的
/// 引用，一个月后就没了。所以换头像时把图**复制**一份、缩到 256 存进
/// `avatars/`，跟聊天图片分开。
///
/// ## 历史是一个栈
///
/// 最后一张是当前头像；「换回上一张」就是弹掉最后一张（连文件一起删）。
/// 栈空了就是默认那只猫。最多留 [maxHistory] 张，更早的删掉。
///
/// 它可以自己换（见 `AvatarTool`，Cleo 选的是「发的任何图它喜欢都能拿去用」），
/// 所以「换回上一张」必须随时可用——随手发张截图被它换上了，得退得回来。
class AvatarStore extends ChangeNotifier {
  AvatarStore();

  static final instance = AvatarStore();

  /// 你自己的头像用这个 key，**所有对话共用一张**——你是同一个人。
  ///
  /// 对话 id 是 uuid 或 `book_xxx`，撞不上这个。它的换头像工具只拿
  /// 当前对话的 id，所以它改不了你的头像。
  static const userKey = '_user';

  /// 头像目录。[StorageService.init] 里设；没设的时候什么都不存、一律默认。
  static String? dirPath;

  static const maxHistory = 10;
  static const _size = 256;

  /// 测试里换掉插件——插件要调原生那边，测试环境里调不到。
  @visibleForTesting
  static Future<Uint8List> Function(Uint8List bytes) encode = _encodeWebp;

  static Future<Uint8List> _encodeWebp(Uint8List bytes) =>
      FlutterImageCompress.compressWithList(
        bytes,
        // 短边缩到 256。气泡里的头像才 28，顶栏 34，256 在高分屏上也够清楚。
        minWidth: _size,
        minHeight: _size,
        quality: 85,
        format: CompressFormat.webp,
      );

  final Map<String, List<String>> _stacks = {};

  /// 当前头像文件；没设过、没读过、或者文件没了，返回 null（用默认）。
  File? currentFile(String conversationId) {
    final dir = dirPath;
    final stack = _stacks[conversationId];
    if (dir == null || stack == null || stack.isEmpty) return null;
    final file = File('$dir/${stack.last}');
    return file.existsSync() ? file : null;
  }

  /// 有没有自定义过（有才能「换回上一张」「恢复默认」）。
  bool hasCustom(String conversationId) =>
      _stacks[conversationId]?.isNotEmpty ?? false;

  /// 从盘上读这段对话的头像历史。读过的不重复读。
  Future<void> load(String conversationId) async {
    if (_stacks.containsKey(conversationId)) return;
    final dir = dirPath;
    if (dir == null) return;
    var stack = <String>[];
    try {
      final index = File(_indexPath(dir, conversationId));
      if (await index.exists()) {
        final data = jsonDecode(await index.readAsString());
        stack = [for (final e in (data['stack'] as List)) '$e'];
      }
    } catch (e) {
      debugPrint('[avatar] 读 $conversationId 的头像失败，当默认处理：$e');
    }
    _stacks[conversationId] = stack;
    notifyListeners();
  }

  /// 换成这张图。
  Future<void> setFromBytes(String conversationId, List<int> bytes) async {
    final dir = dirPath;
    if (dir == null) throw StateError('头像目录还没初始化');
    await load(conversationId);

    final input = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    var out = input;
    try {
      final encoded = await encode(input);
      if (encoded.isNotEmpty) out = encoded;
    } catch (e) {
      // 缩不了就存原图：头像换不上比头像大一点糟得多。
      debugPrint('[avatar] 缩图失败，存原图：$e');
    }

    await Directory(dir).create(recursive: true);
    final name = '${const Uuid().v4()}.img';
    await File('$dir/$name').writeAsBytes(out);

    final stack = _stacks[conversationId]!..add(name);
    while (stack.length > maxHistory) {
      _deleteFile(dir, stack.removeAt(0));
    }
    await _save(dir, conversationId);
    notifyListeners();
  }

  /// 换回上一张。已经是默认头像了（没有可退的）返回 false。
  Future<bool> revert(String conversationId) async {
    final dir = dirPath;
    if (dir == null) return false;
    await load(conversationId);
    final stack = _stacks[conversationId]!;
    if (stack.isEmpty) return false;
    _deleteFile(dir, stack.removeLast());
    await _save(dir, conversationId);
    notifyListeners();
    return true;
  }

  /// 恢复默认：历史全清。
  Future<void> reset(String conversationId) async {
    final dir = dirPath;
    if (dir == null) return;
    await load(conversationId);
    final stack = _stacks[conversationId]!;
    for (final name in stack) {
      _deleteFile(dir, name);
    }
    stack.clear();
    await _save(dir, conversationId);
    notifyListeners();
  }

  @visibleForTesting
  void clearCache() => _stacks.clear();

  static String _indexPath(String dir, String conversationId) =>
      '$dir/${conversationId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json';

  Future<void> _save(String dir, String conversationId) async {
    await Directory(dir).create(recursive: true);
    await File(
      _indexPath(dir, conversationId),
    ).writeAsString(jsonEncode({'stack': _stacks[conversationId]}));
  }

  static void _deleteFile(String dir, String name) {
    try {
      final file = File('$dir/$name');
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
