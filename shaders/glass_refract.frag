#version 460 core
#include <flutter/runtime_effect.glsl>

// 玻璃边缘的折射。
//
// ## 这个 shader 在做什么
//
// 真玻璃是有厚度的。光穿过一块玻璃板的边缘时会被弯折，所以透过边缘看到的
// 背景是**被推开、被放大**的，而正中间几乎不变。Cleo 看别人的 App 时说
// 「像拿了凸透镜或凹透镜那样」——说的就是这一下。
//
// 做法：离边越近，采样点就越往外偏。中间那一大块原样透过，只有边上那圈
// 在动。所以它不会把内容搅糊，只是让边「厚」起来。
//
// ## 为什么必须开 Impeller
//
// `ImageFilter.shader` 在 Skia 后端直接抛 UnsupportedError。这个仓库
// 2026-09-08 之前一直把 Impeller 关着（为了修 OPPO 上的文字渲染），
// 那期间这个效果做不出来。见 AndroidManifest 里那段注释。

uniform vec2 uSize;        // 被采样区域的尺寸（第一个 uniform 必须是 vec2）
uniform float uRadius;     // 卡片圆角，跟 Flutter 那边保持一致
uniform float uThickness;  // 边缘「玻璃有多厚」，单位是像素
uniform float uStrength;   // 折射强度：往外推多少像素
uniform sampler2D uTex;    // 底下已经模糊过的画面

out vec4 fragColor;

/// 到圆角矩形边界的有符号距离。里面为负，外面为正。
float roundedBoxSDF(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 uv = FlutterFragCoord().xy;
    vec2 center = uSize * 0.5;
    vec2 p = uv - center;

    float d = roundedBoxSDF(p, center, uRadius);   // 边界上为 0，中心为负

    // 只在最外圈 uThickness 内起作用；再往里一律 0。
    // smoothstep 让它从边缘平滑地衰减到中间，不会出现一道硬边。
    float edge = 1.0 - smoothstep(-uThickness, 0.0, d);
    edge = clamp(edge, 0.0, 1.0);

    // 越靠近边、推得越狠，而且用平方让中间几乎完全不受影响——
    // 线性衰减会让整张卡片都轻微变形，看着像糊了而不是像玻璃。
    float amount = edge * edge;

    // 往外推：方向是从中心指向当前像素。
    vec2 dir = length(p) > 0.001 ? normalize(p) : vec2(0.0);
    vec2 offset = dir * amount * uStrength;

    // 采样点夹在自己这块区域里，别去取到外面（会取到黑边）。
    vec2 sampleUv = clamp(uv + offset, vec2(0.5), uSize - 0.5);

    fragColor = texture(uTex, sampleUv / uSize);
}
