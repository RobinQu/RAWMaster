// CUDA memory/concurrency probe for the 041 scene worker.
//
// The NVIDIA Vulkan ICD on the validation host returns
// VK_ERROR_INCOMPATIBLE_DRIVER, so this probe uses CUDA to measure the actual
// VRAM footprint of the same 9-node, tiled 60MP scene graph. It is a memory
// measurement fallback, not the production Vulkan backend.

#include <cuda_runtime.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#define CUDA_CHECK(expr)                                                       \
  do {                                                                         \
    cudaError_t error = (expr);                                                \
    if (error != cudaSuccess) {                                                \
      std::fprintf(stderr, "%s:%d: %s -> %s\n", __FILE__, __LINE__, #expr,     \
                   cudaGetErrorString(error));                                 \
      std::exit(3);                                                            \
    }                                                                          \
  } while (0)

namespace {

constexpr float kAP1Y[3] = {0.2722287168f, 0.6740817658f, 0.0536895174f};

struct Args {
  std::string input;
  std::string reference;
  int width = 0;
  int height = 0;
  int tile = 2048;
  int jobs = 1;
  int cache_mb = 0;
  bool full_stage = false;
};

struct Curve {
  float2 p0;
  float2 p1;
  float2 p2;
  int count;
};

struct Job {
  int id = 0;
  float4* input = nullptr;
  float4* output = nullptr;
  float4* tile_input = nullptr;
  float4* img[5] = {};
  float* cov[4] = {};
  unsigned char* cache = nullptr;
  // Full-stage allocations, representing RAW decode and display delivery.
  unsigned short* mosaic = nullptr;
  unsigned char* saturation = nullptr;
  float4* hdr = nullptr;
  float4* sdr = nullptr;
  unsigned short* pq = nullptr;
  cudaStream_t stream = nullptr;
  cudaEvent_t start = nullptr;
  cudaEvent_t stop = nullptr;
  double ms = 0;
};

__device__ __forceinline__ float clamp01(float value) {
  return fminf(1.0f, fmaxf(0.0f, value));
}

__device__ __forceinline__ float smoothstep01(float edge0, float edge1, float value) {
  float t = clamp01((value - edge0) / (edge1 - edge0));
  return t * t * (3.0f - 2.0f * t);
}

__global__ void coverage_linear(float* out, int width, int height, int origin_x,
                                int origin_y, int geometry_width, int geometry_height,
                                float sx, float sy, float ex, float ey) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x >= width || y >= height) return;
  float2 q = make_float2((origin_x + x + 0.5f) / geometry_width,
                         (origin_y + y + 0.5f) / geometry_height);
  float2 start = make_float2(sx, sy);
  float2 axis = make_float2(ex - sx, ey - sy);
  float value = ((q.x - start.x) * axis.x + (q.y - start.y) * axis.y) /
                (axis.x * axis.x + axis.y * axis.y);
  out[y * width + x] = clamp01(value);
}

__global__ void coverage_radial(float* out, int width, int height, int origin_x,
                                int origin_y, int geometry_width, int geometry_height,
                                float cx, float cy, float rx, float ry, float feather) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x >= width || y >= height) return;
  float2 q = make_float2((origin_x + x + 0.5f) / geometry_width,
                         (origin_y + y + 0.5f) / geometry_height);
  float dx = (q.x - cx) / rx;
  float dy = (q.y - cy) / ry;
  float radius = sqrtf(dx * dx + dy * dy);
  float value = feather == 0.0f
                    ? (radius <= 1.0f ? 1.0f : 0.0f)
                    : 1.0f - smoothstep01(1.0f - feather, 1.0f, radius);
  out[y * width + x] = clamp01(value);
}

__global__ void coverage_combine(const float* a, const float* b, float* out,
                                 int width, int height, int mode) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x >= width || y >= height) return;
  int index = y * width + x;
  float av = a[index];
  float bv = b[index];
  float value = mode == 0 ? av + bv * (1.0f - av)
                          : mode == 1 ? av * (1.0f - bv) : av * bv;
  out[index] = clamp01(value);
}

