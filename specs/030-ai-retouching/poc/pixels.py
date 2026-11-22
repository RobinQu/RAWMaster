"""Shared sRGB transfer and linear-light compositing for the 8-bit controls."""

import numpy as np


def linear(srgb):
    value = np.asarray(srgb, dtype=np.float64) / 255
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


def srgb8(value):
    bounded = np.clip(value, 0, 1)
    encoded = np.where(bounded <= 0.0031308, bounded * 12.92, 1.055 * bounded ** (1 / 2.4) - 0.055)
    return np.rint(encoded * 255).astype(np.uint8)


def composite(base, candidate, mask):
    alpha = np.asarray(mask, dtype=np.float64)[:, :, None] / 255
    return srgb8(linear(base) * (1 - alpha) + linear(candidate) * alpha)
