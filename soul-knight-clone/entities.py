"""Player, Enemy, and Boss classes."""

import math
import random
import pygame
from settings import *
from utils import distance, angle_between, normalize, circle_collision, clamp
from sprites import get_sprite


# ═══════════════════════════════════════════════════════════════
# Player
# ═══════════════════════════════════════════════════════════════

class Player:
    def __init__(self, x, y):
        self.x = x
        self.y = y
        self.width = PLAYER_SIZE
        self.height = PLAYER_SIZE + 4
        self.speed = PLAYER_SPEED

        # Health & shield
        self.max_hp = PLAYER_MAX_HP
        self.hp = PLAYER_MAX_HP
        self.max_shield = PLAYER_MAX_SHIELD
        self.shield = PLAYER_MAX_SHIELD
        self.shield_regen_timer = 0  # counts up from last hit

        # Energy
        self.max_energy = PLAYER_MAX_ENERGY
        self.energy = PLAYER_MAX_ENERGY

        # Weapon
        self.weapon = None  # set by Game
        self.projectiles = []

        # Skill
        self.skill_cooldown = SKILL_COOLDOWN
        self.skill_cooldown_timer = 0
        self.skill_active = False
        self.skill_timer = 0

        # Stats
        self.alive = True
        self.damage_mult = 1.0
        self.speed_mult = 1.0
        self.fire_rate_mult = 1.0
        self.score = 0
        self.facing_angle = 0  # radians, for aiming

        self.rect = pygame.Rect(x, y, self.width, self.height)

    @property
    def pos(self):
        return (self.x, self.y)

    def take_damage(self, amount):
        self.shield_regen_timer = 0
        remaining = amount
        # Shield absorbs first
        if self.shield > 0:
            absorbed = min(self.shield, remaining)
            self.shield -= absorbed
            remaining -= absorbed
        # HP takes the rest
        if remaining > 0:
            self.hp -= remaining
            if self.hp <= 0:
                self.hp = 0
                self.alive = False

    def heal(self, amount):
        self.hp = min(self.max_hp, self.hp + amount)

    def restore_energy(self, amount):
        self.energy = min(self.max_energy, self.energy + amount)

    def add_score(self, points):
        self.score += points

    def get_input(self):
        """Read keyboard / mouse state."""
        keys = pygame.key.get_pressed()
        mouse = pygame.mouse.get_pressed()
        mx, my = pygame.mouse.get_pos()
        return keys, mouse, mx, my

    def update(self, dt, keys, mouse_buttons, mouse_pos, room_rect):
        if not self.alive:
            return

        # ── Movement ───────────────────────────────────────
        dx, dy = 0, 0
        if keys[pygame.K_w] or keys[pygame.K_UP]:
            dy -= 1
        if keys[pygame.K_s] or keys[pygame.K_DOWN]:
            dy += 1
        if keys[pygame.K_a] or keys[pygame.K_LEFT]:
            dx -= 1
        if keys[pygame.K_d] or keys[pygame.K_RIGHT]:
            dx += 1

        if dx != 0 or dy != 0:
            dx, dy = normalize(dx, dy)
        speed = self.speed * self.speed_mult

        self.x += dx * speed * dt
        self.y += dy * speed * dt

        # Room bounds
        margin = 10
        self.x = clamp(self.x, room_rect.left + margin,
                      room_rect.right - self.width - margin)
        self.y = clamp(self.y, room_rect.top + margin,
                      room_rect.bottom - self.height - margin)

        self.rect.topleft = (int(self.x), int(self.y))

        # ── Aiming ─────────────────────────────────────────
        # Convert screen mouse to world position (camera offset handled by caller)
        self.facing_angle = angle_between(
            (self.x + self.width / 2, self.y + self.height / 2),
            mouse_pos
        )

        # ── Shield regen ───────────────────────────────────
        if self.shield < self.max_shield:
            self.shield_regen_timer += dt
            if self.shield_regen_timer >= PLAYER_SHIELD_REGEN_DELAY:
                self.shield = min(self.max_shield,
                                  self.shield + PLAYER_SHIELD_REGEN * dt)

        # ── Energy regen ───────────────────────────────────
        if self.energy < self.max_energy:
            self.energy = min(self.max_energy,
                              self.energy + PLAYER_ENERGY_REGEN * dt)

        # ── Skill ──────────────────────────────────────────
        if self.skill_active:
            self.skill_timer -= dt
            if self.skill_timer <= 0:
                self.skill_active = False
                self.fire_rate_mult = 1.0
        if self.skill_cooldown_timer > 0:
            self.skill_cooldown_timer = max(0, self.skill_cooldown_timer - dt)

        # ── Weapon ─────────────────────────────────────────
        if self.weapon:
            actual_fire_rate = self.weapon.fire_rate / self.fire_rate_mult
            self.weapon.fire_rate = actual_fire_rate
            self.weapon.update(dt)

        # ── Projectiles ────────────────────────────────────
        for p in self.projectiles:
            p.update(dt)
        self.projectiles = [p for p in self.projectiles if p.alive]

    def try_shoot(self, camera_x=0, camera_y=0):
        """Attempt to fire current weapon. Returns list of new projectiles."""
        if not self.weapon or not self.alive:
            return []

        if not self.weapon.can_fire(self.energy):
            return []

        cx = self.x + self.width / 2
        cy = self.y + self.height / 2
        projs, energy_cost = self.weapon.fire(cx, cy, self.facing_angle)
        self.energy -= energy_cost
        self.projectiles.extend(projs)
        return projs

    def use_skill(self):
        """Activate character skill if off cooldown."""
        if self.skill_cooldown_timer > 0 or self.skill_active:
            return False
        self.skill_active = True
        self.skill_timer = SKILL_DURATION
        self.skill_cooldown_timer = SKILL_COOLDOWN
        self.fire_rate_mult = 2.0  # double fire rate
        return True

    def reload_weapon(self):
        if self.weapon:
            self.weapon.reload_manual()

    def draw(self, screen, camera_x=0, camera_y=0):
        if not self.alive:
            return
        sx = self.x - camera_x
        sy = self.y - camera_y
        sprite = get_sprite("player")
        screen.blit(sprite, (sx, sy))

        # Skill active indicator (glow)
        if self.skill_active:
            glow = pygame.Surface((sprite.get_width() + 6, sprite.get_height() + 6),
                                  pygame.SRCALPHA)
            glow.fill((255, 200, 50, 80))
            screen.blit(glow, (sx - 3, sy - 3))

    def get_center(self):
        return self.x + self.width / 2, self.y + self.height / 2


