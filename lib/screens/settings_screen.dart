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
import '../services/weread_service.dart';
import 'tools_screen.dart';
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
  final _wereadKeyController = TextEditingController();
  final _userNameController = TextEditingController();

  // 密钥默认打码，点小眼睛才明文——设置页经常被截图/投屏。
  bool _showApiKey = false;
  bool _showElevenKey = false;
  bool _showTavilyKey = false;
  bool _showWereadKey = false;

  bool _backupBusy = false;

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
          '日记 ${summary.diaryEntries}、一隅 ${summary.musings}。'
          '密钥需要重新填。',
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));
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
  }

  @override
  void dispose() {
    _keyController.dispose();
    _endpointController.dispose();
    _modelController.dispose();
    _elevenKeyController.dispose();
    _elevenVoiceController.dispose();
    _tavilyKeyController.dispose();
    _wereadKeyController.dispose();
    _userNameController.dispose();
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
    _wereadKeyController.text = await WereadService.getKey() ?? '';
    _userNameController.text = _settings.userName;
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
        padding: const EdgeInsets.all(16),
        children: [
          // 称呼 —— 首页问候语用这个名字
          _sectionHeader('称呼', PhosphorIconsRegular.user, theme),
          const SizedBox(height: 8),
          TextField(
            controller: _userNameController,
            decoration: InputDecoration(
              hintText: '首页问候语怎么称呼你（留空则不带名字）',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: const Icon(PhosphorIconsRegular.check, size: 20),
                tooltip: '保存',
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  _settings.userName = _userNameController.text.trim();
                  await _settings.save();
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('已保存'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ),
            onSubmitted: (v) async {
              _settings.userName = v.trim();
              await _settings.save();
            },
          ),

          // 外观 —— 标题字体衬线/黑体切换
          const SizedBox(height: 20),
          _sectionHeader('外观', PhosphorIconsRegular.palette, theme),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text('标题衬线体'),
            subtitle: const Text('AppBar 标题用宋体（衬线）风格，关闭则用黑体'),
            value: _settings.titleSerif,
            onChanged: (v) {
              setState(() => _settings.titleSerif = v);
              context.read<SettingsProvider>().setTitleSerif(v);
            },
          ),
          const SizedBox(height: 20),

          // API Configuration Section
          _sectionHeader('API 配置', PhosphorIconsRegular.key, theme),
          const SizedBox(height: 8),

          // Provider selector tabs（Wrap 保证所有标签都可见、可点）
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

          const Divider(height: 40),

          // TTS Settings
          _sectionHeader('TTS 语音', PhosphorIconsRegular.speakerHigh, theme),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text('语音来源'),
                const Spacer(),
                SegmentedButton<TtsProvider>(
                  segments: const [
                    ButtonSegment(
                      value: TtsProvider.system,
                      label: Text('系统(免费)'),
                    ),
                    ButtonSegment(
                      value: TtsProvider.elevenlabs,
                      label: Text('ElevenLabs'),
                    ),
                  ],
                  selected: {_settings.ttsProvider},
                  onSelectionChanged: (s) {
                    setState(() => _settings.ttsProvider = s.first);
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
              setState(() => _settings.ttsAutoPlay = v);
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
                        () => setState(() => _showElevenKey = !_showElevenKey),
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
              setState(() => _settings.autoTts = v);
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

          const Divider(height: 40),

          // Tavily 联网搜索
          _sectionHeader('联网搜索', PhosphorIconsRegular.compass, theme),
          const SizedBox(height: 8),
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
                      () => setState(() => _showTavilyKey = !_showTavilyKey),
                    ),
                    IconButton(
                      icon: const Icon(PhosphorIconsRegular.floppyDisk),
                      tooltip: '保存',
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await SearchTool.saveKey(
                          _tavilyKeyController.text.trim(),
                        );
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

          const Divider(height: 40),

          // 微信读书：这里是唯一能改 key 的地方（书架那边的弹窗只在首次没填时出现）
          _sectionHeader('微信读书', PhosphorIconsRegular.books, theme),
          const SizedBox(height: 8),
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
                      () => setState(() => _showWereadKey = !_showWereadKey),
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

          const Divider(height: 40),

          // MCP Server Settings
          _sectionHeader('MCP 服务器', PhosphorIconsRegular.link, theme),
          const SizedBox(height: 8),
          // 从抽屉挪过来的：这是诊断页，属于设置，不该和「设置」平级
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: const Icon(PhosphorIconsRegular.wrench),
            title: const Text('已注册的工具'),
            subtitle: const Text('查看 AI 能调用哪些手机能力，以及服务运行状态'),
            trailing: const Icon(PhosphorIconsRegular.caretRight, size: 16),
            onTap:
                () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const ToolsScreen())),
          ),
          SwitchListTile(
            title: const Text('启用 MCP Server'),
            subtitle: Text('允许其他设备通过端口 ${_settings.webSocketPort} 连接'),
            value: _settings.serverEnabled,
            onChanged: (v) async {
              setState(() => _settings.serverEnabled = v);
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
                  setState(() => _settings.serverEnabled = false);
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

          const Divider(height: 40),

          // External MCP Servers
          _sectionHeader('自定义 MCP 服务器', PhosphorIconsRegular.link, theme),
          const SizedBox(height: 8),

          // Connected servers status
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
                  color:
                      server.enabled ? theme.colorScheme.primary : Colors.grey,
                ),
                title: Text(server.name, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  server.url,
                  style: const TextStyle(fontSize: 11),
                ),
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
                        setState(() {});
                      },
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    IconButton(
                      icon: const Icon(PhosphorIconsRegular.trash, size: 18),
                      onPressed: () async {
                        final mcp = context.read<ExternalMcpProvider>();
                        await ExternalMcpServerService.remove(server.id);
                        mcp.disconnect(server.url);
                        _externalServers =
                            await ExternalMcpServerService.load();
                        setState(() {});
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
                            setState(() {});
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
                            final provider =
                                context.read<ExternalMcpProvider>();
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
                            setState(() {});
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
                setState(() {});
              },
              icon: const Icon(PhosphorIconsRegular.plus, size: 16),
              label: const Text('添加 MCP 服务器'),
            ),

          const Divider(height: 40),

          // 数据备份
          _sectionHeader('数据备份', PhosphorIconsRegular.floppyDisk, theme),
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

          const Divider(height: 40),

          // About
          _sectionHeader('关于', PhosphorIconsRegular.info, theme),
          ListTile(
            title: const Text('手机 AI 助手'),
            subtitle: Text('v1.0.0\n支持 MCP 协议 & 手机工具\nbuild: $buildCommit'),
          ),
        ],
      ),
    );
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

  Widget _sectionHeader(String title, IconData icon, ThemeData theme) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}
