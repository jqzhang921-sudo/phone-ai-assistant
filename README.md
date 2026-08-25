# 手机 AI 助手

一个装在手机上的陪伴型 AI App。除了聊天，它有自己的日记、会写信、会把觉得值得留的话收起来，也能调用手机的相机、定位、日历、文件。

Flutter 写的，个人项目。模型走任意 OpenAI 兼容端点，密钥存在系统加密存储里，不进代码库。

<!-- TODO: 放两张截图 —— 首页 + 聊天页 -->

---

## 设计取向

这个 App 有意思的地方不在功能表，在几个「为什么这么做」。

### 不给这段关系起名字

最早的系统提示词写死了「你是用户的好朋友、日常小伙伴」。结果模型演的是它对「朋友」这个词的刻板印象：每句都要接个问题、不停找话题、还爱解说你们正在聊天这件事（「还是就等着我回你消息呢」）。

**角色标签给模型的是一个要扮演的形象，具体的行为约束给的才是怎么做。** 所以现在的人设里没有任何身份词，只有「像发微信一样短」「不用每句都接一个问题」「不知道就说不知道」这类可执行的约束。

用户可以自定义性格，但那个入口标着「TA 的性格」而不是「自定义人设」——**按钮上写什么，决定了人往里面填什么**。

### 记忆分两层，成本按话题数算

长期记忆是**话题**（`MemoryTopic`），每条有名字、一行摘要、若干条细节。

- **摘要层**常驻系统提示词，跟人设待在一起
- **细节**不常驻，模型要用时调 `open_memory` 取

于是「记得多少」和「每轮多贵」解耦了——记 50 条和记 5 条，常驻成本差的只是几十个字。

分四类：关于你 / 关于 TA / 最近 / 相处方式。每类最多 5 个话题、每话题 12 条细节，**满了明确拒绝，而不是悄悄挤掉旧的**。

增删改全走工具（`remember` / `update_memory` / `forget`），**没有自动衰减**——衰减是静悄悄的，规模小的时候和 bug 分不清。

### 提示词按「多久变一次」排序

前缀命中缓存是逐字节从头比对的，把易变的放前面会让后面整段一起作废。所以顺序是：

```
名字（几乎不变）→ 人设（const）→ 读记录的规则（const）→ 记忆摘要（记忆改了才变）
                                                        ↑ 到这里都吃缓存

最近的日记 / 收藏 / 书 / 信  →  挂在最后一条用户消息尾部，每轮重付
```

这次拆分把每轮实付的字数砍掉了四成——原来有约 800 字**从不改变的指令文字**混在数据里挂在尾部，每轮重付一次。详见 `memory_context.dart` 的文件头注释。

### 它会写东西，不只是应答

- **日记** — 用它自己的口吻记，一天可以有几篇
- **一隅** — 它说过的话，你觉得值得留的收进来；开了开关它也能自己收
- **信** — 和聊天分开的慢通道。它知道有哪些信，但**看不到内容**，内容留在信里
- **我想说** — 首页那句随口说的话

### 聊久了不该性情大变

对话超过 80 条会把早期消息折成摘要。但压缩那一刻会把几十条「它实际怎么答」的**样本**一次性抽走——人设给的是抽象规则，原文给的是实例，而实例比规则强得多。样本没了它就退回出厂习惯：更长、更助手腔。

所以保留的原文条数（45）比直觉需要的多，摘要也被要求带上「你们说话的样子」而不只是事实。**事实忘了还能用工具翻回来，语气翻不回来。**

---

## 架构

```
lib/
├── config/       主题、形状、设置、API 密钥
├── models/       对话、消息、书、日记、信、记忆话题、一隅
├── screens/      聊天、书架、栖息、日记、信、一隅、记忆、设置、性格…
├── services/
│   ├── ai_client.dart            流式对话 + 工具循环
│   ├── memory_context.dart       记忆分层（三块，去处不同）
│   ├── history_compactor.dart    历史压缩
│   ├── storage_service.dart      本地存储
│   ├── backup_service.dart       导出 / 导入
│   ├── mcp_server.dart           把手机能力开放给电脑
│   ├── external_mcp_client.dart  连外部 MCP 服务器
│   └── phone_tools/              工具实现
└── widgets/
```

**既是 MCP server 也是 client。** 手机可以把自己的工具暴露给电脑上的 agent，也能连外部 MCP 服务器把别人的工具接进来。

⚠️ MCP server **默认关闭**：它绑 `anyIPv4` 且没有任何认证，同一局域网内任何设备连上就能调用全部手机工具（拍照、定位、读文件、读日历）。真要从电脑连手机时再打开。

---

## 手机能力

模型能调的 26 个工具：

| 类别 | 工具 |
|---|---|
| 相机 / 图片 | `take_photo` `pick_image` |
| 文件 | `pick_file` `read_file` `write_file` `list_files` `read_clipboard` |
| 传感 | `get_location` `get_sensors` `get_time` `get_weather` |
| 联网 | `web_search` `search_news` |
| 日程 | `set_alarm` `set_timer` `add_calendar_event` `list_calendar_events` |
| 自己的记录 | `write_diary_entry` `recall_records` `save_to_corner` |
| 长期记忆 | `remember` `open_memory` `update_memory` `forget` |
| 微信读书 | `list_highlighted_books` `get_book_highlights` |

读日历默认「每次问」——日历数据会离开手机，保守的默认值比省事重要。

---

## 跑起来

需要 Flutter（Dart SDK `^3.7.0`）和 Android 设备或模拟器。

```bash
git clone git@github.com:jqzhang921-sudo/phone-ai-assistant.git
cd phone-ai-assistant
flutter pub get
flutter run
```

**密钥在 App 里配，不在代码里。** 装好之后：

设置 → 模型与密钥 → 对话模型，填三样：

| | |
|---|---|
| API Key | 存进 `flutter_secure_storage`（Android 加密存储），不落到 SharedPreferences |
| API Endpoint | 任意 OpenAI 兼容端点。留空用 `https://api.openai.com/v1` |
| 模型 | 比如 `gpt-4o`、`claude-sonnet-5`、`deepseek-chat` |

可选：

- **视觉识图** — 单独的识图模型。你用的模型本身能看图的话不用配
- **语音朗读** — 系统 TTS 或 ElevenLabs

出包：

```bash
flutter build apk --release
```

release 需要 `android/key.properties` 和你自己的 keystore；没配会退回 debug 签名。

数据可以在设置里整个导出成 JSON（对话、书、日记、收藏、设置），**导出文件不含 API 密钥**。

---

## 现状与边界

个人项目，按自己需要长出来的，没有做成通用产品的打算。

- **只在 Android 上跑过。** 其他平台的目录是 Flutter 默认脚手架，没验证过
- **界面全中文**，提示词也是
- 微信读书要自己提供 cookie
- MCP server 没有认证，默认关着。别在公共 WiFi 下打开
- 测试覆盖的是容易出错的地方（记忆分层、`.docx` 解析、消息序列化、压缩阈值），不是全量覆盖

## 许可

暂未指定。
