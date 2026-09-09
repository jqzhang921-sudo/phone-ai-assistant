import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 开聊之前先把这本书查一下。
///
/// ## 为什么需要这个
///
/// 2026-09-07，用户拿《金枝玉叶》（余耕）来聊，AI 没读过——这没错，也照实
/// 说了。但接下来整场讨论它只能空着手提问，**体验塌了一半**。
///
/// 它有 `web_search`，也真去搜了，query 是对的（「余耕 金枝玉叶 小说」），
/// 搜索还返回了 `success: true`。可拿回来的是：
///
/// ```
/// 余（汉语文字）_百度百科      ← 讲甲骨文的
/// 余 - PRTS 明日方舟中文Wiki
/// 余 - 萌娘百科
/// ```
///
/// 复现之后确认：**国内直连时 www.bing.com 会重定向到 cn.bing.com，而国内版
/// Bing 把「余耕」拆成了「余」**，后面「金枝玉叶」整个丢掉。换语序、加书名号、
/// 加「豆瓣」都没用——只会从「余」变成成语和 1994 年那部电影。同一条查询走
/// 国际版 Bing 则 8/8 全对。所以这不是工具坏了，是**通用搜索在国内这条路上
/// 查不了书**。
///
/// ## 为什么用微信读书，而不是修搜索
///
/// 它是**书库**，不是搜索引擎：给一个书名，回来的是结构化的书名/作者/出版社/
/// 简介，不会混进同名的成语、电影、人名。国内直连通，不用登录，不用 key。
///
/// 而且这个仓库本来就接着微信读书（划线导入），多用一个接口不多一份依赖。
///
/// ## 为什么是自动查，不是给它一把工具
///
/// **模型不知道自己不知道。** 对《金枝玉叶》这种书名是常见词的作品，它心里
/// 有个模糊印象，就不会触发搜索，直接顺着聊——那正是体验塌掉的样子。
///
/// 靠「该查的时候会去查」和靠「没读过就说没读过」是同一种指望，都靠不住。
/// 所以进聊天页就查，一次，不问它的意见。
///
/// ## 2026-09-09：加上热门划线
///
/// 简介只有一百来字，而且是**营销文案**——「一部横跨三十年的家族史诗」这种
/// 话，模型拿到手里跟没拿一样：说不出人名，也不知道书是什么调子。
///
/// 同一个域名下 `/web/book/bestbookmarks` 是公开的（实测 200，不用登录不用
/// key），回来的是**全网读者划得最多的十句原文**，外加每句所在的章节名。
/// 五本书实测全部命中，十句合计五六百字。
///
/// 它补的正是简介缺的那半边：
/// - 简介是**别人的概括**，划线是**原文**——语言什么样，一眼就看出来
/// - 十个章节名连起来就是骨架（「六、谁是反革命」「二十二、文革来了」）
/// - 顺带告诉它**大家在意的是哪几段**，提起来不会挑到边角料
///
/// ⚠️ 但它同时把「装读过」的门槛拉低了：手里有了十句真原文，编第十一句
/// 就顺理成章。所以 [BookFacts.asPromptBlock] 里那条「你手上只有这几句」
/// 必须跟着写死，不能省。
class HotMark {
  /// 原文。
  final String text;

  /// 这句在哪一章。拿不到就是 null——章节名是附赠的，不该因为它缺了就丢掉原句。
  final String? chapter;

  const HotMark(this.text, {this.chapter});
}

class BookFacts {
  final String title;
  final String? author;
  final String? publisher;
  final String? intro;

  /// 微信读书那边的 id。查热门划线要用它，所以必须留住。
  final String? bookId;

  /// 全网读者划得最多的几句原文。查不到就是空表。
  final List<HotMark> hotMarks;

  /// 是不是**确认过**同一本。
  ///
  /// 用户报了作者、并且和查到的对得上，才算确认。他只说了个书名时查到的
  /// 那一本只是「最可能」——同名的书海了去了，所以要让 AI 先问一句。
  final bool confirmed;

  const BookFacts({
    required this.title,
    this.author,
    this.publisher,
    this.intro,
    this.bookId,
    this.hotMarks = const [],
    required this.confirmed,
  });

  /// 划线是第二次请求才回来的，所以要能往一份已有的资料上补。
  BookFacts withHotMarks(List<HotMark> marks) => BookFacts(
    title: title,
    author: author,
    publisher: publisher,
    intro: intro,
    bookId: bookId,
    hotMarks: marks,
    confirmed: confirmed,
  );

