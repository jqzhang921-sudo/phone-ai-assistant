import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_keys.dart';
import '../models/chat_message.dart';
import '../models/mcp_tool.dart';

/// 把时间戳格式化并拼在消息内容前面，让模型能看到每条消息的发生时间。
String _withTimestamp(String content, DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final ts =
      '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  return '[time: $ts]\n$content';
}

/// 去掉模型可能复读出来的 [time: ...] 时间戳标记。
String _stripTimeMarkers(String text) {
  return text
      .replaceAll(RegExp(r'\[time:[^\]]*\]'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trimLeft();
}

/// 修复损坏的对话历史：如果某条 assistant 消息发起了工具调用，但对应的
/// tool_call_id 在后面找不到匹配的 toolResult 消息（比如因为工具执行时
/// 异常中断、或者旧版本代码的bug导致结果没存下来），就给它补一条占位的
/// 失败结果。不修的话，这类对话会在每次发消息时都被服务商 API 以
/// "tool_calls 缺少对应响应" 为由拒绝（400），且没法靠重试恢复，因为
/// 坏掉的历史已经存进本地了。
List<ChatMessage> _sanitizeToolCallHistory(List<ChatMessage> messages) {
  final result = <ChatMessage>[];
  for (var i = 0; i < messages.length; i++) {
    final msg = messages[i];
    result.add(msg);
    if (msg.role != MessageRole.assistant ||
        msg.toolCalls == null ||
        msg.toolCalls!.isEmpty) {
      continue;
    }
    // 收集紧随其后、属于这一轮的 toolResult 消息，看看有没有覆盖所有
    // tool_call_id（一直找到下一条非 toolResult 消息为止）
    // 扫描其后的全部历史，而不是只看紧邻的连续 toolResult。
    //
    // 原来一遇到非 toolResult 消息就 break：只要结果之间夹了任何一条别的消息
    // （模型在工具调用之间说了句话、或多轮工具交错），后面的结果就被判成
    // 「没有响应」，于是补上占位、真结果反而被 _repairToolMessages 当孤儿剔除，
    // 服务端照样报 tool_call_id 缺响应。
    final answered = <String>{};
    for (var j = i + 1; j < messages.length; j++) {
      final next = messages[j];
      if (next.role == MessageRole.toolResult && next.toolCallId != null) {
        answered.add(next.toolCallId!);
      }
    }
    for (final tc in msg.toolCalls!) {
      if (!answered.contains(tc.id)) {
        result.add(
          ChatMessage(
            id: 'repair_${tc.id}',
            role: MessageRole.toolResult,
            content: jsonEncode({
              'success': false,
              'error': '工具结果丢失（历史记录已自动修复，此结果为占位）',
            }),
            toolCallId: tc.id,
          ),
        );
      }
    }
  }
  return result;
}

/// 系统级提示：时间戳只是元数据，模型不应复述。
const _timeMetaInstruction =
    '注意：消息内容中可能带有 [time: ...] 前缀，这是系统自动注入的发送时间元数据，'
    '仅供你了解对话时间线。绝对不要在回复中输出、模仿或重复 [time: ...] 这类标记。';

class AiClient {
  final ApiKeyConfig config;
  final List<McpTool>? tools;

  AiClient({required this.config, this.tools});

  /// [systemPrompt] 是**长期不变**的人设，[memoryContext] 是每天都在变的记忆。
  /// 两者必须分开传，别在调用方就拼成一个字符串——原因见 [_attachMemory]。
  Stream<AiStreamEvent> chat(
    List<ChatMessage> messages, {
    String? systemPrompt,
    String? memoryContext,
    String? historySummary,
  }) {
    final safeMessages = _sanitizeToolCallHistory(messages);
    switch (config.provider) {
      case 'openai':
        return _openaiChat(
          safeMessages,
          systemPrompt: systemPrompt,
          memoryContext: memoryContext,
          historySummary: historySummary,
        );
      case 'anthropic':
        return _anthropicChat(
          safeMessages,
          systemPrompt: systemPrompt,
          memoryContext: memoryContext,
          historySummary: historySummary,
        );
      default:
        return _openaiChat(
          safeMessages,
          systemPrompt: systemPrompt,
          memoryContext: memoryContext,
          historySummary: historySummary,
        );
    }
  }

  /// 摘要拼进 system 块，而不是像记忆那样挂到尾部。
  ///
  /// 两者的易变程度不同：记忆几乎天天变，所以必须躲开缓存前缀；摘要只在每次
  /// 压缩时变一次（几十条消息才一次），放在前面反而更合理——它代表的就是被
  /// 折叠掉的那段最早的历史，位置上本来就该在那儿。
  static String _buildSystemContent(String? systemPrompt, String? summary) {
    final buf = StringBuffer('$systemPrompt\n\n$_timeMetaInstruction');
    if (summary != null && summary.trim().isNotEmpty) {
      buf.write('\n\n## 更早对话的摘要\n（这段聊得比较久了，早期原文已折叠成下面这段。'
          '需要时可以当作你记得的事，但别复述给用户听。）\n$summary');
    }
    return buf.toString();
  }

  /// 把记忆挂到**最后一条用户消息**上，而不是拼进 system。
  ///
  /// 为了 prompt caching。服务端缓存的是请求前缀，命中要求跟已存的缓存单元
  /// 完整匹配；记忆放在最前面，它一变（写了篇日记、或者只是「最近一封信是 3
  /// 天前」跨天变成 4 天前），后面几千 token 的对话历史就整段错位，全部落空。
  ///
  /// 挂到尾部之后，`[人设][对话历史]` 这一大段跨轮次逐字节不变，正好是
  /// DeepSeek 文档里「第一轮 A+B，第二轮 A+B+C」那种能整段命中的形状。
  ///
  /// 不新增一条 system 消息、而是并进用户消息里，是为了避开兼容性风险——
  /// 不是所有 OpenAI 兼容端点都接受 system 出现在消息列表中间或末尾。
  static void _attachMemory(
    List<Map<String, dynamic>> apiMessages,
    String? memoryContext,
  ) {
    if (memoryContext == null || memoryContext.trim().isEmpty) return;
    final idx = apiMessages.lastIndexWhere((m) => m['role'] == 'user');
    if (idx < 0) return;

    final block =
        '（以下是你这边的背景记录，供你参考。不是用户说的话，'
        '也不用主动提起。）\n$memoryContext\n\n---\n\n';

    final content = apiMessages[idx]['content'];
    if (content is String) {
      apiMessages[idx] = {...apiMessages[idx], 'content': '$block$content'};
    } else if (content is List) {
      // 带图片的消息，content 是分块数组，插一个文本块在最前面
      apiMessages[idx] = {
        ...apiMessages[idx],
        'content': [
          {'type': 'text', 'text': block},
          ...content,
        ],
      };
    }
  }

  Stream<AiStreamEvent> _openaiChat(
    List<ChatMessage> messages, {
    String? systemPrompt,
    String? memoryContext,
    String? historySummary,
  }) async* {
    final endpoint = config.endpoint ?? 'https://api.openai.com/v1';
    final model = config.model ?? 'gpt-4o';

    final apiMessages = <Map<String, dynamic>>[];

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      apiMessages.add({
        'role': 'system',
        'content': _buildSystemContent(systemPrompt, historySummary),
      });
    }

    for (final msg in messages) {
      switch (msg.role) {
        case MessageRole.user:
          if (msg.imageData != null && config.provider == 'openai') {
            apiMessages.add({
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': _withTimestamp(msg.content, msg.timestamp),
                },
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/jpeg;base64,${msg.imageData}',
                  },
                },
              ],
            });
          } else {
            apiMessages.add({
              'role': 'user',
              'content': _withTimestamp(msg.content, msg.timestamp),
            });
          }
          break;
        case MessageRole.assistant:
          if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
            final contentText = msg.content;
            apiMessages.add({
              'role': 'assistant',
              'content':
                  contentText.isEmpty
                      ? null
                      : _withTimestamp(contentText, msg.timestamp),
              'tool_calls':
                  msg.toolCalls!
                      .map(
                        (t) => {
                          'id': t.id,
                          'type': 'function',
                          'function': {
                            'name': t.name,
                            'arguments': jsonEncode(t.arguments),
                          },
                        },
                      )
                      .toList(),
            });
          } else {
            apiMessages.add({
              'role': 'assistant',
              'content': _withTimestamp(msg.content, msg.timestamp),
            });
          }
          break;
        case MessageRole.toolResult:
          apiMessages.add({
            'role': 'tool',
            'tool_call_id': msg.toolCallId ?? '',
            'content': msg.content,
          });
          break;
        case MessageRole.toolCall:
          // Skip - tool_calls already embedded in assistant messages
          break;
        case MessageRole.system:
          apiMessages.add({'role': 'system', 'content': msg.content});
          break;
      }
    }

    // 记忆挂在尾部，必须在 _repairToolMessages 之前——那一步会按 tool_call_id
    // 重排消息，之后再挂就可能挂错位置。
    _attachMemory(apiMessages, memoryContext);

    // 兜底：确保每个 assistant 的 tool_calls 都有对应的 tool 响应。
    // 若历史里存在"孤儿" tool_calls（工具执行中断/异常留下的），
    // 直接补一条错误响应，否则 DeepSeek 报 invalid_request_error。
    final cleaned = _repairToolMessages(apiMessages);

    final body = <String, dynamic>{
      'model': model,
      'messages': cleaned,
      'stream': true,
      'max_tokens': 4096,
    };

    if (tools != null && tools!.isNotEmpty) {
      body['tools'] =
          tools!
              .map(
                (t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.inputSchema,
                  },
                },
              )
              .toList();
    }

    try {
      var attempt = 0;
      while (true) {
        attempt++;
        final request = http.Request(
          'POST',
          Uri.parse('$endpoint/chat/completions'),
        );
        request.headers.addAll({
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiKey}',
        });
        request.body = jsonEncode(body);

        final response = await http.Client().send(request);

        if (response.statusCode == 200) {
          yield* _streamOpenAiResponse(response);
          return;
        }

        final error = await response.stream.bytesToString();
        final lowered = error.toLowerCase();
        final toolHistoryError =
            lowered.contains('invalid_request_error') &&
            (lowered.contains('tool_call') ||
                lowered.contains('tool messages') ||
                lowered.contains('insufficient'));
        if (toolHistoryError && attempt == 1) {
          // 工具历史异常（如孤儿 tool_calls）：去掉全部工具消息，纯文本重试一次。
          //
          // ⚠️ 这个兜底会让模型完全看不到工具结果——工具明明执行成功了，
          // 模型却回答「我这边是空的」。原来这里把服务端错误直接吞掉，
          // 于是两边都看不见问题。先打出来，好定位第一次请求为什么非法。
          debugPrint('[ai_client] 工具历史被服务端拒绝，将丢弃全部工具消息重试。'
              '原始错误：$error');
          // 手机上看不到日志，所以直接显示在对话里——否则这个降级完全无声，
          // 用户只会看到模型说「我没收到结果」，看不出是 App 丢掉的。
          // 定位完根因后应当移除。
          yield AiStreamEvent.token(
            '⚠️ 工具结果被服务端拒绝，已丢弃后重试。原始错误：\n'
            '${error.length > 500 ? '${error.substring(0, 500)}…' : error}\n\n',
          );
          // 用 cleaned 而不是 apiMessages：后者没经过 _repairToolMessages
          body['messages'] = _stripAllToolMessages(cleaned);
          continue;
        }
        yield AiStreamEvent.error('API 错误 (${response.statusCode}): $error');
        return;
      }
    } catch (e) {
      yield AiStreamEvent.error('网络错误: $e');
    }
  }

  /// 处理 OpenAI 兼容的流式响应并产出事件。
  Stream<AiStreamEvent> _streamOpenAiResponse(
    http.StreamedResponse response,
  ) async* {
    String? contentBuffer;
    // 直接建成非空 list：原来是 `List<ToolCallInfo>? toolCalls` 加一路 `!`，
    // 空列表和 null 在这里本来就是同一个意思（末尾按 isNotEmpty 判断）。
    final toolCalls = <ToolCallInfo>[];
    // Accumulate raw argument JSON text per tool call index
    final Map<int, String> argBuffers = {};

    // 必须走 LineSplitter，不能对每个分片各自 split('\n')。
    //
    // response.stream 给的是任意大小的字节块，不保证按行对齐。一行 SSE 被切在
    // 两个分片里时，原来的写法两半都会丢：前半段 `data: {"delta":{"content":"想`
    // jsonDecode 失败被下面的 catch 吞掉，后半段 `到了"}}]}` 不以 data: 开头被
    // 跳过——于是这个 token 无声消失。表现是长回复里零星掉字（不是尾部截断），
    // 回复越长分片越多、掉得越厉害。
    //
    // LineSplitter 自己维护跨分片的缓冲，只吐完整的行，末尾没有换行符的最后
    // 一行也会补吐出来。
    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6).trim();
      if (data == '[DONE]') break;

      try {
        final json = jsonDecode(data);

        // 缓存命中情况：流式响应的最后一片会带 usage（部分服务端要显式开启才给）。
        // 打出来才能验证「记忆挂尾部」到底有没有让前缀命中，否则全靠猜。
        final usage = json['usage'];
        if (usage is Map) {
          final hit = usage['prompt_cache_hit_tokens'];
          final miss = usage['prompt_cache_miss_tokens'];
          if (hit != null || miss != null) {
            debugPrint('[ai_client] prompt cache 命中 $hit / 未命中 $miss');
          } else {
            debugPrint('[ai_client] usage: $usage');
          }
        }

        final delta = json['choices']?[0]?['delta'];

        if (delta == null) continue;

        if (delta['content'] != null) {
          contentBuffer = (contentBuffer ?? '') + delta['content'];
          yield AiStreamEvent.token(delta['content']);
        }

        if (delta['tool_calls'] != null) {
          for (final tc in delta['tool_calls']) {
            final idx = tc['index'] ?? 0;

            while (toolCalls.length <= idx) {
              toolCalls.add(ToolCallInfo(id: '', name: '', arguments: {}));
            }

            if (tc['id'] != null) {
              toolCalls[idx] = ToolCallInfo(
                id: tc['id'],
                name: toolCalls[idx].name,
                arguments: toolCalls[idx].arguments,
              );
            }
            if (tc['function']?['name'] != null) {
              toolCalls[idx] = ToolCallInfo(
                id: toolCalls[idx].id,
                name: tc['function']['name'],
                arguments: toolCalls[idx].arguments,
              );
            }
            // 只累积，不在分片阶段解析——解析统一放到流结束后。
            //
            // 原来每来一个分片就试着 jsonDecode：只要某个中间状态恰好是合法
            // JSON（比如先到一个 `{}`），arguments 就被锁成空对象；之后拼上
            // 真内容，缓冲区变成 `{}{"query":"…"}` 永远解析失败，catch 静默吞掉，
            // 于是发出去的调用里 query 一直是空的。
            if (tc['function']?['arguments'] != null) {
              argBuffers[idx] =
                  (argBuffers[idx] ?? '') +
                  tc['function']['arguments'].toString();
            }
          }
        }
      } catch (e) {
        // 别再静默吞了——掉字的 bug 就是藏在这个 catch 后面躲了这么久。
        debugPrint('[ai_client] SSE 行解析失败（$e）：$data');
      }
    }

    if (toolCalls.isNotEmpty) {
      // 流结束了，参数分片已经完整，这时才解析
      for (var i = 0; i < toolCalls.length; i++) {
        final raw = argBuffers[i]?.trim();
        if (raw == null || raw.isEmpty) continue;
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map) {
            toolCalls[i] = ToolCallInfo(
              id: toolCalls[i].id,
              name: toolCalls[i].name,
              arguments: Map<String, dynamic>.from(parsed),
            );
          }
        } catch (e) {
          debugPrint('[ai_client] 工具参数解析失败，原始内容：$raw（$e）');
        }
      }
      yield AiStreamEvent.toolCalls(toolCalls);
    } else if (contentBuffer != null) {
      yield AiStreamEvent.done(_stripTimeMarkers(contentBuffer));
    }
  }

  /// 纯文本兜底：去掉所有 tool 消息与 assistant 的 tool_calls，只保留文字消息。
  static List<Map<String, dynamic>> _stripAllToolMessages(
    List<Map<String, dynamic>> apiMessages,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final msg in apiMessages) {
      final role = msg['role'];
      if (role == 'tool') continue;
      if (role == 'assistant') {
        final copy = Map<String, dynamic>.from(msg)..remove('tool_calls');
        final text = (copy['content'] as String?)?.trim() ?? '';
        if (text.isEmpty) continue;
        out.add(copy);
      } else {
        out.add(msg);
      }
    }
    return out;
  }

  Stream<AiStreamEvent> _anthropicChat(
    List<ChatMessage> messages, {
    String? systemPrompt,
    String? memoryContext,
    String? historySummary,
  }) async* {
    final endpoint = config.endpoint ?? 'https://api.anthropic.com/v1';
    final model = config.model ?? 'claude-sonnet-5';

    final apiMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      switch (msg.role) {
        case MessageRole.user:
          apiMessages.add({
            'role': 'user',
            'content': _withTimestamp(msg.content, msg.timestamp),
          });
          break;
        case MessageRole.assistant:
          if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
            final content = <Map<String, dynamic>>[];
            if (msg.content.isNotEmpty) {
              content.add({
                'type': 'text',
                'text': _withTimestamp(msg.content, msg.timestamp),
              });
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
            apiMessages.add({
              'role': 'assistant',
              'content': _withTimestamp(msg.content, msg.timestamp),
            });
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
              },
            ],
          });
          break;
        case MessageRole.toolCall:
          // Skip - tool_use already embedded in assistant messages
          break;
        case MessageRole.system:
          apiMessages.add({'role': 'user', 'content': msg.content});
          break;
      }
    }

    _attachMemory(apiMessages, memoryContext);

    final body = <String, dynamic>{
      'model': model,
      'max_tokens': 4096,
      'messages': apiMessages,
      'stream': true,
    };

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      body['system'] = _buildSystemContent(systemPrompt, historySummary);
    }

    if (tools != null && tools!.isNotEmpty) {
      body['tools'] =
          tools!
              .map(
                (t) => {
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.inputSchema,
                },
              )
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
        yield AiStreamEvent.error(
          'Claude API 错误 (${response.statusCode}): $error',
        );
        return;
      }

      String contentBuffer = '';
      final toolCalls = <ToolCallInfo>[];

      // 同 _streamOpenAiResponse：按分片切行会丢掉跨分片的那一行。
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
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
              toolCalls.add(
                ToolCallInfo(
                  id: block['id'],
                  name: block['name'],
                  arguments: Map<String, dynamic>.from(block['input'] ?? {}),
                ),
              );
            }
          } else if (type == 'message_delta') {}
        } catch (e) {
          debugPrint('[ai_client] SSE 行解析失败（$e）：$data');
        }
      }

      if (toolCalls.isNotEmpty) {
        yield AiStreamEvent.toolCalls(toolCalls);
      } else {
        yield AiStreamEvent.done(_stripTimeMarkers(contentBuffer));
      }
    } catch (e) {
      yield AiStreamEvent.error('网络错误: $e');
    }
  }

  /// 修复消息历史：确保 assistant 的每个 tool_call_id 都有对应 tool 响应。
  /// 若缺失（工具中断/异常留下孤儿 tool_calls），补一条错误响应，
  /// 防止 DeepSeek/OpenAI 报 "insufficient tool messages"。
  static List<Map<String, dynamic>> _repairToolMessages(
    List<Map<String, dynamic>> apiMessages,
  ) {
    // 第一遍：收集所有被 assistant 引用过的 tool_call_id，以及已响应的 id
    final allCallIds = <String>{};
    final respondedIds = <String>{};
    for (final msg in apiMessages) {
      if (msg['role'] == 'assistant' && msg['tool_calls'] != null) {
        for (final tc in msg['tool_calls'] as List) {
          final id = (tc as Map)['id'] as String?;
          if (id != null && id.isNotEmpty) allCallIds.add(id);
        }
      } else if (msg['role'] == 'tool') {
        final id = msg['tool_call_id'] as String?;
        if (id != null && id.isNotEmpty) respondedIds.add(id);
      }
    }

    final completeIds = allCallIds.intersection(respondedIds);
    final orphanIds = allCallIds.difference(respondedIds);

    // 第二遍：剔除孤儿 tool_calls 及其对应的 tool 消息，
    // 保证发出的每个 assistant(tool_calls) 都有完整响应（顺序保留）。
    final cleaned = <Map<String, dynamic>>[];
    for (final msg in apiMessages) {
      if (msg['role'] == 'tool') {
        final id = msg['tool_call_id'] as String?;
        if (id != null && orphanIds.contains(id)) continue;
        cleaned.add(msg);
        continue;
      }
      if (msg['role'] == 'assistant' && msg['tool_calls'] != null) {
        final calls =
            (msg['tool_calls'] as List).where((tc) {
              final id = (tc as Map)['id'] as String?;
              return id != null && completeIds.contains(id);
            }).toList();
        if (calls.isEmpty) {
          final text = (msg['content'] as String?)?.trim() ?? '';
          if (text.isEmpty) continue; // 纯工具消息且无响应 → 整条丢弃
          final copy = Map<String, dynamic>.from(msg)..remove('tool_calls');
          cleaned.add(copy);
        } else {
          final copy = Map<String, dynamic>.from(msg)..['tool_calls'] = calls;
          cleaned.add(copy);
        }
        continue;
      }
      cleaned.add(msg);
    }
    return _reorderToolMessages(cleaned);
  }

  /// 把每组 tool 响应挪回它对应的 assistant(tool_calls) 紧后面。
  ///
  /// 服务端要求的不只是「存在响应」，而是响应必须**紧邻**排在 tool_calls 之后
  /// （报错原文：insufficient tool messages following tool_calls message）。
  /// 而模型经常在发起调用和拿到结果之间说话，那条文本消息会把两者隔开，
  /// 于是整条历史被判非法。这里按 tool_call_id 归位，不改变其余消息的相对顺序。
  static List<Map<String, dynamic>> _reorderToolMessages(
    List<Map<String, dynamic>> msgs,
  ) {
    // 先把所有 tool 消息按 id 索引出来
    final toolById = <String, Map<String, dynamic>>{};
    for (final m in msgs) {
      if (m['role'] == 'tool') {
        final id = m['tool_call_id'] as String?;
        if (id != null && id.isNotEmpty) toolById[id] = m;
      }
    }
    if (toolById.isEmpty) return msgs;

    final placed = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final m in msgs) {
      if (m['role'] == 'tool') {
        final id = m['tool_call_id'] as String?;
        // 已经跟着 assistant 放过了，这里跳过，避免重复
        if (id != null && placed.contains(id)) continue;
        out.add(m);
        continue;
      }
      out.add(m);
      if (m['role'] == 'assistant' && m['tool_calls'] != null) {
        for (final tc in m['tool_calls'] as List) {
          final id = (tc as Map)['id'] as String?;
          if (id == null) continue;
          final toolMsg = toolById[id];
          if (toolMsg != null && placed.add(id)) out.add(toolMsg);
        }
      }
    }
    return out;
  }
}

class AiStreamEvent {
  final AiEventType type;
  final String? text;
  final List<ToolCallInfo>? toolCalls;
  final String? error;

  const AiStreamEvent._({
    required this.type,
    this.text,
    this.toolCalls,
    this.error,
  });

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
