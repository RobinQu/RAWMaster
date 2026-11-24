#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

struct Pixel {
  float v[4];
};
struct Step {
  uint32_t op, a, b, mask;
  float rows[3][4];
};
static_assert(sizeof(Step) == 64);
static_assert(sizeof(Pixel) == 16);

static float mix(float a, float b, float t) { return a + (b - a) * t; }
static float axis(int i) {
  return static_cast<float>((65535 * i + 31) / 63) / 65535.0f;
}
using UnaryMath = float (*)(float);
using BinaryMath = float (*)(float, float);
static float luma(const float v[3]) {
  return v[0] * 0.2126f + v[1] * 0.7152f + v[2] * 0.0722f;
}
static float cube(const Pixel *table, int cell, const float f[3], int channel) {
  auto pair = [&](int offset) {
    return mix(table[cell + offset].v[channel],
               table[cell + offset + 1].v[channel], f[0]);
  };
  return mix(mix(pair(0), pair(64), f[1]), mix(pair(4096), pair(4160), f[1]),
             f[2]);
}
static Pixel invalid_pixel() {
  const float invalid = std::numeric_limits<float>::quiet_NaN();
  return {{invalid, invalid, invalid, invalid}};
}
static Pixel filter(const Step &step, const Pixel *atlas, Pixel p,
                    UnaryMath encode) {
  const float *params = step.rows[0], *planes = step.rows[1];
  if (planes[3] == 1)
    return p;
  for (float value : p.v)
    if (!std::isfinite(value))
      return invalid_pixel();
  if (p.v[3] < 0)
    return invalid_pixel();
  if (p.v[3] > 1) {
    uint32_t bits;
    std::memcpy(&bits, &p.v[3], sizeof(bits));
    if (params[3] != 1 || bits > 0x3f800003u)
      return invalid_pixel();
    p.v[3] = 1;
  }
  if (p.v[3] < 1.0f / 65535.0f)
    return p;
  float u[3], bounded[3], f[3], residual[3], colored[3];
  int cell = 0, stride = 1;
  bool extended = false;
  for (int c = 0; c < 3; ++c) {
    u[c] = p.v[c] / p.v[3];
    if (!std::isfinite(u[c]))
      return invalid_pixel();
    bounded[c] = std::clamp(u[c], 0.0f, 1.0f);
    residual[c] = u[c] - bounded[c];
    extended |= u[c] != bounded[c];
    const float q = encode(bounded[c]);
    int i = std::clamp(static_cast<int>(std::floor(q * 63.0f)), 0, 62);
    if (i > 0 && q < axis(i))
      --i;
    if (i < 62 && q > axis(i + 1))
      ++i;
    f[c] = (q - axis(i)) / (axis(i + 1) - axis(i));
    cell += i * stride;
    stride *= 64;
  }
  const Pixel *lower = atlas + static_cast<size_t>(planes[0]) * 262144,
              *upper = atlas + static_cast<size_t>(planes[1]) * 262144;
  const float residual_y = luma(residual);
  for (int c = 0; c < 3; ++c) {
    float delta;
    if (planes[2] == 1)
      delta = cube(upper, cell, f, c) * params[0];
    else if (params[0] == 0)
      delta = cube(lower, cell, f, c);
    else
      delta = mix(cube(lower, cell, f, c), cube(upper, cell, f, c), params[0]);
    colored[c] =
        (extended && params[2] > 0)
            ? bounded[c] + delta + mix(residual[c], residual_y, params[1])
            : u[c] + delta;
  }
  if (extended && params[2] == 2) {
    const float y = luma(colored);
    for (float &value : colored)
      value = y;
  }
  for (int c = 0; c < 3; ++c)
    p.v[c] = colored[c] * p.v[3];
  return p;
}

static float decode_srgb(float encoded, BinaryMath power) {
  const float value = std::abs(encoded);
  const float decoded = value <= .04045f ? value / 12.92f : power((value + .055f) / 1.055f, 2.4f);
  return encoded < 0 ? -decoded : decoded;
}

