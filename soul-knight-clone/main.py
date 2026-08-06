#!/usr/bin/env python3
"""元气地牢 (Soul Dungeon) — A Soul Knight-inspired roguelike dungeon crawler."""

import sys
import math
import random
import pygame
from settings import *
from sprites import get_sprite
from utils import distance, circle_collision, point_in_rect, clamp
from entities import Player, Enemy, Boss
from weapons import Weapon, Projectile, SlashEffect
from dungeon import Dungeon, Room
from items import Item, Buff
import ui


# ═══════════════════════════════════════════════════════════════
# Game class — state machine and main loop
# ═══════════════════════════════════════════════════════════════

class Game:
    def __init__(self):
        pygame.init()
        self.screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
        pygame.display.set_caption(TITLE)
        self.clock = pygame.time.Clock()
        self.running = True

        # State machine
        self.state = "TITLE"  # TITLE | PLAYING | PAUSED | DEAD | FLOOR_TRANSITION

        # Game objects (created on new game)
        self.player = None
        self.dungeon = None
        self.current_room = None
        self.enemies = []
        self.items = []
        self.buffs = []
        self.floor_num = 1
        self.max_floors = 3  # floors to beat

        # Camera offset (so room aligns to screen)
        self.camera_x = 0
        self.camera_y = 0

        # Floor transition
        self.transition_timer = 0
        self.transition_duration = 2.0

        # Screen shake
        self.shake_timer = 0
        self.shake_intensity = 0

        # Particles (simple list of (x, y, vx, vy, life, color))
        self.particles = []

    # ── Game flow ──────────────────────────────────────────

    def new_game(self):
        """Start a fresh run."""
        self.floor_num = 1
        self.buffs = []
        self._start_floor()

    def _start_floor(self):
        """Generate a new floor."""
        self.dungeon = Dungeon(DUNGEON_SIZE, self.floor_num)
        room = self.dungeon.current_room

        # Player spawns at room center
        px, py = room.center
        self.player = Player(px, py)
        # Give starting weapon on first floor
        if self.floor_num == 1:
            self.player.weapon = Weapon("pistol")

        self.enemies = room.spawn_enemies(self.floor_num)
        self.items = room.spawn_loot(self.floor_num)
        self._update_camera()

    def _update_camera(self):
        """Center camera on current room."""
        room = self.dungeon.current_room
        self.camera_x = room.rect.x
        self.camera_y = room.rect.y

    def _next_floor(self):
        """Advance to next floor."""
        self.floor_num += 1
        if self.floor_num > self.max_floors:
            # Victory!
            self.state = "DEAD"  # reuse death screen for now
            self.player.alive = False  # but they won
            return
        self._start_floor()
        # Give weapon upgrade on new floor
        self._upgrade_weapon()

    def _upgrade_weapon(self):
        """Give the player a random new weapon each floor."""
        weapons = ["pistol", "rifle", "shotgun", "laser", "sword"]
        key = random.choice(weapons)
        self.player.weapon = Weapon(key)

    # ── Collision detection ────────────────────────────────

    def _handle_collisions(self, dt):
        """Check all projectile-enemy, enemy-player, item-player collisions."""
        player = self.player
        room = self.dungeon.current_room

        # Player projectiles vs enemies
        for proj in player.projectiles[:]:
            if not proj.alive:
                continue
            for enemy in self.enemies[:]:
                if not enemy.alive:
                    continue
                if enemy in proj.hit_enemies:
                    continue

                # Check collision based on projectile type
                hit = False
                if isinstance(proj, Projectile):
                    hit = circle_collision(
                        (proj.x, proj.y), proj.size,
                        (enemy.x, enemy.y), enemy.size)
                elif isinstance(proj, SlashEffect):
                    hit = circle_collision(
                        (enemy.x, enemy.y), enemy.size,
                        (proj.x, proj.y), proj.size // 2)

                if hit:
                    dmg = int(proj.damage * player.damage_mult)
                    enemy.take_damage(dmg)
                    proj.hit_enemies.add(enemy)
                    if not proj.piercing:
                        proj.alive = False
                    # Spawn hit particles
                    self._spawn_particles(enemy.x, enemy.y, 3, RED)
                    # Screen shake on boss hit
                    if isinstance(enemy, Boss):
                        self.shake_timer = 0.1
                        self.shake_intensity = 4

                    if not enemy.alive:
                        player.add_score(enemy.score_value)
                        self._spawn_particles(enemy.x, enemy.y, 10, enemy.color)
                        self._check_room_clear()
                    break  # one hit per frame per projectile

        # Enemy projectiles vs player
        all_enemy_projs = []
        for enemy in self.enemies:
            all_enemy_projs.extend(enemy.projectiles)

        for proj in all_enemy_projs:
            if not proj.alive:
                continue
            hit = circle_collision(
                (proj.x, proj.y), proj.size,
                (player.x + player.width / 2, player.y + player.height / 2),
                player.width / 2)
            if hit:
                player.take_damage(proj.damage)
                proj.alive = False
                self._spawn_particles(player.x + player.width / 2,
                                     player.y + player.height / 2, 5, RED)
                self.shake_timer = 0.15
                self.shake_intensity = 6

        # Enemy contact damage vs player
        for enemy in self.enemies:
            if not enemy.alive:
                continue
            if enemy.behavior in ("chase", "erratic"):
                hit = circle_collision(
                    (enemy.x, enemy.y), enemy.size,
                    (player.x + player.width / 2, player.y + player.height / 2),
                    player.width / 2 + 4)
                if hit:
                    # Apply damage with cooldown (simple: track last hit time)
                    if not hasattr(enemy, '_last_contact_hit'):
                        enemy._last_contact_hit = 0
                    enemy._last_contact_hit -= dt
                    if enemy._last_contact_hit <= 0:
                        enemy._last_contact_hit = 0.5  # half second cooldown
                        player.take_damage(enemy.damage)
                        self._spawn_particles(player.x + player.width / 2,
                                             player.y + player.height / 2, 3, RED)

        # Items vs player
        for item in self.items[:]:
            if not item.alive:
                continue
            hit = distance((item.x, item.y),
                          (player.x + player.width / 2,
                           player.y + player.height / 2)) < 30
            if hit:
                item.apply(player)
                item.alive = False
                self.items.remove(item)

    def _check_room_clear(self):
        """Check if all enemies in current room are dead."""
        if any(e.alive for e in self.enemies):
            return
        # Room cleared
        room = self.dungeon.current_room
        if not room.cleared:
            self.dungeon.room_cleared()
            # Chance for a buff drop when room is cleared
            if random.random() < 0.25:
                buff_type = random.choice(["speed_boost", "damage_boost"])
                self.buffs.append(Buff(
                    "速度提升" if buff_type == "speed_boost" else "伤害翻倍",
                    10.0, buff_type,
                    CYAN if buff_type == "speed_boost" else ORANGE
                ))
                self.buffs[-1].apply_start(self.player)

            # Boss clear → floor complete
            if room.room_type == "boss":
                # Brief delay then transition
                self.transition_timer = self.transition_duration
                self.state = "FLOOR_TRANSITION"

    # ── Room transition ────────────────────────────────────

    def _check_room_transition(self):
        """Check if player is at a door and switch rooms."""
        player = self.player
        room = self.dungeon.current_room

        # Only allow transition if current room is cleared or it's the start room
        if not room.cleared and room.room_type != "start":
            return

        new_room = self.dungeon.try_room_transition(player.x, player.y)
        if new_room:
            # Determine which direction we came from
            for d in ["up", "down", "left", "right"]:
                if room.doors[d]:
                    adj = {"up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)}[d]
                    ngx, ngy = room.grid_x + adj[0], room.grid_y + adj[1]
                    if (ngx, ngy) in self.dungeon.grid and \
                       self.dungeon.grid[(ngx, ngy)] == new_room:
                        px, py = new_room.get_player_entry_pos(d)
                        player.x, player.y = px, py
                        break

            # Load new room enemies if not cleared
            self.enemies = []
            if not new_room.cleared:
                self.enemies = new_room.spawn_enemies(self.floor_num)
            # Load loot
            if new_room.cleared:
                self.items = []
            else:
                self.items = new_room.spawn_loot(self.floor_num)

            self._update_camera()

    # ── Particles ──────────────────────────────────────────

    def _spawn_particles(self, x, y, count, color):
        for _ in range(count):
            angle = random.uniform(0, math.pi * 2)
            speed = random.uniform(50, 200)
            vx = math.cos(angle) * speed
            vy = math.sin(angle) * speed
            life = random.uniform(0.2, 0.6)
            self.particles.append([x, y, vx, vy, life, color])

    def _update_particles(self, dt):
        for p in self.particles[:]:
            p[0] += p[2] * dt
            p[1] += p[3] * dt
            p[4] -= dt
            if p[4] <= 0:
                self.particles.remove(p)

    # ── Main update ────────────────────────────────────────

    def update(self, dt):
        """Update game logic."""
        # Cap dt to avoid physics explosions
        dt = min(dt, 0.1)

        if self.state == "FLOOR_TRANSITION":
            self.transition_timer -= dt
            if self.transition_timer <= 0:
                self._next_floor()
                self.state = "PLAYING"
            return

        if self.state != "PLAYING":
            return

        player = self.player
        keys = pygame.key.get_pressed()
        mouse_buttons = pygame.mouse.get_pressed()
        mx, my = pygame.mouse.get_pos()

        # Convert mouse position to world coordinates
        world_mx = mx + self.camera_x
        world_my = my + self.camera_y

        # Update player
        room_rect = self.dungeon.current_room.rect
        player.update(dt, keys, mouse_buttons, (world_mx, world_my), room_rect)

        # Shooting
        if mouse_buttons[0]:  # Left click
            player.try_shoot(self.camera_x, self.camera_y)

        # Skill
        if mouse_buttons[2]:  # Right click
            player.use_skill()

        # Reload
        if keys[pygame.K_r]:
            player.reload_weapon()

        # Update enemies
        for enemy in self.enemies:
            enemy.update(dt, player, room_rect)

        # Update items
        for item in self.items:
            item.update(dt)

        # Update buffs
        for buff in self.buffs[:]:
            buff.update(dt)
            if not buff.active:
                buff.remove(player)
                self.buffs.remove(buff)

        # Collisions
        self._handle_collisions(dt)

        # Room transition
        self._check_room_transition()

        # Particles
        self._update_particles(dt)

        # Shake decay
        if self.shake_timer > 0:
            self.shake_timer = max(0, self.shake_timer - dt)

        # Death check
        if not player.alive:
            self.state = "DEAD"

    # ── Main draw ──────────────────────────────────────────

    def draw(self):
        """Draw everything based on current state."""
        screen = self.screen
        screen.fill(BLACK)

        if self.state == "TITLE":
            ui.draw_title_screen(screen)

        elif self.state in ("PLAYING", "PAUSED", "DEAD", "FLOOR_TRANSITION"):
            self._draw_game_world()

            if self.state == "PAUSED":
                ui.draw_pause_screen(screen)
            elif self.state == "DEAD":
                ui.draw_death_screen(screen, self.player, self.floor_num)
            elif self.state == "FLOOR_TRANSITION":
                progress = 1.0 - (self.transition_timer / self.transition_duration)
                ui.draw_floor_transition(screen, self.floor_num, progress)

        pygame.display.flip()

    def _draw_game_world(self):
        """Draw the game world (room + entities + HUD)."""
        screen = self.screen

        # Screen shake offset
        shake_x, shake_y = 0, 0
        if self.shake_timer > 0:
            shake_x = random.randint(-self.shake_intensity, self.shake_intensity)
            shake_y = random.randint(-self.shake_intensity, self.shake_intensity)

        # Draw current room
        room = self.dungeon.current_room
        room.draw(screen, self.camera_x + shake_x, self.camera_y + shake_y)

        # Draw items
        for item in self.items:
            item.draw(screen, self.camera_x + shake_x, self.camera_y + shake_y)

        # Draw enemies
        for enemy in self.enemies:
            enemy.draw(screen, self.camera_x + shake_x, self.camera_y + shake_y)

        # Draw enemy projectiles
        for enemy in self.enemies:
            for proj in enemy.projectiles:
                proj.draw(screen, self.camera_x + shake_x, self.camera_y + shake_y)

        # Draw player
        self.player.draw(screen, self.camera_x + shake_x, self.camera_y + shake_y)

        # Draw player projectiles
        for proj in self.player.projectiles:
            proj.draw(screen, self.camera_x + shake_x, self.camera_y + shake_y)

        # Draw particles
        for p in self.particles:
            sx = int(p[0] - self.camera_x - shake_x)
            sy = int(p[1] - self.camera_y - shake_y)
            alpha = int(255 * (p[4] / 0.6))
            c = (*p[5], alpha)
            s = pygame.Surface((4, 4), pygame.SRCALPHA)
            s.fill(c)
            screen.blit(s, (sx - 2, sy - 2))

        # Draw HUD
        ui.draw_hud(screen, self.player, self.player.weapon,
                    self.dungeon, self.floor_num)

        # Draw active buff indicators
        for i, buff in enumerate(self.buffs):
            bx = SCREEN_WIDTH - 130
            by = SCREEN_HEIGHT - 30 - i * 22
            frac = buff.fraction()
            bar_w = 100
            pygame.draw.rect(screen, DARK_GRAY, (bx, by, bar_w, 6))
            pygame.draw.rect(screen, buff.color,
                           (bx, by, int(bar_w * frac), 6))
            pygame.draw.rect(screen, WHITE, (bx, by, bar_w, 6), 1)
            ui._text(screen, buff.name, bx, by - 14, buff.color, 12)

        # Door lock indicator (room not cleared)
        if room.room_type != "start" and not room.cleared:
            ui._text(screen, "消灭所有敌人才能通过!", SCREEN_WIDTH // 2,
                    SCREEN_HEIGHT - 20, RED, 18, center=True)

    # ── Input handling ─────────────────────────────────────

    def handle_events(self):
        """Process pygame events."""
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self.running = False

            elif event.type == pygame.KEYDOWN:
                if self.state == "TITLE":
                    if event.key == pygame.K_SPACE:
                        self.state = "PLAYING"
                        self.new_game()
                    elif event.key == pygame.K_ESCAPE:
                        self.running = False

                elif self.state == "PLAYING":
                    if event.key == pygame.K_ESCAPE:
                        self.state = "PAUSED"
                    # Weapon switch keys
                    elif event.key == pygame.K_1:
                        self.player.weapon = Weapon("pistol")
                    elif event.key == pygame.K_2:
                        self.player.weapon = Weapon("rifle")
                    elif event.key == pygame.K_3:
                        self.player.weapon = Weapon("shotgun")
                    elif event.key == pygame.K_4:
                        self.player.weapon = Weapon("laser")
                    elif event.key == pygame.K_5:
                        self.player.weapon = Weapon("sword")

                elif self.state == "PAUSED":
                    if event.key == pygame.K_ESCAPE:
                        self.state = "PLAYING"
                    elif event.key == pygame.K_q:
                        self.state = "TITLE"

                elif self.state == "DEAD":
                    if event.key == pygame.K_SPACE:
                        self.state = "PLAYING"
                        self.new_game()
                    elif event.key == pygame.K_q:
                        self.state = "TITLE"

    # ── Run ────────────────────────────────────────────────

    def run(self):
        """Main game loop."""
        while self.running:
            dt = self.clock.tick(FPS) / 1000.0

            self.handle_events()
            self.update(dt)
            self.draw()

        pygame.quit()
        sys.exit()


# ═══════════════════════════════════════════════════════════════
# Entry point
# ═══════════════════════════════════════════════════════════════

if __name__ == "__main__":
    game = Game()
    game.run()
