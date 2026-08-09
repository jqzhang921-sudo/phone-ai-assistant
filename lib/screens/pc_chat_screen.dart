import 'package:flutter/material.dart';
import '../services/pc_bridge_service.dart';

class _Msg {
  final String role; // 'user' | 'pc' | 'status' | 'error'
  String text;
  _Msg(this.role, this.text);
}

class PcChatScreen extends StatefulWidget {
  const PcChatScreen({super.key});

  @override
  State<PcChatScreen> createState() => _PcChatScreenState();
}

class _PcChatScreenState extends State<PcChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <_Msg>[];
  PcBridgeChat? _chat;
  PcBridgeConfig _config = const PcBridgeConfig(
    url: 'ws://100.79.248.111:8787',
    token: '',
    agent: 'codex',
  );
  bool _connected = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAndConnect();
  }

  @override
  void dispose() {
    _chat?.dispose();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadAndConnect() async {
    _config = await PcBridgeStorage.load();
    if (!mounted) return;
    if (_config.token.isEmpty) {
      _add(_Msg('status', '还没配置连接，点右上角设置'));
      return;
    }
    _connect();
  }

  Future<void> _connect() async {
    _chat?.dispose();
    setState(() {
      _connected = false;
      _busy = false;
    });
    _add(_Msg('status', '连接 ${_config.url} …'));
    try {
      final chat = PcBridgeChat();
      _chat = chat;
      final stream = await chat.start(_config);
      stream.listen(_onEvent);
    } catch (e) {
      _add(_Msg('error', '连接失败：$e'));
      setState(() => _connected = false);
    }
  }

  void _onEvent(PcBridgeEvent event) {
    if (!mounted) return;
    switch (event) {
      case PcBridgeText(:final text):
        _appendPcText(text);
      case PcBridgeStatus(:final message):
        _add(_Msg('status', message));
        if (message == '已连接电脑') setState(() => _connected = true);
      case PcBridgeDone(:final exitCode):
        setState(() => _busy = false);
        _add(_Msg('status', exitCode == 0 ? '完成' : '结束（exit $exitCode）'));
      case PcBridgeError(:final message):
        setState(() => _busy = false);
        _add(_Msg('error', message));
    }
  }

  void _add(_Msg m) {
    setState(() => _messages.add(m));
    _scrollToBottom();
  }

  void _appendPcText(String text) {
    setState(() {
      if (_messages.isNotEmpty && _messages.last.role == 'pc' && !_busy) {
        _messages.last.text += text;
      } else if (_messages.isNotEmpty && _messages.last.role == 'pc' && _busy) {
        _messages.last.text += text;
      } else {
        _messages.add(_Msg('pc', text));
      }
    });
    _scrollToBottom();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    _add(_Msg('user', text));
    if (!_connected) {
      _add(_Msg('error', '还没连上电脑'));
      return;
    }
    setState(() => _busy = true);
    _chat?.sendMessage(_config, text);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _openSettings() async {
    final urlCtrl = TextEditingController(text: _config.url);
    final tokenCtrl = TextEditingController(text: _config.token);
    var agent = _config.agent;
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setDlg) => AlertDialog(
                  title: const Text('电脑连接设置'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'WebSocket 地址',
                          hintText: 'ws://100.x.x.x:8787',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: tokenCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'AUTH_TOKEN',
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: agent,
                        decoration: const InputDecoration(labelText: 'Agent'),
                        items: const [
                          DropdownMenuItem(
                            value: 'codex',
                            child: Text('codex'),
                          ),
                          DropdownMenuItem(
                            value: 'claude',
                            child: Text('claude'),
                          ),
                        ],
                        onChanged: (v) => setDlg(() => agent = v ?? 'codex'),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('保存并连接'),
                    ),
                  ],
                ),
          ),
    );
    if (ok == true) {
      _config = PcBridgeConfig(
        url: urlCtrl.text.trim().isEmpty ? _config.url : urlCtrl.text.trim(),
        token: tokenCtrl.text.trim(),
        agent: agent,
      );
      await PcBridgeStorage.save(_config);
      _connect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: _connected ? const Color(0xFF34C759) : scheme.outline,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text('电脑'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '连接设置',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '重连',
            onPressed: _connect,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child:
                _messages.isEmpty
                    ? Center(
                      child: Text(
                        '通过电脑上的 Claude Code / Codex 聊天',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                    : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) => _buildBubble(theme, _messages[i]),
                    ),
          ),
          _buildInput(theme),
        ],
      ),
    );
  }

  Widget _buildBubble(ThemeData theme, _Msg m) {
    final scheme = theme.colorScheme;
    if (m.role == 'status' || m.role == 'error') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Center(
          child: Text(
            m.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: m.role == 'error' ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    final isUser = m.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color:
                isUser
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(m.text, style: TextStyle(color: scheme.onSurface)),
        ),
      ),
    );
  }

  Widget _buildInput(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: '输入消息…',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(
                    color: scheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.75),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (_busy)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: '停止',
              onPressed: () => _chat?.cancel(),
            ),
          IconButton(
            icon: Icon(
              Icons.send_rounded,
              color: _connected ? scheme.primary : scheme.outline,
            ),
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}
