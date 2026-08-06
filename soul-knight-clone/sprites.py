"""Pixel sprite generation — all art is code-drawn on pygame Surfaces."""

import pygame
from settings import *


def _surface(size, color=None):
    """Create a small surface, optionally filled."""
    s = pygame.Surface(size, pygame.SRCALPHA)
    if color:
        s.fill(color)
    return s


# ── Player sprite ─────────────────────────────────────────────

def make_player_sprite():
    """20×24 pixel knight — blue theme."""
    w, h = 24, 28
    surf = pygame.Surface((w, h), pygame.SRCALPHA)

    # Body (blue tunic)
    pygame.draw.rect(surf, (40, 80, 200), (6, 10, 12, 10))
    # Head
    pygame.draw.rect(surf, (255, 210, 150), (8, 2, 8, 9))
    # Helmet / visor
    pygame.draw.rect(surf, (60, 60, 60), (7, 2, 10, 4))
    pygame.draw.rect(surf, (100, 180, 255), (9, 3, 6, 2))
    # Legs
    pygame.draw.rect(surf, (30, 50, 150), (7, 20, 4, 6))
    pygame.draw.rect(surf, (30, 50, 150), (13, 20, 4, 6))
    # Arms
    pygame.draw.rect(surf, (40, 80, 200), (2, 12, 4, 7))
    pygame.draw.rect(surf, (40, 80, 200), (18, 12, 4, 7))
    # Belt
    pygame.draw.rect(surf, (120, 80, 40), (6, 18, 12, 3))

    return surf


# ── Enemy sprites ─────────────────────────────────────────────

def make_slime_sprite():
    """18×14 green blob."""
    w, h = 22, 16
    surf = pygame.Surface((w, h), pygame.SRCALPHA)
    c = (100, 220, 80)
    # Main blob
    pygame.draw.ellipse(surf, c, (0, 4, 22, 10))
    # Top dome
    pygame.draw.ellipse(surf, c, (3, 0, 16, 12))
    # Eyes
    pygame.draw.rect(surf, WHITE, (5, 3, 4, 4))
    pygame.draw.rect(surf, WHITE, (12, 3, 4, 4))
    pygame.draw.rect(surf, BLACK, (6, 4, 2, 2))
    pygame.draw.rect(surf, BLACK, (13, 4, 2, 2))
    return surf


def make_skeleton_sprite():
    """20×24 bone-white archer."""
    w, h = 20, 26
    surf = pygame.Surface((w, h), pygame.SRCALPHA)
    c = (210, 210, 200)
    # Skull
    pygame.draw.rect(surf, c, (6, 0, 8, 8))
    pygame.draw.rect(surf, BLACK, (8, 2, 2, 2))
    pygame.draw.rect(surf, BLACK, (11, 2, 2, 2))
    # Spine
    pygame.draw.rect(surf, c, (9, 8, 2, 8))
    # Ribs
    pygame.draw.rect(surf, c, (4, 10, 12, 2))
    pygame.draw.rect(surf, c, (5, 13, 10, 2))
    # Arms
    pygame.draw.rect(surf, c, (0, 10, 5, 2))   # left
    pygame.draw.rect(surf, c, (15, 10, 5, 2))  # right
    # Legs
    pygame.draw.rect(surf, c, (6, 18, 3, 8))
    pygame.draw.rect(surf, c, (11, 18, 3, 8))
    # Bow (tiny)
    pygame.draw.arc(surf, BROWN, (15, 8, 8, 6), 0, 3.14, 2)
    return surf


def make_bat_sprite():
    """18×12 purple bat."""
    w, h = 22, 14
    surf = pygame.Surface((w, h), pygame.SRCALPHA)
    c = (160, 60, 200)
    body_c = (100, 30, 140)
    # Wings
    pygame.draw.polygon(surf, c, [(0, 2), (8, 6), (0, 10)])
    pygame.draw.polygon(surf, c, [(22, 2), (14, 6), (22, 10)])
    # Body
    pygame.draw.ellipse(surf, body_c, (7, 4, 8, 6))
    # Eyes
    pygame.draw.rect(surf, RED, (9, 5, 2, 2))
    pygame.draw.rect(surf, RED, (12, 5, 2, 2))
    return surf


def make_boss_sprite():
    """40×44 big dark knight boss."""
    w, h = 44, 48
    surf = pygame.Surface((w, h), pygame.SRCALPHA)
    # Body (dark armor)
    pygame.draw.rect(surf, (60, 20, 20), (8, 16, 28, 18))
    # Shoulder pads
    pygame.draw.rect(surf, (80, 30, 30), (2, 14, 14, 10))
    pygame.draw.rect(surf, (80, 30, 30), (28, 14, 14, 10))
    # Head / helmet
    pygame.draw.rect(surf, (40, 15, 15), (14, 0, 16, 18))
    pygame.draw.rect(surf, (180, 40, 40), (16, 2, 12, 6))  # visor glow
    # Horns
    pygame.draw.polygon(surf, (50, 20, 20), [(12, 0), (8, 0), (12, 8)])
    pygame.draw.polygon(surf, (50, 20, 20), [(32, 0), (36, 0), (32, 8)])
    # Legs
    pygame.draw.rect(surf, (50, 15, 15), (12, 34, 8, 14))
    pygame.draw.rect(surf, (50, 15, 15), (24, 34, 8, 14))
    # Arms
    pygame.draw.rect(surf, (60, 20, 20), (0, 18, 10, 8))
    pygame.draw.rect(surf, (60, 20, 20), (34, 18, 10, 8))
    # Sword (boss holds a big one)
    pygame.draw.rect(surf, (200, 60, 60), (36, 10, 6, 26))
    pygame.draw.rect(surf, (255, 200, 100), (35, 8, 8, 4))  # guard

    return surf