__global__ void coverage_adjust(const float* in, float* out, int width, int height,
                                float strength, int inverted) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x >= width || y >= height) return;
  int index = y * width + x;
  float value = inverted ? 1.0f - in[index] : in[index];
  out[index] = clamp01(value * strength);
}

__device__ __forceinline__ float exposure_delta(float ev, Curve curve) {
  if (curve.count == 0) return 0.0f;
  if (ev <= curve.p0.x) return curve.p0.y - curve.p0.x;
  if (curve.count == 1) return curve.p0.y - curve.p0.x;
  if (ev <= curve.p1.x) {
    float t = (ev - curve.p0.x) / (curve.p1.x - curve.p0.x);
    return (curve.p0.y - curve.p0.x) +
           t * ((curve.p1.y - curve.p1.x) - (curve.p0.y - curve.p0.x));
  }
  if (curve.count == 2) return curve.p1.y - curve.p1.x;
  if (ev <= curve.p2.x) {
    float t = (ev - curve.p1.x) / (curve.p2.x - curve.p1.x);
    return (curve.p1.y - curve.p1.x) +
           t * ((curve.p2.y - curve.p2.x) - (curve.p1.y - curve.p1.x));
  }
  return curve.p2.y - curve.p2.x;
}

__global__ void corrector(const float4* in, const float* mask, float4* out, int width,
                         int height, float ev, float strength, Curve curve,
                         int has_mask) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x >= width || y >= height) return;
  int index = y * width + x;
  float4 a = in[index];
  if (a.w <= 0.0f) {
    out[index] = make_float4(0, 0, 0, 0);
    return;
  }
  float m = has_mask ? mask[index] : 1.0f;
  float weight = strength * m;
  float gain = exp2f(ev);
  float3 rgb = make_float3(a.x, a.y, a.z);
  float luma = rgb.x * kAP1Y[0] + rgb.y * kAP1Y[1] + rgb.z * kAP1Y[2];
  if (curve.count > 0 && luma > 0.0f) {
    float delta = log2f(luma) - log2f(a.w) + log2f(gain);
    gain *= exp2f(exposure_delta(delta, curve));
  }
  rgb.x *= 1.0f + (gain - 1.0f) * weight;
  rgb.y *= 1.0f + (gain - 1.0f) * weight;
  rgb.z *= 1.0f + (gain - 1.0f) * weight;
  out[index] = make_float4(rgb.x, rgb.y, rgb.z, a.w);
}

__global__ void parallel_mix(const float4* base, const float4* light,
                             const float4* dark, float4* out, int width, int height,
                             float light_weight, float dark_weight) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x >= width || y >= height) return;
  int index = y * width + x;
  float4 b = base[index];
  float4 l = light[index];
  float4 d = dark[index];
  float4 first = make_float4(b.x + light_weight * (l.x - b.x),
                             b.y + light_weight * (l.y - b.y),
                             b.z + light_weight * (l.z - b.z), b.w);
  float4 second = make_float4(first.x + dark_weight * (d.x - b.x),
                              first.y + dark_weight * (d.y - b.y),
                              first.z + dark_weight * (d.z - b.z), first.w);
  out[index] = second;
}

__global__ void group_mix(const float4* base, const float4* child, float4* out,
                          int width, int height, float strength) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;
  if (x >= width || y >= height) return;
  int index = y * width + x;
  float4 b = base[index];
  float4 c = child[index];
  out[index] = make_float4(b.x + strength * (c.x - b.x),
                           b.y + strength * (c.y - b.y),
                           b.z + strength * (c.z - b.z), b.w);
}

dim3 block_2d() { return dim3(16, 16); }

dim3 grid_2d(int width, int height) {
  return dim3((width + 15) / 16, (height + 15) / 16);
}

