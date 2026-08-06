"""Procedural dungeon generation — grid-based rooms, BFS connectivity."""

import random
import math
from collections import deque
import pygame
from settings import *


class Room:
    """A single room in the dungeon."""

    def __init__(self, grid_x, grid_y, room_type="combat"):
        self.grid_x = grid_x
        self.grid_y = grid_y
        self.room_type = room_type
        self.cleared = False
        self.visited = False

        # Pixel position (top-left corner of room interior)
        # Room occupies part of the screen
        self.rect = pygame.Rect(0, 0, ROOM_WIDTH, ROOM_HEIGHT)

        # Doors: which directions have connections
        self.doors = {"up": False, "down": False, "left": False, "right": False}

        # Obstacles (list of pygame.Rects placed inside the room)
        self.obstacles = []
        self._generate_obstacles()

        # Enemies spawned for this room
        self.enemy_spawns = []  # list of (enemy_type, x, y)

        # Loot spawns
        self.loot_spawns = []  # list of (item_type, x, y)

        # Center of the room (where player enters)
        self.center = (ROOM_WIDTH // 2, ROOM_HEIGHT // 2)

    def _generate_obstacles(self):
        """Place random obstacles in the room."""
        rng = random.Random(hash((self.grid_x, self.grid_y, "obs")))
        count = rng.randint(2, 6)
        for _ in range(count):
            w = rng.randint(40, 80)
            h = rng.randint(40, 80)
            x = rng.randint(80, ROOM_WIDTH - w - 80)
            y = rng.randint(60, ROOM_HEIGHT - h - 60)
            self.obstacles.append(pygame.Rect(x, y, w, h))

    def spawn_enemies(self, floor_num=1):
        """Return list of Enemy instances for this room."""
        from entities import Enemy, Boss
        enemies = []

        if self.room_type == "start" or self.room_type == "shop":
            return enemies

        rng = random.Random(hash((self.grid_x, self.grid_y, floor_num)))

        if self.room_type == "boss":
            boss = Boss(ROOM_WIDTH // 2, ROOM_HEIGHT // 3, floor_num)
            enemies = [boss]
        else:
            count = rng.randint(2, 5)
            types = ["slime", "skeleton", "bat"]
            # Higher floors get more skeletons
            if floor_num >= 2:
                types.append("skeleton")
            if floor_num >= 3:
                types.append("skeleton")

            for _ in range(count):
                etype = rng.choice(types)
                ex = rng.randint(100, ROOM_WIDTH - 100)
                ey = rng.randint(80, ROOM_HEIGHT - 80)
                e = Enemy(ex, ey, etype, floor_num)
                enemies.append(e)

        return enemies

    def spawn_loot(self, floor_num=1):
        """Return list of Item instances for this room (on clear)."""
        from items import Item
        items = []
        rng = random.Random(hash((self.grid_x, self.grid_y, floor_num, "loot")))

        if self.room_type == "start":
            return items

        if self.room_type == "boss":
            # Boss drops a weapon pickup + hearts
            items.append(Item(ROOM_WIDTH // 2, ROOM_HEIGHT // 2 - 20, "heart"))
            items.append(Item(ROOM_WIDTH // 2, ROOM_HEIGHT // 2 + 20, "energy"))
            items.append(Item(ROOM_WIDTH // 2 + 30, ROOM_HEIGHT // 2, "coin"))
            return items

        # Combat / treasure rooms
        count = rng.randint(0, 2)
        loot_types = ["heart", "energy", "coin"]
        for _ in range(count):
            itype = rng.choice(loot_types)
            ix = rng.randint(120, ROOM_WIDTH - 120)
            iy = rng.randint(100, ROOM_HEIGHT - 100)
            items.append(Item(ix, iy, itype))

        return items

    def draw(self, screen, camera_x=0, camera_y=0):
        """Draw room interior."""
        from sprites import get_sprite

        # Floor — tiled
        floor_tile = get_sprite("floor", 0)
        tw, th = floor_tile.get_width(), floor_tile.get_height()
        rx, ry = self.rect.topleft
        rw, rh = self.rect.size

        for tx in range(0, rw, tw):
            for ty in range(0, rh, th):
                v = (tx // tw + ty // th) % 2
                screen.blit(get_sprite("floor", v),
                           (rx + tx - camera_x, ry + ty - camera_y))

        # Walls (border)
        wall = get_sprite("wall")
        # Top wall
        for tx in range(0, rw, tw):
            screen.blit(wall, (rx + tx - camera_x, ry - camera_y))
        # Bottom wall
        for tx in range(0, rw, tw):
            screen.blit(wall, (rx + tx - camera_x, ry + rh - th - camera_y))
        # Left wall
        for ty in range(0, rh, th):
            screen.blit(wall, (rx - camera_x, ry + ty - camera_y))
        # Right wall
        for ty in range(0, rh, th):
            screen.blit(wall, (rx + rw - tw - camera_x, ry + ty - camera_y))

        # Door openings (cutouts in walls — draw dark)
        door_color = (20, 20, 20)
        door_size = 60
        if self.doors["up"]:
            pygame.draw.rect(screen, door_color,
                           (rx + rw // 2 - door_size // 2 - camera_x,
                            ry - 4 - camera_y, door_size, 12))
        if self.doors["down"]:
            pygame.draw.rect(screen, door_color,
                           (rx + rw // 2 - door_size // 2 - camera_x,
                            ry + rh - 8 - camera_y, door_size, 12))
        if self.doors["left"]:
            pygame.draw.rect(screen, door_color,
                           (rx - 4 - camera_x,
                            ry + rh // 2 - door_size // 2 - camera_y, 12, door_size))
        if self.doors["right"]:
            pygame.draw.rect(screen, door_color,
                           (rx + rw - 8 - camera_x,
                            ry + rh // 2 - door_size // 2 - camera_y, 12, door_size))

        # Obstacles
        for obs in self.obstacles:
            pygame.draw.rect(screen, DARK_BROWN,
                           (obs.x + rx - camera_x, obs.y + ry - camera_y,
                            obs.width, obs.height))
            # Border
            pygame.draw.rect(screen, BROWN,
                           (obs.x + rx - camera_x, obs.y + ry - camera_y,
                            obs.width, obs.height), 2)

        # Door indicators
        for d in ["up", "down", "left", "right"]:
            if self.doors[d]:
                marker = get_sprite("door", d)
                if d == "up":
                    mx, my = rw // 2, 10
                elif d == "down":
                    mx, my = rw // 2, rh - 30
                elif d == "left":
                    mx, my = 10, rh // 2
                else:
                    mx, my = rw - 30, rh // 2
                screen.blit(marker, (rx + mx - camera_x, ry + my - camera_y))


class Dungeon:
    """Manages the dungeon grid and room transitions."""

    def __init__(self, size=DUNGEON_SIZE, floor_num=1):
        self.size = size
        self.floor_num = floor_num
        self.grid = {}  # (gx, gy) -> Room
        self.current_room = None
        self.start_room = None
        self.boss_room = None
        self.room_count = 0

        self._generate()

    def _generate(self):
        """Generate a connected dungeon using BFS + random pruning."""
        # Pick random start near center
        cx, cy = self.size // 2, self.size // 2
        self.grid = {}
        self.room_count = 0

        # Start room
        start = Room(cx, cy, "start")
        self.grid[(cx, cy)] = start
        self.start_room = start
        self.room_count = 1

        # BFS to generate connected rooms
        queue = deque([(cx, cy)])
        visited = {(cx, cy)}
        target_count = random.randint(MIN_ROOMS, MAX_ROOMS)

        while queue and self.room_count < target_count:
            gx, gy = queue.popleft()
            dirs = [("up", 0, -1), ("down", 0, 1), ("left", -1, 0), ("right", 1, 0)]
            random.shuffle(dirs)

            for dname, dx, dy in dirs:
                nx, ny = gx + dx, gy + dy
                if 0 <= nx < self.size and 0 <= ny < self.size:
                    if (nx, ny) not in visited:
                        # Random chance to add room
                        if random.random() < 0.65 or self.room_count < MIN_ROOMS:
                            # Determine room type
                            rtype = "combat"
                            if self.room_count == target_count - 1:
                                rtype = "boss"
                            elif random.random() < 0.1 and self.room_count > 3:
                                rtype = "treasure"
                            elif random.random() < 0.08 and self.room_count > 2:
                                rtype = "shop"

                            room = Room(nx, ny, rtype)
                            self.grid[(nx, ny)] = room
                            self.room_count += 1

                            # Connect doors
                            room.doors[self._opposite_door(dname)] = True
                            self.grid[(gx, gy)].doors[dname] = True

                            visited.add((nx, ny))
                            queue.append((nx, ny))

                            if rtype == "boss":
                                self.boss_room = room

        # Ensure we have a boss room
        if self.boss_room is None:
            # Make the farthest room the boss room
            farthest = start
            max_dist = 0
            for pos, room in self.grid.items():
                d = abs(pos[0] - cx) + abs(pos[1] - cy)
                if d > max_dist:
                    max_dist = d
                    farthest = room
            farthest.room_type = "boss"
            self.boss_room = farthest

        self.current_room = start
        self.current_room.visited = True

    def _opposite_door(self, direction):
        return {"up": "down", "down": "up", "left": "right", "right": "left"}[direction]

    def get_room(self, gx, gy):
        return self.grid.get((gx, gy))

    def get_current_room(self):
        return self.current_room

    def try_room_transition(self, player_x, player_y):
        """Check if player is at a door and transition rooms.
        Returns new room or None."""
        room = self.current_room
        margin = 20

        if player_y < margin and room.doors["up"]:
            return self._transition("up")
        if player_y > ROOM_HEIGHT - margin and room.doors["down"]:
            return self._transition("down")
        if player_x < margin and room.doors["left"]:
            return self._transition("left")
        if player_x > ROOM_WIDTH - margin and room.doors["right"]:
            return self._transition("right")
        return None

    def _transition(self, direction):
        """Move to adjacent room in given direction."""
        dx, dy = {"up": (0, -1), "down": (0, 1),
                  "left": (-1, 0), "right": (1, 0)}[direction]
        gx, gy = self.current_room.grid_x + dx, self.current_room.grid_y + dy
        new_room = self.grid.get((gx, gy))
        if new_room:
            self.current_room = new_room
            self.current_room.visited = True
        return new_room

    def room_cleared(self):
        """Mark current room as cleared."""
        self.current_room.cleared = True

    def get_player_entry_pos(self, from_direction):
        """Get player spawn position when entering from a door."""
        opposite = self._opposite_door(from_direction)
        if opposite == "up":
            return ROOM_WIDTH // 2, ROOM_HEIGHT - 60
        elif opposite == "down":
            return ROOM_WIDTH // 2, 60
        elif opposite == "left":
            return ROOM_WIDTH - 60, ROOM_HEIGHT // 2
        else:
            return 60, ROOM_HEIGHT // 2

    def draw_minimap(self, screen, offset_x, offset_y, size=120):
        """Draw a minimap showing explored rooms."""
        cell = size // self.size
        ox = offset_x
        oy = offset_y

        for (gx, gy), room in self.grid.items():
            if not room.visited:
                continue
            rx = ox + gx * cell
            ry = oy + gy * cell

            # Room color by type
            if room == self.current_room:
                color = WHITE
            elif room.room_type == "boss":
                color = RED
            elif room.room_type == "treasure":
                color = YELLOW
            elif room.room_type == "shop":
                color = CYAN
            elif room.cleared:
                color = DARK_GRAY
            else:
                color = GRAY

            pygame.draw.rect(screen, color, (rx + 1, ry + 1, cell - 2, cell - 2))

            # Connections
            if room.doors["up"] and (gx, gy - 1) in self.grid:
                if self.grid[(gx, gy - 1)].visited:
                    pygame.draw.line(screen, GRAY,
                                   (rx + cell // 2, ry),
                                   (rx + cell // 2, ry - cell // 2), 1)
            if room.doors["down"] and (gx, gy + 1) in self.grid:
                if self.grid[(gx, gy + 1)].visited:
                    pygame.draw.line(screen, GRAY,
                                   (rx + cell // 2, ry + cell),
                                   (rx + cell // 2, ry + cell + cell // 2), 1)
            if room.doors["left"] and (gx - 1, gy) in self.grid:
                if self.grid[(gx - 1, gy)].visited:
                    pygame.draw.line(screen, GRAY,
                                   (rx, ry + cell // 2),
                                   (rx - cell // 2, ry + cell // 2), 1)
            if room.doors["right"] and (gx + 1, gy) in self.grid:
                if self.grid[(gx + 1, gy)].visited:
                    pygame.draw.line(screen, GRAY,
                                   (rx + cell, ry + cell // 2),
                                   (rx + cell + cell // 2, ry + cell // 2), 1)

        # Border
        pygame.draw.rect(screen, GRAY, (ox, oy, size, size), 1)
