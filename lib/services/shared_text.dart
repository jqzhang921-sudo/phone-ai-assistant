import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 别的 App 分享过来的一段文字，拆成「哪本书」和「哪段话」。
///
/// ## 这是干什么用的
///
/// 有人问能不能从番茄免费小说导入。番茄没有对外接口，硬要导就只能逆向它的
/// 私有协议——那种东西在他们下次发版时就会坏。
///
/// 所以走系统分享：番茄（以及起点、知乎、浏览器、备忘录……）分享一段文字，
/// 系统面板里选「读书讨论」，文字就到这儿了。**接的是安卓的动作，不是某个
/// App 的接口**，所以谁改版都不影响。
class SharedReading {
  /// 认出来的书名。认不出来就是 null——不瞎猜，界面会问。
  final String? bookTitle;

  /// 正文。分享一本书的时候通常是空的（推广语和链接都被剥掉了）。
  final String body;

  const SharedReading({this.bookTitle, required this.body});

  /// 正文够长才算「摘了一段」，否则只是「指了一本书」。
  ///
  /// 分享一本书剥完推广语基本什么都不剩；分享一段原文至少是个句子。
  /// 12 个字是拍的，但两边差得远，不是在切一条细线。
  bool get isExcerpt => body.runes.length >= 12;

  /// 什么都没解析出来——比如分享过来的只有一条链接。
  bool get isEmpty => bookTitle == null && body.isEmpty;

  /// 链接。整条剥掉，不留。
  static final _url = RegExp(r'https?://\S+');

  /// 《书名》
  static final _titleMark = RegExp(r'《([^《》]{1,60})》');

  /// 推广语。分享出来的文字里总带着这些，留着会被当成正文存进收藏。
  static final _promo = RegExp(
    r'(快来|一起看|推荐给你|点击链接|复制.{0,6}(打开|链接)|下载.{0,6}(APP|app|客户端)'
    r'|分享自|来自\s*@|扫码|免费(阅读|观看)|更多精彩)',
  );

  /// 「我在番茄免费小说看《XXX》」这类开场白。
  static final _iAmReading = RegExp(r'^我(正)?在.{0,14}(看|读|阅读)');

  /// 「——《书名》 作者」这类出处行。给书名，但不是正文。
  static final _attribution = RegExp(r'^\s*[—–\-]{1,3}\s*\S');

  /// 「来自番茄小说」「摘自微信读书」这类落款。
  ///
  /// 跟 [_promo] 分开是因为判据不同：这些词本身可能出现在正文里
  /// （「我摘自哪本书都记得」），所以还要**这一行短**才算落款。
  /// 只靠关键词会误杀正文。
  static final _sourceTail = RegExp(
    r'^\s*(来自|摘自|出自|选自)?\s*[「『《]?'
    r'(番茄|微信读书|起点|掌阅|QQ ?阅读|豆瓣|得到|樊登)',
  );

  /// 正文两头的引号。选中一段带引号复制出来很常见。
  static final _wrapQuotes = RegExp(r'^[「『“"‘’]+|[」』”"‘’]+$');

  static SharedReading parse(String raw) {
    String? title;
    final kept = <String>[];

    for (var line in raw.split('\n')) {
      line = line.replaceAll(_url, ' ').trim();
      if (line.isEmpty) continue;

      // 书名认第一个就够。后面再出现的多半是推广语里重复的那次。
      final m = _titleMark.firstMatch(line);
      title ??= m?.group(1)?.trim();

      // 出处行只取书名，本身不算正文
      if (_attribution.hasMatch(line)) continue;
      if (_promo.hasMatch(line)) continue;
      if (_iAmReading.hasMatch(line)) continue;
      // 落款：短，且以某个阅读 App 的名字开头
      if (line.runes.length <= 20 && _sourceTail.hasMatch(line)) continue;

      // 整行就是个《书名》，那它是指路不是正文
      if (m != null && line.replaceAll(_titleMark, '').trim().length < 4) {
        continue;
      }

      kept.add(line);
    }

    var body = kept.join('\n').trim().replaceAll(_wrapQuotes, '').trim();

    // 只留下一小截、又没认出书名——那这一小截本身就是书名。
    // 比如有人直接在备忘录里选中「活着」分享过来。
    if (title == null && body.isNotEmpty && body.runes.length < 12) {
      title = body;
      body = '';
    }

    return SharedReading(
      bookTitle: (title != null && title.isNotEmpty) ? title : null,
      body: body,
    );
  }
}

/// 取分享过来的文字。原生那边存着，这边来取（取走即清）。
///
/// 冷启动的时候 intent 早就到了，而 Dart 刚起来还没人接，所以不能只靠推送。
/// 见 `ShareIntentChannel.kt` 里的说明。
class SharedTextChannel {
  static const _channel = MethodChannel('share_intent');

  /// 取一次待处理的分享；没有就返回 null。
  static Future<SharedReading?> take() async {
    try {
      final text = await _channel.invokeMethod<String>('take');
      if (text == null || text.trim().isEmpty) return null;
      final parsed = SharedReading.parse(text);
      return parsed.isEmpty ? null : parsed;
    } catch (e) {
      // 主 App 上根本没挂这个通道，静默即可，别打扰。
      debugPrint('[share] 取分享内容失败：$e');
      return null;
    }
  }

  /// 把一段文字发到系统分享面板。
  ///
  /// 导出讨论用的。不自己写文件——写进 Download 要过 MediaStore 和权限那一套，
  /// 而分享面板本来就通向所有地方（微信、便签、网盘），还不用要任何权限。
  ///
  /// 返回是否真的发出去了；失败由调用方决定怎么兜（一般退回复制）。
  static Future<bool> sendOut(String text, {String? subject}) async {
    if (text.trim().isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('send', {
        'text': text,
        if (subject != null) 'subject': subject,
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('[share] 发起分享失败：$e');
      return false;
    }
  }

  /// App 已经开着的时候又分享进来一条。
  static void listen(void Function(SharedReading) onShare) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onShare') return null;
      final text = call.arguments as String?;
      if (text == null || text.trim().isEmpty) return null;
      final parsed = SharedReading.parse(text);
      if (!parsed.isEmpty) onShare(parsed);
      return null;
    });
  }
}