# ═══════════════════════════════════════════════════════════════
# Enemies
# ═══════════════════════════════════════════════════════════════

class Enemy:
    """Generic enemy with type-specific behavior."""

    def __init__(self, x, y, enemy_type, floor_num=1):
        data = ENEMY_DATA[enemy_type]
        self.enemy_type = enemy_type
        self.name = data["name"]
        self.x = float(x)
        self.y = float(y)
        self.speed = data["speed"]
        self.damage = data["damage"]
        self.size = data["size"]
        self.color = data["color"]
        self.behavior = data["behavior"]
        self.attack_range = data["attack_range"]
        self.attack_cooldown = data["attack_cooldown"]
        self.projectile_speed = data["projectile_speed"]
        self.preferred_distance = data.get("preferred_distance", 200)
        self.score_value = data["score"]

        # Scale HP by floor
        self.max_hp = int(data["hp"] * (1 + FLOOR_ENEMY_MULTIPLIER * (floor_num - 1)))
        self.hp = self.max_hp

        self.alive = True
        self.attack_timer = random.uniform(0, self.attack_cooldown)
        self.projectiles = []

        # Erratic movement state (bat)
        self.erratic_angle = random.uniform(0, math.pi * 2)
        self.erratic_timer = 0
        self.erratic_interval = random.uniform(0.5, 1.5)

        self.rect = pygame.Rect(0, 0, self.size, self.size)
        self.rect.center = (int(x), int(y))

    @property
    def pos(self):
        return (self.x, self.y)

    def take_damage(self, amount):
        self.hp -= amount
        if self.hp <= 0:
            self.hp = 0
            self.alive = False

    def update(self, dt, player, room_rect):
        if not self.alive:
            return

        px, py = player.x + player.width / 2, player.y + player.height / 2
        ex, ey = self.x, self.y
        dist = distance((ex, ey), (px, py))
        angle = angle_between((ex, ey), (px, py))

        dx, dy = 0, 0

        if self.behavior == "chase":
            # Move directly toward player
            if dist > self.size + player.width / 2:
                dx, dy = normalize(px - ex, py - ey)
                dx *= self.speed
                dy *= self.speed

        elif self.behavior == "keep_distance":
            # Try to stay at preferred distance
            if dist < self.preferred_distance - 20:
                # Too close, back away
                dx, dy = normalize(ex - px, ey - py)
                dx *= self.speed
                dy *= self.speed
            elif dist > self.preferred_distance + 20:
                # Too far, approach
                dx, dy = normalize(px - ex, py - ey)
                dx *= self.speed
                dy *= self.speed

        elif self.behavior == "erratic":
            # Erratic flight pattern
            self.erratic_timer += dt
            if self.erratic_timer >= self.erratic_interval:
                self.erratic_angle = random.uniform(0, math.pi * 2)
                self.erratic_timer = 0
                self.erratic_interval = random.uniform(0.3, 1.2)
            dx, dy = math.cos(self.erratic_angle) * self.speed, \
                     math.sin(self.erratic_angle) * self.speed
            # Also bias toward player slightly
            px_nudge = (px - ex) * 0.3
            py_nudge = (py - ey) * 0.3
            dx += px_nudge
            dy += py_nudge

        self.x += dx * dt
        self.y += dy * dt

        # Room bounds
        margin = 10
        self.x = clamp(self.x, room_rect.left + margin,
                      room_rect.right - self.size - margin)
        self.y = clamp(self.y, room_rect.top + margin,
                      room_rect.bottom - self.size - margin)

        self.rect.center = (int(self.x), int(self.y))

        # ── Attack ────────────────────────────────────────
        self.attack_timer -= dt
        if self.attack_range > 0 and dist < self.attack_range:
            if self.attack_timer <= 0:
                self.attack_timer = self.attack_cooldown
                self._ranged_attack(px, py)

        # Update enemy projectiles
        for p in self.projectiles:
            p.update(dt)
        self.projectiles = [p for p in self.projectiles if p.alive]

    def _ranged_attack(self, target_x, target_y):
        """Fire a projectile at the player."""
        from weapons import Projectile
        a = angle_between((self.x, self.y), (target_x, target_y))
        vx, vy = math.cos(a) * self.projectile_speed, \
                 math.sin(a) * self.projectile_speed
        self.projectiles.append(
            Projectile(self.x, self.y, vx, vy, self.damage,
                       color=RED, size=5, lifetime=3.0)
        )

    def draw(self, screen, camera_x=0, camera_y=0):
        if not self.alive:
            return
        sx = self.x - camera_x
        sy = self.y - camera_y
        sprite = get_sprite(self.enemy_type)
        screen.blit(sprite, (sx, sy))

        # HP bar (only when damaged)
        if self.hp < self.max_hp:
            bar_w = self.size + 4
            bar_h = 3
            bar_x = sx - (bar_w - self.size) // 2
            bar_y = sy - 6
            frac = self.hp / self.max_hp
            pygame.draw.rect(screen, DARK_GRAY, (bar_x, bar_y, bar_w, bar_h))
            pygame.draw.rect(screen, RED, (bar_x, bar_y, int(bar_w * frac), bar_h))


