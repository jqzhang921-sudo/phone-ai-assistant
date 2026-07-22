import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../config/api_keys.dart';
import '../config/settings.dart';
import '../services/ai_client.dart';
import '../services/external_mcp_service.dart';
import '../services/phone_tools/search_tool.dart';
import '../services/tts_service.dart';
import 'chat_screen.dart';

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
    _externalServers = await ExternalMcpServerService.load();

    // Select first config with a missing key
    final missingKey = _configs.where((c) => c.apiKey == null || c.apiKey!.isEmpty).firstOrNull;
    if (missingKey != null) {
      _selectConfig(missingKey);
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
        final aiClient = AiClient(
          config: config,
        );
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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // API Configuration Section
          _sectionHeader('API 配置', Icons.key, theme),
          const SizedBox(height: 8),

          // Provider selector tabs
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: _configs.map((config) {
                final selected = config.provider == _selectedProvider;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(config.name),
                    selected: selected,
                    onSelected: (_) => _selectConfig(config),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),

          if (_selectedProvider != null) ...[
            _buildConfigFields(),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saveCurrent,
              icon: const Icon(Icons.save),
              label: const Text('保存 API 配置'),
            ),
          ],

          const Divider(height: 40),

          // TTS Settings
          _sectionHeader('TTS 语音', Icons.volume_up, theme),
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
                        value: TtsProvider.system, label: Text('系统(免费)')),
                    ButtonSegment(
                        value: TtsProvider.elevenlabs, label: Text('ElevenLabs')),
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
          if (_settings.ttsProvider == TtsProvider.elevenlabs) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _elevenKeyController,
                obscureText: false,
                decoration: InputDecoration(
                  labelText: 'ElevenLabs API Key',
                  hintText: 'elevenlabs.io → 头像 → API Keys',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste),
                    tooltip: '从剪贴板粘贴',
                    onPressed: () => _pasteInto(_elevenKeyController),
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
                    icon: const Icon(Icons.content_paste),
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
                  icon: const Icon(Icons.save),
                  label: const Text('保存'),
                  onPressed: () async {
                    await _saveTts();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('已保存'),
                            duration: Duration(seconds: 1)),
                      );
                    }
                  },
                ),
              ),
            ),
          ],
          SwitchListTile(
            title: const Text('自动朗读'),
            subtitle: Text(_settings.ttsProvider == TtsProvider.elevenlabs
                ? 'AI 回复后自动朗读（ElevenLabs 会按量扣费）'
                : 'AI 回复后自动朗读'),
            value: _settings.autoTts,
            onChanged: (v) {
              setState(() => _settings.autoTts = v);
              _settings.save();
            },
          ),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('测试语音'),
            subtitle: Text(_settings.ttsProvider == TtsProvider.elevenlabs
                ? '用 ElevenLabs 试读一句（会消耗少量额度）'
                : '用系统引擎试读一句（需手机已装 TTS 引擎）'),
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
          _sectionHeader('联网搜索', Icons.travel_explore, theme),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: TextField(
              controller: _tavilyKeyController,
              decoration: InputDecoration(
                labelText: 'Tavily API Key',
                hintText: 'tavily.com → Dashboard → API Keys',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.save),
                  tooltip: '保存',
                  onPressed: () async {
                    await SearchTool.saveKey(_tavilyKeyController.text.trim());
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Tavily Key 已保存'),
                            duration: Duration(seconds: 1)),
                      );
                    }
                  },
                ),
              ),
            ),
          ),

          const Divider(height: 40),

          // MCP Server Settings
          _sectionHeader('MCP 服务器', Icons.link, theme),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('启用 MCP Server'),
            subtitle: Text(
                '允许其他设备通过端口 ${_settings.webSocketPort} 连接'),
            value: _settings.serverEnabled,
            onChanged: (v) async {
              setState(() => _settings.serverEnabled = v);
              final server = context.read<McpServerProvider>().server;
              if (v) {
                final ok = await server.start(_settings.webSocketPort);
                if (!ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('启动 MCP Server 失败，请检查端口'),
                        backgroundColor: Colors.red),
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
              leading: const Icon(Icons.wifi),
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
                      text: _settings.webSocketPort.toString()),
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
          _sectionHeader('自定义 MCP 服务器', Icons.link, theme),
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
                    ...mcpProv.clients.map((c) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.check_circle,
                                  size: 14, color: Colors.green),
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
                        )),
                    const SizedBox(height: 8),
                  ],
                );
              }
              return const SizedBox.shrink();
            },
          ),

          // Server list
          ..._externalServers.map((server) => Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.dns_outlined,
                    color: server.enabled
                        ? theme.colorScheme.primary
                        : Colors.grey,
                  ),
                  title: Text(server.name,
                      style: const TextStyle(fontSize: 14)),
                  subtitle: Text(server.url,
                      style: const TextStyle(fontSize: 11)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: server.enabled,
                        onChanged: (v) async {
                          server.enabled = v;
                          await ExternalMcpServerService.save(_externalServers);
                          if (v) {
                            context
                                .read<ExternalMcpProvider>()
                                .connectTo(server);
                          } else {
                            context
                                .read<ExternalMcpProvider>()
                                .disconnect(server.url);
                          }
                          setState(() {});
                        },
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () async {
                          await ExternalMcpServerService.remove(server.id);
                          context
                              .read<ExternalMcpProvider>()
                              .disconnect(server.url);
                          _externalServers = await ExternalMcpServerService.load();
                          setState(() {});
                        },
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              )),

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
                          icon: const Icon(Icons.link, size: 16),
                          label: const Text('添加并连接'),
                          onPressed: () async {
                            final name = _mcpNameController.text.trim();
                            final url = _mcpUrlController.text.trim();
                            if (name.isEmpty || url.isEmpty) return;

                            // Show loading
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('⏳ 连接中...'), duration: Duration(seconds: 30)),
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
                              ScaffoldMessenger.of(context).hideCurrentSnackBar();
                              if (error == null) {
                                // Success: save and clear
                                await ExternalMcpServerService.add(server);
                                _mcpNameController.clear();
                                _mcpUrlController.clear();
                                _showAddMcp = false;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('✅ 已连接到 $name'), duration: Duration(seconds: 2)),
                                );
                              } else {
                                // Failure: keep form, show error
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('❌ $error'),
                                    backgroundColor: Colors.orange,
                                    duration: Duration(seconds: 5),
                                  ),
                                );
                              }
                            }
                            _externalServers = await ExternalMcpServerService.load();
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
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加 MCP 服务器'),
            ),

          const Divider(height: 40),

          // About
          _sectionHeader('关于', Icons.info_outline, theme),
          ListTile(
            title: const Text('手机 AI 助手'),
            subtitle: const Text('v1.0.0\n支持 MCP 协议 & 手机工具'),
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
          decoration: const InputDecoration(
            labelText: 'API Key',
            border: OutlineInputBorder(),
            hintText: 'sk-...',
          ),
          obscureText: true,
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
        Text(title,
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.primary)),
      ],
    );
  }
}