  /// 拼成塞进 system prompt 的那一段。
  ///
  /// 四条框死的话都在这儿，一条都不能少：
  /// - **这不是你读过它**——否则它会拿着一段简介开始装读过，比不知道更糟
  /// - **原文只有这几句**——有了真原句之后，这条比原来更要紧
  /// - **对不上以用户为准**——查错书的时候，用户才是唯一的事实来源
  /// - 没确认的要先问一句——问一句的成本，远小于聊错一本书
  String asPromptBlock() {
    final b = StringBuffer();
    b.writeln('---');
    b.writeln('下面是从微信读书查到的这本书的资料，供你参考：');
    b.writeln('书名：《$title》');
    if (author != null && author!.isNotEmpty) b.writeln('作者：$author');
    if (publisher != null && publisher!.isNotEmpty) {
      b.writeln('出版：$publisher');
    }
    if (intro != null && intro!.isNotEmpty) b.writeln('简介：$intro');

    if (hotMarks.isNotEmpty) {
      b.writeln();
      b.writeln('这本书在微信读书里被读者划得最多的几句原文（括号里是所在章节）：');
      for (final m in hotMarks) {
        final where =
            (m.chapter == null || m.chapter!.isEmpty) ? '' : '（${m.chapter}）';
        b.writeln('- $where${m.text}');
      }
      b.writeln();
      b.writeln(
        '这几句是**原文**，不是简介——可以直接引，可以顺着某一句的语气去谈'
        '这本书写得怎么样。章节名连起来也能让你知道这书大致怎么走。',
      );
      b.writeln(
        '**但你手上的原文就只有这几句。** 别的句子、它们的上下文、这些话是谁'
        '在什么情境下说的，你都不知道。**不许再写出第二批「原文」**，'
        '也不许把某一句的前因后果讲成你读过的样子。',
      );
    }

    b.writeln();
    b.writeln(
      '**这段资料不等于你读过这本书。** 它只有梗概和零星几句，没有细节、'
      '没有整本书的语言、没有那些只有读过才知道的地方。用户问你读没读过，'
      '照实说没读过。'
      '你可以用它来提起某个具体的人或事，让提问落到实处，'
      '但不要拿它去复述情节、不要装作熟悉。',
    );
    b.writeln(
      '**尤其不要编人物的动机和因果。** 资料和用户没说过的事——某个人为什么'
      '那么做、他当时在想什么、那个时代逼了他什么——你都不知道。'
      '想说这类话就必须先说明白这是你的猜测，并且请他纠正；'
      '不能用陈述句讲出来。'
      '**把一句话的信息展开成一整套解读，是这件事里最容易犯、也最伤人的错**：'
      '他会以为你读过，然后带着一个不存在的版本去理解自己刚读完的书。',
    );
    b.writeln(
      '如果资料和用户说的对不上，**一律以用户为准**——同名的书和影视很多，'
      '查错的可能一直在。',
    );
    if (!confirmed) {
      b.writeln(
        '用户没有说作者，所以这一本未必是他读的那本。'
        '开口前先用一句话确认（比如「我查到的是$author那本，是这本吗」），'
        '别默认就是它。',
      );
    }
    b.writeln('---');
    return b.toString();
  }
}

class BookLookup {
  /// 一次拿几句热门划线。
  ///
  /// 十句约五六百字（≈400 token）。实测 `count=30` 也给，但再多就开始收
  /// 边角料——按划的人数排序，第二十句往后已经掉到个位数，噪音比信息多。
  static const _kHotMarkCount = 10;

  /// 单句上限。极少数划线是整段，塞进提示词会把别的挤掉。
  static const _kHotMarkMaxChars = 120;

  /// 微信读书的公开搜索。不用登录，也不用 key。
  static Uri _searchUri(String keyword) => Uri.parse(
    'https://weread.qq.com/web/search/global'
    '?keyword=${Uri.encodeQueryComponent(keyword)}'
    '&maxIdx=0&fragmentSize=120&count=5',
  );

  /// 热门划线。同样公开，同样不用登录。
  static Uri _hotMarkUri(String bookId) => Uri.parse(
    'https://weread.qq.com/web/book/bestbookmarks'
    '?bookId=${Uri.encodeQueryComponent(bookId)}&count=$_kHotMarkCount',
  );

