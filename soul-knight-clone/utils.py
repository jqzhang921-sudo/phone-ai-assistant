"""Utility functions: math, collision detection."""

import math
import pygame


def distance(a, b):
    """Euclidean distance between two (x, y) tuples."""
    return math.hypot(a[0] - b[0], a[1] - b[1])


def angle_between(a, b):
    """Angle in radians from point a to point b."""
    return math.atan2(b[1] - a[1], b[0] - a[0])


def vec_from_angle(angle, speed):
    """Return (vx, vy) from angle and speed."""
    return math.cos(angle) * speed, math.sin(angle) * speed


def normalize(vx, vy):
    """Return unit vector."""
    mag = math.hypot(vx, vy)
    if mag == 0:
        return 0, 0
    return vx / mag, vy / mag


def rect_collision(r1, r2):
    """Check if two pygame.Rects overlap."""
    return r1.colliderect(r2)


def circle_collision(c1, r1, c2, r2):
    """Circle-circle collision. c1, c2 are (x, y) centers; r1, r2 are radii."""
    return distance(c1, c2) < r1 + r2


def clamp(value, lo, hi):
    return max(lo, min(hi, value))


def lerp(a, b, t):
    return a + (b - a) * t


def point_in_rect(px, py, rect):
    return rect.collidepoint(px, py)
