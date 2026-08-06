"""HUD, menus, and screen overlays."""

import math
import pygame
from settings import *


# ── Font helpers ──────────────────────────────────────────────

def _font(size=20):
    return pygame.font.Font(None, size)


def _text(screen, text, x, y, color=WHITE, size=20, center=False):
    surf = _font(size).render(text, True, color)
    if center:
        rect = surf.get_rect(center=(x, y))
        screen.blit(surf, rect)
    else:
        screen.blit(surf, (x, y))


# ═══════════════════════════════════════════════════════════════
# HUD (in-game overlay)
# ═══════════════════════════════════════════════════════════════

def draw_hud(screen, player, weapon, dungeon, floor_num):
    """Draw the in-game HUD on top of the game view."""
    sw = SCREEN_WIDTH
    margin = 12

    # ── HP bar (top-left) ──────────────────────────────────
    bar_w, bar_h = 140, 10
    bx, by = margin, margin

    # Shield bar
    shield_frac = player.shield / player.max_shield
    pygame.draw.rect(screen, DARK_GRAY, (bx, by, bar_w, bar_h))
    if shield_frac > 0:
        pygame.draw.rect(screen, (80, 160, 255),
                        (bx, by, int(bar_w * shield_frac), bar_h))
    pygame.draw.rect(screen, WHITE, (bx, by, bar_w, bar_h), 1)
    _text(screen, f"护盾 {int(player.shield)}", bx + 4, by - 14, (80, 160, 255), 14)

    # HP bar
    by2 = by + bar_h + 4
    hp_frac = player.hp / player.max_hp
    pygame.draw.rect(screen, DARK_GRAY, (bx, by2, bar_w, bar_h))
    pygame.draw.rect(screen, RED, (bx, by2, int(bar_w * hp_frac), bar_h))
    pygame.draw.rect(screen, WHITE, (bx, by2, bar_w, bar_h), 1)
    _text(screen, f"HP {int(player.hp)}/{player.max_hp}", bx + 4, by2 - 14, RED, 14)

    # ── Energy bar (below HP) ──────────────────────────────
    by3 = by2 + bar_h + 4
    energy_frac = player.energy / player.max_energy
    ebar_w = 120
    pygame.draw.rect(screen, DARK_GRAY, (bx, by3, ebar_w, 6))
    pygame.draw.rect(screen, BLUE, (bx, by3, int(ebar_w * energy_frac), 6))
    pygame.draw.rect(screen, WHITE, (bx, by3, ebar_w, 6), 1)
    _text(screen, f"能量 {int(player.energy)}", bx + 4, by3 - 12, CYAN, 12)

    # ── Weapon info (bottom-left) ──────────────────────────
    if weapon:
        wy = SCREEN_HEIGHT - 44
        _text(screen, weapon.name, margin, wy, WHITE, 20)
        # Ammo
        ammo_str = f"{int(weapon.ammo)}" if weapon.magazine_size != float("inf") else "∞"
        if weapon.reloading:
            ammo_str = "装弹中..."
            color = YELLOW
        else:
            color = WHITE if weapon.ammo > 0 else RED
        _text(screen, ammo_str, margin, wy + 22, color, 16)

    # ── Skill indicator (right of HP) ──────────────────────
    sx, sy = bx + bar_w + 20, by
    skill_ready = player.skill_cooldown_timer <= 0 and not player.skill_active
    if player.skill_active:
        skill_text = f"技能: 双持 {player.skill_timer:.1f}s"
        skill_color = (255, 200, 50)
    elif skill_ready:
        skill_text = "技能: 就绪 [右键]"
        skill_color = GREEN
    else:
        skill_text = f"技能: CD {player.skill_cooldown_timer:.1f}s"
        skill_color = GRAY
    _text(screen, skill_text, sx, sy, skill_color, 16)

    # ── Score & Floor (top-right) ──────────────────────────
    _text(screen, f"第 {floor_num} 层", sw - margin - 80, margin, WHITE, 20)
    _text(screen, f"得分: {player.score}", sw - margin - 80, margin + 22, YELLOW, 16)

    # ── Minimap (top-right) ────────────────────────────────
    if dungeon:
        mm_size = 110
        dungeon.draw_minimap(screen, sw - mm_size - margin, margin + 50, mm_size)

    # ── Buffs (below minimap) ──────────────────────────────
    # (drawn by main loop if needed — placeholder)

    # ── Crosshair dot (center of screen) ───────────────────
    pygame.draw.circle(screen, WHITE, (sw // 2, SCREEN_HEIGHT // 2), 2)


# ═══════════════════════════════════════════════════════════════
# Title screen
# ═══════════════════════════════════════════════════════════════

def draw_title_screen(screen, alpha=255):
    """Pixel-style title screen."""
    screen.fill(BLACK)

    cx, cy = SCREEN_WIDTH // 2, SCREEN_HEIGHT // 2

    # Title (simulated pixel font with large text)
    title_surf = _font(72).render("元气地牢", True, (255, 200, 50))
    title_rect = title_surf.get_rect(center=(cx, cy - 80))
    # Shadow
    shadow = _font(72).render("元气地牢", True, (80, 60, 20))
    screen.blit(shadow, (title_rect.x + 3, title_rect.y + 3))
    screen.blit(title_surf, title_rect)

    # Subtitle
    _text(screen, "SOUL DUNGEON", cx, cy - 30, WHITE, 28, center=True)
    _text(screen, "— 元气骑士风格 Roguelike —", cx, cy + 10, GRAY, 18, center=True)

    # Instructions
    instructions = [
        "WASD 移动    鼠标瞄准    左键射击",
        "右键 技能(双持)    R 换弹",
        "ESC 暂停    SPACE 开始",
    ]
    for i, line in enumerate(instructions):
        _text(screen, line, cx, cy + 60 + i * 28, GRAY, 18, center=True)

    # Blinking "press space"
    t = pygame.time.get_ticks() / 1000
    if int(t * 2) % 2 == 0:
        _text(screen, "按 SPACE 开始游戏", cx, cy + 170, YELLOW, 24, center=True)

    _text(screen, "v0.1 — 用 Python + Pygame 打造", cx, SCREEN_HEIGHT - 30, DARK_GRAY, 14, center=True)


# ═══════════════════════════════════════════════════════════════
# Pause screen
# ═══════════════════════════════════════════════════════════════

def draw_pause_screen(screen):
    """Semi-transparent pause overlay."""
    overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
    overlay.fill((0, 0, 0, 180))
    screen.blit(overlay, (0, 0))

    cx, cy = SCREEN_WIDTH // 2, SCREEN_HEIGHT // 2
    _text(screen, "游戏暂停", cx, cy - 40, WHITE, 48, center=True)
    _text(screen, "ESC 继续    Q 退出", cx, cy + 20, GRAY, 24, center=True)


# ═══════════════════════════════════════════════════════════════
# Death screen
# ═══════════════════════════════════════════════════════════════

def draw_death_screen(screen, player, floor_num):
    """Death / game over overlay."""
    overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
    overlay.fill((0, 0, 0, 200))
    screen.blit(overlay, (0, 0))

    cx, cy = SCREEN_WIDTH // 2, SCREEN_HEIGHT // 2
    _text(screen, "你死了", cx, cy - 60, RED, 56, center=True)
    _text(screen, f"到达: 第 {floor_num} 层", cx, cy - 10, WHITE, 28, center=True)
    _text(screen, f"得分: {player.score}", cx, cy + 24, YELLOW, 28, center=True)

    t = pygame.time.get_ticks() / 1000
    if int(t * 2) % 2 == 0:
        _text(screen, "按 SPACE 重新开始", cx, cy + 80, WHITE, 24, center=True)
    _text(screen, "按 Q 返回标题", cx, cy + 110, GRAY, 20, center=True)


# ═══════════════════════════════════════════════════════════════
# Floor transition
# ═══════════════════════════════════════════════════════════════

def draw_floor_transition(screen, floor_num, progress=0.5):
    """Black screen with floor number shown between levels."""
    screen.fill(BLACK)
    cx, cy = SCREEN_WIDTH // 2, SCREEN_HEIGHT // 2
    _text(screen, f"第 {floor_num} 层", cx, cy, WHITE, 56, center=True)
    _text(screen, "准备进入...", cx, cy + 50, GRAY, 24, center=True)
