import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'ai_client.dart' show mimeOfImage;

class VisionService {
  static const _keyStorage = 'mimo_api_key';
  static const _endpoint = 'https://api.xiaomimimo.com/v1/chat/completions';
  static const _model = 'mimo-v2.5';
  static final _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<void> saveKey(String key) async =>
      await _secure.write(key: _keyStorage, value: key);

  static Future<String?> getKey() async => await _secure.read(key: _keyStorage);

  /// Analyze an image (base64 or URL). Returns a text description.
  static Future<String?> analyze(String imageBase64, {String? prompt}) async {
    final key = await getKey();
    if (key == null) return null;
    final userPrompt = prompt ?? '请详细描述这张图片的内容';

    try {
      final resp = await http.post(
        Uri.parse(_endpoint),
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': userPrompt},
                {
                  'type': 'image_url',
                  // 按真实格式报。原来写死 jpeg：发 png 时就是错的，
                  // 聊天图片改存 WebP 以后每张都会报错格式。
                  'image_url': {
                    'url':
                        'data:${mimeOfImage(imageBase64)};base64,$imageBase64',
                  },
                },
              ],
            },
          ],
        }),
      );
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body);
      return data['choices']?[0]?['message']?['content'] as String?;
    } catch (_) {
      return null;
    }
  }
}