void print_oom(int jobs, int tile, int cache_mb, bool full_stage,
               double baseline_mb, double logical_mb, int failed_job) {
  std::printf(
      "{\"success\":false,\"jobs\":%d,\"allocatedJobs\":%d,\"tile\":%d,"
      "\"cacheMB\":%d,\"stage\":\"%s\",\"baselineMB\":%.1f,\"logicalMB\":%.1f,"
      "\"failedJob\":%d}\n",
      jobs, failed_job, tile, cache_mb, full_stage ? "full" : "scene", baseline_mb,
      logical_mb, failed_job);
}

bool cuda_alloc(void** pointer, size_t bytes, size_t* logical, int job, int jobs,
                int tile, int cache_mb, bool full_stage, double baseline_mb,
                int* failed_job) {
  cudaError_t error = cudaMalloc(pointer, bytes);
  if (error != cudaSuccess) {
    std::fprintf(stderr, "cudaMalloc job %d bytes %zu: %s\n", job, bytes,
                 cudaGetErrorString(error));
    *failed_job = job;
    print_oom(jobs, tile, cache_mb, full_stage, baseline_mb,
              *logical / (1024.0 * 1024.0), job);
    return false;
  }
  *logical += bytes;
  return true;
}

void free_job(Job& job) {
  auto free_pointer = [](auto** pointer) {
    if (*pointer) {
      cudaFree(*pointer);
      *pointer = nullptr;
    }
  };
  free_pointer(&job.input);
  free_pointer(&job.output);
  free_pointer(&job.tile_input);
  for (auto& pointer : job.img) free_pointer(&pointer);
  for (auto& pointer : job.cov) free_pointer(&pointer);
  free_pointer(&job.cache);
  free_pointer(&job.mosaic);
  free_pointer(&job.saturation);
  free_pointer(&job.hdr);
  free_pointer(&job.sdr);
  free_pointer(&job.pq);
  if (job.stream) cudaStreamDestroy(job.stream);
  if (job.start) cudaEventDestroy(job.start);
  if (job.stop) cudaEventDestroy(job.stop);
}

void run_job(Job& job, const Args& args) {
  cudaSetDevice(0);
  CUDA_CHECK(cudaEventRecord(job.start, job.stream));
  Curve curve{make_float2(-4.0f, -3.5f), make_float2(0.0f, 0.0f),
              make_float2(3.0f, 2.0f), 3};
  for (int y = 0; y < args.height; y += args.tile) {
    int tile_height = std::min(args.tile, args.height - y);
    for (int x = 0; x < args.width; x += args.tile) {
      int tile_width = std::min(args.tile, args.width - x);
      size_t src_pitch = static_cast<size_t>(args.width) * 16;
      size_t dst_pitch = static_cast<size_t>(tile_width) * 16;
      char* source = reinterpret_cast<char*>(job.input) +
                     (static_cast<size_t>(y) * args.width + x) * 16;
      CUDA_CHECK(cudaMemcpy2DAsync(job.tile_input, dst_pitch, source, src_pitch,
                                   dst_pitch, tile_height,
                                   cudaMemcpyDeviceToDevice, job.stream));
      dim3 grid = grid_2d(tile_width, tile_height);
      coverage_linear<<<grid, block_2d(), 0, job.stream>>>(
          job.cov[0], tile_width, tile_height, x, y, args.width, args.height,
          0.1f, 0.0f, 0.9f, 1.0f);
      coverage_radial<<<grid, block_2d(), 0, job.stream>>>(
          job.cov[1], tile_width, tile_height, x, y, args.width, args.height,
          0.5f, 0.5f, 0.4f, 0.6f, 0.2f);
      coverage_combine<<<grid, block_2d(), 0, job.stream>>>(
          job.cov[0], job.cov[1], job.cov[2], tile_width, tile_height, 2);
      coverage_adjust<<<grid, block_2d(), 0, job.stream>>>(
          job.cov[2], job.cov[3], tile_width, tile_height, 0.75f, 1);
      corrector<<<grid, block_2d(), 0, job.stream>>>(
          job.tile_input, job.cov[3], job.img[0], tile_width, tile_height, 1.2f,
          0.8f, curve, 1);
      corrector<<<grid, block_2d(), 0, job.stream>>>(
          job.tile_input, nullptr, job.img[1], tile_width, tile_height, -0.7f,
          1.0f, Curve{make_float2(0, 0), make_float2(0, 0), make_float2(0, 0), 0}, 0);
      parallel_mix<<<grid, block_2d(), 0, job.stream>>>(
          job.tile_input, job.img[0], job.img[1], job.img[2], tile_width, tile_height,
          0.65f, 0.35f);
      corrector<<<grid, block_2d(), 0, job.stream>>>(
          job.img[2], nullptr, job.img[3], tile_width, tile_height, 0.35f, 1.0f,
          Curve{make_float2(0, 0), make_float2(0, 0), make_float2(0, 0), 0}, 0);
      group_mix<<<grid, block_2d(), 0, job.stream>>>(
          job.img[2], job.img[3], job.img[4], tile_width, tile_height, 0.8f);
      char* destination = reinterpret_cast<char*>(job.output) +
                          (static_cast<size_t>(y) * args.width + x) * 16;
      CUDA_CHECK(cudaMemcpy2DAsync(destination, src_pitch, job.img[4], dst_pitch,
                                   dst_pitch, tile_height, cudaMemcpyDeviceToDevice,
                                   job.stream));
    }
  }
  CUDA_CHECK(cudaEventRecord(job.stop, job.stream));
  CUDA_CHECK(cudaEventSynchronize(job.stop));
  float elapsed_ms = 0;
  CUDA_CHECK(cudaEventElapsedTime(&elapsed_ms, job.start, job.stop));
  job.ms = elapsed_ms;
}