static float signed_srgb(float value, UnaryMath encode) {
  const float v = encode(std::abs(value));
  return value < 0 ? -v : v;
}

static float contrast_v3(float value, float amount, UnaryMath gain, BinaryMath power) {
  if (value <= 0 || value >= 1 || amount == 0)
    return value;
  const float pivot = .55f;
  const float exponent = gain(1.3f * amount);
  return value < pivot ? pivot * power(value / pivot, exponent)
                       : 1.0f - (1.0f - pivot) * power((1.0f - value) / (1.0f - pivot), exponent);
}

using RGB = std::array<float, 3>;

static float mask_luma(const RGB &rgb) {
  return std::fma(rgb[0], .2126f, std::fma(rgb[1], .7152f, rgb[2] * .0722f));
}

static float mask_smooth(float lo, float hi, float x) {
  const float t = std::clamp((x - lo) / std::max(hi - lo, 1e-5f), 0.0f, 1.0f);
  return t * t * (3.0f - 2.0f * t);
}

static Pixel color_grading_v2(const Step &step, const Pixel *rows, Pixel p,
                              UnaryMath encode, BinaryMath power) {
  if (step.rows[0][1] == 0 || !std::all_of(p.v, p.v + 4, [](float v) { return std::isfinite(v); }))
    return p;
  const float alpha = p.v[3];
  if (alpha <= 0.0f)
    return {{0.0f, 0.0f, 0.0f, alpha}};
  RGB rgb;
  for (int i = 0; i < 3; ++i) {
    const float straight = p.v[i] / alpha;
    if (!std::isfinite(straight))
      return invalid_pixel();
    rgb[i] = signed_srgb(straight, encode);
  }
  const Pixel *table = rows + static_cast<size_t>(step.rows[0][0]);
  const float u = std::clamp(mask_luma(rgb), 0.0f, 1.0f);
  const float center = std::fma(-.25f, table[4].v[1], .5f);
  const float radius = table[4].v[3];
  const float shadow = std::clamp((u - table[4].v[2]) / radius, 0.0f, 1.0f);
  const float shadows = 1.0f - shadow * shadow * (3.0f - 2.0f * shadow);
  const float highlights = mask_smooth(center, center + radius, u);
  const float midtones = 1.0f - shadows - highlights;
  const float envelope = 4.0f * u * (1.0f - u);
  Pixel wheel;
  for (int i = 0; i < 4; ++i)
    wheel.v[i] = std::fma(highlights, table[2].v[i],
                         std::fma(midtones, table[1].v[i], shadows * table[0].v[i]));
  for (int i = 0; i < 3; ++i) {
    rgb[i] += std::fma(wheel.v[i], envelope, wheel.v[3]);
    rgb[i] += std::fma(table[3].v[i], envelope, table[3].v[3]);
    p.v[i] = decode_srgb(rgb[i], power) * alpha;
  }
  return p;
}

static float fract(float value) { return value - std::floor(value); }

static RGB mask_shift_hue(const RGB &rgb, float offset, UnaryMath encode, BinaryMath power) {
  RGB e;
  for (int i = 0; i < 3; ++i)
    e[i] = signed_srgb(rgb[i], encode);
  const float hi = std::max({e[0], e[1], e[2]}), lo = std::min({e[0], e[1], e[2]});
  const float d = hi - lo;
  float hue = 0.0f;
  if (d > 1e-8f) {
    if (hi == e[0]) hue = (e[1] - e[2]) / d;
    else if (hi == e[1]) hue = 2.0f + (e[2] - e[0]) / d;
    else hue = 4.0f + (e[0] - e[1]) / d;
  }
  hue = hue / 6.0f - std::floor(hue / 6.0f);
  hue = fract(hue + offset + 1.0f);
  const float saturation = hi > 1e-8f ? d / hi : 0.0f;
  const float offsets[] = {0.0f, 2.0f / 3.0f, 1.0f / 3.0f};
  RGB shifted;
  for (int i = 0; i < 3; ++i) {
    const float triangle = std::abs(fract(hue + offsets[i]) * 6.0f - 3.0f);
    const float component = std::clamp(triangle - 1.0f, 0.0f, 1.0f);
    shifted[i] = decode_srgb(hi * std::fma(component - 1.0f, saturation, 1.0f), power);
  }
  return shifted;
}

