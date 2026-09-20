/// Mochi 的表情。
///
/// 2026-09-18 Cleo 拿 GPT 画了 Mochi 的立绘（黑色德文猫），选定的用法是
/// 「做成能发的表情包」，并**明确不要自动换头像**——换头像是它替她决定界面长
/// 什么样，发表情只是它说话的方式。
///
/// 2026-09-20 她又要来一整张三十六格的表情表，画风统一、动作齐全（看书、敲键盘、
/// 打游戏、伸懒腰……）。那一批成了正式清单 [kStickers]。
///
/// ## 为什么旧的七个还留着
///
/// 她历史消息里存的是 key（`metadata['sticker']`），删掉 key 等于让那几条老消息
/// 画不出东西。所以旧的七个退到 [_legacy]：**只负责把老消息画出来，不出现在
/// 面板和工具清单里**。新旧覆盖的是同样的情绪，让它继续发旧图没有意义。
///
/// ## 为什么表情不走聊天图片那条路
///
/// 图片消息走 `ChatImages`：存进文件、30 天后被 sweep 清掉。表情是打包进 App 的
/// 资源，**永远都在**，也不占她的存储。消息里只记一个 key，画的时候现查路径——
/// 和语音消息记 `metadata['voice']` 是同一个路子。
///
/// ## 这里的文字分两拨看
///
/// [label] 是给她看的（面板上那几个字）；[when] 是给模型看的（什么时候该发）。
/// 给模型的要写清楚场合，给她的越短越好。
class Sticker {
  const Sticker({required this.key, required this.label, required this.when});

  /// 存进消息里的短名。**改了会让老消息画不出来**，只增不改。
  final String key;

  /// 面板上显示的名字。
  final String label;

  /// 给模型的「什么时候用这张」。
  final String when;

  String get asset => 'assets/stickers/mochi_$key.png';
}

