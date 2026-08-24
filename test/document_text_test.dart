import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/document_text.dart';

/// 造一个最小的 .docx：一个 zip，里面就 word/document.xml 一份。
Uint8List _docx(String documentXml) {
  final archive = Archive();
  final bytes = utf8.encode(documentXml);
  archive.addFile(ArchiveFile('word/document.xml', bytes.length, bytes));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _plain(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  group('纯文本', () {
    test('.md 和 .txt 原样读出来', () {
      const text = '# 性格\n说话短一点，别每句都追问。';
      expect(DocumentText.extract(name: 'a.md', bytes: _plain(text)), text);
      expect(DocumentText.extract(name: 'a.txt', bytes: _plain(text)), text);
    });

    test('认不出的后缀也按纯文本试一把', () {
      // 用户把 .txt 改成了别的名字，不该被拒之门外
      expect(
        DocumentText.extract(name: 'persona.bak', bytes: _plain('喜欢猫')),
        '喜欢猫',
      );
    });

    test('坏字节不该让整份文档读不出来', () {
      final broken = Uint8List.fromList([...utf8.encode('好'), 0xFF, 0xFE]);
      // 不抛异常，坏的地方变成替换字符，用户自己看得见
      expect(DocumentText.extract(name: 'a.txt', bytes: broken), contains('好'));
    });
  });

  group('.docx', () {
    test('段落变成换行，而不是连成一坨', () {
      final bytes = _docx(
        '<w:document><w:body>'
        '<w:p><w:r><w:t>性格：安静</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>说话方式：短</w:t></w:r></w:p>'
        '</w:body></w:document>',
      );
      expect(
        DocumentText.extract(name: 'a.docx', bytes: bytes),
        '性格：安静\n说话方式：短',
      );
    });

    test('同一段里的多个 run 不该被拆开', () {
      // Word 会因为一个字变色就把一句话切成好几个 <w:r>，
      // 这些必须接回一句，不能一段一行
      final bytes = _docx(
        '<w:document><w:body><w:p>'
        '<w:r><w:t>不要</w:t></w:r>'
        '<w:r><w:t>每句都</w:t></w:r>'
        '<w:r><w:t>追问</w:t></w:r>'
        '</w:p></w:body></w:document>',
      );
      expect(DocumentText.extract(name: 'a.docx', bytes: bytes), '不要每句都追问');
    });

    test('XML 实体要还原，&amp; 最后换', () {
      final bytes = _docx(
        '<w:document><w:body><w:p><w:r>'
        '<w:t>喜欢 &lt;猫&gt; &amp; 狗</w:t>'
        '</w:r></w:p></w:body></w:document>',
      );
      expect(DocumentText.extract(name: 'a.docx', bytes: bytes), '喜欢 <猫> & 狗');
    });

    test('域代码和修订删除的内容不该漏进正文', () {
      final bytes = _docx(
        '<w:document><w:body><w:p>'
        '<w:r><w:t>看这个</w:t></w:r>'
        '<w:r><w:instrText> HYPERLINK "http://x.com" </w:instrText></w:r>'
        '<w:r><w:delText>这句被删掉了</w:delText></w:r>'
        '<w:r><w:t>链接</w:t></w:r>'
        '</w:p></w:body></w:document>',
      );
      final out = DocumentText.extract(name: 'a.docx', bytes: bytes);
      expect(out, '看这个链接');
      expect(out.contains('HYPERLINK'), isFalse);
      expect(out.contains('被删掉了'), isFalse);
    });

    test('<w:br/> 变换行，<w:tab/> 变制表符', () {
      final bytes = _docx(
        '<w:document><w:body><w:p><w:r>'
        '<w:t>上</w:t><w:br/><w:t>下</w:t><w:tab/><w:t>右</w:t>'
        '</w:r></w:p></w:body></w:document>',
      );
      expect(DocumentText.extract(name: 'a.docx', bytes: bytes), '上\n下\t右');
    });

    test('连续空段落压成一个空行，不留一大片白', () {
      final bytes = _docx(
        '<w:document><w:body>'
        '<w:p><w:r><w:t>头</w:t></w:r></w:p>'
        '<w:p></w:p><w:p></w:p><w:p></w:p><w:p></w:p>'
        '<w:p><w:r><w:t>尾</w:t></w:r></w:p>'
        '</w:body></w:document>',
      );
      expect(DocumentText.extract(name: 'a.docx', bytes: bytes), '头\n\n尾');
    });

    test('不是 docx 结构就明确报错，不返回一坨乱码', () {
      final archive = Archive();
      final junk = utf8.encode('nothing here');
      archive.addFile(ArchiveFile('readme.txt', junk.length, junk));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      expect(
        () => DocumentText.extract(name: 'a.docx', bytes: bytes),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