// A frozen mask attenuates each control in the original local equation.
static Pixel mask_tone_v3(const Step &step, Pixel p, float coverage, UnaryMath encode,
                          UnaryMath gain, BinaryMath power) {
  const float alpha = p.v[3];
  if (step.rows[2][0] == 0 || coverage == 0.0f || alpha <= 0.0f)
    return p;
  const float *adjust = step.rows[0], *tone = step.rows[1];
  const float exposure = gain(2.0f * adjust[0] * coverage);
  RGB rgb;
  for (int i = 0; i < 3; ++i) {
    rgb[i] = p.v[i] / alpha;
    if (!std::isfinite(rgb[i]))
      return invalid_pixel();
    rgb[i] *= exposure;
  }
  const float base = std::clamp(signed_srgb(mask_luma(rgb), encode), 0.0f, 1.0f);
  const float highlights = 1.0f + .5f * adjust[1] * mask_smooth(.5f, 1.0f, base) * coverage;
  const float shadows = 1.0f + .5f * adjust[2] * (1.0f - mask_smooth(0.0f, .5f, base)) * coverage;
  for (float &value : rgb) { value *= highlights; value *= shadows; }
  const float y = mask_luma(rgb), e = signed_srgb(y, encode), contrast = tone[0] * coverage;
  if (e > 0.0f && e < 1.0f && contrast != 0.0f) {
    const float decoded = decode_srgb(contrast_v3(e, contrast, gain, power), power);
    for (float &value : rgb)
      value = std::abs(y) > 1e-8f ? value * (decoded / y) : value + (decoded - y);
  }
  const float black = .05f * tone[2] * coverage;
  for (float &value : rgb) value = (value - black) / (1.0f - black);
  const float white = mask_smooth(.45f, 1.0f, std::clamp(signed_srgb(mask_luma(rgb), encode), 0.0f, 1.0f));
  for (float &value : rgb) value *= 1.0f + .35f * tone[1] * white * coverage;
  const float hue = tone[3] * coverage;
  if (hue != 0.0f) rgb = mask_shift_hue(rgb, hue, encode, power);
  const float gray = mask_luma(rgb), saturation = 1.0f + adjust[3] * coverage;
  for (int i = 0; i < 3; ++i)
    p.v[i] = std::fma(rgb[i] - gray, saturation, gray) * alpha;
  return p;
}