class Boss(Enemy):
    """Boss enemy with multi-phase attack patterns."""

    def __init__(self, x, y, floor_num=1):
        data = BOSS_DATA["knight_boss"]
        self.enemy_type = "boss"
        self.name = data["name"]
        self.x = float(x)
        self.y = float(y)
        self.speed = data["speed"]
        self.damage = data["damage"]
        self.size = data["size"]
        self.color = data["color"]
        self.behavior = "chase"
        self.attack_range = 350
        self.attack_cooldown = 1.0
        self.projectile_speed = 250
        self.preferred_distance = 150
        self.score_value = data["score"]

        self.max_hp = int(data["hp"] * (1 + FLOOR_ENEMY_MULTIPLIER * (floor_num - 1)))
        self.hp = self.max_hp

        self.alive = True
        self.attack_timer = 2.0  # initial delay
        self.projectiles = []
        self.rect = pygame.Rect(0, 0, self.size, self.size)
        self.rect.center = (int(x), int(y))

        # Boss-specific
        self.phases = data["phases"]
        self.current_phase = 0
        self.charge_target = None
        self.charge_speed = 350
        self.phase_timer = 0
        self.bullet_pattern_timer = 0

    def _get_current_pattern(self):
        hp_frac = self.hp / self.max_hp
        pattern = "charge"  # default
        for phase in self.phases:
            if hp_frac <= phase["hp_threshold"]:
                pattern = phase["pattern"]
        return pattern

    def take_damage(self, amount):
        super().take_damage(amount)
        # Flash white briefly (handled by draw)

    def update(self, dt, player, room_rect):
        if not self.alive:
            return

        px, py = player.x + player.width / 2, player.y + player.height / 2
        ex, ey = self.x, self.y
        dist = distance((ex, ey), (px, py))
        angle = angle_between((ex, ey), (px, py))

        pattern = self._get_current_pattern()
        self.phase_timer += dt

        dx, dy = 0, 0

        if pattern == "charge":
            # Move toward player, occasionally dash
            if dist > 60:
                dx, dy = normalize(px - ex, py - ey)
                dx *= self.speed
                dy *= self.speed
            self.attack_timer -= dt
            if self.attack_timer <= 0:
                self.attack_timer = 1.5
                # Charge attack: burst of speed toward player
                self.charge_target = (px, py)
            if self.charge_target:
                cx, cy = self.charge_target
                cd = distance((ex, ey), (cx, cy))
                if cd < 30:
                    self.charge_target = None
                else:
                    dx, dy = normalize(cx - ex, cy - ey)
                    dx *= self.charge_speed
                    dy *= self.charge_speed

        elif pattern == "fan_shot":
            # Keep distance and fire fan patterns
            if dist < 120:
                dx, dy = normalize(ex - px, ey - py)
                dx *= self.speed * 0.8
                dy *= self.speed * 0.8
            elif dist > 250:
                dx, dy = normalize(px - ex, py - ey)
                dx *= self.speed
                dy *= self.speed
            self.bullet_pattern_timer -= dt
            if self.bullet_pattern_timer <= 0:
                self.bullet_pattern_timer = 0.8
                self._fan_attack(px, py)

        elif pattern == "berserk":
            # Fast chase + melee range
            if dist > 40:
                dx, dy = normalize(px - ex, py - ey)
                dx *= self.speed * 1.6
                dy *= self.speed * 1.6
            self.attack_timer -= dt
            if self.attack_timer <= 0:
                self.attack_timer = 0.5
                # Multiple fast shots
                for a_off in [-0.3, 0, 0.3]:
                    self._single_shot(px, py, a_off)

        self.x += dx * dt
        self.y += dy * dt

        # Stay in room
        margin = 10
        self.x = clamp(self.x, room_rect.left + margin,
                      room_rect.right - self.size - margin)
        self.y = clamp(self.y, room_rect.top + margin,
                      room_rect.bottom - self.size - margin)

        self.rect.center = (int(self.x), int(self.y))

        for p in self.projectiles:
            p.update(dt)
        self.projectiles = [p for p in self.projectiles if p.alive]

    def _fan_attack(self, px, py):
        from weapons import Projectile
        base_angle = angle_between((self.x, self.y), (px, py))
        for offset in [-0.5, -0.25, 0, 0.25, 0.5]:
            a = base_angle + offset
            vx, vy = math.cos(a) * self.projectile_speed, \
                     math.sin(a) * self.projectile_speed
            self.projectiles.append(
                Projectile(self.x, self.y, vx, vy, self.damage,
                          color=(220, 80, 40), size=6, lifetime=3.0)
            )

    def _single_shot(self, px, py, angle_offset=0):
        from weapons import Projectile
        a = angle_between((self.x, self.y), (px, py)) + angle_offset
        vx, vy = math.cos(a) * self.projectile_speed * 1.3, \
                 math.sin(a) * self.projectile_speed * 1.3
        self.projectiles.append(
            Projectile(self.x, self.y, vx, vy, self.damage,
                      color=(220, 80, 40), size=5, lifetime=3.0)
        )

    def draw(self, screen, camera_x=0, camera_y=0):
        if not self.alive:
            return
        sx = self.x - camera_x
        sy = self.y - camera_y
        sprite = get_sprite("boss")
        screen.blit(sprite, (sx, sy))

        # Boss HP bar — always visible, at top of screen
        bar_w = 300
        bar_h = 12
        bar_x = camera_x + SCREEN_WIDTH // 2 - bar_w // 2
        bar_y = camera_y + 16
        frac = self.hp / self.max_hp
        pygame.draw.rect(screen, DARK_GRAY, (bar_x, bar_y, bar_w, bar_h))
        hp_color = RED if frac > 0.3 else (255, 50, 50)
        pygame.draw.rect(screen, hp_color, (bar_x, bar_y, int(bar_w * frac), bar_h))
        pygame.draw.rect(screen, WHITE, (bar_x, bar_y, bar_w, bar_h), 2)

        # Boss name
        font = pygame.font.Font(None, 24)
        name_surf = font.render(self.name, True, WHITE)
        screen.blit(name_surf, (bar_x, bar_y - 18))
