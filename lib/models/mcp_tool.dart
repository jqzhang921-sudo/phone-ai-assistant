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

  factory McpTool.fromJson(Map<String, dynamic> json) => McpTool(
        name: json['name'],
        description: json['description'],
        inputSchema: Map<String, dynamic>.from(json['inputSchema']),
        category: json['category'] ?? 'general',
      );
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
        error:
            json['error'] != null ? McpError.fromJson(json['error']) : null,
        id: json['id'] as String?,
      );
}

class McpError {
  final int code;
  final String message;

  const McpError({required this.code, required this.message});

  Map<String, dynamic> toJson() => {'code': code, 'message': message};

  factory McpError.fromJson(Map<String, dynamic> json) => McpError(
        code: json['code'],
        message: json['message'],
      );
}