# ── Projectile sprites ────────────────────────────────────────

def make_bullet_sprite(color, size=6):
    """Small round bullet."""
    s = pygame.Surface((size + 4, size + 4), pygame.SRCALPHA)
    pygame.draw.circle(s, color, (size // 2 + 2, size // 2 + 2), size // 2)
    # Bright center
    bright = tuple(min(c + 80, 255) for c in color)
    pygame.draw.circle(s, bright, (size // 2 + 2, size // 2 + 2), size // 4)
    return s


def make_laser_beam(color, width=6, length=30):
    """Laser beam segment (drawn rotated at runtime)."""
    s = pygame.Surface((length, width), pygame.SRCALPHA)
    core = tuple(min(c + 100, 255) for c in color)
    pygame.draw.rect(s, core, (0, 1, length, width - 2))
    pygame.draw.rect(s, color, (0, 0, length, width))
    return s


def make_sword_slash(color, size=60):
    """Arc-shaped slash effect."""
    s = pygame.Surface((size, size), pygame.SRCALPHA)
    cx, cy = size // 2, size // 2
    for i in range(3):
        r = size // 2 - i * 5
        alpha = 150 - i * 30
        c = (*color, alpha)
        pygame.draw.arc(s, c, (cx - r, cy - r, r * 2, r * 2), -0.8, 0.8, 4 - i)
    return s


# ── Item / pickup sprites ─────────────────────────────────────

def make_heart_sprite():
    s = pygame.Surface((14, 14), pygame.SRCALPHA)
    pygame.draw.rect(s, RED, (2, 4, 4, 4))
    pygame.draw.rect(s, RED, (8, 4, 4, 4))
    pygame.draw.rect(s, RED, (4, 2, 6, 2))
    pygame.draw.rect(s, RED, (4, 8, 6, 2))
    pygame.draw.rect(s, RED, (6, 0, 2, 2))
    pygame.draw.rect(s, RED, (6, 10, 2, 2))
    return s


def make_energy_sprite():
    s = pygame.Surface((14, 16), pygame.SRCALPHA)
    pygame.draw.rect(s, BLUE, (2, 0, 10, 16))
    pygame.draw.rect(s, (100, 180, 255), (4, 2, 6, 12))
    pygame.draw.rect(s, CYAN, (6, 4, 2, 8))
    return s


def make_coin_sprite():
    s = pygame.Surface((12, 12), pygame.SRCALPHA)
    pygame.draw.circle(s, YELLOW, (6, 6), 5)
    pygame.draw.circle(s, (255, 240, 100), (6, 6), 3)
    return s


# ── Wall / floor tiles ────────────────────────────────────────

def make_floor_tile(variant=0):
    """Floor tile with slight variation."""
    s = pygame.Surface((TILE_SIZE, TILE_SIZE))
    base = (60, 50, 40) if variant == 0 else (55, 45, 38)
    s.fill(base)
    # Random-looking speckle
    import random
    rng = random.Random(variant * 137)
    for _ in range(6):
        x, y = rng.randint(0, TILE_SIZE - 1), rng.randint(0, TILE_SIZE - 1)
        shade = rng.randint(-10, 10)
        c = (min(255, max(0, base[0] + shade)),
             min(255, max(0, base[1] + shade)),
             min(255, max(0, base[2] + shade)))
        s.set_at((x, y), c)
    return s


def make_wall_tile():
    s = pygame.Surface((TILE_SIZE, TILE_SIZE))
    s.fill(DARK_GRAY)
    # Brick pattern
    pygame.draw.rect(s, GRAY, (0, 0, TILE_SIZE, 2))
    pygame.draw.rect(s, GRAY, (0, TILE_SIZE // 2, TILE_SIZE, 2))
    pygame.draw.rect(s, GRAY, (0, 0, 2, TILE_SIZE))
    pygame.draw.rect(s, GRAY, (TILE_SIZE // 2, 0, 2, TILE_SIZE))
    pygame.draw.rect(s, GRAY, (TILE_SIZE - 2, 0, 2, TILE_SIZE))
    return s


# ── Door indicator ────────────────────────────────────────────

def make_door_marker(direction):
    """Arrow pointing in door direction."""
    s = pygame.Surface((20, 20), pygame.SRCALPHA)
    cx, cy = 10, 10
    if direction == "up":
        pts = [(10, 2), (2, 14), (18, 14)]
    elif direction == "down":
        pts = [(10, 18), (2, 6), (18, 6)]
    elif direction == "left":
        pts = [(2, 10), (14, 2), (14, 18)]
    else:  # right
        pts = [(18, 10), (6, 2), (6, 18)]
    pygame.draw.polygon(s, (255, 255, 200, 180), pts)
    return s


# ── Cache ─────────────────────────────────────────────────────

_sprite_cache = {}

def get_sprite(key, *args):
    """Get or create a cached sprite."""
    cache_key = (key, args)
    if cache_key not in _sprite_cache:
        makers = {
            "player": make_player_sprite,
            "slime": make_slime_sprite,
            "skeleton": make_skeleton_sprite,
            "bat": make_bat_sprite,
            "boss": make_boss_sprite,
            "bullet": make_bullet_sprite,
            "laser": make_laser_beam,
            "sword": make_sword_slash,
            "heart": make_heart_sprite,
            "energy": make_energy_sprite,
            "coin": make_coin_sprite,
            "floor": make_floor_tile,
            "wall": make_wall_tile,
            "door": make_door_marker,
        }
        _sprite_cache[cache_key] = makers[key](*args)
    return _sprite_cache[cache_key]
