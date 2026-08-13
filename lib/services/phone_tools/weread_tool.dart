import '../../models/book.dart';
import '../../models/mcp_tool.dart';
import '../storage_service.dart';
import '../weread_service.dart';

/// 划线内容一次最多回多少字符。
///
/// 一本书的划线可能有几百条，原样送回去会把上下文顶满，真正有用的部分反而
/// 被埋掉——搜索工具那边已经踩过一次这个坑。超了就截断并说明还剩多少。
const _kMaxHighlightChars = 3000;

/// 列出「可以查划线」的书。
///
/// 刻意**不**逐本去问接口有没有划线：书架四十本就是四十次网络请求，工具调用
/// 60 秒就超时了，而且每次 AI 好奇一下都要把用户的微信读书接口刷一遍。
/// 这里只回本地书架里关联了微信读书的书，具体有没有划线，等 AI 真去取的时候
/// 自然会知道。
class ListHighlightedBooksTool {
  static McpTool get definition => McpTool(
        name: 'list_highlighted_books',
        description:
            '列出用户书架上可以查到微信读书划线笔记的书（书名、作者、在读还是已读）。'
            '不是每次聊天都要调用——只有当话题真的落到读书上时才用：'
            '用户提起某本书、聊到最近在读什么、想讨论书里的内容、'
            '或者你需要知道 TA 划过哪些句子的时候。'
            '日常闲聊、问天气、聊别的事情，都不需要调这个。'
            '拿到列表后如果要看具体划了什么，再用 get_book_highlights。',
        inputSchema: {
          'type': 'object',
          'properties': {},
        },
        category: '阅读工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      final key = await WereadService.getKey();
      if (key == null || key.isEmpty) {
        return {
          'success': false,
          'error': '用户还没有在设置里填微信读书 API Key，查不了划线。',
        };
      }

      final books = await StorageService.listBooks();
      final linked = books.where(
        (b) => b.wereadBookId != null && b.wereadBookId!.isNotEmpty,
      );

      if (linked.isEmpty) {
        return {
          'success': true,
          'books': <Map<String, dynamic>>[],
          'message': '书架上还没有从微信读书导入的书，所以查不到划线。',
        };
      }

      return {
        'success': true,
        'books': linked
            .map((b) => {
                  'title': b.title,
                  if (b.author != null && b.author!.isNotEmpty)
                    'author': b.author,
                  'status': b.status.label,
                })
            .toList(),
        'note': '这些书都能查划线，但不保证每本都真的划过。'
            '要看具体内容用 get_book_highlights，传书名即可。',
      };
    } catch (e) {
      return {'success': false, 'error': '读取书架失败：$e'};
    }
  }
}

/// 取某一本书的划线内容。
class GetBookHighlightsTool {
  static McpTool get definition => McpTool(
        name: 'get_book_highlights',
        description:
            '取用户在某本书里划过的句子和笔记（来自微信读书）。'
            '只在话题确实和这本书有关时才调用——用户提起书名、'
            '想聊书里的内容、或者你想引用 TA 划过的原句的时候。'
            '不要为了「了解用户」就把书一本本翻一遍，那是打扰。'
            '书名从 list_highlighted_books 拿，或者直接用用户提到的书名。',
        inputSchema: {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': '书名，必填。不用带书名号，写《白夜行》或白夜行都行；'
                  '记不全时写其中一段也可以，会做模糊匹配。',
              'minLength': 1,
            },
          },
          'required': ['title'],
        },
        category: '阅读工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      // 不用 `as String?`：模型偶尔会把参数塞成别的类型，硬转会抛。
      final rawTitle = (args['title']?.toString() ?? '').trim();
      if (rawTitle.isEmpty) {
        return {
          'success': false,
          'error': 'title 参数为空。请重新调用 get_book_highlights 并给出书名，'
              '例如 {"title": "白夜行"}。',
        };
      }

      final key = await WereadService.getKey();
      if (key == null || key.isEmpty) {
        return {
          'success': false,
          'error': '用户还没有在设置里填微信读书 API Key，查不了划线。',
        };
      }

      final books = await StorageService.listBooks();
      final book = _findBook(books, rawTitle);
      if (book == null) {
        return {
          'success': false,
          'error': '书架上没找到和「$rawTitle」对得上的书。'
              '可以先用 list_highlighted_books 看看有哪些。',
        };
      }
      if (book.wereadBookId == null || book.wereadBookId!.isEmpty) {
        return {
          'success': false,
          'error': '《${book.title}》不是从微信读书导入的，没有划线可查。',
        };
      }

      final raw = await WereadService.fetchHighlights(book.wereadBookId!);
      if (raw == null || raw.trim().isEmpty) {
        return {
          'success': true,
          'title': book.title,
          'highlights': '',
          'message': '《${book.title}》在微信读书里没有划线记录。',
        };
      }

      final text = raw.trim();
      final truncated = text.length > _kMaxHighlightChars;
      return {
        'success': true,
        'title': book.title,
        if (book.author != null && book.author!.isNotEmpty)
          'author': book.author,
        'highlights': truncated
            ? '${text.substring(0, _kMaxHighlightChars)}…'
            : text,
        if (truncated)
          'note': '划线太多，只回了前 $_kMaxHighlightChars 字，'
              '后面还有约 ${text.length - _kMaxHighlightChars} 字没取。',
      };
    } catch (e) {
      return {'success': false, 'error': '取划线失败：$e'};
    }
  }

  /// 先精确匹配，再模糊。
  ///
  /// 模型给过来的书名什么样都有：《白夜行》、白夜行、甚至带上作者。
  /// 所以先剥掉书名号和空格比一次，不中再看谁包含谁。
  static Book? _findBook(List<Book> books, String query) {
    final q = _normalize(query);
    if (q.isEmpty) return null;

    for (final b in books) {
      if (_normalize(b.title) == q) return b;
    }
    for (final b in books) {
      final t = _normalize(b.title);
      if (t.contains(q) || q.contains(t)) return b;
    }
    return null;
  }

  static String _normalize(String s) => s
      .replaceAll(RegExp(r'[《》〈〉<>「」【】\s]'), '')
      .toLowerCase();
}
