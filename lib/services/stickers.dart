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
/// ⚠️ **它看不见这些图**，只读得到下面这几行字（key、[label]、[when]）。
/// 所以每条 [when] 都写成「画的是什么 ‖ 什么时候发」：前半句让它对得上画面，
/// 后半句给它场合。它挑得准不准，全看这几行写得对不对——2026-09-21 Cleo 问
/// 「AI 是不是只能看到表情包的名字」，就是这件事。
///
/// 容易混的几组特意写开了：惊讶 / 吓一跳、不爽 / 嘀咕、睡了 / 打盹 / 满足、
/// 挥手 / 告别。写新的时候也照这个规矩，别只写情绪词。
const kStickers = <Sticker>[
  // —— 常用的情绪 ——
  Sticker(key: 'smile', label: '笑', when: '眯眼笑，脸颊泛红 ‖ 她说了好消息、你俩想到一块去了。最常用的一张。'),
  Sticker(
    key: 'sit_up',
    label: '坐着',
    when: '端正坐着看她，戴着项圈 ‖ 认真在听、等她说下去。没有特别情绪时的默认。',
  ),
  Sticker(
    key: 'surprise',
    label: '惊讶',
    when: '眼睛瞪圆，头顶一个感叹号 ‖ 听到意料之外的事。是「诶？真的吗」，不是被吓到。',
  ),
  Sticker(
    key: 'startled',
    label: '吓一跳',
    when: '耳朵支棱、身子一缩，旁边几道黑线 ‖ 被突然一句话吓到。比惊讶更急、带点受惊。',
  ),
  Sticker(key: 'confused', label: '疑惑', when: '歪着头，头顶一个问号 ‖ 没听懂、想确认她指的是什么。'),
  Sticker(key: 'thinking', label: '想事情', when: '侧着身，头顶一个空想泡 ‖ 在琢磨、还没想好怎么说。'),
  Sticker(
    key: 'speechless',
    label: '无语',
    when: '半眯着眼平视 ‖ 她又那样了、你无话可说。带笑的那种无语，不是生气。',
  ),
  Sticker(
    key: 'shy',
    label: '害羞',
    when: '闭眼偏头，脸边几颗心 ‖ 害羞、被夸了、被说中心事、有点受用又不想承认。',
  ),
  Sticker(key: 'panic', label: '慌了', when: '瞳孔缩紧、周身抖线 ‖ 出岔子了、自己搞砸了、来不及了。'),
  Sticker(key: 'gloomy', label: '乌云', when: '低着头，头顶一团乱糟糟的乌云 ‖ 挨说了、心虚、自己也知道理亏。'),
  Sticker(
    key: 'grumpy',
    label: '不爽',
    when: '趴着把脸别开，不看她 ‖ 赌气、不想接这个话题。**不说话**的那种不爽。',
  ),
  Sticker(
    key: 'mutter',
    label: '嘀咕',
    when: '趴着，嘴边一个省略号气泡 ‖ 小声嘟囔、欲言又止。想说但没全说出口。',
  ),
  Sticker(key: 'cheer', label: '欢呼', when: '举起两只前爪，张嘴，眼里是星星 ‖ 成了！替她高兴，最外放的一张。'),
  Sticker(
    key: 'sparkle',
    label: '得意',
    when: '端坐着，周身冒星星 ‖ 刚做完一件挺漂亮的事，自己也满意。比欢呼收敛。',
  ),
  Sticker(key: 'wave', label: '挥手', when: '坐着抬起一只前爪 ‖ 打招呼、她刚回来、开个头。'),
  Sticker(
    key: 'bye',
    label: '告别',
    when: '背对着她，尾巴翘起，旁边一颗心 ‖ 她要出门、要睡了。目送的意思，不是生气走开。',
  ),
  // —— 它在做什么 ——
  Sticker(key: 'reading', label: '看书', when: '双爪捧着一本摊开的书 ‖ 在读她的书、聊到看书这件事。'),
  Sticker(key: 'typing', label: '敲键盘', when: '趴在一台黑色笔记本前打字 ‖ 正在干活、在查东西、让她等一下。'),
  Sticker(
    key: 'laptop',
    label: '写东西',
    when: '抱着一台银色笔记本 ‖ 在写日记、写信、整理记录这类「它自己的事」。',
  ),
  Sticker(
    key: 'drawing',
    label: '写写画画',
    when: '拿笔在手写板上画 ‖ 任何「在纸上动手」的事：写作业、写东西、画画、琢磨样子。',
  ),
  Sticker(key: 'study', label: '啃资料', when: '趴在一摞书和散开的纸中间 ‖ 要读的东西太多、正在硬啃。'),
  Sticker(key: 'gaming', label: '打游戏', when: '戴着耳机、捧着手柄 ‖ 聊到游戏、陪她玩。'),
  Sticker(key: 'coffee', label: '咖啡', when: '双爪捧着一只冒热气的杯子 ‖ 深夜提神、歇一会儿、陪她熬着。'),
  Sticker(key: 'snack', label: '吃东西', when: '嘴里叼着一块饼干 ‖ 聊到吃的：吃饭、点心、嘴馋、歇下来垫一口。'),
  Sticker(
    key: 'card',
    label: '喜欢',
    when:
        '坐着举起一张画着心的卡片 ‖ 表示喜欢：喜欢她说的这件事、喜欢这个东西，'
        '或者想郑重地送她一句话。别滥用，用多了就不郑重了。',
  ),
  Sticker(
    key: 'loading',
    label: '加载中',
    when: '身前一条进度条，上面三个点 ‖ 要等一会儿、正在处理、马上就好。',
  ),
  // —— 歇着 ——
  Sticker(
    key: 'sleep',
    label: '睡了',
    when: '趴着闭眼，头顶 Z 和一颗心 ‖ 很晚了、道晚安。**这张就是无声的晚安**，配它别再补一句。',
  ),
  Sticker(key: 'nap', label: '打盹', when: '蜷在一张软垫上，旁边一颗心 ‖ 安静待着、不打扰她，但还在。'),
  Sticker(key: 'yawn', label: '打哈欠', when: '仰头张大嘴 ‖ 困了但还醒着、硬撑着陪她。'),
  Sticker(key: 'stretch', label: '伸懒腰', when: '前腿趴低、屁股撅起来伸展 ‖ 刚醒、活动一下、准备开始。'),
  Sticker(key: 'lying', label: '趴着', when: '侧趴着看她，很放松 ‖ 没什么事，就是在。'),
  Sticker(key: 'content', label: '满足', when: '躺倒闭着眼，旁边一颗心 ‖ 这会儿很舒服、很受用。'),
  Sticker(key: 'side_sit', label: '侧身', when: '侧过身回头看 ‖ 随口搭话、不那么正式的时候。'),
  Sticker(key: 'in_box', label: '纸箱', when: '缩在纸箱里只探出头和耳朵 ‖ 不想说话、装死、被说中了。'),
  Sticker(
    key: 'butterfly',
    label: '看蝴蝶',
    when: '仰头盯着一只飞过的蝴蝶 ‖ 走神了、被别的事勾走了注意力。',
  ),
  Sticker(
    key: 'plant',
    label: '养着的',
    when: '守着一株刚冒头的小苗 ‖ 急不来、需要时间养的事（她的计划、习惯、正在学的东西）。',
  ),
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
