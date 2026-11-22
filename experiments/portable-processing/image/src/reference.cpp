#include <cstddef>
#include <cstdint>
#include <cstring>

struct Pixel { float v[4]; };
struct Step { uint32_t op, a, b, mask; float rows[3][4]; };
static_assert(sizeof(Step) == 64);
static_assert(sizeof(Pixel) == 16);

// Rust bounds both step_count and count before calling. Tile-local intermediate
// values keep the CPU reference independent of the GPU compiler and its fusion.
extern "C" void rmi_reference_tile(const Step *steps, size_t step_count, const Pixel *source,
                                  const float *mask, Pixel *output, size_t count) {
    Pixel scratch[64][256];
    const Pixel *planes[64];
    for (size_t node = 0; node < step_count; ++node) {
        const Step &s = steps[node];
        if (s.op == 0) { planes[node] = source; continue; }
        if (s.op == 1) { continue; } // Mask input has a separate scalar representation.
        Pixel *dst = node + 1 == step_count ? output : scratch[node];
        planes[node] = dst;
        const Pixel *a = planes[s.a];
        for (size_t i = 0; i < count; ++i) {
            const Pixel &p = a[i];
            Pixel &q = dst[i];
            q.v[3] = p.v[3];
            if (s.op == 2) {
                for (int c = 0; c < 3; ++c) q.v[c] = p.v[c] * s.rows[0][0];
            } else if (s.op == 3) {
                for (int c = 0; c < 3; ++c) {
                    const float *r = s.rows[c];
                    q.v[c] = p.v[0] * r[0] + p.v[1] * r[1] + p.v[2] * r[2];
                }
            } else {
                const Pixel &layer = planes[s.b][i];
                const float w = mask[i];
                if (w == 0 || w == 1) { q = w == 0 ? p : layer; continue; }
                for (int c = 0; c < 3; ++c) q.v[c] = p.v[c] + (layer.v[c] - p.v[c]) * w;
            }
        }
    }
    if (step_count == 1) std::memcpy(output, source, count * sizeof(Pixel));
}
