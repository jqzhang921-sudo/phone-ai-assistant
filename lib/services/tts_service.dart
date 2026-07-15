import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import '../config/settings.dart';

/// 统一的文字转语音服务。背后可切换「系统(免费)」或「ElevenLabs(云端)」。
///
/// 只在用户点击时才合成/播放（on-demand），ElevenLabs 合成结果按消息 id 缓存，
/// 同一条再次点击不会重复调用 API（不重复扣费）。
class TtsService extends ChangeNotifier {
  final FlutterTts _flutterTts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();

  /// 正在播放的消息 id（null 表示没有在播）
  String? _playingId;

  /// 正在合成中的消息 id（ElevenLabs 网络请求期间）
  String? _loadingId;

  /// ElevenLabs 合成音频缓存：消息 id -> mp3 字节
  final Map<String, Uint8List> _audioCache = {};

  TtsService() {
    _init();
  }

  String? get playingId => _playingId;
  String? get loadingId => _loadingId;
  bool isPlaying(String messageId) => _playingId == messageId;
  bool isLoading(String messageId) => _loadingId == messageId;

  Future<void> _init() async {
    await _flutterTts.setLanguage('zh-CN');
    // 系统 TTS 播完/取消/出错时清掉播放状态
    _flutterTts.setCompletionHandler(_clearPlaying);
    _flutterTts.setCancelHandler(_clearPlaying);
    _flutterTts.setErrorHandler((_) => _clearPlaying());
    // ElevenLabs 音频播完时清掉播放状态
    _audioPlayer.onPlayerComplete.listen((_) => _clearPlaying());
  }

  void _clearPlaying() {
    if (_playingId != null) {
      _playingId = null;
      notifyListeners();
    }
  }

  /// 点击喇叭：正在放这条 -> 停；否则按当前设置的来源合成并播放。
  /// 出错时抛 [TtsException]，调用方负责提示用户。
  Future<void> toggle(String messageId, String text) async {
    if (_playingId == messageId) {
      await stop();
      return;
    }
    await stop(); // 停掉其它正在播的
    final clean = _cleanForTts(text);
    if (clean.isEmpty) return;

    final settings = await AppSettings.load(); // 每次读最新设置，来源随时可切
    if (settings.ttsProvider == TtsProvider.system) {
      await _speakSystem(messageId, clean);
    } else {
      await _speakElevenLabs(messageId, clean, settings);
    }
  }

  Future<void> stop() async {
    await _flutterTts.stop();
    await _audioPlayer.stop();
    _clearPlaying();
  }

  Future<void> _speakSystem(String messageId, String text) async {
    _playingId = messageId;
    notifyListeners();
    await _flutterTts.setLanguage('zh-CN');
    await _flutterTts.speak(text);
    // 播完由 completionHandler 清状态
  }

  Future<void> _speakElevenLabs(
      String messageId, String text, AppSettings settings) async {
    final apiKey = settings.elevenLabsApiKey.trim();
    if (apiKey.isEmpty) {
      throw TtsException('还没填 ElevenLabs API Key（设置 → 语音来源）');
    }
    final voiceId = settings.elevenLabsVoiceId.trim().isEmpty
        ? AppSettings.defaultElevenLabsVoice
        : settings.elevenLabsVoiceId.trim();
    // 缓存键含音色：换了音色，同一条消息会重新合成（用新音色）
    final cacheKey = '$messageId|$voiceId';

    // 命中缓存：直接播，不再调 API（不重复扣费）
    final cached = _audioCache[cacheKey];
    if (cached != null) {
      _playingId = messageId;
      notifyListeners();
      await _audioPlayer.play(BytesSource(cached, mimeType: 'audio/mpeg'));
      return;
    }

    _loadingId = messageId;
    notifyListeners();
    try {
      final resp = await http.post(
        Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$voiceId'),
        headers: {
          'xi-api-key': apiKey,
          'Content-Type': 'application/json',
          'Accept': 'audio/mpeg',
        },
        body: jsonEncode({
          'text': text,
          'model_id': 'eleven_multilingual_v2',
          'voice_settings': {'stability': 0.5, 'similarity_boost': 0.75},
        }),
      );
      if (resp.statusCode != 200) {
        throw TtsException(
            'ElevenLabs 失败 ${resp.statusCode}：${_shortBody(resp.body)}');
      }
      final bytes = resp.bodyBytes;
      _audioCache[cacheKey] = bytes;
      _loadingId = null;
      _playingId = messageId;
      notifyListeners();
      await _audioPlayer.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
    } finally {
      if (_loadingId == messageId) {
        _loadingId = null;
        notifyListeners();
      }
    }
  }

  String _shortBody(String body) =>
      body.length > 200 ? '${body.substring(0, 200)}…' : body;

  /// 朗读前清洗：去掉括号（及其内容），跳过旁白/动作/注释/链接。
  /// 覆盖 （） () 【】 [] 「」 《》 等，循环直到干净以处理嵌套。
  static final List<RegExp> _bracketPatterns = [
    RegExp(r'（[^（）]*）'),   // 中文圆括号
    RegExp(r'\([^()]*\)'),      // 英文圆括号
    RegExp(r'【[^【】]*】'),     // 中文方括号
    RegExp(r'\[[^\[\]]*\]'),    // 英文方括号
    RegExp(r'「[^「」]*」'),     // 日文引号
    RegExp(r'《[^《》]*》'),     // 书名号
    RegExp(r'〈[^〈〉]*〉'),     // 尖书名号
    RegExp(r'｛[^｛｝]*｝'),     // 全角大括号
    RegExp(r'\*[^*]+\*'),       // markdown *斜体*
    RegExp(r'~~[^~]+~~'),        // markdown ~~删除线~~
  ];

  String _cleanForTts(String text) {
    var t = text;
    // 循环直到不再变化，处理嵌套括号
    var changed = true;
    while (changed) {
      changed = false;
      for (final pattern in _bracketPatterns) {
        final before = t;
        t = t.replaceAll(pattern, '');
        if (t != before) changed = true;
      }
    }
    // 最后折叠多余空格和换行
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    return t.trim();
  }

  @override
  void dispose() {
    _flutterTts.stop();
    _audioPlayer.dispose();
    super.dispose();
  }
}

class TtsException implements Exception {
  final String message;
  TtsException(this.message);
  @override
  String toString() => message;
}
