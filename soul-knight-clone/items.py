"""Pickup items and temporary buffs."""

import math
import pygame
from settings import *
from sprites import get_sprite
from utils import distance


class Item:
    """A pickup on the ground."""

    def __init__(self, x, y, item_type):
        data = ITEM_DATA[item_type]
        self.item_type = item_type
        self.name = data["name"]
        self.x = x
        self.y = y
        self.color = data["color"]
        self.size = data["size"]
        self.heal_hp = data.get("heal_hp", 0)
        self.heal_energy = data.get("heal_energy", 0)
        self.score = data.get("score", 0)
        self.alive = True
        self.bob_offset = 0
        self.bob_timer = 0

        self.rect = pygame.Rect(x - self.size, y - self.size,
                                self.size * 2, self.size * 2)

    def update(self, dt):
        # Floating bob animation
        self.bob_timer += dt
        self.bob_offset = math.sin(self.bob_timer * 3) * 3

    def apply(self, player):
        """Apply pickup effect to player. Returns True if consumed."""
        if self.heal_hp > 0:
            player.heal(self.heal_hp)
        if self.heal_energy > 0:
            player.restore_energy(self.heal_energy)
        if self.score > 0:
            player.add_score(self.score)
        return True

    def draw(self, screen, camera_x=0, camera_y=0):
        if not self.alive:
            return
        sx = self.x - camera_x
        sy = self.y - camera_y + self.bob_offset
        sprite_key = {"heart": "heart", "energy": "energy", "coin": "coin"}
        key = sprite_key.get(self.item_type)
        if key:
            sprite = get_sprite(key)
            screen.blit(sprite, (sx - sprite.get_width() // 2,
                                sy - sprite.get_height() // 2))


class Buff:
    """Temporary player buff with duration."""

    def __init__(self, name, duration, effect, color=YELLOW):
        self.name = name
        self.duration = duration
        self.timer = duration
        self.effect = effect  # "speed_boost" | "damage_boost"
        self.color = color
        self.active = True

    def update(self, dt):
        self.timer -= dt
        if self.timer <= 0:
            self.active = False

    def fraction(self):
        return max(0, self.timer / self.duration)

    def apply_start(self, player):
        """Apply buff effect to player."""
        if self.effect == "speed_boost":
            player.speed_mult = 1.5
        elif self.effect == "damage_boost":
            player.damage_mult = 2.0

    def remove(self, player):
        """Remove buff effect from player."""
        if self.effect == "speed_boost":
            player.speed_mult = 1.0
        elif self.effect == "damage_boost":
            player.damage_mult = 1.0
