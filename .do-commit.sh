#!/bin/bash
cd ~/projects || exit 1

# 纯格式噪音，撤掉
git checkout -- lib/models/discussion_note.dart

# 临时脚本不进仓库
rm -f .crlf-fix.sh .check-noise.sh

git add -A
echo "=== 将提交 ==="
git diff --cached --stat | tail -3
echo

git commit -F - <<'MSG'
feat(ui): 按设计稿全局改版，补齐收藏与记录检索

界面诊断的五条（卡片和背景只差 2% 亮度、字阶挤在一起、三套描边规则
并存、设置页一千行直筒清单、没有任何材质层）逐条处理：

- 两套 ColorScheme：奶白 #FDF8F1 / 暖黑 #171310，卡片纯白 / #251F1A，
  次级灰只留一档（4.6:1），层次靠阴影不靠描边
- AppShadow 三档柔光（负 spreadRadius 是关键），深色一律不画
- 品牌图标入库：8 个白色 Alpha 母版 + 徽标，运行时着色，一份文件管深浅
- 主页去掉输入框（和导航胶囊两个悬浮元素互相抢）、「我想说」换白卡压淡印
- 聊天：气泡配色、时间戳收敛到跨 5 分钟、日期分隔胶囊、底层徽标水印
- 书架去白卡、封面渐变发丝线、分段筛选
- 设置 11 个平铺 section 收成 5 组，细项进二级页
- 抽屉、栖息、信 / 日记 / 一隅重做，三个内页跑通「双作者」样式

新功能：

- 收藏：MusingEntry 加 source / savedBy / messageId / conversationId，
  聊天页每条消息可收，沐 可自主收（设置里开关 + 12h 冷却 + 每次 2 条），
  双方都收过升成「一起收的」
- recall_records / save_to_corner 两个工具：记不清就去翻，说要收就真收
- 深色模式终于有入口（themeMode 一直存着，但设置页没 UI 能改）

有几处**故意和设计稿不一致**，原因都写在代码注释里：气泡尖角朝头像
（稿子那版没有头像）、「下一封信」不是「下一篇日记」（攒素材的是信，
写日记反而是攒素材的方式）、最近对话不加三种图标（Conversation 没有
类型字段）、「在线」接 currentClient 真状态、信不进检索。

徽标从规范图重切：交付包里那批是有损抠图（圆被切平、带进说明文字、
比例失真），按列墨迹密度定位后重出。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG

echo
echo "=== 提交结果 ==="
git log --oneline -3
echo
echo "=== 与远端的差距 ==="
git status -sb | head -1
