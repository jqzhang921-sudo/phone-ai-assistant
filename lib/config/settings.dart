import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 语音来源：系统（免费，离线）或 ElevenLabs（云端，音质好，按量计费）
enum TtsProvider { system, elevenlabs }

/// 读日历的授权策略。
///
/// Android 自己的 READ_CALENDAR 是一次性授权，给了之后系统不再过问。
/// 但日历内容会随工具返回值发给模型——那是会离开这台手机的数据，
/// 值得在系统权限之上再有一层用户自己说了算的开关。
enum CalendarAccess {
  /// 每次读之前问一句（默认）
  ask,

  /// 一直允许，不再打扰
  always,

  /// 不允许，工具直接拒绝
  never,
}

class AppSettings {
  static const _themeKey = 'theme_mode';
  static const _ttsEnabledKey = 'tts_enabled';
  static const _autoTtsKey = 'auto_tts';
  static const _webSocketPortKey = 'websocket_port';
  static const _serverEnabledKey = 'server_enabled';
  static const _ttsProviderKey = 'tts_provider';
  static const _userNameKey = 'user_name';
  static const _aiNameKey = 'ai_name';
  static const _ttsAutoPlayKey = 'tts_auto_play';
  static const _titleSerifKey = 'title_serif';
  static const _aiSelfFavoriteKey = 'ai_self_favorite';
  static const _calendarAccessKey = 'calendar_access';
  static const _personaKey = 'global_persona';
  static const _personaEnabledKey = 'global_persona_enabled';

  // ElevenLabs — key stored in secure storage
  static const _elevenLabsKeyKey = 'elevenlabs_api_key';
  static const _elevenLabsVoiceKey = 'elevenlabs_voice_id';
  static const defaultElevenLabsVoice = '21m00Tcm4TlvDq8ikWAM';

  static final _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  bool ttsEnabled;
  bool autoTts;
  int webSocketPort;
  /// 手机自己开一个 MCP 服务端等外面连进来。
  ///
  /// **默认关。** 它绑的是 anyIPv4，同一个局域网里任何设备都能连上，
  /// 而且没有任何认证——连上就能调用全部手机工具（拍照、定位、读文件、
  /// 读日历）。在公共 WiFi 下这是实打实的暴露面。
  ///
  /// 注意：`McpServer` 身兼两职，工具**注册表**和这个监听是分开的——
  /// 关掉监听不影响聊天里的工具，那些走的是 `registeredTools`。
  ///
  /// 真要从电脑连手机时再去设置里打开，到那时应该先给它加 token。
  bool serverEnabled;
  ThemeMode themeMode;
  TtsProvider ttsProvider;
  String elevenLabsApiKey;
  String elevenLabsVoiceId;
  String userName;

  /// AI 的名字。用在信的落款上，也会告诉它自己叫什么。空着就不落款。
  String aiName;
  bool ttsAutoPlay;
  bool titleSerif; // true=衬线体(宋体)，false=黑体

  /// 让 AI 自己也收藏。默认关——这是它替用户做决定，得先点头。
  bool aiSelfFavorite;

  /// 读日历的授权策略。默认「每次问」——日历数据会离开手机，
  /// 保守的默认值比省事重要。
  CalendarAccess calendarAccess;

  /// 全局的「TA 的性格」。**只有 [personaEnabled] 打开时才生效。**
  ///
  /// 优先级：某段对话自己的设定 > 这里 > 代码里的 basePersona。
  /// 对话自己的永远赢——用户在那段对话里明确改过，不该被一个全局开关推翻。
  String persona;

  /// 默认关。开着才用 [persona]。
  ///
  /// 分成「文本」和「开关」两个字段，而不是「空字符串等于关」：这样关掉之后
  /// 写过的东西还在，想再打开不用重写一遍。关一个开关和删一段字，
  /// 是两件不同的事。
  bool personaEnabled;

  AppSettings({
    this.ttsEnabled = true,
    this.autoTts = false,
    this.webSocketPort = 8765,
    this.serverEnabled = false,
    this.themeMode = ThemeMode.system,
    this.ttsProvider = TtsProvider.system,
    this.elevenLabsApiKey = '',
    this.elevenLabsVoiceId = defaultElevenLabsVoice,
    this.userName = '',
    this.aiName = '',
    this.ttsAutoPlay = false,
    this.titleSerif = true,
    this.aiSelfFavorite = false,
    this.calendarAccess = CalendarAccess.ask,
    this.persona = '',
    this.personaEnabled = false,
  });

