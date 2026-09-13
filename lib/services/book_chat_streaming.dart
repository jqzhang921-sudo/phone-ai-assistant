import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import 'ai_client.dart';
import 'app_providers.dart';
import 'book_chat_store.dart';
import 'mcp_server.dart';

/// 单本讨论和多本讨论共用的「发消息 → 流式 → 工具循环 → 落盘」。
///
/// ## 为什么要抽出来
///
/// 这份逻辑在 `book_chat_screen.dart` 和 `multi_book_chat_screen.dart` 里各抄了
/// 一份，几乎一字不差。抄两份的代价是修 bug 要修两遍：工具结果该 `jsonEncode`
/// 成 JSON 的那处，单本早就修好了，多本那份一直留着 `.toString()` 的老写法
/// （Map 的 Dart 格式不是合法 JSON），同一个 bug 换个入口又炸一次。抽到一处，
/// 这类分叉才不会再发生。
///
/// ## 为什么是 mixin 而不是 controller
///
/// 这份循环要不停 [setState] 更新气泡、要从 `context.read` 拿 provider。
/// 抽成一个 ChangeNotifier controller 就得把这两样都搬出去、再用监听接回来，
/// 改动面更大。mixin 直接坐在 State 上，原来怎么写现在还怎么写，只是不再有
/// 第二份。
///
/// ## 读书版要显示思考
///
/// 引导型的价值在于「它为什么这么问」——看见推理过程，比只看见那个问题有用。
/// 主 App 那边思考是附加信息，这边它本身就是内容的一部分，所以思考跟着正文
/// 一起流出来。
mixin BookChatStreaming<T extends StatefulWidget> on State<T> {
  // ===== 每个 Screen 要实现 =====

  Conversation get conversation;
  set conversation(Conversation c);

  /// 这一场的人设 + 书目资料 + 用户自己的划线。单本/多本各拼各的。
  String get systemPrompt;

  ScrollController get scrollController;
  TextEditingController get textController;

  /// 本轮开始前要等的事。单本要在发之前等书目查询落地（最多 4 秒），
  /// 多本没有，留空实现即可。
  Future<void> beforeTurn() async {}

  // ===== mixin 自己管 =====

  final Uuid _streamUuid = const Uuid();
  bool isLoading = false;

  Future<void> loadConversation() async {
    try {
      final dir = await BookChatStore.dir();
      final file = File('${dir.path}/${conversation.id}.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        final loaded = Conversation.fromJson(data);
        // 每次都刷新成人设最新版，别让旧记录里存的旧提示词盖过现在。
        loaded.systemPrompt = systemPrompt;
        setState(() => conversation = loaded);
      }
    } catch (_) {}
  }

  Future<void> saveConversation() async {
    final dir = await BookChatStore.dir();
    final file = File('${dir.path}/${conversation.id}.json');
    await file.writeAsString(jsonEncode(conversation.toJson()));
  }

  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> sendMessage() async {
    final text = textController.text.trim();
    if (text.isEmpty || isLoading) return;
    textController.clear();

    setState(() {
      conversation.messages.add(
        ChatMessage(
          id: _streamUuid.v4(),
          role: MessageRole.user,
          content: text,
        ),
      );
      isLoading = true;
    });
    scrollToBottom();
    await continueTurn();
  }

  Future<void> continueTurn() async {
    await beforeTurn();
    if (!mounted) return;

    final aiClient = context.read<AiClientProvider>().currentClient;
    final mcpServer = context.read<McpServerProvider>().server;
    final externalTools = context.read<ExternalMcpProvider>().allExternalTools;

    if (aiClient == null) {
      setState(() {
        conversation.messages.add(
          ChatMessage(
            id: _streamUuid.v4(),
            role: MessageRole.assistant,
            content: '请先在设置中配置 API Key',
          ),
        );
        isLoading = false;
      });
      return;
    }

    final allTools = [
      ...mcpServer.registeredTools.map((r) => r.tool),
      ...externalTools,
    ];
    final clientWithTools = AiClient(config: aiClient.config, tools: allTools);

    int maxRounds = 5;
    while (maxRounds > 0) {
      maxRounds--;
      String? fullResponse;
      // 思考单独攒，不进 fullResponse——那个要发回服务端当上文。
      String? thinkingBuffer;

      try {
        await for (final event in clientWithTools.chat(
          conversation.messages,
          systemPrompt: systemPrompt,
        )) {
          switch (event.type) {
            case AiEventType.thinking:
              thinkingBuffer = (thinkingBuffer ?? '') + (event.text ?? '');
              updateAssistantMessage(
                fullResponse ?? '',
                thinking: thinkingBuffer,
              );
              break;

            case AiEventType.token:
              fullResponse = (fullResponse ?? '') + (event.text ?? '');
              updateAssistantMessage(fullResponse);
              break;

            case AiEventType.toolCalls:
              updateAssistantMessage(
                fullResponse ?? '',
                toolCalls: event.toolCalls ?? [],
              );
              finalizeStreamMessage();
              for (final tc in event.toolCalls ?? []) {
                final toolResult = await executeTool(mcpServer, tc);
                conversation.messages.add(
                  ChatMessage(
                    id: _streamUuid.v4(),
                    role: MessageRole.toolResult,
                    content: toolResult,
                    toolCallId: tc.id,
                  ),
                );
              }
              fullResponse = null;
              break;

            case AiEventType.done:
              fullResponse = event.text ?? fullResponse ?? '';
              updateAssistantMessage(fullResponse);
              break;

            case AiEventType.error:
              updateAssistantMessage(
                event.error?.contains('400') == true
                    ? '抱歉，该模型暂不支持图片识别'
                    : event.error?.contains('401') == true
                    ? 'API 密钥无效或已过期，请在设置中更新'
                    : '抱歉，我遇到了一点问题，请再试一次',
              );
              finalizeStreamMessage();
              fullResponse = 'done';
              break;
          }
        }
      } catch (e) {
        updateAssistantMessage('发送消息失败: $e');
      }

      if (fullResponse != null) break;
    }

    if (!mounted) return;
    setState(() => isLoading = false);
    scrollToBottom();
    await saveConversation();
  }

  /// 执行一个工具调用，成功失败都返回 JSON。
  ///
  /// 失败路径也必须是 JSON：模型和界面都按 JSON 读，混进裸字符串
  /// （`'错误: ...'`）会让两边都拿不到结构化的失败原因。
  Future<String> executeTool(McpServer mcpServer, ToolCallInfo tc) async {
    final executor =
        mcpServer.registeredTools
            .where((r) => r.tool.name == tc.name)
            .firstOrNull
            ?.executor;
    if (executor != null) {
      return encodeToolResult(() => executor(tc.arguments), tc.name);
    }

    for (final client in context.read<ExternalMcpProvider>().clients) {
      if (client.tools.any((t) => t.name == tc.name)) {
        return encodeToolResult(
          () => client.callTool(tc.name, tc.arguments),
          tc.name,
        );
      }
    }

    return jsonEncode({'success': false, 'error': '工具 ${tc.name} 未找到'});
  }

  /// ⚠️ 一律 `jsonEncode`，不要用 `.toString()`。
  ///
  /// 工具返回的是 Map，`Map.toString()` 出来是 Dart 格式
  /// （`{success: true, query: ...}`）——**键和字符串值都没有引号，不是合法
  /// JSON**。这个字符串有两个下游：
  ///
  /// 1. 发回给模型当工具结果 → 模型只能连蒙带猜地读
  /// 2. 界面拿去 `jsonDecode` → 解析失败 → 每一次调用都被标成 failed
  ///
  /// 2026-09-07 的症状是《金枝玉叶》那场里 `Web search · 2x · 2 failed`，
  /// 展开却写着 `success: true`——照着红字判断它在瞎编，结果冤枉了它。
  Future<String> encodeToolResult(
    Future<dynamic> Function() run,
    String name,
  ) async {
    try {
      return jsonEncode(await run());
    } catch (e) {
      return jsonEncode({'success': false, 'error': '$name 执行失败: $e'});
    }
  }

  /// [thinking] 传 null = 「这次没有新的思考」，不是「清掉已有的」。
  /// 正文每来一个 token 就重建一次这条消息，不保留的话思考会被冲掉。
  void updateAssistantMessage(
    String content, {
    List<ToolCallInfo>? toolCalls,
    String? thinking,
  }) {
    setState(() {
      if (conversation.messages.isNotEmpty &&
          conversation.messages.last.role == MessageRole.assistant &&
          conversation.messages.last.id.startsWith('stream_')) {
        conversation.messages.last = ChatMessage(
          id: conversation.messages.last.id,
          role: MessageRole.assistant,
          content: content,
          toolCalls: toolCalls,
          thinking: thinking ?? conversation.messages.last.thinking,
        );
      } else {
        conversation.messages.add(
          ChatMessage(
            id: 'stream_${_streamUuid.v4()}',
            role: MessageRole.assistant,
            content: content,
            toolCalls: toolCalls,
            thinking: thinking,
          ),
        );
      }
    });
    scrollToBottom();
  }

  void finalizeStreamMessage() {
    setState(() {
      if (conversation.messages.isNotEmpty &&
          conversation.messages.last.role == MessageRole.assistant &&
          conversation.messages.last.id.startsWith('stream_')) {
        final old = conversation.messages.last;
        conversation.messages.last = ChatMessage(
          id: _streamUuid.v4(),
          role: MessageRole.assistant,
          content: old.content,
          toolCalls: old.toolCalls,
          thinking: old.thinking,
        );
      }
    });
  }
}
