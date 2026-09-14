import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

/// 聊天里发的图：**存成文件，消息里只记一个引用**。
///
/// ## 为什么
///
/// 原来是把整张图 base64 之后直接塞进 [ChatMessage.images]，跟着对话 JSON
/// 一起存。2026-09-14 真机上量到 Mu5e 那段对话 **2.1 亿字符（约 200MB）**：
///
/// - 点进对话：读文件 1.1 秒 + 解析 0.6 秒
/// - 每聊完一轮存一次盘，就是把这 200MB 整个重新编码、重写一遍
/// - 最近几十条里的图，每一轮都跟着历史重新发给模型
///
/// 图拆出去以后，对话文件只剩文字。
///
/// ## `images` 里的一项现在有三种样子
///
/// - `file:<名字>`：图在 [dirPath] 下面
/// - `cleared:`：图已经清掉了（超过 [keep]），气泡里显示「图片已清理」
/// - 其他：老数据，内联 base64。读盘时会被 [migrateInline] 换掉，
///   但代码仍然认它——备份恢复回来的老文件、测试里手写的消息都是这种
///
/// ## 为什么只留 [keep] 这么久
///
/// Cleo 说的：「以前发过的图可以清理掉，一直存下去肯定越来越大」。
/// 图是给当下那一轮看的，模型也只看得到最近几十条。
class ChatImages {
  /// 图留多久。超过的 [sweep] 会删文件，[migrateInline] 直接标成已清理。
  static const keep = Duration(days: 30);

  static const _filePrefix = 'file:';
  static const clearedMark = 'cleared:';

  /// 图片目录。[StorageService.init] 里设。
  ///
  /// 可空是故意的：后台 isolate、测试里可能没人设过它，那时候文件引用一律
  /// 按「找不到」处理，不能炸。
  static String? dirPath;

  static bool isFileRef(String image) => image.startsWith(_filePrefix);
  static bool isCleared(String image) => image.startsWith(clearedMark);

  /// 文件引用对应的文件；不是文件引用、或者文件已经没了，返回 null。
  static File? fileOf(String image) {
    final dir = dirPath;
    if (dir == null || !isFileRef(image)) return null;
    final file = File('$dir/${image.substring(_filePrefix.length)}');
    return file.existsSync() ? file : null;
  }

  /// 发给模型用的 base64。清掉的、找不到文件的返回 null——**不带就是了**，
  /// 不能因为一张旧图没了整轮请求就发不出去。
  static String? base64Of(String image) {
    if (isCleared(image)) return null;
    if (!isFileRef(image)) return image; // 老的内联 base64
    final file = fileOf(image);
    if (file == null) return null;
    try {
      return base64Encode(file.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  /// 存一张新图，返回要写进消息里的引用。
  static Future<String> save(List<int> bytes) async {
    final dir = Directory(dirPath!);
    await dir.create(recursive: true);
    final name = '${const Uuid().v4()}.img';
    await File('${dir.path}/$name').writeAsBytes(bytes);
    return '$_filePrefix$name';
  }

  /// 把一场对话 JSON 里的内联 base64 图就地换掉，返回换了几张。
  ///
  /// 在**解码之前的 Map** 上做，而不是在 [ChatMessage] 上：消息是不可变的，
  /// 在这儿改最省事，而且能跟 JSON 解析一起放进后台 isolate——所以这里
  /// **只能用参数**，不能碰 [dirPath] 这种静态变量（新 isolate 里是空的）。
  ///
  /// - 超过 [keep] 的：直接标成已清理，不落文件（落了也马上被 [sweep] 删）
  /// - 以内的：解出来写成文件，**修改时间设成消息的时间**，
  ///   不然 [sweep] 会以为它们全是今天发的，又得再存 30 天
  ///
  /// 写文件失败的也标成已清理：留着内联 base64，文件就永远瘦不下来。
  static int migrateInline(
    Map<String, dynamic> conv, {
    required String dirPath,
    required DateTime now,
  }) {
    final messages = conv['messages'];
    if (messages is! List) return 0;
    var changed = 0;
    for (final m in messages) {
      if (m is! Map) continue;
      final images = m['images'];
      if (images is! List || images.isEmpty) continue;
      final at = _timeOf(m['timestamp']) ?? now;
      final expired = now.difference(at) > keep;
      final safeId = '${m['id']}'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      for (var i = 0; i < images.length; i++) {
        final image = '${images[i]}';
        if (isFileRef(image) || isCleared(image)) continue;
        changed++;
        if (expired) {
          images[i] = clearedMark;
          continue;
        }
        try {
          Directory(dirPath).createSync(recursive: true);
          final name = '${safeId}_$i.img';
          File('$dirPath/$name')
            ..writeAsBytesSync(base64Decode(image))
            ..setLastModifiedSync(at);
          images[i] = '$_filePrefix$name';
        } catch (_) {
          images[i] = clearedMark;
        }
      }
    }
    return changed;
  }

  static DateTime? _timeOf(Object? raw) => switch (raw) {
    int ms => DateTime.fromMillisecondsSinceEpoch(ms),
    String s => DateTime.tryParse(s),
    _ => null,
  };

  /// 删掉超过 [keep] 的图片文件，返回删了几个。
  ///
  /// 消息里的引用不用跟着改：找不到文件就显示「图片已清理」，发给模型时跳过。
  static Future<int> sweep({String? dir, DateTime? now}) async {
    final path = dir ?? dirPath;
    if (path == null) return 0;
    final folder = Directory(path);
    if (!await folder.exists()) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(keep);
    var deleted = 0;
    await for (final entry in folder.list()) {
      if (entry is! File) continue;
      try {
        if ((await entry.lastModified()).isBefore(cutoff)) {
          await entry.delete();
          deleted++;
        }
      } catch (_) {}
    }
    return deleted;
  }
}
