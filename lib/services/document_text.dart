import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 从文件里把**纯文字**抠出来。
///
/// 只做一件事：拿到文字，交给调用方填进输入框。**不存文件，也不存路径。**
///
/// 为什么导入是「填进框」而不是「挂一个文件」：
///
/// - 抠出来什么，用户当场看得见、能改。.docx 的抠取天生是近似的
///   （表格、页眉、修订痕迹都可能漏进来或漏掉），能改就不致命。
/// - 只有一条存储路径。挂文件的话，用户哪天删了那个文件，人设就空了，
///   而且他不会知道是为什么。
/// - 「文件」和「手写」于是不是两种模式，只是同一个框的两种填法——
///   字数上限、实时计数、保存逻辑全都只有一套。
///
/// 格式和成本的关系：**抠出来的文字一样，用量就一样。** 字体、表格、样式
/// 在这一步就没了，进模型的只有纯文字。格式只决定「能不能读出来」。
class DocumentText {
  /// 认得的后缀。给 file_picker 的白名单用。
  ///
  /// 不收 .pdf：带排版的 PDF 抠出来经常是碎的（断行、分栏错位），
  /// 而且要另一套解析。宁可不支持，也不要给一段自己都读不顺的文字。
  static const extensions = ['md', 'txt', 'docx'];

  /// 按后缀挑解析方式。认不出来就当纯文本试一把——
  /// 用户改了后缀名的 .txt 不该被拒之门外。
  static String extract({required String name, required Uint8List bytes}) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.docx')) return _fromDocx(bytes);
    return _fromPlainText(bytes);
  }

  /// 纯文本。用 allowMalformed：一个坏字节不该让整份文档读不出来，
  /// 坏的地方变成 � 用户自己看得见。
  static String _fromPlainText(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true).trim();

  /// .docx = 一个 zip，正文在 `word/document.xml`。
  ///
  /// 用剥标签而不是正则抓 `<w:t>`：`</w:p>`（段落结束）在 w:t 之外，
  /// 只抓 w:t 会把所有段落连成一坨。先把段落和换行标记换成 \n，
  /// 再把剩下的标签整个剥掉，段落结构才留得住。
  static String _fromDocx(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.files.where((f) => f.name == 'word/document.xml');
    if (entry.isEmpty) {
      throw const FormatException('这个 .docx 里没有找到正文（word/document.xml）');
    }
    var xml = utf8.decode(
      entry.first.content as List<int>,
      allowMalformed: true,
    );

    // 先干掉不该出现在正文里的两类：域代码（HYPERLINK 之类）和修订删除的内容。
    // 不先剥掉，它们会跟着正文一起流进去，读起来像乱码。
    xml = xml
        .replaceAll(RegExp(r'<w:instrText[^>]*>.*?</w:instrText>', dotAll: true), '')
        .replaceAll(RegExp(r'<w:delText[^>]*>.*?</w:delText>', dotAll: true), '');

    final text = xml
        .replaceAll(RegExp(r'<w:br\s*/>'), '\n')
        .replaceAll(RegExp(r'<w:tab\s*/>'), '\t')
        .replaceAll('</w:p>', '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '');

    return _unescape(text).replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// XML 实体。`&amp;` 必须**最后**换——先换它的话，
  /// 文档里字面写的 `&amp;lt;` 会被两步连着解成 `<`。
  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#160;', ' ')
      .replaceAll('&amp;', '&');
}
