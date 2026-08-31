import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Which wire protocol an entry uses. Derived from the URL scheme — there is
/// nothing for the user to pick.
enum McpTransportKind { streamableHttp, webSocket, unknown }

class ExternalMcpServer {
  final String id;
  String name;
  String url;
  bool enabled;

  /// Bearer token for servers that require auth. Sent as
  /// `Authorization: Bearer <token>` on every HTTP request.
  ///
  /// ⚠️ 明文存在 SharedPreferences 里，和 ElevenLabs 的 key 一样——手机本地、
  /// 不出网，但没有加密。**任何地方都不要把它打进日志或界面提示**。
  ///
  /// 只对 HTTP 传输有意义：ws:// 那条是 App 自带的本机服务器，没有鉴权，
  /// 而且 WebSocket 握手带自定义头在各平台上行为不一致，索性不支持。
  String? token;

  ExternalMcpServer({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.token,
  });

  bool get hasToken => token != null && token!.isNotEmpty;

  /// 查询串里这些名字当密钥看。
  static const _secretParams = {
    'key',
    'token',
    'api_key',
    'apikey',
    'secret',
    'access_token',
    'password',
  };

  /// 给界面看的地址：查询串里的密钥打码。
  ///
  /// 不是所有服务器都把凭据放在头里。滴滴那种是
  /// `https://…/mcp-servers?key=XXX`——**URL 本身就是凭据**。而服务器列表的
  /// 副标题和「已连接」那一行都会把地址整串印出来，不打码等于摊在屏幕上给
  /// 旁边的人看。token 那个输入框是 obscure 的，这里也得跟上。
  String get displayUrl {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.queryParameters.isEmpty) return url;

    var masked = false;
    final params = <String, String>{};
    uri.queryParameters.forEach((k, v) {
      if (v.isNotEmpty && _secretParams.contains(k.toLowerCase())) {
        params[k] = '••••';
        masked = true;
      } else {
        params[k] = v;
      }
    });
    return masked ? uri.replace(queryParameters: params).toString() : url;
  }

  McpTransportKind get transport {
    switch (Uri.tryParse(url)?.scheme) {
      case 'http':
      case 'https':
        return McpTransportKind.streamableHttp;
      case 'ws':
      case 'wss':
        return McpTransportKind.webSocket;
      default:
        return McpTransportKind.unknown;
    }
  }

  /// Short label for the server list.
  String get transportLabel {
    switch (transport) {
      case McpTransportKind.streamableHttp:
        return 'HTTP';
      case McpTransportKind.webSocket:
        return 'WS';
      case McpTransportKind.unknown:
        return '?';
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
    if (hasToken) 'token': token,
  };

  factory ExternalMcpServer.fromJson(Map<String, dynamic> json) =>
      ExternalMcpServer(
        id: json['id'] as String,
        name: (json['name'] ?? 'MCP Server') as String,
        url: json['url'] as String,
        enabled: json['enabled'] ?? true,
        token: json['token'] as String?,
      );
}

class ExternalMcpServerService {
  static const _key = 'external_mcp_servers';

  static Future<List<ExternalMcpServer>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_key);
    if (data == null || data.isEmpty) return [];

    // Current format: a JSON array.
    try {
      final decoded = jsonDecode(data);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => ExternalMcpServer.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      }
    } catch (_) {
      // Not JSON — fall through to the legacy reader below.
    }

    // Legacy format: `id|name|url|enabled` joined by `||`. Kept so existing
    // installs do not lose their servers; rewritten as JSON on the next save.
    final migrated = <ExternalMcpServer>[];
    for (final entry in data.split('||')) {
      final parts = entry.split('|');
      if (parts.length < 3) continue;
      migrated.add(
        ExternalMcpServer(
          id: parts[0],
          name: parts[1],
          url: parts[2],
          enabled: parts.length > 3 ? parts[3] == '1' : true,
        ),
      );
    }
    if (migrated.isNotEmpty) await save(migrated);
    return migrated;
  }

  static Future<void> save(List<ExternalMcpServer> servers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(servers.map((s) => s.toJson()).toList()),
    );
  }

  static Future<void> add(ExternalMcpServer server) async {
    final servers = await load();
    servers.add(server);
    await save(servers);
  }

  static Future<void> remove(String id) async {
    final servers = await load();
    servers.removeWhere((s) => s.id == id);
    await save(servers);
  }

  static Future<void> update(ExternalMcpServer server) async {
    final servers = await load();
    final idx = servers.indexWhere((s) => s.id == server.id);
    if (idx >= 0) {
      servers[idx] = server;
      await save(servers);
    }
  }
}
