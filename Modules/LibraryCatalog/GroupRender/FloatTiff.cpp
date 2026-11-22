#include "RenderMath.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <unistd.h>
#include <vector>

namespace {
void u16(std::vector<uint8_t> &h, uint16_t v) {
  h.push_back(v & 255);
  h.push_back(v >> 8);
}
void u32(std::vector<uint8_t> &h, uint32_t v) {
  u16(h, v & 65535);
  u16(h, v >> 16);
}
void tag(std::vector<uint8_t> &h, int id, int type, uint32_t count,
         uint32_t value) {
  u16(h, id);
  u16(h, type);
  u32(h, count);
  u32(h, value);
}
} // namespace

extern "C" int gr_tiff(const char *path, const float *rgb, int w, int h,
                       const uint8_t *icc, int iccLength, double *stats) {
  static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
                "TIFF float writer requires little endian samples");
  constexpr uint32_t tags = 13, rows = 64;
  if (w < 1 || h < 1 || iccLength <= 4 || !icc)
    return 1;
  uint32_t strips = (h + rows - 1) / rows, arrays = 8 + 2 + tags * 12 + 4;
  uint32_t bits = arrays, format = bits + 6, offsets = format + 6,
           lengths = offsets + 4 * strips;
  uint32_t profile = lengths + 4 * strips,
           start = (profile + uint32_t(iccLength) + 3) & ~uint32_t(3);
  uint64_t total = uint64_t(w) * h, bytes = total * 12;
  if (uint64_t(start) + bytes > UINT32_MAX)
    return 2;
  std::vector<uint8_t> header{'I', 'I'};
  u16(header, 42);
  u32(header, 8);
  u16(header, tags);
  tag(header, 256, 4, 1, w);
  tag(header, 257, 4, 1, h);
  tag(header, 258, 3, 3, bits);
  tag(header, 259, 3, 1, 1);
  tag(header, 262, 3, 1, 2);
  tag(header, 273, 4, strips, strips == 1 ? start : offsets);
  tag(header, 274, 3, 1, 1);
  tag(header, 277, 3, 1, 3);
  tag(header, 278, 4, 1, rows);
  tag(header, 279, 4, strips, strips == 1 ? uint32_t(bytes) : lengths);
  tag(header, 284, 3, 1, 1);
  tag(header, 339, 3, 3, format);
  tag(header, 34675, 7, iccLength, profile);
  u32(header, 0);
  for (int i = 0; i < 3; ++i)
    u16(header, 32);
  for (int i = 0; i < 3; ++i)
    u16(header, 3);
  for (uint32_t i = 0; i < strips; ++i)
    u32(header, start + i * rows * uint32_t(w) * 12);
  for (uint32_t i = 0; i < strips; ++i)
    u32(header, std::min(rows, uint32_t(h) - i * rows) * uint32_t(w) * 12);
  header.insert(header.end(), icc, icc + iccLength);
  header.resize(start, 0);
  double lo = std::numeric_limits<double>::infinity(), hi = -lo, highlight = 0,
         negative = 0, sum = 0;
  for (uint64_t i = 0; i < total; ++i) {
    const float *v = rgb + 3 * i;
    for (int c = 0; c < 3; ++c) {
      if (!std::isfinite(v[c]))
        return 3;
      lo = std::min(lo, double(v[c]));
      hi = std::max(hi, double(v[c]));
    }
    highlight += std::max({v[0], v[1], v[2]}) > 1;
    negative += std::min({v[0], v[1], v[2]}) < 0;
    sum += .2126 * v[0] + .7152 * v[1] + .0722 * v[2];
  }
  stats[0] = lo;
  stats[1] = hi;
  stats[2] = highlight;
  stats[3] = negative;
  stats[4] = sum / total;
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
  if (fd < 0)
    return 4;
  FILE *stream = fdopen(fd, "wb");
  if (!stream) {
    close(fd);
    unlink(path);
    return 5;
  }
  bool success =
      fwrite(header.data(), 1, header.size(), stream) == header.size() &&
      fwrite(rgb, 1, bytes, stream) == bytes && fflush(stream) == 0 &&
      fsync(fd) == 0;
  if (fclose(stream) != 0)
    success = false;
  if (!success) {
    unlink(path);
    return 6;
  }
  return 0;
}
