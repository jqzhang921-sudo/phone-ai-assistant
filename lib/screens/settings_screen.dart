import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../services/backup_service.dart';
import '../config/api_keys.dart';
import '../config/settings.dart';
import '../config/build_info.dart';
import '../services/ai_client.dart';
import '../services/external_mcp_service.dart';
import '../services/phone_tools/search_tool.dart';
import '../services/tts_service.dart';
import '../services/vision_service.dart';
import '../services/weread_service.dart';
import 'tools_screen.dart';
import 'musing_corner_screen.dart';
import '../widgets/background_sheet.dart';
import '../services/storage_service.dart';
import '../config/app_shape.dart';
import '../services/app_providers.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<ApiKeyConfig> _configs = [];
  AppSettings _settings = AppSettings();
  bool _loading = true;
  String? _selectedProvider;
  final _keyController = TextEditingController();
  final _endpointController = TextEditingController();
  final _modelController = TextEditingController();
  final _elevenKeyController = TextEditingController();
  final _elevenVoiceController = TextEditingController();
  final _tavilyKeyController = TextEditingController();
  final _visionKeyController = TextEditingController();
  bool _visionSectionExpanded = false;
  final _wereadKeyController = TextEditingController();
  final _userNameController = TextEditingController();
  final _aiNameController = TextEditingController();

  // 密钥默认打码，点小眼睛才明文——设置页经常被截图/投屏。
  bool _showApiKey = false;
  bool _showElevenKey = false;
  bool _showTavilyKey = false;
  bool _showWereadKey = false;

  bool _backupBusy = false;

  /// 「收藏的话」右侧那个计数，异步取一次
  int? _favoriteCount;

  /// 「聊天背景」右侧显示的当前档位
  String _backgroundLabel = '';

  Future<void> _exportBackup() async {
    setState(() => _backupBusy = true);
    try {
      final file = await BackupService.exportToFile();
      final size = (await file.length() / 1024).toStringAsFixed(0);
      await Share.shareXFiles([
        XFile(file.path),
      ], text: '手机 AI 助手数据备份（${size}KB，不含密钥）');
    } catch (e) {
      if (mounted) _snack('导出失败：$e');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importBackup() async {
    final picked = await FilePicker.platform.pickFiles(withData: false);
    final path = picked?.files.single.path;
    if (path == null) return;

    if (!mounted) return;
    final replace = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('怎么导入？'),
            content: const Text(
              '合并：只补进本机没有的内容，现有的一律不动（推荐）。\n\n'
              '覆盖：同一条内容以备份里的为准，本机改动会被冲掉。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('覆盖'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('合并'),
              ),
            ],
          ),
    );
    if (replace == null) return;

    setState(() => _backupBusy = true);
    try {
      final raw = await File(path).readAsString();
      final summary = await BackupService.importBackup(
        jsonDecode(raw) as Map<String, dynamic>,
        replace: replace,
      );
      if (mounted) {
        _snack(
          '导入完成：对话 ${summary.conversations}、'
          '讨论 ${summary.bookConversations}、'
          '日记 ${summary.diaryEntries}、一隅 ${summary.musings}、'
          '书 ${summary.books}、信 ${summary.letters}。'
          '封面图和密钥需要重新加。',
        );
      }
    } on FormatException catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
    );
  }

  /// 密钥输入框右侧的「显示/隐藏」按钮。
  Widget _revealButton(bool visible, VoidCallback onToggle) {
    return IconButton(
      icon: Icon(
        visible ? PhosphorIconsRegular.eyeSlash : PhosphorIconsRegular.eye,
      ),
      tooltip: visible ? '隐藏' : '显示',
      onPressed: onToggle,
    );
  }

  // External MCP server state
  List<ExternalMcpServer> _externalServers = [];
  bool _showAddMcp = false;
  final _mcpNameController = TextEditingController();
  final _mcpUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _loadFavoriteCount();
    _loadBackgroundLabel();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _endpointController.dispose();
    _modelController.dispose();
    _elevenKeyController.dispose();
    _elevenVoiceController.dispose();
    _tavilyKeyController.dispose();
    _visionKeyController.dispose();
    _wereadKeyController.dispose();
    _userNameController.dispose();
    _aiNameController.dispose();
    _mcpNameController.dispose();
    _mcpUrlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _configs = await ApiKeyService.loadKeys();
    _settings = await AppSettings.load();
    _elevenKeyController.text = _settings.elevenLabsApiKey;
    _elevenVoiceController.text = _settings.elevenLabsVoiceId;
    _tavilyKeyController.text = await SearchTool.getStoredKey() ?? '';
    _visionKeyController.text = await VisionService.getKey() ?? '';
    _wereadKeyController.text = await WereadService.getKey() ?? '';
    _userNameController.text = _settings.userName;
    _aiNameController.text = _settings.aiName;
    _externalServers = await ExternalMcpServerService.load();

    // 只在首次打开时自动选中一个配置（避免每次保存后被跳走）
    if (_selectedProvider == null && _configs.isNotEmpty) {
      final missingKey =
          _configs
              .where((c) => c.apiKey == null || c.apiKey!.isEmpty)
              .firstOrNull;
      _selectConfig(missingKey ?? _configs.first);
    }

    setState(() => _loading = false);
  }

  void _selectConfig(ApiKeyConfig config) {
    _selectedProvider = config.provider;
    _keyController.text = config.apiKey ?? '';
    _endpointController.text = config.endpoint ?? '';
    _modelController.text = config.model ?? '';
    setState(() {});
  }

  Future<void> _saveCurrent() async {
    if (_selectedProvider == null) return;
    final config = ApiKeyConfig(
      provider: _selectedProvider!,
      name: _configs.firstWhere((c) => c.provider == _selectedProvider!).name,
      apiKey: _keyController.text.trim(),
      endpoint: _endpointController.text.trim(),
      model: _modelController.text.trim(),
    );
    await ApiKeyService.saveKey(config);
    await _load();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );

      // Update AI client in provider
      if (_keyController.text.trim().isNotEmpty) {
        final aiClient = AiClient(config: config);
        context.read<AiClientProvider>().setClient(aiClient);
      }
    }
  }

  Future<void> _pasteInto(TextEditingController c) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim();
    if (t != null && t.isNotEmpty) {
      c.text = t;
      setState(() {});
    }
  }

  Future<void> _saveTts() async {
    _settings.elevenLabsApiKey = _elevenKeyController.text.trim();
    _settings.elevenLabsVoiceId = _elevenVoiceController.text.trim();
    await _settings.save();
  }

  Future<void> _saveSettings() async {
    await _settings.save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          _group(theme, '我们', [
            _row(
              theme,
              asset: 'paw',
              title: '我',
              value: _settings.userName.isEmpty ? '未设置' : _settings.userName,
              primary: true,
              onTap:
                  () => _editName(
                    title: '你叫什么',
                    hint: '首页问候语怎么称呼你（留空则不带名字）',
                    controller: _userNameController,
                    apply: (v) => _settings.userName = v,
                  ),
            ),
            _row(
              theme,
              asset: 'cat',
              title: '你',
              value: _settings.aiName.isEmpty ? '未设置' : _settings.aiName,
              primary: true,
              onTap:
                  () => _editName(
                    title: 'TA 叫什么',
                    hint: '留空则信里不落款',
                    controller: _aiNameController,
                    apply: (v) => _settings.aiName = v,
                  ),
            ),
            _switchRow(
              theme,
              icon: PhosphorIconsRegular.textAa,
              title: '标题用宋体',
              subtitle: '关掉是黑体',
              value: _settings.titleSerif,
              onChanged: (v) {
                setState(() => _settings.titleSerif = v);
                context.read<SettingsProvider>().setTitleSerif(v);
              },
            ),
          ]),

          _group(theme, '模型与密钥', [
            _row(
              theme,
              icon: PhosphorIconsRegular.key,
              title: '对话模型',
              value: _modelSummary,
              primary: true,
              onTap: () => _openDetail('对话模型', _secModel),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.speakerHigh,
              title: '语音朗读',
              value:
                  _settings.ttsProvider == TtsProvider.elevenlabs
                      ? 'ElevenLabs'
                      : '系统',
              onTap: () => _openDetail('语音朗读', _secTts),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.eye,
              title: '视觉识图 · 联网搜索',
              value: _visionSearchSummary,
              onTap:
                  () => _openDetail(
                    '视觉识图 · 联网搜索',
                    (t, set) => [
                      ..._secVision(t, set),
                      const SizedBox(height: 24),
                      ..._secTavily(t, set),
                    ],
                  ),
            ),
          ]),

          _group(theme, '外观与陪伴', [
            _row(
              theme,
              asset: 'waves',
              title: '聊天背景',
              value: _backgroundLabel,
              primary: true,
              onTap: () async {
                await showBackgroundSheet(context);
                await _loadBackgroundLabel();
              },
            ),
            _row(
              theme,
              asset: 'flower',
              title: '收藏的话',
              value: _favoriteCount == null ? '' : '$_favoriteCount 条',
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MusingCornerScreen()),
                );
                _loadFavoriteCount();
              },
            ),
            _switchRow(
              theme,
              asset: 'flower',
              // 名字跟着设置走。写死一个名字的话，用户在上面「你」那一栏
              // 改了称呼，这个开关的标题还停在旧名字上。
              title:
                  _settings.aiName.trim().isEmpty
                      ? '让 TA 自己收藏'
                      : '让${_settings.aiName.trim()}自己收藏',
              subtitle: '它回看对话时，挑一两句留下',
              value: _settings.aiSelfFavorite,
              onChanged: (v) async {
                setState(() => _settings.aiSelfFavorite = v);
                await _settings.save();
              },
            ),
            _row(
              theme,
              asset: 'sun',
              title: '深色模式',
              value: _themeModeLabel,
              onTap: _pickThemeMode,
            ),
          ]),

          _group(theme, '手机能力', [
            _row(
              theme,
              icon: PhosphorIconsRegular.wrench,
              title: '已注册的工具',
              subtitle: 'AI 能调用哪些手机能力',
              primary: true,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ToolsScreen()),
                  ),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.wifiHigh,
              title: 'MCP 服务器',
              value:
                  _settings.serverEnabled
                      ? '端口 ${_settings.webSocketPort}'
                      : '已关闭',
              onTap:
                  () => _openDetail(
                    'MCP 服务器',
                    (t, set) => [
                      ..._secMcp(t, set),
                      const SizedBox(height: 24),
                      ..._secMcpExt(t, set),
                    ],
                  ),
            ),
            _row(
              theme,
              asset: 'books',
              title: '微信读书',
              value: _wereadKeyController.text.isEmpty ? '未配置' : '已配置',
              onTap: () => _openDetail('微信读书', _secWeread),
            ),
          ]),

          _group(theme, '数据', [
            _row(
              theme,
              icon: PhosphorIconsRegular.floppyDisk,
              title: '备份与恢复',
              subtitle: '导出 / 导入 json，不含密钥',
              onTap: () => _openDetail('备份与恢复', _secBackup),
            ),
          ]),

          const SizedBox(height: 28),
          Center(
            child: Text(
              '手机 AI 助手 · v1.0.0 · build $buildCommit',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 分组容器与行 ──────────────────────────────────────────────
  //
  // 原来是 11 个平铺的 _sectionHeader 一路铺到底，1000 行直筒清单，
  // 找一个开关得从头滚到尾。现在收成几组：主列表只放「叫什么名字、
  // 用哪个模型、开没开」这种一眼要看的结论，密钥、endpoint、端口这些
  // 填一次就不再动的，全收进二级页。

  /// 组标题在容器外，容器本身是圆角白卡 + 柔光。
  Widget _group(ThemeData theme, String title, List<Widget> rows) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(
          Divider(
            height: 1,
            thickness: 1,
            // 从底座右缘起，不通栏——通栏的线会把一组切成几块
            indent: 56,
            endIndent: 14,
            color: scheme.outlineVariant,
          ),
        );
      }
      children.add(rows[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              boxShadow: AppShadow.soften(dark),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  /// 品牌图标按视觉重量给高度，不要统一成一个数。
  static const Map<String, double> _assetHeight = {
    'cat': 17,
    'books': 15,
    'mountain': 13,
    'flower': 17,
    'waves': 13,
    'star': 16,
    'paw': 14,
    'sun': 15,
  };

  Widget _iconBase(
    ThemeData theme, {
    String? asset,
    IconData? icon,
    required bool primary,
  }) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final fg =
        primary
            ? scheme.primary
            : (dark ? scheme.onSurface : const Color(0xFF463F37));
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            primary
                ? scheme.primary.withValues(alpha: 0.11)
                : scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(11),
      ),
      child:
          asset != null
              ? Image.asset(
                'assets/icons/$asset.png',
                height: _assetHeight[asset] ?? 16,
                color: fg,
              )
              : Icon(icon, size: 17, color: fg),
    );
  }

  Widget _row(
    ThemeData theme, {
    String? asset,
    IconData? icon,
    required String title,
    String? subtitle,
    String? value,
    bool primary = false,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
        child: Row(
          children: [
            _iconBase(theme, asset: asset, icon: icon, primary: primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (value != null && value.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Icon(
              PhosphorIconsRegular.caretRight,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow(
    ThemeData theme, {
    IconData? icon,
    String? asset,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
      child: Row(
        children: [
          _iconBase(theme, asset: asset, icon: icon, primary: false),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// 二级页。内容还是原来那些 widget，只是搬进了自己的一屏。
  ///
  /// `set` 同时刷新二级页和主列表——主列表右侧要显示当前值，
  /// 在二级页里改完退回来必须是新的。
  void _openDetail(
    String title,
    List<Widget> Function(ThemeData, StateSetter) body,
  ) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder:
                (_) => Scaffold(
                  appBar: AppBar(title: Text(title)),
                  body: StatefulBuilder(
                    builder:
                        (ctx, set) => ListView(
                          padding: const EdgeInsets.all(16),
                          children: body(Theme.of(ctx), (fn) {
                            set(fn);
                            if (mounted) setState(() {});
                          }),
                        ),
                  ),
                ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  Future<void> _editName({
    required String title,
    required String hint,
    required TextEditingController controller,
    required void Function(String) apply,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
    );
    if (result == null) return;
    apply(result);
    await _settings.save();
    if (mounted) setState(() {});
  }

  String get _themeModeLabel => switch (_settings.themeMode) {
    ThemeMode.light => '常关',
    ThemeMode.dark => '常开',
    ThemeMode.system => '跟随系统',
  };

  Future<void> _pickThemeMode() async {
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in ThemeMode.values)
                  ListTile(
                    title: Text(switch (m) {
                      ThemeMode.light => '常关',
                      ThemeMode.dark => '常开',
                      ThemeMode.system => '跟随系统',
                    }),
                    trailing:
                        _settings.themeMode == m
                            ? const Icon(PhosphorIconsRegular.check, size: 20)
                            : null,
                    onTap: () => Navigator.of(ctx).pop(m),
                  ),
              ],
            ),
          ),
    );
    if (picked == null) return;
    setState(() => _settings.themeMode = picked);
    await _settings.save();
    if (mounted) context.read<SettingsProvider>().setThemeMode(picked);
  }

  String get _modelSummary {
    final name =
        _modelController.text.isNotEmpty
            ? _modelController.text
            : (_selectedProvider ?? '未选择');
    return _keyController.text.isEmpty ? '$name · 缺密钥' : name;
  }

  String get _visionSearchSummary {
    final vision = _visionKeyController.text.isNotEmpty;
    final search = _tavilyKeyController.text.isNotEmpty;
    if (vision && search) return '都已配置';
    if (search) return '仅联网';
    if (vision) return '仅识图';
    return '未配置';
  }

  Future<void> _loadBackgroundLabel() async {
    final path = await StorageService.getBackgroundImagePath();
    final preset = await StorageService.getBackgroundPreset();
    if (!mounted) return;
    setState(() {
      _backgroundLabel =
          path != null
              ? '自定义图片'
              : switch (preset) {
                'light' => '浅色',
                'dark' => '深色',
                _ => '跟随主题',
              };
    });
  }

  Future<void> _loadFavoriteCount() async {
    final list = await StorageService.listFavoritedMusings();
    if (mounted) setState(() => _favoriteCount = list.length);
  }

  List<Widget> _secModel(ThemeData theme, StateSetter set) {
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children:
            _configs.map((config) {
              final selected = config.provider == _selectedProvider;
              return ChoiceChip(
                label: Text(config.name),
                selected: selected,
                onSelected: (_) => _selectConfig(config),
              );
            }).toList(),
      ),
      const SizedBox(height: 16),

      if (_selectedProvider != null) ...[
        _buildConfigFields(),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _saveCurrent,
          icon: const Icon(PhosphorIconsRegular.floppyDisk),
          label: const Text('保存 API 配置'),
        ),
      ],
    ];
  }

  List<Widget> _secVision(ThemeData theme, StateSetter set) {
    return [
      // 视觉识图（可选）——默认收起，只有当前主模型不支持看图时才需要
      Card(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(PhosphorIconsRegular.eye),
              title: const Text('视觉识图（可选）'),
              subtitle: const Text(
                '如果你的对话模型本身就支持看图（比如 GPT-4o、Claude 等），不用配置这个',
              ),
              trailing: Icon(
                _visionSectionExpanded
                    ? PhosphorIconsRegular.caretUp
                    : PhosphorIconsRegular.caretDown,
              ),
              onTap: () {
                set(() => _visionSectionExpanded = !_visionSectionExpanded);
              },
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState:
                  _visionSectionExpanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '只有当前主模型不认识图片、需要单独一个能看图的模型来帮忙描述时，才需要填这里。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _visionKeyController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '视觉模型 API Key',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await VisionService.saveKey(
                          _visionKeyController.text.trim(),
                        );
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('已保存'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      icon: const Icon(PhosphorIconsRegular.floppyDisk),
                      label: const Text('保存视觉模型 Key'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _secTavily(ThemeData theme, StateSetter set) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: TextField(
          controller: _tavilyKeyController,
          obscureText: !_showTavilyKey,
          decoration: InputDecoration(
            labelText: 'Tavily API Key',
            hintText: 'tavily.com → Dashboard → API Keys',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _revealButton(
                  _showTavilyKey,
                  () => set(() => _showTavilyKey = !_showTavilyKey),
                ),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.floppyDisk),
                  tooltip: '保存',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await SearchTool.saveKey(_tavilyKeyController.text.trim());
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('Tavily Key 已保存'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _secTts(ThemeData theme, StateSetter set) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Text('语音来源'),
            const Spacer(),
            SegmentedButton<TtsProvider>(
              segments: const [
                ButtonSegment(value: TtsProvider.system, label: Text('系统(免费)')),
                ButtonSegment(
                  value: TtsProvider.elevenlabs,
                  label: Text('ElevenLabs'),
                ),
              ],
              selected: {_settings.ttsProvider},
              onSelectionChanged: (s) {
                set(() => _settings.ttsProvider = s.first);
                _settings.save();
              },
            ),
          ],
        ),
      ),
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: const Text('自动朗读 AI 回复'),
        subtitle: const Text('收到回复后自动播放语音'),
        value: _settings.ttsAutoPlay,
        onChanged: (v) {
          set(() => _settings.ttsAutoPlay = v);
          _settings.save();
        },
      ),
      if (_settings.ttsProvider == TtsProvider.elevenlabs) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _elevenKeyController,
            obscureText: !_showElevenKey,
            decoration: InputDecoration(
              labelText: 'ElevenLabs API Key',
              hintText: 'sk_ 开头，创建时仅显示一次，官网复制完整 key（列表里的是 ID 不能用）',
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _revealButton(
                    _showElevenKey,
                    () => set(() => _showElevenKey = !_showElevenKey),
                  ),
                  IconButton(
                    icon: const Icon(PhosphorIconsRegular.clipboardText),
                    tooltip: '从剪贴板粘贴',
                    onPressed: () => _pasteInto(_elevenKeyController),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _elevenVoiceController,
            decoration: InputDecoration(
              labelText: '音色 ID (Voice ID)',
              hintText: '留空用默认 Rachel；elevenlabs.io → Voices 复制 ID',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(PhosphorIconsRegular.clipboardText),
                tooltip: '从剪贴板粘贴',
                onPressed: () => _pasteInto(_elevenVoiceController),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(PhosphorIconsRegular.floppyDisk),
              label: const Text('保存'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await _saveTts();
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('已保存'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
          ),
        ),
      ],
      SwitchListTile(
        title: const Text('自动朗读'),
        subtitle: Text(
          _settings.ttsProvider == TtsProvider.elevenlabs
              ? 'AI 回复后自动朗读（ElevenLabs 会按量扣费）'
              : 'AI 回复后自动朗读',
        ),
        value: _settings.autoTts,
        onChanged: (v) {
          set(() => _settings.autoTts = v);
          _settings.save();
        },
      ),
      ListTile(
        leading: const Icon(PhosphorIconsRegular.playCircle),
        title: const Text('测试语音'),
        subtitle: Text(
          _settings.ttsProvider == TtsProvider.elevenlabs
              ? '用 ElevenLabs 试读一句（会消耗少量额度）'
              : '用系统引擎试读一句（需手机已装 TTS 引擎）',
        ),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          final tts = context.read<TtsService>();
          await _saveTts();
          try {
            await tts.toggle('__tts_test__', '你好，这是语音测试');
          } catch (e) {
            messenger.showSnackBar(SnackBar(content: Text('$e')));
          }
        },
      ),
    ];
  }

  List<Widget> _secWeread(ThemeData theme, StateSetter set) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: TextField(
          controller: _wereadKeyController,
          obscureText: !_showWereadKey,
          decoration: InputDecoration(
            labelText: '微信读书 API Key',
            hintText: 'wrk- 开头；是登录凭证，会过期，失效后重新获取',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _revealButton(
                  _showWereadKey,
                  () => set(() => _showWereadKey = !_showWereadKey),
                ),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.floppyDisk),
                  tooltip: '保存',
                  onPressed: () async {
                    await WereadService.saveKey(
                      _wereadKeyController.text.trim(),
                    );
                    if (mounted) _snack('微信读书 Key 已保存');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _secMcp(ThemeData theme, StateSetter set) {
    return [
      SwitchListTile(
        title: const Text('启用 MCP Server'),
        subtitle: Text('允许其他设备通过端口 ${_settings.webSocketPort} 连接'),
        value: _settings.serverEnabled,
        onChanged: (v) async {
          set(() => _settings.serverEnabled = v);
          final messenger = ScaffoldMessenger.of(context);
          final server = context.read<McpServerProvider>().server;
          if (v) {
            final ok = await server.start(_settings.webSocketPort);
            if (!ok && mounted) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('启动 MCP Server 失败，请检查端口'),
                  backgroundColor: Colors.red,
                ),
              );
              set(() => _settings.serverEnabled = false);
            }
          } else {
            await server.stop();
          }
          await _saveSettings();
        },
      ),
      if (_settings.serverEnabled) ...[
        ListTile(
          leading: const Icon(PhosphorIconsRegular.wifiHigh),
          title: const Text('端口'),
          trailing: SizedBox(
            width: 80,
            child: TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              controller: TextEditingController(
                text: _settings.webSocketPort.toString(),
              ),
              onSubmitted: (v) {
                _settings.webSocketPort = int.tryParse(v) ?? 8765;
                _saveSettings();
              },
            ),
          ),
        ),
      ],
    ];
  }

  List<Widget> _secMcpExt(ThemeData theme, StateSetter set) {
    return [
      Consumer<ExternalMcpProvider>(
        builder: (context, mcpProv, _) {
          if (mcpProv.clients.isNotEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已连接 ${mcpProv.clients.length} 个服务器',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.green,
                  ),
                ),
                const SizedBox(height: 4),
                ...mcpProv.clients.map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(
                          PhosphorIconsRegular.checkCircle,
                          size: 14,
                          color: Colors.green,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${c.config.name} (${c.config.url})',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          '${c.tools.length} 工具',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          }
          return const SizedBox.shrink();
        },
      ),

      // Server list
      ..._externalServers.map(
        (server) => Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            leading: Icon(
              PhosphorIconsRegular.database,
              color: server.enabled ? theme.colorScheme.primary : Colors.grey,
            ),
            title: Text(server.name, style: const TextStyle(fontSize: 14)),
            subtitle: Text(server.url, style: const TextStyle(fontSize: 11)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: server.enabled,
                  onChanged: (v) async {
                    final mcp = context.read<ExternalMcpProvider>();
                    server.enabled = v;
                    await ExternalMcpServerService.save(_externalServers);
                    if (v) {
                      mcp.connectTo(server);
                    } else {
                      mcp.disconnect(server.url);
                    }
                    set(() {});
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.trash, size: 18),
                  onPressed: () async {
                    final mcp = context.read<ExternalMcpProvider>();
                    await ExternalMcpServerService.remove(server.id);
                    mcp.disconnect(server.url);
                    _externalServers = await ExternalMcpServerService.load();
                    set(() {});
                  },
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),

      // Add new server
      if (_showAddMcp)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _mcpNameController,
                  decoration: const InputDecoration(
                    labelText: '服务器名称',
                    hintText: '我的 MCP Server',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _mcpUrlController,
                  decoration: const InputDecoration(
                    labelText: 'WebSocket URL',
                    hintText: 'ws://192.168.1.100:8765',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        _showAddMcp = false;
                        set(() {});
                      },
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(PhosphorIconsRegular.link, size: 16),
                      label: const Text('添加并连接'),
                      onPressed: () async {
                        final name = _mcpNameController.text.trim();
                        final url = _mcpUrlController.text.trim();
                        if (name.isEmpty || url.isEmpty) return;

                        // Show loading
                        final messenger = ScaffoldMessenger.of(context);
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('⏳ 连接中...'),
                            duration: Duration(seconds: 30),
                          ),
                        );

                        final server = ExternalMcpServer(
                          id: const Uuid().v4(),
                          name: name,
                          url: url,
                        );

                        // Try to connect first
                        final provider = context.read<ExternalMcpProvider>();
                        final error = await provider.connectTo(server);

                        if (mounted) {
                          messenger.hideCurrentSnackBar();
                          if (error == null) {
                            // Success: save and clear
                            await ExternalMcpServerService.add(server);
                            _mcpNameController.clear();
                            _mcpUrlController.clear();
                            _showAddMcp = false;
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('✅ 已连接到 $name'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          } else {
                            // Failure: keep form, show error
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('❌ $error'),
                                backgroundColor: Colors.orange,
                                duration: Duration(seconds: 5),
                              ),
                            );
                          }
                        }
                        _externalServers =
                            await ExternalMcpServerService.load();
                        set(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        )
      else
        OutlinedButton.icon(
          onPressed: () {
            _showAddMcp = true;
            set(() {});
          },
          icon: const Icon(PhosphorIconsRegular.plus, size: 16),
          label: const Text('添加 MCP 服务器'),
        ),
    ];
  }

  List<Widget> _secBackup(ThemeData theme, StateSetter set) {
    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(
          '导出对话、讨论、日记、一隅。不含任何 API 密钥，'
          '也不含书籍封面——导入后密钥需要重新填一次。',
          style: TextStyle(fontSize: 12, height: 1.5),
        ),
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: const Icon(PhosphorIconsRegular.export),
        title: const Text('导出备份'),
        subtitle: const Text('生成 json 文件，可发到微信或存网盘'),
        enabled: !_backupBusy,
        onTap: _backupBusy ? null : _exportBackup,
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: const Icon(PhosphorIconsRegular.downloadSimple),
        title: const Text('导入备份'),
        subtitle: const Text('从 json 文件恢复，可选合并或覆盖'),
        enabled: !_backupBusy,
        onTap: _backupBusy ? null : _importBackup,
      ),
    ];
  }

  Widget _buildConfigFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _keyController,
          decoration: InputDecoration(
            labelText: 'API Key',
            border: const OutlineInputBorder(),
            hintText: 'sk-...',
            suffixIcon: _revealButton(
              _showApiKey,
              () => setState(() => _showApiKey = !_showApiKey),
            ),
          ),
          obscureText: !_showApiKey,
          maxLines: 1,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _endpointController,
          decoration: const InputDecoration(
            labelText: 'API Endpoint（可选，留空用默认）',
            border: OutlineInputBorder(),
            hintText: 'https://api.openai.com/v1',
          ),
          maxLines: 1,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(
            labelText: '模型（可选，留空用默认）',
            border: OutlineInputBorder(),
            hintText: 'gpt-4o / claude-sonnet-5',
          ),
          maxLines: 1,
        ),
      ],
    );
  }
}