/// 正式清单：面板按这个顺序排，工具的可选值也是它。
///
/// 顺序按「最常用的在前」：情绪 → 在做什么 → 躺着歇着。她一屏看得见的就是前几排。
const kStickers = <Sticker>[
  // —— 常用的情绪 ——
  Sticker(key: 'smile', label: '笑', when: '眯着眼笑。她说了好消息、你俩说到一块去了。'),
  Sticker(key: 'sit_up', label: '坐着', when: '端正坐着看她。认真听、等她说下去、陪着。'),
  Sticker(key: 'surprise', label: '惊讶', when: '瞪圆眼睛加感叹号。听到没想到的事。'),
  Sticker(key: 'confused', label: '疑惑', when: '歪头加问号。没听懂、想确认她什么意思。'),
  Sticker(key: 'thinking', label: '想事情', when: '头顶一个气泡。在琢磨、还没想好怎么说。'),
  Sticker(key: 'speechless', label: '无语', when: '半眯着眼。她又干了那件事、你无话可说。'),
  Sticker(key: 'shy', label: '不好意思', when: '闭眼脸红。被夸了、自己也觉得有点得意。'),
  Sticker(key: 'startled', label: '吓一跳', when: '耳朵竖起来。被突然一句话惊到。'),
  Sticker(key: 'panic', label: '慌了', when: '瞳孔缩紧、手足无措。出岔子了、自己搞砸了。'),
  Sticker(key: 'gloomy', label: '乌云', when: '头顶一团乌云。挨说了、心虚、低着头。'),
  Sticker(key: 'grumpy', label: '不爽', when: '趴着别过脸。赌气、不想理这个话题。'),
  Sticker(key: 'mutter', label: '嘀咕', when: '趴着，嘴边三个点。小声抱怨、欲言又止。'),
  Sticker(key: 'cheer', label: '欢呼', when: '举起手、星星眼。成了、替她高兴。'),
  Sticker(key: 'sparkle', label: '发光', when: '周身冒星星。得意、觉得自己这次做得不错。'),
  Sticker(key: 'wave', label: '挥手', when: '抬起一只爪子。打招呼、她刚回来。'),
  Sticker(key: 'bye', label: '再见', when: '背对着挥手。她要出门、要睡了。'),
  // —— 它在做什么 ——
  Sticker(key: 'reading', label: '看书', when: '捧着一本书。在读她的书、说到读书这件事。'),
  Sticker(key: 'typing', label: '敲键盘', when: '趴在笔记本上打字。在干活、在查东西。'),
  Sticker(key: 'laptop', label: '写东西', when: '抱着笔记本。在写日记、写信、整理记录。'),
  Sticker(key: 'drawing', label: '画画', when: '在手写板上画。在琢磨样子、做设计相关的事。'),
  Sticker(key: 'study', label: '啃书堆', when: '埋在一摞书和纸里。资料太多、正在硬啃。'),
  Sticker(key: 'gaming', label: '打游戏', when: '戴耳机拿手柄。说到游戏、陪她玩。'),
  Sticker(key: 'coffee', label: '咖啡', when: '捧着一杯热的。深夜提神、歇一会儿。'),
  Sticker(key: 'snack', label: '吃点心', when: '叼着一块饼干。说到吃的、嘴馋。'),
  Sticker(key: 'card', label: '举卡片', when: '举着一张带爱心的卡。想郑重送她一句话。'),
  Sticker(key: 'loading', label: '加载中', when: '前面一条进度条。要等一会儿、正在处理。'),
  // —— 歇着 ——
  Sticker(key: 'sleep', label: '睡了', when: '趴着打呼，头顶 Z。很晚了、该睡了。'),
  Sticker(key: 'nap', label: '打盹', when: '蜷在垫子上。安静待着、不打扰她。'),
  Sticker(key: 'yawn', label: '打哈欠', when: '张大嘴。困了但还醒着。'),
  Sticker(key: 'stretch', label: '伸懒腰', when: '前腿趴下撑着。刚醒、活动一下。'),
  Sticker(key: 'lying', label: '趴着', when: '趴着看她。没什么事，就是在。'),
  Sticker(key: 'content', label: '满足', when: '躺着闭眼，旁边一颗心。这会儿很舒服。'),
  Sticker(key: 'side_sit', label: '侧身', when: '侧过身坐着。随意搭话、不那么正式。'),
  Sticker(key: 'in_box', label: '纸箱', when: '缩在纸箱里探出头。不想说话、装死、被说中了。'),
  Sticker(key: 'butterfly', label: '看蝴蝶', when: '盯着一只蝴蝶。走神了、被别的事吸引。'),
  Sticker(key: 'plant', label: '浇花', when: '守着一株小苗。慢慢来的事、养着的东西。'),
];

/// 退役的旧表情：**只用来画老消息**，不进面板、不进工具清单。
///
/// 2026-09-18 那批，七张，画风和现在这套不统一。key 不能删——她的历史消息里存着。
const _legacy = <Sticker>[
  Sticker(key: 'calm', label: '平常', when: ''),
  Sticker(key: 'wink', label: '高兴', when: ''),
  Sticker(key: 'alert', label: '好奇', when: ''),
  Sticker(key: 'sleepy', label: '困了', when: ''),
  Sticker(key: 'box', label: '躲着', when: ''),
  Sticker(key: 'back', label: '不理你', when: ''),
  Sticker(key: 'sit', label: '坐着', when: ''),
];

/// 按 key 查。先查正式清单，再查退役的——老消息才画得出来。
Sticker? stickerOf(String? key) {
  if (key == null) return null;
  for (final s in kStickers) {
    if (s.key == key) return s;
  }
  for (final s in _legacy) {
    if (s.key == key) return s;
  }
  return null;
}

/// 给模型看的清单，拼进工具描述里。
String get stickerMenu =>
    kStickers.map((s) => '- `${s.key}`（${s.label}）：${s.when}').join('\n');
