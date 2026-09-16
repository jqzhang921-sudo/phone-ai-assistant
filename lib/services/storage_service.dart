import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../models/book.dart';
import '../models/conversation.dart';
import '../models/conversation_summary.dart';
import '../models/diary_entry.dart';
import '../models/letter.dart';
import '../models/memory_topic.dart';
import '../models/musing_entry.dart';
import '../utils/dates.dart';
import 'avatar_store.dart';
import 'chat_images.dart';
import 'xiaoke_channel.dart';

class StorageService {
  static late Directory _dir;
  static const _kBackgroundImageKey = 'chat_background_image_path';
  static const _kBackgroundPresetKey = 'chat_background_preset';

  static Future<void> init() async {
    _dir = await getApplicationDocumentsDirectory();
    ChatImages.dirPath = '${_dir.path}/chat_images';
    AvatarStore.dirPath = '${_dir.path}/avatars';
    XiaokeChannel.dirPath = '${_dir.path}/xiaoke';
  }

  /// 删掉拆图前留的原文件备份（`conversations_pre_images/`）。
  ///
  /// 备份只为「拆图那一下出错能找回来」。2026-09-14 Mu5e 拆完核对过，
  /// Cleo 说删——200MB 一直占着没有意义。启动时删：拆图发生在点进对话
  /// 那一刻，那一轮 App 开着的期间备份都在，下次启动才清。
  static Future<void> dropPreImageBackups() async {
    try {
      final dir = Directory('${_dir.path}/conversations_pre_images');
      if (!await dir.exists()) return;
      var bytes = 0;
      await for (final f in dir.list()) {
        if (f is File) bytes += await f.length();
      }
      await dir.delete(recursive: true);
      debugPrint('[images] 拆图备份已删，释放 ${bytes ~/ (1024 * 1024)}MB');
    } catch (e) {
      debugPrint('[images] 删拆图备份失败：$e');
    }
  }