double compare_reference(const float4* device_output, const std::vector<char>& reference,
                         size_t pixels) {
  std::vector<float> actual(pixels * 4);
  CUDA_CHECK(cudaMemcpy(actual.data(), device_output, pixels * 16,
                        cudaMemcpyDeviceToHost));
  const float* expected = reinterpret_cast<const float*>(reference.data());
  double max_abs = 0;
  double max_relative = 0;
  double sum_abs = 0;
  size_t over = 0;
  size_t nonfinite = 0;
  size_t samples = pixels * 4;
  for (size_t index = 0; index < samples; ++index) {
    float a = actual[index];
    float e = expected[index];
    if (!std::isfinite(a) || !std::isfinite(e)) {
      ++nonfinite;
      continue;
    }
    double difference = std::fabs(static_cast<double>(a) - e);
    double relative = difference / std::max(1.0, std::fabs(static_cast<double>(e)));
    max_abs = std::max(max_abs, difference);
    max_relative = std::max(max_relative, relative);
    sum_abs += difference;
    if (relative > 1e-5) ++over;
  }
  std::fprintf(stderr, "reference: maxAbs=%g maxRelative=%g meanAbs=%g over1e5=%zu nonfinite=%zu\n",
               max_abs, max_relative, sum_abs / samples, over, nonfinite);
  return max_abs;
}

std::vector<char> read_file(const std::string& path, size_t expected) {
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  if (!stream) {
    std::fprintf(stderr, "cannot open %s\n", path.c_str());
    std::exit(2);
  }
  size_t size = static_cast<size_t>(stream.tellg());
  if (size != expected) {
    std::fprintf(stderr, "%s is %zu bytes, expected %zu\n", path.c_str(), size, expected);
    std::exit(2);
  }
  stream.seekg(0);
  std::vector<char> data(size);
  stream.read(data.data(), static_cast<std::streamsize>(size));
  if (!stream) {
    std::fprintf(stderr, "short read %s\n", path.c_str());
    std::exit(2);
  }
  return data;
}

