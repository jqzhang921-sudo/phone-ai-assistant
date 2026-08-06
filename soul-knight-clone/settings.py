"""Game constants and configuration."""

# Window
SCREEN_WIDTH = 960
SCREEN_HEIGHT = 640
FPS = 60
TITLE = "元气地牢 - Soul Dungeon"

# Colors (R, G, B)
BLACK = (0, 0, 0)
WHITE = (255, 255, 255)
GRAY = (128, 128, 128)
DARK_GRAY = (40, 40, 40)
RED = (220, 50, 50)
GREEN = (50, 220, 50)
BLUE = (50, 100, 220)
YELLOW = (220, 220, 50)
ORANGE = (240, 140, 30)
PURPLE = (160, 50, 220)
CYAN = (50, 200, 200)
BROWN = (139, 90, 43)
DARK_BROWN = (80, 50, 20)
LIGHT_BROWN = (180, 130, 80)

# Room
ROOM_WIDTH = 800
ROOM_HEIGHT = 560
TILE_SIZE = 40
WALL_THICKNESS = 8

# Dungeon
DUNGEON_SIZE = 7  # 7x7 grid
MIN_ROOMS = 8
MAX_ROOMS = 14
ROOM_TYPES = ["start", "combat", "combat", "combat", "treasure", "shop", "boss"]

# Player
PLAYER_SPEED = 200  # pixels per second
PLAYER_SIZE = 20
PLAYER_MAX_HP = 6
PLAYER_MAX_SHIELD = 6
PLAYER_SHIELD_REGEN = 0.5  # per second after 3s of no damage
PLAYER_SHIELD_REGEN_DELAY = 3.0
PLAYER_MAX_ENERGY = 100
PLAYER_ENERGY_REGEN = 10  # per second

# Weapons (defined in weapons.py, constants here for balancing)
WEAPON_DATA = {
    "pistol": {
        "name": "手枪",
        "damage": 3, "fire_rate": 0.4, "magazine": 12, "reload_time": 1.2,
        "bullet_speed": 500, "spread": 0.05, "energy_cost": 0,
        "type": "projectile", "color": YELLOW,
    },
    "rifle": {
        "name": "步枪",
        "damage": 2, "fire_rate": 0.15, "magazine": 25, "reload_time": 1.5,
        "bullet_speed": 600, "spread": 0.08, "energy_cost": 0,
        "type": "projectile", "color": ORANGE,
    },
    "shotgun": {
        "name": "霰弹枪",
        "damage": 2, "fire_rate": 0.7, "magazine": 6, "reload_time": 1.8,
        "bullet_speed": 450, "spread": 0.3, "energy_cost": 0, "pellets": 5,
        "type": "shotgun", "color": RED,
    },
    "laser": {
        "name": "激光枪",
        "damage": 4, "fire_rate": 0.1, "magazine": float("inf"), "reload_time": 0,
        "bullet_speed": 800, "spread": 0.0, "energy_cost": 4,
        "type": "laser", "color": CYAN,
    },
    "sword": {
        "name": "光剑",
        "damage": 5, "fire_rate": 0.5, "magazine": float("inf"), "reload_time": 0,
        "bullet_speed": 0, "spread": 0, "energy_cost": 0, "range": 50,
        "type": "melee", "color": PURPLE,
    },
}

# Enemies
ENEMY_DATA = {
    "slime": {
        "name": "史莱姆", "hp": 8, "speed": 80, "damage": 2, "size": 16,
        "color": (100, 220, 80), "behavior": "chase", "attack_range": 0,
        "attack_cooldown": 0, "projectile_speed": 0, "score": 10,
    },
    "skeleton": {
        "name": "骷髅射手", "hp": 10, "speed": 60, "damage": 1, "size": 18,
        "color": (200, 200, 190), "behavior": "keep_distance",
        "attack_range": 300, "attack_cooldown": 1.5, "projectile_speed": 300,
        "score": 15, "preferred_distance": 200,
    },
    "bat": {
        "name": "蝙蝠", "hp": 5, "speed": 140, "damage": 1, "size": 12,
        "color": (160, 60, 200), "behavior": "erratic", "attack_range": 0,
        "attack_cooldown": 0, "projectile_speed": 0, "score": 8,
    },
}

BOSS_DATA = {
    "knight_boss": {
        "name": "暗黑骑士", "hp": 80, "speed": 100, "damage": 3, "size": 36,
        "color": (180, 40, 40), "score": 200,
        "phases": [
            {"hp_threshold": 1.0, "pattern": "charge"},
            {"hp_threshold": 0.5, "pattern": "fan_shot"},
            {"hp_threshold": 0.2, "pattern": "berserk"},
        ],
    }
}

# Items
ITEM_DATA = {
    "heart": {"name": "生命之心", "heal_hp": 2, "color": RED, "size": 10},
    "energy": {"name": "能量瓶", "heal_energy": 30, "color": BLUE, "size": 10},
    "coin": {"name": "金币", "score": 50, "color": YELLOW, "size": 8},
}

# Skills
SKILL_COOLDOWN = 8.0  # seconds
SKILL_DURATION = 3.0   # seconds (dual wield / fire rate double)

# Difficulty scaling
FLOOR_ENEMY_MULTIPLIER = 0.2  # +20% HP per floor