// Matches the V3 point stage in enabled-group order. RGB is straight only inside the node.
static Pixel basic_v3(const Step &step, Pixel p, UnaryMath encode, UnaryMath gain, BinaryMath power) {
  const float *light = step.rows[0], *color = step.rows[1], *mono = step.rows[2];
  const auto flags = static_cast<uint32_t>(color[3]);
  const float alpha = p.v[3];
  if (flags == 0 || alpha <= 0)
    return p;
  float c[3];
  for (int channel = 0; channel < 3; ++channel) {
    c[channel] = p.v[channel] / alpha;
    if (!std::isfinite(c[channel]))
      return invalid_pixel();
  }
  if (flags & 1) {
    const float y = luma(c), encoded = signed_srgb(y, encode);
    const float w = std::clamp(encoded, 0.0f, 1.0f);
    const float target = contrast_v3(encoded + .8f * light[0] * w * (1.0f - w), light[1], gain, power);
    const float output = decode_srgb(target, power);
    const float black = .05f * light[2];
    for (float &value : c) {
      value = std::abs(y) > 1e-8f ? value * (output / y) : value + (output - y);
      value = (value - black) / (1.0f - black);
    }
    const float t = std::clamp((std::clamp(signed_srgb(luma(c), encode), 0.0f, 1.0f) - .45f) / (1.0f - .45f), 0.0f, 1.0f);
    const float white_weight = t * t * (3.0f - 2.0f * t);
    for (float &value : c)
      value *= 1.0f + .35f * light[3] * white_weight;
  }
  if (flags & 2) {
    float e[] = {signed_srgb(c[0], encode), signed_srgb(c[1], encode), signed_srgb(c[2], encode)};
    const float y = luma(e), top = std::max({e[0], e[1], e[2]}), bottom = std::min({e[0], e[1], e[2]});
    const float saturation = std::clamp((top - bottom) / std::max(std::abs(top), 1e-4f), 0.0f, 1.0f);
    const float skin = e[0] > e[1] && e[1] > e[2] ? .5f : 1.0f;
    const float warm = e[0] > e[2] && e[1] > e[2] ? 1.0f : 0.0f;
    const float blue = std::max(0.0f, e[2] - std::max(e[0], e[1])) * (1.0f - std::clamp(y, 0.0f, 1.0f));
    const float scale = (1.0f + color[0] * (1.0f - .391f * warm)) * (1.0f + 1.35f * color[1] * (1.0f - saturation) * skin);
    const float blue_saturation[] = {-2.576f, -.364f, .447f};
    const float blue_vibrance[] = {-1.830f, -.494f, -.142f};
    for (int channel = 0; channel < 3; ++channel) {
      e[channel] = y + (e[channel] - y) * scale;
      e[channel] += blue * (color[0] * blue_saturation[channel] + color[1] * blue_vibrance[channel]);
    }
    const float tint[] = {e[0] * .0214143f + e[1] * .0479051f - e[2] * .0105798f - .0019973f,
                          0.0f, -e[0] * .0231834f - e[1] * .0894344f - e[2] * .0299565f + .0047775f};
    for (int channel = 0; channel < 3; ++channel)
      c[channel] = decode_srgb(e[channel] + 2.0f * color[2] * tint[channel], power);
  }
  if (flags & 4) {
    const float e[] = {signed_srgb(c[0], encode), signed_srgb(c[1], encode), signed_srgb(c[2], encode)};
    float gray = luma(e) + mono[0] * (.09f * (e[1] - e[0]) + .392f * (e[1] - e[2]));
    const float w = std::clamp(gray, 0.0f, 1.0f);
    gray += .8f * mono[1] * w * (1.0f - w);
    const float value = decode_srgb(contrast_v3(gray, mono[2], gain, power), power);
    return {{value * alpha, value * alpha, value * alpha, alpha}};
  }
  return {{c[0] * alpha, c[1] * alpha, c[2] * alpha, alpha}};
}

// Layout matches the Float32 tables prepared once by the Rust PCHIP operator.
static float curve_value(const Pixel *table, int channel, float x) {
  const int segments = static_cast<int>(table[0].v[channel]);
  if (segments == 0)
    return x;
  const float black = table[1].v[channel], white = table[2].v[channel];
  x = (x - black) / (white - black);
  const Pixel *segment = table + 5 + channel * 30;
  if (x < 0)
    return x + segment[1].v[2];
  for (int i = 1; i < segments && x > segment[0].v[1]; ++i)
    segment += 2;
  const float *a = segment[0].v, *b = segment[1].v;
  if (x > 1)
    return x + (a[2] + b[0] + b[1] + b[2]) - 1.0f;
  const float t = (x - a[0]) / (a[1] - a[0]);
  return ((a[2] * t + b[0]) * t + b[1]) * t + b[2];
}

static float level_value(const Pixel *table, int channel, float x) {
  const int count = static_cast<int>(table[3 + channel / 4].v[channel % 4]);
  if (count == 0)
    return x;
  const Pixel *points = table + 125 + channel * 5;
  const float *a = points[0].v;
  if (x <= a[0])
    return x + a[1] - a[0];
  for (int i = 1; i < count; ++i) {
    const float *b = points[i].v;
    if (x <= b[0])
      return mix(a[1], b[1], (x - a[0]) / (b[0] - a[0]));
    a = b;
  }
  return x + a[1] - a[0];
}

