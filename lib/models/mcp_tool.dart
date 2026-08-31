class McpTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final String category;

  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.category,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'category': category,
  };

  /// 别人家的服务器返回什么都有可能，这里只当 `name` 是必需的。
  ///
  /// MCP 规范里 `description` 本来就是可选的；`inputSchema` 虽然写的是必需，
  /// 实际上也有服务器不给。原来这两个都是硬取，缺一个就抛——而抛出去会被
  /// `ExternalMcpClient.connect()` 外层一兜，变成整台服务器「连接失败」。
  /// **一个畸形工具废掉一整台**，代价和收益完全不成比例。
  ///
  /// 没有 schema 时给一个空的 object：模型看到的是「一个不收参数的工具」，
  /// 比工具直接消失强——真调错了服务器会自己报错，那是它该管的事。
  factory McpTool.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw FormatException('工具缺少 name：$json');
    }
    final schema = json['inputSchema'];
    return McpTool(
      name: name,
      description: json['description'] as String? ?? '',
      inputSchema:
          schema is Map
              ? Map<String, dynamic>.from(schema)
              : const {'type': 'object', 'properties': <String, dynamic>{}},
      category: json['category'] as String? ?? 'general',
    );
  }
}

class McpRequest {
  final String method;
  final Map<String, dynamic>? params;
  final String? id;

  const McpRequest({required this.method, this.params, this.id});

  Map<String, dynamic> toJson() => {
    'jsonrpc': '2.0',
    'method': method,
    if (params != null) 'params': params,
    if (id != null) 'id': id,
  };

  factory McpRequest.fromJson(Map<String, dynamic> json) => McpRequest(
    method: json['method'],
    params: json['params'] as Map<String, dynamic>?,
    id: json['id'] as String?,
  );
}

class McpResponse {
  final dynamic result;
  final McpError? error;
  final String? id;

  const McpResponse({this.result, this.error, this.id});

  Map<String, dynamic> toJson() => {
    'jsonrpc': '2.0',
    if (result != null) 'result': result,
    if (error != null) 'error': error!.toJson(),
    if (id != null) 'id': id,
  };

  factory McpResponse.fromJson(Map<String, dynamic> json) => McpResponse(
    result: json['result'],
    error: json['error'] != null ? McpError.fromJson(json['error']) : null,
    id: json['id'] as String?,
  );
}

class McpError {
  final int code;
  final String message;

  const McpError({required this.code, required this.message});

  Map<String, dynamic> toJson() => {'code': code, 'message': message};

  factory McpError.fromJson(Map<String, dynamic> json) =>
      McpError(code: json['code'], message: json['message']);
}