Args parse_args(int argc, char** argv) {
  Args args;
  for (int index = 1; index < argc; ++index) {
    std::string key = argv[index];
    auto next = [&]() -> std::string {
      if (index + 1 >= argc) {
        std::fprintf(stderr, "missing value for %s\n", key.c_str());
        std::exit(2);
      }
      return argv[++index];
    };
    if (key == "--input") args.input = next();
    else if (key == "--reference") args.reference = next();
    else if (key == "--width") args.width = std::stoi(next());
    else if (key == "--height") args.height = std::stoi(next());
    else if (key == "--tile") args.tile = std::stoi(next());
    else if (key == "--jobs") args.jobs = std::stoi(next());
    else if (key == "--cache-mb") args.cache_mb = std::stoi(next());
    else if (key == "--full") args.full_stage = true;
    else {
      std::fprintf(stderr, "unknown argument %s\n", key.c_str());
      std::exit(2);
    }
  }
  if (args.input.empty() || args.width <= 0 || args.height <= 0 || args.tile < 64 ||
      args.jobs <= 0 || args.cache_mb < 0) {
    std::fprintf(stderr,
                 "usage: scene-bench --input AP1.f32 --width W --height H "
                 "[--reference out.f32] [--tile 2048] [--jobs 1] [--cache-mb 0] [--full]\n");
    std::exit(2);
  }
  return args;
}

}  // namespace

