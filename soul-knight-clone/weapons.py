"""Weapon definitions and shooting logic."""

import math
import random
import pygame
from settings import *
from utils import vec_from_angle, normalize
from sprites import get_sprite


class Projectile:
    """A bullet / laser bolt / anything that flies and hits."""

    def __init__(self, x, y, vx, vy, damage, color=YELLOW, size=6,
                 piercing=False, lifetime=5.0):
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.damage = damage
        self.color = color
        self.size = size
        self.piercing = piercing  # laser pierces enemies
        self.lifetime = lifetime
        self.alive = True
        self.hit_enemies = set()  # track pierced enemies
        self.rect = pygame.Rect(0, 0, size, size)

    def update(self, dt):
        self.x += self.vx * dt
        self.y += self.vy * dt
        self.lifetime -= dt
        if self.lifetime <= 0:
            self.alive = False
        self.rect.center = (int(self.x), int(self.y))

    def draw(self, screen, camera_x=0, camera_y=0):
        sx = self.x - camera_x
        sy = self.y - camera_y
        sprite = get_sprite("bullet", self.color, self.size)
        screen.blit(sprite, (sx - sprite.get_width() // 2,
                             sy - sprite.get_height() // 2))


class SlashEffect:
    """Melee slash visual / hitbox."""

    def __init__(self, x, y, angle, damage, size=60, duration=0.15):
        self.x = x
        self.y = y
        self.angle = angle
        self.damage = damage
        self.size = size
        self.duration = duration
        self.timer = duration
        self.alive = True
        self.hit_enemies = set()

    def update(self, dt):
        self.timer -= dt
        if self.timer <= 0:
            self.alive = False

    def draw(self, screen, camera_x=0, camera_y=0):
        sx = self.x - camera_x
        sy = self.y - camera_y
        sprite = get_sprite("sword", PURPLE, self.size)
        rot = pygame.transform.rotate(sprite, -math.degrees(self.angle) + 90)
        screen.blit(rot, (sx - rot.get_width() // 2, sy - rot.get_height() // 2))

    def hit_rect(self):
        """Return approximate hit rectangle."""
        r = self.size // 2
        return pygame.Rect(self.x - r, self.y - r, r * 2, r * 2)


class Weapon:
    """Base weapon class."""

    def __init__(self, key):
        data = WEAPON_DATA[key]
        self.key = key
        self.name = data["name"]
        self.damage = data["damage"]
        self.fire_rate = data["fire_rate"]
        self.magazine_size = data["magazine"]
        self.reload_time = data["reload_time"]
        self.bullet_speed = data["bullet_speed"]
        self.spread = data["spread"]
        self.energy_cost = data["energy_cost"]
        self.wtype = data["type"]
        self.color = data["color"]
        self.pellets = data.get("pellets", 1)
        self.range = data.get("range", 50)

        self.ammo = self.magazine_size
        self.reloading = False
        self.reload_timer = 0
        self.fire_timer = 0

    def update(self, dt):
        if self.fire_timer > 0:
            self.fire_timer -= dt

        if self.reloading:
            self.reload_timer -= dt
            if self.reload_timer <= 0:
                self.ammo = self.magazine_size
                self.reloading = False

    def can_fire(self, energy):
        """Check if weapon can fire right now."""
        if self.reloading:
            return False
        if self.fire_timer > 0:
            return False
        if self.ammo <= 0:
            return False
        if self.energy_cost > energy:
            return False
        return True

    def fire(self, x, y, angle):
        """Try to fire. Returns (list of Projectile/SlashEffect, energy_used)."""
        if self.fire_timer > 0:
            return [], 0

        self.fire_timer = self.fire_rate
        self.ammo -= 1
        if self.ammo <= 0 and self.magazine_size != float("inf"):
            self.reloading = True
            self.reload_timer = self.reload_time

        results = []
        spread_angle = self.spread * 0.5

        if self.wtype == "projectile":
            a = angle + random.uniform(-spread_angle, spread_angle)
            vx, vy = vec_from_angle(a, self.bullet_speed)
            results.append(Projectile(x, y, vx, vy, self.damage,
                                      self.color, size=6))

        elif self.wtype == "shotgun":
            for _ in range(self.pellets):
                a = angle + random.uniform(-spread_angle, spread_angle)
                vx, vy = vec_from_angle(a, self.bullet_speed)
                results.append(Projectile(x, y, vx, vy, self.damage,
                                          self.color, size=4))

        elif self.wtype == "laser":
            vx, vy = vec_from_angle(angle, self.bullet_speed)
            results.append(Projectile(x, y, vx, vy, self.damage,
                                      self.color, size=8, piercing=True,
                                      lifetime=0.5))

        elif self.wtype == "melee":
            results.append(SlashEffect(x, y, angle, self.damage, size=self.range))

        return results, self.energy_cost

    def reload_manual(self):
        """Manual reload (R key)."""
        if not self.reloading and self.ammo < self.magazine_size:
            self.reloading = True
            self.reload_timer = self.reload_time

    def ammo_fraction(self):
        """Returns 0.0 - 1.0 or 1.0 for infinite ammo."""
        if self.magazine_size == float("inf"):
            return 1.0
        return self.ammo / self.magazine_size
