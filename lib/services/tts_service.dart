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

  /// ElevenLabs 合成音频缓存：`消息id|音色` -> mp3 字节。
  ///
  /// ## 为什么要封顶
  ///
  /// 原来是个只进不出的 Map。ElevenLabs 回来的是一整段 mp3，一条十几秒的
  /// 回复就有几百 KB；读上一百条就是几十 MB 钉死在内存里——而它们**再也
  /// 不会被播第二遍**，用户早翻过去了。这不是缓慢泄漏，是跟着朗读条数
  /// 线性往上涨，正是「用久了内存变得非常大」里最直白的一处。
  ///
  /// 封顶之后超出就按插入顺序丢最旧的。丢掉的代价只是「再点一次要重新
  /// 合成、多花一次钱」，功能一点不少。
  static const int _audioCacheMaxBytes = 8 * 1024 * 1024;

  final Map<String, Uint8List> _audioCache = {};
  int _audioCacheBytes = 0;

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

  /// 放进缓存，并把总量压回上限以内。
  void _cacheAudio(String key, Uint8List bytes) {
    // 单条就超过上限的（超长回复）：存了也是白占，还会把前面的一并挤掉，
    // 所以直接不存。不这么写的话，下面那个 while 会清空整个缓存、
    // 最后只留下它自己。
    if (bytes.length > _audioCacheMaxBytes) return;

    final old = _audioCache.remove(key);
    if (old != null) _audioCacheBytes -= old.length;

    _audioCache[key] = bytes;
    _audioCacheBytes += bytes.length;

    // 按插入顺序淘汰，最早放进来的是最不可能再听的。
    while (_audioCacheBytes > _audioCacheMaxBytes && _audioCache.isNotEmpty) {
      final oldest = _audioCache.keys.first;
      _audioCacheBytes -= _audioCache.remove(oldest)!.length;
    }
  }

  Future<void> _speakElevenLabs(
    String messageId,
    String text,
    AppSettings settings,
  ) async {
    final apiKey = settings.elevenLabsApiKey.trim();
    if (apiKey.isEmpty) {
      throw TtsException('还没填 ElevenLabs API Key（设置 → 语音来源）');
    }
    final voiceId =
        settings.elevenLabsVoiceId.trim().isEmpty
            ? AppSettings.defaultElevenLabsVoice
            : settings.elevenLabsVoiceId.trim();
    // 缓存键含音色：换了音色，同一条消息会重新合成（用新音色）
    final cacheKey = '$messageId|$voiceId';

    // 命中缓存：直接播，不再调 API（不重复扣费）
    final cached = _audioCache.remove(cacheKey);
    if (cached != null) {
      // 放回队尾。拿出又放回不改总量，但这条从此算「最近用过的」，
      // 淘汰时不会轮到它——否则反复听同一条，它反而可能被挤掉。
      _audioCache[cacheKey] = cached;
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
          'ElevenLabs 失败 ${resp.statusCode}：${_shortBody(resp.body)}',
        );
      }
      final bytes = resp.bodyBytes;
      _cacheAudio(cacheKey, bytes);
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

  /// 朗读前清洗：只去掉圆括号（及其内容），如 （旁白）（动作）。
  /// 其他括号（【】[]「」《》等）照常朗读。循环直到干净以处理嵌套。
  static final List<RegExp> _bracketPatterns = [
    RegExp(r'（[^（）]*）'), // 中文圆括号
    RegExp(r'\([^()]*\)'), // 英文圆括号
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
