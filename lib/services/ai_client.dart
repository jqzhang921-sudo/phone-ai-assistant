import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_keys.dart';
import '../models/chat_message.dart';
import '../models/mcp_tool.dart';

class AiClient {
  final ApiKeyConfig config;
  final List<McpTool>? tools;

  AiClient({required this.config, this.tools});

  Stream<AiStreamEvent> chat(List<ChatMessage> messages,
      {String? systemPrompt}) {
    switch (config.provider) {
      case 'openai':
        return _openaiChat(messages, systemPrompt: systemPrompt);
      case 'anthropic':
        return _anthropicChat(messages, systemPrompt: systemPrompt);
      default:
        return _openaiChat(messages, systemPrompt: systemPrompt);
    }
  }

  Stream<AiStreamEvent> _openaiChat(List<ChatMessage> messages,
      {String? systemPrompt}) async* {
    final endpoint = config.endpoint ?? 'https://api.openai.com/v1';
    final model = config.model ?? 'gpt-4o';

    final apiMessages = <Map<String, dynamic>>[];

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      apiMessages.add({'role': 'system', 'content': systemPrompt});
    }

    for (final msg in messages) {
      switch (msg.role) {
        case MessageRole.user:
          if (msg.imageData != null && config.provider == 'openai') {
            apiMessages.add({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': msg.content},
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/jpeg;base64,${msg.imageData}'
                  }
                },
              ],
            });
          } else {
            apiMessages.add({'role': 'user', 'content': msg.content});
          }
          break;
        case MessageRole.assistant:
          if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
            final contentText = msg.content ?? '';
            apiMessages.add({
              'role': 'assistant',
              'content': contentText.isEmpty ? null : contentText,
              'tool_calls': msg.toolCalls!
                  .map((t) => {
                        'id': t.id,
                        'type': 'function',
                        'function': {
                          'name': t.name,
                          'arguments': jsonEncode(t.arguments),
                        },
                      })
                  .toList(),
            });
          } else {
            apiMessages.add({'role': 'assistant', 'content': msg.content});
          }
          break;
        case MessageRole.toolResult:
          apiMessages.add({
            'role': 'tool',
            'tool_call_id': msg.toolCallId ?? '',
            'content': msg.content ?? '',
          });
          break;
        case MessageRole.toolCall:
          // Skip - tool_calls already embedded in assistant messages
          break;
        case MessageRole.system:
          apiMessages.add({'role': 'system', 'content': msg.content});
          break;
        default:
          break;
      }
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': apiMessages,
      'stream': true,
      'max_tokens': 4096,
    };

    if (tools != null && tools!.isNotEmpty) {
      body['tools'] = tools!
          .map((t) => {
                'type': 'function',
                'function': {
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.inputSchema,
                },
              })
          .toList();
    }

    try {
      final request = http.Request('POST', Uri.parse('$endpoint/chat/completions'));
      request.headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}',
      });
      request.body = jsonEncode(body);

      final response = await http.Client().send(request);

      if (response.statusCode != 200) {
        final error = await response.stream.bytesToString();
        yield AiStreamEvent.error('API 错误 (${response.statusCode}): $error');
        return;
      }

      String? contentBuffer;
      List<ToolCallInfo>? toolCalls;
      // Accumulate raw argument JSON text per tool call index
      final Map<int, String> argBuffers = {};

      await for (final chunk in response.stream.transform(utf8.decoder)) {
        final lines = chunk.split('\n');
        for (final line in lines) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6).trim();
          if (data == '[DONE]') break;

          try {
            final json = jsonDecode(data);
            final delta = json['choices']?[0]?['delta'];

            if (delta == null) continue;

            if (delta['content'] != null) {
              contentBuffer = (contentBuffer ?? '') + delta['content'];
              yield AiStreamEvent.token(delta['content']);
            }

            if (delta['tool_calls'] != null) {
              for (final tc in delta['tool_calls']) {
                final idx = tc['index'] ?? 0;
                toolCalls ??= [];

                while (toolCalls!.length <= idx) {
                  toolCalls!.add(ToolCallInfo(
                    id: '', name: '', arguments: {},
                  ));
                }

                if (tc['id'] != null) {
                  toolCalls![idx] = ToolCallInfo(
                    id: tc['id'], name: toolCalls![idx].name,
                    arguments: toolCalls![idx].arguments,
                  );
                }
                if (tc['function']?['name'] != null) {
                  toolCalls![idx] = ToolCallInfo(
                    id: toolCalls![idx].id, name: tc['function']['name'],
                    arguments: toolCalls![idx].arguments,
                  );
                }
                // Accumulate arguments fragments and parse only when complete
                if (tc['function']?['arguments'] != null) {
                  final argText = tc['function']['arguments'].toString();
                  argBuffers[idx] = (argBuffers[idx] ?? '') + argText;
                  try {
                    final parsed = jsonDecode(argBuffers[idx]!);
                    toolCalls![idx] = ToolCallInfo(
                      id: toolCalls![idx].id,
                      name: toolCalls![idx].name,
                      arguments: Map<String, dynamic>.from(parsed),
                    );
                  } catch (_) {
                    // Partial JSON chunk, keep accumulating
                  }
                }
              }
            }
          } catch (_) {}
        }
      }

      if (toolCalls != null && toolCalls!.isNotEmpty) {
        yield AiStreamEvent.toolCalls(toolCalls!);
      } else if (contentBuffer != null) {
        yield AiStreamEvent.done(contentBuffer);
      }
    } catch (e) {
      yield AiStreamEvent.error('网络错误: $e');
    }
  }

  Stream<AiStreamEvent> _anthropicChat(List<ChatMessage> messages,
      {String? systemPrompt}) async* {
    final endpoint = config.endpoint ?? 'https://api.anthropic.com/v1';
    final model = config.model ?? 'claude-sonnet-5';

    final apiMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      switch (msg.role) {
        case MessageRole.user:
          apiMessages.add({'role': 'user', 'content': msg.content});
          break;
        case MessageRole.assistant:
          if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
            final content = <Map<String, dynamic>>[];
            if (msg.content.isNotEmpty) {
              content.add({'type': 'text', 'text': msg.content});
            }
            for (final tc in msg.toolCalls!) {
              content.add({
                'type': 'tool_use',
                'id': tc.id,
                'name': tc.name,
                'input': tc.arguments,
              });
            }
            apiMessages.add({'role': 'assistant', 'content': content});
          } else {
            apiMessages.add({'role': 'assistant', 'content': msg.content});
          }
          break;
        case MessageRole.toolResult:
          apiMessages.add({
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': msg.toolCallId,
                'content': msg.content,
              }
            ],
          });
          break;
        case MessageRole.toolCall:
          // Skip - tool_use already embedded in assistant messages
          break;
        case MessageRole.system:
          apiMessages.add({'role': 'user', 'content': msg.content});
          break;
        default:
          break;
      }
    }

    final body = <String, dynamic>{
      'model': model,
      'max_tokens': 4096,
      'messages': apiMessages,
      'stream': true,
    };

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      body['system'] = systemPrompt;
    }

    if (tools != null && tools!.isNotEmpty) {
      body['tools'] = tools!
          .map((t) => {
                'name': t.name,
                'description': t.description,
                'input_schema': t.inputSchema,
              })
          .toList();
    }

    try {
      final request = http.Request('POST', Uri.parse('$endpoint/messages'));
      request.headers.addAll({
        'Content-Type': 'application/json',
        'x-api-key': config.apiKey ?? '',
        'anthropic-version': '2023-06-01',
      });
      request.body = jsonEncode(body);

      final response = await http.Client().send(request);

      if (response.statusCode != 200) {
        final error = await response.stream.bytesToString();
        yield AiStreamEvent.error('Claude API 错误 (${response.statusCode}): $error');
        return;
      }

      String contentBuffer = '';
      List<ToolCallInfo>? toolCalls;

      await for (final chunk in response.stream.transform(utf8.decoder)) {
        final lines = chunk.split('\n');
        for (final line in lines) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6);
          if (data == '[DONE]') break;

          try {
            final json = jsonDecode(data);
            final type = json['type'];

            if (type == 'content_block_delta') {
              final delta = json['delta'];
              if (delta?['type'] == 'text_delta') {
                contentBuffer += delta['text'];
                yield AiStreamEvent.token(delta['text']);
              }
            } else if (type == 'content_block_start') {
              final block = json['content_block'];
              if (block?['type'] == 'tool_use') {
                toolCalls ??= [];
                toolCalls!.add(ToolCallInfo(
                  id: block['id'],
                  name: block['name'],
                  arguments: Map<String, dynamic>.from(block['input'] ?? {}),
                ));
              }
            } else if (type == 'message_delta') {
            }
          } catch (_) {}
        }
      }

      if (toolCalls != null && toolCalls!.isNotEmpty) {
        yield AiStreamEvent.toolCalls(toolCalls!);
      } else {
        yield AiStreamEvent.done(contentBuffer);
      }
    } catch (e) {
      yield AiStreamEvent.error('网络错误: $e');
    }
  }
}

class AiStreamEvent {
  final AiEventType type;
  final String? text;
  final List<ToolCallInfo>? toolCalls;
  final String? error;

  const AiStreamEvent._(
      {required this.type, this.text, this.toolCalls, this.error});

  factory AiStreamEvent.token(String text) =>
      AiStreamEvent._(type: AiEventType.token, text: text);

  factory AiStreamEvent.toolCalls(List<ToolCallInfo> calls) =>
      AiStreamEvent._(type: AiEventType.toolCalls, toolCalls: calls);

  factory AiStreamEvent.done(String text) =>
      AiStreamEvent._(type: AiEventType.done, text: text);

  factory AiStreamEvent.error(String error) =>
      AiStreamEvent._(type: AiEventType.error, error: error);
}

enum AiEventType { token, toolCalls, done, error }
