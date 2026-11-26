# 本机 FLUX 下载与 worker 联调记录

2026-11-26 · M4 Max / 128 GB / macOS 27.0.1

## 完整权重下载

命令：

```sh
RAWMASTER_LIVE_FLUX_FULL_DOWNLOAD=1 \
RAWMASTER_LIVE_FLUX_FULL_DOWNLOAD_ROOT=/tmp/flux-full-download \
swift test --filter testLiveFullManifestDownloadIfEnabled
```

结果：

- 清单：`devin-lai/flux-3-image-klein-mlx-q8@d9790a1ceaba200e8b773fb236f7c9fa754283a7`
- 102 个文件，10,281,769,642 bytes
- 逐文件大小与 SHA-256 校验通过，随后 `verify()` 再校验一次
- 第三次续传从 62% 开始，346s 完成
- 前两次分别在中途遇到 CDN 连接丢失；已完成文件在重开后保留并被跳过

失败消息会带当前文件，例如：

```text
下载 q8/transformer/single_blocks.14.safetensors 失败：The network connection was lost。已完成的文件会保留。
```

下载实现按 32 MiB 分块发送 `Range` 请求并追加写入 `.part`，完成后流式计算 SHA-256；关闭设置或暂停时保留 `.part`，继续时从断点续传。单个文件失败会做 2 次退避重试，服务器忽略 Range 或返回 416 时回退到从 0 重下。

真实 Range 测试：`single_blocks.14.safetensors` 130 MB，预置前 1 MiB 后请求 `bytes=1048576-...`，首响应 206，25s 完成且最终 SHA-256 与清单一致。

## Swift → Rust worker

命令：

```sh
RAWMASTER_LIVE_FLUX_MODEL=output/research/flux3-klein/models/q8 \
RAWMASTER_LIVE_FLUX_WORKER=.build/out/Products/Debug/RAWMaster_RAWMasterAI.bundle/Contents/Resources/Resources/FluxWorker/flux-worker \
swift test --filter testLiveRustWorkerIfModelProvided
```

结果：通过。64×64、16 步，约 3.1s；回执、PNG 尺寸、模型/权重/运行时 revision、RNG 身份和 `peakMLXBytes` 均通过 Swift 校验。

## 打包产物

`scripts/build-app.sh debug` 生成的 app 包：

- `FluxWorker/flux-worker` 19 MB，ad-hoc 签名
- `FluxWorker/mlx.metallib` 175 MB
- `codesign --verify --deep --strict` 通过
- 直接以 `env -i HOME=... PATH=/usr/bin:/bin` 从 app 包运行 worker，不设置 `RAWMASTER_MLX_METALLIB`，仍通过同目录 metallib 回退完成 64×64 推理（3.46s）