  /// 性格描述的字数上限，手写和导入文件同一个数。
  ///
  /// 成本只跟**字数**走，跟来源没关系，所以两套限制只会让人困惑。
  ///
  /// 2000 汉字大约 1500~2000 token。它进的是 system 前缀，支持 prompt
  /// caching 的端点多数轮次命中，实际形状是「每次会话第一条付一次全价」，
  /// 不是每条都付。再往上（比如塞进整份文档）除了贵，还会**稀释**——
  /// 人设太长模型抓不住重点。
  static const int maxPersonaChars = 2000;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();

    // ElevenLabs key: try secure storage first, then migrate from plain text
    String elevenLabsKey =
        await _secureStorage.read(key: _elevenLabsKeyKey) ?? '';
    if (elevenLabsKey.isEmpty) {
      final oldValue = prefs.getString(_elevenLabsKeyKey);
      if (oldValue != null && oldValue.isNotEmpty) {
        try {
          await _secureStorage.write(key: _elevenLabsKeyKey, value: oldValue);
          await prefs.remove(_elevenLabsKeyKey);
          elevenLabsKey = oldValue;
          debugPrint('[secure] Migrated ElevenLabs key');
        } catch (e) {
          elevenLabsKey = oldValue; // fallback
          debugPrint('[secure] ElevenLabs migration failed: $e');
        }
      }
    }

    return AppSettings(
      ttsEnabled: prefs.getBool(_ttsEnabledKey) ?? true,
      autoTts: prefs.getBool(_autoTtsKey) ?? false,
      webSocketPort: prefs.getInt(_webSocketPortKey) ?? 8765,
      serverEnabled: prefs.getBool(_serverEnabledKey) ?? false,
      themeMode: ThemeMode.values[prefs.getInt(_themeKey) ?? 0],
      ttsProvider: TtsProvider.values[prefs.getInt(_ttsProviderKey) ?? 0],
      elevenLabsApiKey: elevenLabsKey,
      elevenLabsVoiceId:
          prefs.getString(_elevenLabsVoiceKey) ?? defaultElevenLabsVoice,
      userName: prefs.getString(_userNameKey) ?? '',
      aiName: prefs.getString(_aiNameKey) ?? '',
      ttsAutoPlay: prefs.getBool(_ttsAutoPlayKey) ?? false,
      titleSerif: prefs.getBool(_titleSerifKey) ?? true,
      aiSelfFavorite: prefs.getBool(_aiSelfFavoriteKey) ?? false,
      persona: prefs.getString(_personaKey) ?? '',
      personaEnabled: prefs.getBool(_personaEnabledKey) ?? false,
      calendarAccess: CalendarAccess.values.firstWhere(
        (v) => v.name == prefs.getString(_calendarAccessKey),
        orElse: () => CalendarAccess.ask,
      ),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ttsEnabledKey, ttsEnabled);
    await prefs.setBool(_autoTtsKey, autoTts);
    await prefs.setInt(_webSocketPortKey, webSocketPort);
    await prefs.setBool(_serverEnabledKey, serverEnabled);
    await prefs.setInt(_themeKey, themeMode.index);
    await prefs.setInt(_ttsProviderKey, ttsProvider.index);

    // Sensitive → secure storage
    await _secureStorage.write(key: _elevenLabsKeyKey, value: elevenLabsApiKey);
    // Clean up plain-text copy
    await prefs.remove(_elevenLabsKeyKey);

    await prefs.setString(_elevenLabsVoiceKey, elevenLabsVoiceId);
    await prefs.setString(_userNameKey, userName);
    await prefs.setString(_personaKey, persona);
    await prefs.setBool(_personaEnabledKey, personaEnabled);
    await prefs.setString(_aiNameKey, aiName);
    await prefs.setBool(_ttsAutoPlayKey, ttsAutoPlay);
    await prefs.setBool(_titleSerifKey, titleSerif);
    await prefs.setBool(_aiSelfFavoriteKey, aiSelfFavorite);
    await prefs.setString(_calendarAccessKey, calendarAccess.name);
  }
}