static Pixel curves_levels(const Step &step, const Pixel *tables, Pixel p,
                          UnaryMath encode, BinaryMath power) {
  const float alpha = p.v[3];
  if (step.rows[0][1] == 0 || alpha <= 0)
    return p;
  const Pixel *table = tables + static_cast<size_t>(step.rows[0][0]);
  float c[3];
  for (int i = 0; i < 3; ++i) {
    const float straight = p.v[i] / alpha;
    if (!std::isfinite(straight))
      return invalid_pixel();
    c[i] = curve_value(table, i + 1, curve_value(table, 0, signed_srgb(straight, encode)));
  }
  if (table[3].v[0] != 0) {
    const float y = luma(c);
    const float delta = level_value(table, 0, y) - y;
    for (float &value : c)
      value += delta;
  }
  for (int i = 0; i < 3; ++i) {
    const float encoded = level_value(table, i + 2, level_value(table, 1, c[i]));
    p.v[i] = decode_srgb(encoded, power) * alpha;
  }
  return p;
}

// Rust chooses at most 256 pixels for <=64 steps and 128 pixels for <=128.
// Both shapes use the same bounded tile-local scratch.
extern "C" void rm_image_reference_tile(const Step *steps, size_t step_count,
                                        const Pixel *atlas, const Pixel *parameter_rows,
                                        const Pixel *source,
                                        const float *const *masks, Pixel *output,
                                        size_t count, UnaryMath encode,
                                        UnaryMath exp2, BinaryMath power) {
  Pixel scratch[64 * 256];
  const Pixel *planes[128];
  for (size_t node = 0; node < step_count; ++node) {
    const Step &s = steps[node];
    if (s.op == 0) {
      planes[node] = source;
      continue;
    }
    if (s.op == 1) {
      continue;
    } // Mask input has a separate scalar representation.
    Pixel *dst = node + 1 == step_count ? output : scratch + node * count;
    planes[node] = dst;
    const Pixel *a = planes[s.a];
    const float *mask = (s.op == 4 || s.op == 6 || s.op == 9) ? masks[steps[s.mask].a] : nullptr;
    for (size_t i = 0; i < count; ++i) {
      const Pixel &p = a[i];
      Pixel &q = dst[i];
      q.v[3] = p.v[3];
      if (s.op == 2) {
        for (int c = 0; c < 3; ++c)
          q.v[c] = p.v[c] * s.rows[0][0];
      } else if (s.op == 3) {
        for (int c = 0; c < 3; ++c) {
          const float *r = s.rows[c];
          q.v[c] = p.v[0] * r[0] + p.v[1] * r[1] + p.v[2] * r[2];
        }
      } else if (s.op == 5) {
        q = filter(s, atlas, p, encode);
      } else if (s.op == 6) {
        if (mask[i] == 0 || p.v[3] <= 0) {
          q = p;
          continue;
        }
        const float gain = exp2(s.rows[0][0] * mask[i]);
        for (int c = 0; c < 3; ++c)
          q.v[c] = (p.v[c] / p.v[3]) * gain * p.v[3];
      } else if (s.op == 9) {
        q = mask_tone_v3(s, p, mask[i], encode, exp2, power);
      } else if (s.op == 7) {
        q = basic_v3(s, p, encode, exp2, power);
      } else if (s.op == 8) {
        q = curves_levels(s, parameter_rows, p, encode, power);
      } else if (s.op == 10) {
        q = color_grading_v2(s, parameter_rows, p, encode, power);
      } else {
        const Pixel &layer = planes[s.b][i];
        const float w = mask[i];
        if (w == 0 || w == 1) {
          q = w == 0 ? p : layer;
          continue;
        }
        for (int c = 0; c < 3; ++c)
          q.v[c] = p.v[c] + (layer.v[c] - p.v[c]) * w;
      }
    }
  }
  if (step_count == 1)
    std::memcpy(output, source, count * sizeof(Pixel));
}