  static const _kHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
  };

  /// 查一本。查不到、超时、网络不通，一律返回 null——**绝不能挡住开聊**。
  static Future<BookFacts?> fetch({
    required String title,
    String? author,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final keyword = title.trim();
    if (keyword.isEmpty) return null;
    BookFacts? facts;
    try {
      final resp = await http
          .get(_searchUri(keyword), headers: _kHeaders)
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is! Map) return null;
      facts = pick(data['books'], title: title, author: author);
    } catch (e) {
      // 查不到就当没查过。用户要的是聊天，不是等一个转圈。
      debugPrint('[book_lookup] 查《$title》失败：$e');
      return null;
    }
    if (facts == null) return null;

    // 划线是**锦上添花**：拿不到就把书目资料照常给出去，绝不能因为第二次
    // 请求失败连第一次的结果也丢掉。超时给得比搜索短——它排在开聊前面。
    final marks = await _fetchHotMarks(facts.bookId);
    return marks.isEmpty ? facts : facts.withHotMarks(marks);
  }

  static Future<List<HotMark>> _fetchHotMarks(
    String? bookId, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (bookId == null || bookId.isEmpty) return const [];
    try {
      final resp = await http
          .get(_hotMarkUri(bookId), headers: _kHeaders)
          .timeout(timeout);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is! Map) return const [];
      return pickHotMarks(data['bestBookMarks']);
    } catch (e) {
      debugPrint('[book_lookup] 热门划线 $bookId 拿不到：$e');
      return const [];
    }
  }

  /// 从搜索结果里挑出对的那一本。**挑错书比查不到更糟**，所以宁可返回 null。
  ///
  /// 单独拆出来是为了能不联网测——匹配规则才是这里唯一会出错的地方。
  @visibleForTesting
  static BookFacts? pick(
    dynamic books, {
    required String title,
    String? author,
  }) {
    if (books is! List) return null;

    final wantTitle = _norm(title);
    if (wantTitle.isEmpty) return null;
    final wantAuthor = _norm(author ?? '');

    final sameTitle = <Map>[];
    for (final entry in books) {
      if (entry is! Map) continue;
      final info = entry['bookInfo'];
      if (info is! Map) continue;
      if (_norm(info['title']?.toString() ?? '') != wantTitle) continue;
      sameTitle.add(info);
    }
    if (sameTitle.isEmpty) return null;

    if (wantAuthor.isNotEmpty) {
      for (final info in sameTitle) {
        final got = _norm(info['author']?.toString() ?? '');
        // 双向包含：用户写「余耕」，书库写「余耕 著」，或者反过来。
        if (got.isEmpty) continue;
        if (got == wantAuthor ||
            got.contains(wantAuthor) ||
            wantAuthor.contains(got)) {
          return _facts(info, confirmed: true);
        }
      }
      // 书名对上了、作者对不上——**多半是同名的另一本**。宁可什么都不给。
      return null;
    }

    // 用户只说了书名：取搜索结果第一条，但标成未确认，让 AI 先问一句。
    return _facts(sameTitle.first, confirmed: false);
  }

  /// 把热门划线拆出来，顺带把 chapterUid 换成章节名。
  ///
  /// 章节名单独放在 `chapters` 数组里，每条划线只带一个 uid——不映射的话
  /// 提示词里就是一串「（47）」，那还不如不写。实测十条全部能对上。
  @visibleForTesting
  static List<HotMark> pickHotMarks(dynamic bestBookMarks) {
    if (bestBookMarks is! Map) return const [];

    final titles = <int, String>{};
    final chapters = bestBookMarks['chapters'];
    if (chapters is List) {
      for (final c in chapters) {
        if (c is! Map) continue;
        final uid = c['chapterUid'];
        final t = c['title']?.toString().trim() ?? '';
        if (uid is int && t.isNotEmpty) titles[uid] = t;
      }
    }

    final items = bestBookMarks['items'];
    if (items is! List) return const [];

    final out = <HotMark>[];
    final seen = <String>{};
    for (final it in items) {
      if (it is! Map) continue;
      var text = it['markText']?.toString() ?? '';
      // 划线常带原书的排版空白和换行，压掉——它是要拼进提示词的。
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      // 同一句被不同人划成不同长度是常事，去重看压缩后的全文。
      if (!seen.add(text)) continue;
      if (text.length > _kHotMarkMaxChars) {
        text = '${text.substring(0, _kHotMarkMaxChars)}…';
      }
      final uid = it['chapterUid'];
      out.add(HotMark(text, chapter: uid is int ? titles[uid] : null));
      if (out.length >= _kHotMarkCount) break;
    }
    return out;
  }

  static BookFacts _facts(Map info, {required bool confirmed}) => BookFacts(
    title: info['title']?.toString() ?? '',
    author: _clean(info['author']),
    publisher: _clean(info['publisher']),
    intro: _clean(info['intro']),
    bookId: _clean(info['bookId']),
    confirmed: confirmed,
  );

  static String? _clean(dynamic v) {
    final s = v?.toString().trim() ?? '';
    if (s.isEmpty) return null;
    // 简介里偶尔带整段排版空白，压掉——它是要拼进提示词的。
    return s.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// 比书名时把书名号、引号、空格都去掉：用户打的是「金枝玉叶」，
  /// 书库里可能是「金枝玉叶（精装）」——那个括号后缀不去，留着比对前缀。
  static String _norm(String s) =>
      s.replaceAll(RegExp(r'[《》「」『』""“”\s]'), '').trim().toLowerCase();
}