  /// 保存自定义聊天背景图片路径（传 null 清除）
  static Future<void> setBackgroundImagePath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_kBackgroundImageKey);
    } else {
      await prefs.setString(_kBackgroundImageKey, path);
    }
  }

  /// 读取自定义聊天背景图片路径，未设置则返回 null
  static Future<String?> getBackgroundImagePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kBackgroundImageKey);
  }

  /// 背景预设：'none' 跟随主题 / 'light' 浅色 / 'dark' 深色
  static Future<void> setBackgroundPreset(String preset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBackgroundPresetKey, preset);
  }

  static Future<String> getBackgroundPreset() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kBackgroundPresetKey) ?? 'none';
  }

  /// 主页「最近对话」是展开着还是收起着。见 [homeConversations]。
  ///
  /// 记住她的选择：默认收起（主页只留置顶的和最近那条），她点开之后就一直开着，
  /// 直到再点一次。每次回主页都要重新点开的话，这个开关就成了负担。
  static const _kHomeConversationsExpandedKey = 'home_conversations_expanded';

  static Future<void> setHomeConversationsExpanded(bool expanded) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHomeConversationsExpandedKey, expanded);
  }

  static Future<bool> getHomeConversationsExpanded() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kHomeConversationsExpandedKey) ?? false;
  }

  /// 超过这么长的 JSON 挪到另一个 isolate 去解，别卡界面线程。
  ///
  /// 两千条消息的对话约 76 万字符，电脑上解一次 12ms，手机上要慢几倍——
  /// 正好卡在「点进对话」和「返回主页」的那一下。小文件不挪：起一个
  /// isolate 本身也要几毫秒，比直接解还贵。
  ///
  /// ⚠️ 传给 `Isolate.run` 的闭包里**只能用传进去的字符串**。新 isolate 里
  /// 静态变量是空的（[_dir] 没 init 过），碰到 `_convDir` 就炸。
  static const _kOffThreadJsonChars = 100 * 1000;

  static String get _convDir => '${_dir.path}/conversations';
  static String get _trashDir => '${_dir.path}/conversations_trash';

  /// 纯文本索引的落脚处。**故意跟正文分开放，不放进 `conversations/`。**
  ///
  /// 那个目录有几处是「凡是 .json 就当一场对话」的（[listConversations]、
  /// [lastConversationWriteAt]），索引混进去会被当成读不出来的对话，
  /// 轻则报失败，重则把「最近写过对话是什么时候」算错。
  ///
  /// 也不进备份：backup_service 是逐个目录点名的，这里没被点到。
  /// 索引本来就是派生数据，恢复备份后重建一遍就行。
  static String get _indexDir => '${_dir.path}/conversations_index';

  /// ⚠️ **先写临时文件再 rename，不能直接往目标文件上写。**
  ///
  /// 症状是「对话一会消失一会又回来」。原来是 `writeAsString` 直接覆盖目标：
  /// 一段一千多条消息的对话 JSON 将近一兆，写它要花时间，而这期间主页正好去
  /// 列对话，读到的是**半个文件** → `jsonDecode` 抛 → [loadConversation] 返回
  /// null → [listConversations] 把它跳过。写完再刷新，它又出现了。
  ///
  /// 今天起还多了一个写者：后台 isolate 也会往对话里追加主动说的话，
  /// 撞车的窗口比原来更宽。
  ///
  /// `rename` 在同一分区上是原子的：读的人要么看到旧的完整文件，要么看到新的
  /// 完整文件，不存在中间态。写到一半崩了也只是留下一个 .tmp，原文件没动。
  static Future<void> saveConversation(Conversation conv) async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    // ⚠️ `updatedAt` 以前**从来没人更新过**——全项目只有构造函数设过一次，
    // 加消息不动它，存盘也不动它。于是它实际上是「创建时间」，而所有按
    // 「最近」排序的地方都在拿它当依据：
    //
    // - 首页「最近对话」按它倒序 → 每天都在聊的那段沉在下面，
    //   显示的日期还是几周前
    // - 主动说的话要落进「最近动过的那段」 → 落进了一段八月底建的、
    //   早就不聊了的对话里（真机上就是这么错的）
    //
    // 在这里收口，所有调用方自动受益。取最后一条消息的时间而不是 now()：
    // 那才是「最后一次有来有往」，切换对话时的空存盘不该把它顶上去。
    final lastMsg = conv.messages.isEmpty ? null : conv.messages.last.timestamp;
    if (lastMsg != null && lastMsg.isAfter(conv.updatedAt)) {
      conv.updatedAt = lastMsg;
    }
    final target = '$_convDir/${conv.id}.json';
    final tmp = File('$target.tmp');
    // ⚠️ **不要加 `flush: true`。** 原子性靠的是 rename，跟 fsync 没关系：
    // 读的人经过页缓存，看到的要么是旧文件要么是新文件。加上 flush 只是让每次
    // 存盘都等一次磁盘同步——一段一千多条消息的对话将近一兆，等下来就是可感的
    // 卡顿。实测就是这么卡的。
    await tmp.writeAsString(jsonEncode(conv.toJson()));
    await tmp.rename(target);

    // 顺手把纯文本索引也刷一遍。**在这里写，不另起一条读盘再压的路径**：
    // 这场对话此刻就在手上，压索引是白拿的，不用再把刚写下去的东西读回来。
    //
    // 包在 try 里、且失败不作声，是因为索引只是缓存——[listConversationSummaries]
    // 撞见过期或缺失的索引会自己从正文重建。存盘这件事本身绝不能因为它失败。
    try {
      await _writeIndex(conv.id, ConversationSummary.fromConversation(conv));
    } catch (_) {}
  }

  /// 写一份索引。<**临时文件 + rename**>，理由同 [saveConversation]：
  /// 首页随时可能在列对话，不能让它读到半个索引。
  ///
  /// `size`/`mtime` 记的是**正文文件**的大小与修改时间，是索引「新不新鲜」的
  /// 唯一凭据。两个一起比：改内容几乎必然改长度，再叠上毫秒级的时间戳，
  /// 「文件变了而索引看着还新鲜」基本不可能——除了同一毫秒内写两次，
  /// 那种情况下顶多列表旧一拍，下次存盘就回来了。
  static Future<void> _writeIndex(
    String id,
    ConversationSummary summary,
  ) async {
    final src = File('$_convDir/$id.json');
    if (!await src.exists()) return; // 已经删了（比如刚被移进回收站），别写出个孤儿
    final stat = src.statSync();
    final dir = Directory(_indexDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = '$_indexDir/$id.json';
    final tmp = File('$target.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'size': stat.size,
        'mtime': stat.modified.millisecondsSinceEpoch,
        ...summary.toJson(),
      }),
    );
    await tmp.rename(target);
  }

  static Future<Conversation?> loadConversation(String id) async {
    try {
      final file = File('$_convDir/$id.json');
      if (!await file.exists()) return null;
      final data = await file.readAsString();
      final imagesDir = ChatImages.dirPath;
      final (conv, migrated) =
          data.length < _kOffThreadJsonChars
              ? _decodeConversation(data, imagesDir)
              : await Isolate.run(() => _decodeConversation(data, imagesDir));
      // 存量数据里 `updatedAt` 全是创建时间（见 saveConversation 的注释）。
      // 读出来就地纠正，不写盘：排序立刻就对了，而下次真存盘时会落到磁盘上。
      final lastMsg =
          conv.messages.isEmpty ? null : conv.messages.last.timestamp;
      if (lastMsg != null && lastMsg.isAfter(conv.updatedAt)) {
        conv.updatedAt = lastMsg;
      }
      if (migrated > 0) {
        // 图刚从正文里拆出去，**存回去之前先把原文件原样留一份**。
        // 这一步改写的是整段聊天记录，拆错了得有地方找回来。
        // 留不下来就先不存：内存里这份照样能看，原文件一个字没动。
        try {
          final bak = File('${_dir.path}/conversations_pre_images/$id.json');
          if (!await bak.exists()) {
            await bak.parent.create(recursive: true);
            await file.copy(bak.path);
          }
          await saveConversation(conv);
          debugPrint('[images] $id 拆出 $migrated 张图，原文件留在 ${bak.path}');
        } catch (e) {
          debugPrint('[images] $id 备份原文件失败，这次不存：$e');
        }
      }
      return conv;
    } catch (_) {
      return null;
    }
  }

  /// JSON → 对话，顺手把内联的图拆成文件（见 [ChatImages.migrateInline]）。
  ///
  /// 会被放进 `Isolate.run`，所以只用参数，不碰静态变量。
  static (Conversation, int) _decodeConversation(
    String data,
    String? imagesDir,
  ) {
    final map = jsonDecode(data) as Map<String, dynamic>;
    final migrated =
        imagesDir == null
            ? 0
            : ChatImages.migrateInline(
              map,
              dirPath: imagesDir,
              now: DateTime.now(),
            );
    return (Conversation.fromJson(map), migrated);
  }

  /// 上一次列对话（[listConversations] 或 [listConversationSummaries]）
  /// 有几个文件读不出来。
  ///
  /// 原来读失败是**无声跳过**的：那段对话直接从列表里消失，没有报错也没有痕迹，
  /// 用户看到的就是「它突然不见了」——而文件其实还在磁盘上。
  /// 有了原子写之后这个数应该恒为 0；不为 0 就是真出事了，得看得见。
  static int lastListFailures = 0;

  /// 最后一次有对话被写过是什么时候。**不解析任何 JSON。**
  ///
  /// 主动说话的门槛要判断「是不是刚聊完」，原来走 [listConversations] 再遍历
  /// 每条消息找最大时间戳——为了一个时间戳，把每一段对话的 JSON 全解析一遍。
  /// 一段一千多条消息将近一兆，而这件事在 App 启动时就要做一次，正好跟头几帧
  /// 抢主 isolate。实测掉帧就是它。
  ///
  /// 文件的修改时间就够了：存盘就意味着有来有往。它还顺带覆盖了主动说的话
  /// （那也会写文件），而那本来就该算「刚说过话」。
  static Future<DateTime?> lastConversationWriteAt() async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) return null;
    DateTime? latest;
    try {
      for (final f in await dir.list().toList()) {
        if (!f.path.endsWith('.json')) continue;
        final t = f.statSync().modified;
        if (latest == null || t.isAfter(latest)) latest = t;
      }
    } catch (_) {}
    return latest;
  }

  static Future<List<Conversation>> listConversations() async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();

    // 清掉崩溃留下的临时文件。它们不参与列表（下面只收 .json），
    // 但留着会越攒越多。
    for (final f in files) {
      if (f.path.endsWith('.json.tmp')) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    final convs = <Conversation>[];
    var failed = 0;
    for (final file in files) {
      if (file.path.endsWith('.json')) {
        final conv = await loadConversation(
          file.uri.pathSegments.last.replaceAll('.json', ''),
        );
        if (conv != null) {
          convs.add(conv);
        } else {
          // 文件在、但读不出来。以前这里什么都不做，那段对话就无声消失了。
          failed++;
        }
      }
    }
    lastListFailures = failed;

    // 置顶的排最前，其余按更新时间倒序
    convs.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return convs;
  }

  /// 列对话，但只回[纯文本索引]，**不解析图片**。
  ///
  /// 给首页「最近对话」和历史搜索用——它们本来就不需要正文以外的东西，
  /// 而正文在整份数据里只占两百分之一（187 MB 的 base64 图片 vs 953K 字符正文）。
  ///
  /// 语义上和 [listConversations] 一致：同样跳过读不出来的文件、
  /// 同样往 [lastListFailures] 记账、同样置顶优先、同样按更新时间倒序。
  /// 需要完整对话（打开某一场）时用 [loadConversation]。
  static Future<List<ConversationSummary>> listConversationSummaries() async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();

    // 清掉崩溃留下的临时文件，同 [listConversations]。
    for (final f in files) {
      if (f.path.endsWith('.json.tmp')) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }

    final liveIds = <String>{};
    final out = <ConversationSummary>[];
    var failed = 0;
    for (final file in files) {
      if (!file.path.endsWith('.json')) continue;
      final id = file.uri.pathSegments.last.replaceAll('.json', '');
      liveIds.add(id);
      final summary = await _loadSummary(id);
      if (summary == null) {
        failed++;
      } else {
        out.add(summary);
      }
    }
    lastListFailures = failed;

    await _sweepOrphanIndexes(liveIds);

    out.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return out;
  }

  /// 读一场对话的索引。缺失、过期、坏掉都走同一条路：**从正文重建一份**。
  ///
  /// 重建这一次必须把正文整个解析出来（含 base64 图片）——正是要避免的那份常驻
  /// 内存。但它是**一次性**的：解析完只留下 [ConversationSummary]，那个
  /// `Conversation` 随即变成垃圾，不会跟着 App 活到进程结束。建完存回去，
  /// 之后每次列对话都只读几百 KB 的索引。
  ///
  /// 所以升级到这一版之后的第一次列对话会卡一下（等于旧行为），之后就轻了。
  static Future<ConversationSummary?> _loadSummary(String id) async {
    final src = File('$_convDir/$id.json');
    if (!await src.exists()) return null;
    final FileStat stat;
    try {
      stat = src.statSync();
    } catch (_) {
      return null;
    }

    try {
      final index = File('$_indexDir/$id.json');
      if (await index.exists()) {
        final raw = await index.readAsString();
        // 索引里存着每条消息的正文，长对话的索引也有好几百 KB。
        final cached =
            raw.length < _kOffThreadJsonChars
                ? jsonDecode(raw)
                : await Isolate.run(() => jsonDecode(raw));
        if (cached is Map<String, dynamic> &&
            cached['size'] == stat.size &&
            cached['mtime'] == stat.modified.millisecondsSinceEpoch) {
          return ConversationSummary.fromJson(cached);
        }
      }
    } catch (_) {
      // 索引坏了（读到半个、版本旧了、字段缺了）不是错误——它只是缓存，往下重建。
    }

    final conv = await loadConversation(id);
    if (conv == null) return null;
    final summary = ConversationSummary.fromConversation(conv);
    try {
      await _writeIndex(id, summary);
    } catch (_) {}
    return summary;
  }

  /// 删掉正文已经不在了的索引。
  ///
  /// 正常路径不会留下孤儿——移进回收站时索引就跟着删了。但存盘和删除可以撞车：
  /// 索引正写到一半，那边把对话删了，rename 还是会把索引放下去。
  /// 孤儿没人读（[listConversationSummaries] 是从正文目录出发去找索引，不是反过来），
  /// 留着只是白占地方——顺手清掉，别让它无声地越攒越多。
  static Future<void> _sweepOrphanIndexes(Set<String> liveIds) async {
    final dir = Directory(_indexDir);
    if (!await dir.exists()) return;
    try {
      for (final f in await dir.list().toList()) {
        final name = f.uri.pathSegments.last;
        if (name.endsWith('.json') &&
            liveIds.contains(name.replaceAll('.json', ''))) {
          continue;
        }
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 删索引。**尽力而为，删不掉不算错**——理由同 [_sweepOrphanIndexes]：
  /// 索引只从正文目录出发被找到，正文不在了它就再也不会被读到。
  static Future<void> _deleteIndex(String id) async {
    try {
      final f = File('$_indexDir/$id.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 设置对话是否置顶。
  static Future<void> setConversationPinned(String id, bool pinned) async {
    final conv = await loadConversation(id);
    if (conv == null) return;
    conv.isPinned = pinned;
    await saveConversation(conv);
  }

  /// 删除对话：移入回收站（可恢复），而非物理删除。
  static Future<void> deleteConversation(String id) async {
    final src = File('$_convDir/$id.json');
    final trash = File('$_trashDir/$id.json');
    if (await src.exists()) {
      await trash.parent.create(recursive: true);
      await src.rename(trash.path);
    }
    // 索引跟着走。恢复的时候不搬回来——那一场要重建一次索引（就一场，很便宜），
    // 换来的是「回收站里绝对没有和正文对不上的索引」。
    await _deleteIndex(id);
  }

  /// 从回收站恢复对话。
  static Future<void> restoreConversation(String id) async {
    final trash = File('$_trashDir/$id.json');
    if (await trash.exists()) {
      await trash.rename('$_convDir/$id.json');
    }
  }

  /// 从回收站彻底删除。
  static Future<void> permanentlyDeleteConversation(String id) async {
    final trash = File('$_trashDir/$id.json');
    if (await trash.exists()) await trash.delete();
    // 进回收站那一步已经删过索引了。这里再来一次是防着那一步没删成，
    // 让「彻底删除」真的是彻底的。
    await _deleteIndex(id);
  }

  /// 列出回收站中的对话（按更新时间倒序）。
  static Future<List<Conversation>> listTrashedConversations() async {
    final dir = Directory(_trashDir);
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    final convs = <Conversation>[];
    for (final file in files) {
      if (file.path.endsWith('.json')) {
        final conv = await loadConversationFromDir(
          _trashDir,
          file.uri.pathSegments.last.replaceAll('.json', ''),
        );
        if (conv != null) convs.add(conv);
      }
    }
    return convs;
  }

  static Future<Conversation?> loadConversationFromDir(
    String dir,
    String id,
  ) async {
    final file = File('$dir/$id.json');
    if (!await file.exists()) return null;
    try {
      final data = await file.readAsString();
      return Conversation.fromJson(jsonDecode(data));
    } catch (_) {
      return null;
    }
  }

  // ---------------- 日记 ----------------
  static const _kDiaryKey = 'diary_entries';

  /// 按时间倒序返回所有日记（最新的在最前）。
  static Future<List<DiaryEntry>> listDiaryEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDiaryKey);
    if (raw == null) return [];
    final list =
        (jsonDecode(raw) as List)
            .map((e) => DiaryEntry.fromJson(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  /// 保存一条新日记（追加，不覆盖旧的）。
  static Future<void> addDiaryEntry(DiaryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await listDiaryEntries();
    entries.add(entry);
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_kDiaryKey, raw);
  }

  static Future<void> deleteDiaryEntry(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await listDiaryEntries();
    entries.removeWhere((e) => e.id == id);
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_kDiaryKey, raw);
  }

  /// 是否已经有当天日期的日记（避免重复生成）。
  static Future<bool> hasDiaryEntryForToday() async {
    final entries = await listDiaryEntries();
    final now = DateTime.now();
    final todayKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return entries.any((e) => e.dateKey == todayKey);
  }

  // ---------------- 我想说（首页每日一段） ----------------
  static const _kTodayMusingKey = 'today_musing';
  static const _kFavoritedMusingsKey = 'favorited_musings';

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// 读取这个「我想说」日缓存的内容，格式 {date, content, favorited}。
  /// 跨天了就返回 null，由调用方重新生成。
  ///
  /// ⚠️ 用 [musingDayKey] 而不是 [_todayKey]：一天从凌晨 5 点算起，
  /// 深夜那段还算前一天。理由见 `dates.dart` 里 [musingDayStartHour] 的注释。
  /// 键的字符串格式没变，所以已经存着的那条照样认得。
  static Future<Map<String, dynamic>?> getTodayMusing() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTodayMusingKey);
    if (raw == null) return null;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['date'] != musingDayKey(DateTime.now())) return null;
    return data;
  }

  /// 缓存新生成的"我想说"（覆盖旧的，用于手动刷新）。
  static Future<void> setTodayMusing(String content) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kTodayMusingKey,
      jsonEncode({
        'date': musingDayKey(DateTime.now()),
        'content': content,
        'favorited': false,
      }),
    );
  }

  /// 标记今天缓存的"我想说"是否已收藏（仅影响首页星标显示）。
  static Future<void> setTodayMusingFavorited(bool favorited) async {
    final today = await getTodayMusing();
    if (today == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kTodayMusingKey,
      jsonEncode({...today, 'favorited': favorited}),
    );
  }

  /// 收藏列表：按时间倒序。
  static Future<List<MusingEntry>> listFavoritedMusings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFavoritedMusingsKey);
    if (raw == null) return [];
    final list =
        (jsonDecode(raw) as List)
            .map((e) => MusingEntry.fromJson(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static Future<void> addFavoritedMusing(MusingEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await listFavoritedMusings();
    entries.add(entry);
    await prefs.setString(
      _kFavoritedMusingsKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> removeFavoritedMusing(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await listFavoritedMusings();
    entries.removeWhere((e) => e.id == id);
    await prefs.setString(
      _kFavoritedMusingsKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  /// 今天收藏的"一隅"内容列表（喂给日记生成器做素材，不强制引用）。
  static Future<List<MusingEntry>> listFavoritedMusingsForToday() async {
    final entries = await listFavoritedMusings();
    final todayKey = _todayKey();
    return entries.where((e) => e.dateKey == todayKey).toList();
  }

  // ---------------- 长期记忆（关于用户是谁） ----------------

  /// prefs 的键沿用 `memory_facts`（扁平版留下的名字），**故意不改**：
  /// 改了等于让已有数据和备份文件里的那一段变成孤儿，而且备份白名单
  /// （backup_service 的 _allowedKeys）也得跟着改。键是数据契约，
  /// 类型改名不该波及它。
  static const _kMemoryTopicsKey = 'memory_facts';

  /// 每一类的话题上限。
  ///
  /// 比扁平版的 8 少，是因为话题装得下更多东西：一个话题挂十几条细节，
  /// 不再需要靠条数堆。四类 × 5 条摘要 ≈ 20 行常驻，实际用到的通常只有八九个。
  static const kMaxTopicsPerCategory = 5;

  /// 一个话题底下的细节上限。
  ///
  /// 细节不常驻（要 open_memory 才取），所以可以宽松些；但也不能没有边——
  /// 一个话题攒到几十条，取出来的那一坨自己就成了新的上下文负担。
  static const kMaxDetailsPerTopic = 12;

  /// 全部话题。**顺序必须是稳定的**，不能按「最近更新」排。
  ///
  /// 摘要那一层拼进 system 前缀，靠逐字节不变吃 KV 缓存。要是按更新时间倒序，
  /// 改动任何一条都会把整段重排，等于每次写记忆都把后面几千 token 的历史
  /// 挤出缓存——那正是 b715c47 当初把 memoryContext 挪到消息尾部要避开的事。
  ///
  /// 所以固定用「分类顺序 + 创建时间升序」：新加的只会**追加在本类末尾**，
  /// 前面那些逐字节不动。
  static Future<List<MemoryTopic>> listMemoryTopics() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kMemoryTopicsKey);
    if (raw == null) return [];
    final list =
        (jsonDecode(raw) as List)
            .map((e) => MemoryTopic.fromJson(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) {
      final byCategory = a.category.index.compareTo(b.category.index);
      if (byCategory != 0) return byCategory;
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  static Future<List<MemoryTopic>> listMemoryTopicsIn(
    MemoryCategory category,
  ) async {
    final all = await listMemoryTopics();
    return all.where((t) => t.category == category).toList();
  }

  static Future<void> _saveMemoryTopics(List<MemoryTopic> topics) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kMemoryTopicsKey,
      jsonEncode(topics.map((t) => t.toJson()).toList()),
    );
  }

  static Future<void> addMemoryTopic(MemoryTopic topic) async {
    final topics = await listMemoryTopics();
    topics.add(topic);
    await _saveMemoryTopics(topics);
  }

  /// 按 id 替换。找不到就什么都不做——**不要顺手插入一条新的**：
  /// 调用方以为自己在改，结果多出一条，比失败更难查。
  static Future<bool> updateMemoryTopic(MemoryTopic topic) async {
    final topics = await listMemoryTopics();
    final i = topics.indexWhere((t) => t.id == topic.id);
    if (i < 0) return false;
    topics[i] = topic;
    await _saveMemoryTopics(topics);
    return true;
  }

  static Future<bool> removeMemoryTopic(String id) async {
    final topics = await listMemoryTopics();
    final before = topics.length;
    topics.removeWhere((t) => t.id == id);
    if (topics.length == before) return false;
    await _saveMemoryTopics(topics);
    return true;
  }

  // ---------------- 信 ----------------
  static const _kLettersKey = 'letters';
  static const _kLastLetterAttemptKey = 'last_letter_attempt_at';
  static const _kLastFavoritePickKey = 'last_favorite_pick_at';

  /// AI 上一次自己挑收藏是什么时候——用来算冷却
  static Future<DateTime?> getLastFavoritePick() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastFavoritePickKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<void> setLastFavoritePick(DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastFavoritePickKey, t.toIso8601String());
  }

  /// 按时间倒序（最新的在最前）。
  static Future<List<Letter>> listLetters() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLettersKey);
    if (raw == null) return [];
    final list =
        (jsonDecode(raw) as List)
            .map((e) => Letter.fromJson(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static Future<void> _writeLetters(List<Letter> letters) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kLettersKey,
      jsonEncode(letters.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> addLetter(Letter letter) async {
    final letters = await listLetters();
    letters.add(letter);
    await _writeLetters(letters);
  }

  static Future<void> deleteLetter(String id) async {
    final letters = await listLetters();
    letters.removeWhere((e) => e.id == id);
    await _writeLetters(letters);
  }

  static Future<void> markLetterRead(String id) async {
    final letters = await listLetters();
    final idx = letters.indexWhere((e) => e.id == id);
    if (idx < 0 || letters[idx].read) return;
    letters[idx] = letters[idx].copyWith(read: true);
    await _writeLetters(letters);
  }

  /// 未读的 AI 来信数量（给栖息页卡片和底部角标用）。
  static Future<int> unreadLetterCount() async {
    final letters = await listLetters();
    return letters.where((e) => e.isFromAi && !e.read).length;
  }

  /// 上次**尝试**写信的时间——包括 AI 判断「这次没什么可写」而跳过的那次。
  ///
  /// 记「尝试」而不是「发出」是有意的：跳过时如果不记，素材会一直堆在那儿，
  /// 之后每次进栖息页都会重新触发一遍，白白烧 token。
  static Future<DateTime?> getLastLetterAttempt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastLetterAttemptKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> setLastLetterAttempt(DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastLetterAttemptKey, t.toIso8601String());
  }

  /// 书架的只读视图，给写信时统计素材用。
  ///
  /// 写入归 bookshelf_screen 管，这里只读，所以键名在两处各写了一遍。
  static Future<List<Book>> listBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bookshelf_books');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Book.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
