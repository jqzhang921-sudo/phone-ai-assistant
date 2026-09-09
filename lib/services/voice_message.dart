import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../config/settings.dart';

/// 它主动发出来的一条语音。
///
/// ## 跟点喇叭朗读有什么不同
///
/// [TtsService] 是**按需朗读**：文字已经在气泡里了，你点一下才念。念完就完，
/// 音频只在内存里缓存，重启就没。
///
/// 语音消息是另一回事——**它自己决定用说的**。这条消息本来就是语音，文字
/// 是它的附属（长按才看）。所以：
///
/// - 音频必须**落盘**，重启之后还在
/// - 必须有**时长**，不然语音条上没数字，看着像个坏了的控件
/// - 合成失败要能**退回文字**，不能让这条消息整个消失
class VoiceMessage {
  /// mp3 在哪（应用私有目录里的绝对路径）
  final String path;

  /// 多少秒。拿不到就是 null，界面显示成 `--`。
  final int? seconds;

  const VoiceMessage({required this.path, this.seconds});

  Map<String, dynamic> toJson() => {
    'path': path,
    if (seconds != null) 'seconds': seconds,
  };

  static VoiceMessage? fromMetadata(Map<String, dynamic>? metadata) {
    final v = metadata?['voice'];
    if (v is! Map) return null;
    final path = v['path'];
    if (path is! String || path.isEmpty) return null;
    final sec = v['seconds'];
    return VoiceMessage(path: path, seconds: sec is int ? sec : null);
  }
}

/// 合成失败时抛这个，调用方把它当成「这条就用文字发」来处理。
class VoiceSynthException implements Exception {
  final String message;
  const VoiceSynthException(this.message);
  @override
  String toString() => message;
}

class VoiceMessageService {
  static const _uuid = Uuid();

  /// 语音文件放哪。跟聊天记录同级，不进缓存目录——**缓存目录系统会清**，
  /// 而一条语音消息清掉之后，那条聊天就永远读不出来了。
  static Future<Directory> dir() async {
    final app = await getApplicationDocumentsDirectory();
    final d = Directory('${app.path}/voice_messages');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 合成一条语音并存盘。
  ///
  /// 只走 ElevenLabs：系统 TTS 没有「导出成文件」这条路，它是直接朗读的。
  /// 所以没配 key 的时候，这个功能整个不可用——由调用方退回文字。
  static Future<VoiceMessage> synthesize(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const VoiceSynthException('没有可以合成的内容');
    }

    final settings = await AppSettings.load();
    final key = settings.elevenLabsApiKey.trim();
    if (key.isEmpty) {
      throw const VoiceSynthException('还没填 ElevenLabs API Key');
    }
    final voiceId =
        settings.elevenLabsVoiceId.trim().isEmpty
            ? AppSettings.defaultElevenLabsVoice
            : settings.elevenLabsVoiceId.trim();

    final resp = await http.post(
      Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$voiceId'),
      headers: {
        'xi-api-key': key,
        'Content-Type': 'application/json',
        'Accept': 'audio/mpeg',
      },
      body: jsonEncode({
        'text': trimmed,
        'model_id': 'eleven_multilingual_v2',
        'voice_settings': {'stability': 0.5, 'similarity_boost': 0.75},
      }),
    );
    if (resp.statusCode != 200) {
      throw VoiceSynthException('ElevenLabs 失败 ${resp.statusCode}');
    }

    final file = File('${(await dir()).path}/${_uuid.v4()}.mp3');
    await file.writeAsBytes(resp.bodyBytes);

    return VoiceMessage(path: file.path, seconds: await _durationOf(file.path));
  }

  /// 读时长。
  ///
  /// audioplayers 要先把源装载进去才知道多长，所以这里开一个临时的 player、
  /// 量完就扔。拿不到就返回 null——**没有时长不该让整条语音发不出去**。
  static Future<int?> _durationOf(String path) async {
    final player = AudioPlayer();
    try {
      await player.setSourceDeviceFile(path);
      final d = await player.getDuration();
      if (d == null) return null;
      // 不足一秒的也显示 1"，显示 0" 看着像坏了
      return d.inSeconds < 1 ? 1 : d.inSeconds;
    } catch (e) {
      debugPrint('[voice] 读时长失败：$e');
      return null;
    } finally {
      await player.dispose();
    }
  }

  /// 删掉一条语音的音频文件。聊天记录被删时调用，别在私有目录里堆垃圾。
  static Future<void> remove(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[voice] 删除失败：$e');
    }
  }
}