int main(int argc, char** argv) {
  Args args = parse_args(argc, argv);
  CUDA_CHECK(cudaFree(0));
  size_t free_before = 0;
  size_t total = 0;
  CUDA_CHECK(cudaMemGetInfo(&free_before, &total));
  double baseline_mb = static_cast<double>(total - free_before) / (1024.0 * 1024.0);

  size_t pixels = static_cast<size_t>(args.width) * args.height;
  size_t full_bytes = pixels * 16;
  size_t tile_pixels = static_cast<size_t>(args.tile) * args.tile;
  size_t tile_image_bytes = tile_pixels * 16;
  size_t tile_coverage_bytes = tile_pixels * 4;
  size_t logical = 0;
  std::vector<char> host_input = read_file(args.input, full_bytes);
  std::vector<char> reference;
  if (!args.reference.empty()) reference = read_file(args.reference, full_bytes);

  std::vector<Job> jobs(static_cast<size_t>(args.jobs));
  int failed_job = -1;
  for (int job_index = 0; job_index < args.jobs; ++job_index) {
    Job& job = jobs[job_index];
    job.id = job_index;
    CUDA_CHECK(cudaStreamCreate(&job.stream));
    CUDA_CHECK(cudaEventCreate(&job.start));
    CUDA_CHECK(cudaEventCreate(&job.stop));
    auto allocate = [&](void** pointer, size_t bytes) {
      return cuda_alloc(pointer, bytes, &logical, job_index, args.jobs, args.tile,
                        args.cache_mb, args.full_stage, baseline_mb, &failed_job);
    };
    if (!allocate(reinterpret_cast<void**>(&job.input), full_bytes) ||
        !allocate(reinterpret_cast<void**>(&job.output), full_bytes) ||
        !allocate(reinterpret_cast<void**>(&job.tile_input), tile_image_bytes)) {
      break;
    }
    bool ok = true;
    for (auto& pointer : job.img) {
      if (!allocate(reinterpret_cast<void**>(&pointer), tile_image_bytes)) {
        ok = false;
        break;
      }
    }
    if (!ok) break;
    for (auto& pointer : job.cov) {
      if (!allocate(reinterpret_cast<void**>(&pointer), tile_coverage_bytes)) {
        ok = false;
        break;
      }
    }
    if (!ok) break;
    if (args.cache_mb > 0 &&
        !allocate(reinterpret_cast<void**>(&job.cache),
                  static_cast<size_t>(args.cache_mb) * 1024 * 1024)) {
      break;
    }
    if (args.full_stage) {
      if (!allocate(reinterpret_cast<void**>(&job.mosaic), pixels * 2) ||
          !allocate(reinterpret_cast<void**>(&job.saturation), pixels) ||
          !allocate(reinterpret_cast<void**>(&job.hdr), full_bytes) ||
          !allocate(reinterpret_cast<void**>(&job.sdr), full_bytes) ||
          !allocate(reinterpret_cast<void**>(&job.pq), pixels * 3 * 2)) {
        break;
      }
    }
  }

  if (failed_job >= 0) {
    for (auto& job : jobs) free_job(job);
    return 2;
  }

  size_t free_after = 0;
  CUDA_CHECK(cudaMemGetInfo(&free_after, &total));
  double used_mb = static_cast<double>(total - free_after) / (1024.0 * 1024.0);
  double delta_mb = used_mb - baseline_mb;

  CUDA_CHECK(cudaMemcpy(jobs[0].input, host_input.data(), full_bytes,
                        cudaMemcpyHostToDevice));
  for (int job_index = 1; job_index < args.jobs; ++job_index) {
    CUDA_CHECK(cudaMemcpy(jobs[job_index].input, jobs[0].input, full_bytes,
                          cudaMemcpyDeviceToDevice));
  }
  if (args.full_stage) {
    for (auto& job : jobs) {
      CUDA_CHECK(cudaMemsetAsync(job.mosaic, 0, pixels * 2, job.stream));
      CUDA_CHECK(cudaMemsetAsync(job.saturation, 0, pixels, job.stream));
      CUDA_CHECK(cudaMemsetAsync(job.hdr, 0, full_bytes, job.stream));
      CUDA_CHECK(cudaMemsetAsync(job.sdr, 0, full_bytes, job.stream));
      CUDA_CHECK(cudaMemsetAsync(job.pq, 0, pixels * 3 * 2, job.stream));
      if (job.cache) {
        CUDA_CHECK(cudaMemsetAsync(job.cache, 0, static_cast<size_t>(args.cache_mb) * 1024 * 1024,
                                   job.stream));
      }
      CUDA_CHECK(cudaStreamSynchronize(job.stream));
    }
  }
  CUDA_CHECK(cudaDeviceSynchronize());

  auto wall_start = std::chrono::steady_clock::now();
  std::vector<std::thread> threads;
  threads.reserve(static_cast<size_t>(args.jobs));
  for (auto& job : jobs) threads.emplace_back(run_job, std::ref(job), std::cref(args));
  for (auto& thread : threads) thread.join();
  auto wall_end = std::chrono::steady_clock::now();
  double wall_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

  double max_abs = -1;
  if (!reference.empty()) {
    max_abs = compare_reference(jobs[0].output, reference, pixels);
  }

  cudaDeviceProp properties{};
  CUDA_CHECK(cudaGetDeviceProperties(&properties, 0));
  int runtime_version = 0;
  int driver_version = 0;
  CUDA_CHECK(cudaRuntimeGetVersion(&runtime_version));
  CUDA_CHECK(cudaDriverGetVersion(&driver_version));

  std::printf(
      "{\"success\":true,\"device\":\"%s\",\"compute\":\"%d.%d\","
      "\"cudaRuntime\":%d,\"cudaDriver\":%d,"
      "\"width\":%d,\"height\":%d,\"tile\":%d,\"jobs\":%d,"
      "\"cacheMB\":%d,\"stage\":\"%s\",\"baselineMB\":%.1f,\"usedMB\":%.1f,"
      "\"deltaMB\":%.1f,\"logicalMB\":%.1f,\"perJobLogicalMB\":%.1f,"
      "\"wallMs\":%.3f,\"jobMs\":[",
      properties.name, properties.major, properties.minor, runtime_version,
      driver_version, args.width, args.height, args.tile, args.jobs, args.cache_mb,
      args.full_stage ? "full" : "scene", baseline_mb, used_mb, delta_mb,
      logical / (1024.0 * 1024.0),
      logical / (1024.0 * 1024.0) / static_cast<double>(args.jobs), wall_ms);
  for (int index = 0; index < args.jobs; ++index) {
    if (index) std::printf(",");
    std::printf("%.3f", jobs[index].ms);
  }
  std::printf("],\"maxAbs\":%.9g}\n", max_abs);

  for (auto& job : jobs) free_job(job);
  return 0;
}
