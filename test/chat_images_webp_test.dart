import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/chat_images.dart';

/// 发图前转 WebP 只是为了省地方。这几条钉住：**转不好就用原图**，
/// 绝不能因为转码把图发不出去，或者越转越大。
void main() {
  final original = Uint8List.fromList(List.generate(1000, (i) => i % 256));

  test('转出来更小：用 WebP', () async {
    final out = await ChatImages.toWebp(
      original,
      encoder: (_) async => Uint8List(300),
    );
    expect(out.length, 300);
  });

  test('转出来反而更大：用原图', () async {
    final out = await ChatImages.toWebp(
      original,
      encoder: (_) async => Uint8List(2000),
    );
    expect(out, same(original));
  });

  test('转出来是空的：用原图', () async {
    final out = await ChatImages.toWebp(
      original,
      encoder: (_) async => Uint8List(0),
    );
    expect(out, same(original));
  });

  test('插件返回 null：用原图', () async {
    final out = await ChatImages.toWebp(original, encoder: (_) async => null);
    expect(out, same(original));
  });

  test('转码抛异常：用原图，不往外抛', () async {
    final out = await ChatImages.toWebp(
      original,
      encoder: (_) async => throw StateError('原生那边不支持'),
    );
    expect(out, same(original));
  });
}
