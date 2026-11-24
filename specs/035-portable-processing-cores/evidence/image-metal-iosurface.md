# macOS 已驻留纹理接入

生产 Rust 图可以直接读取同一 Metal 设备上的 RGBA32Float IOSurface、可选的 R32Float 覆盖，并将结果写到另一块 RGBA32Float IOSurface。macOS 默认构建导出版本 1 的六个扩展函数，宿主显式申请纹理端口才会使用这条路径。现有 Core Image 适配器仍负责 RAW 解码、工作空间转换和显示端 ICC。普通宿主内存与 Linux 继续使用原缓冲区接口。[扩展头文件](../../../Modules/ImageEdit/include/rawmaster_image_metal.h) · [图编译器](../../../Modules/ImageEdit/src/gpu.rs)

## 接入条件

1. 选择已经持有 F32 backing 的编辑阶段。仓库的 `RawBaseStorage` 给出了缓存形态，`CVPixelBuffer` 和 `IOSurface` 共用底层存储，采用扩展线性 sRGB、预乘 alpha 和顶行优先方向。由普通惰性 `CIImage` 开始时，把它渲染到 F32 backing 所需的时间和内存另计。最终 BGRA8 显示表面承担显示转换。[RAW 缓存](../../../Sources/RAWMasterImaging/PreviewRawBaseStorage.swift) · [显示表面](../../../Sources/RAWMasterImaging/PreviewSharedSurfaceStorage.swift)
2. 用 `rm_image_plan_open_v1` 验证配方和 LUT，用 `rm_image_metal_program_open_v1` 选择宿主已有的 `MTLDevice`。宿主先等待输入生产者完成，再用 `rm_image_metal_frame_bind_v1` 借用输入、蒙版和独占输出。Rust 核查同设备对象及 registryID、FourCC、plane、行跨度、尺寸、格式、用法和 backing 是否重叠。调用方保证像素的工作空间和几何坐标。使用 `makeTexture(descriptor:iosurface:plane:)` 得到同一块存储的纹理视图，并按 wgpu 的原生导入契约为所有传入存储建立已初始化内容。[Apple 纹理创建](https://developer.apple.com/documentation/metal/mtldevice/maketexture(descriptor:iosurface:plane:)) · [wgpu 导入契约](https://github.com/gfx-rs/wgpu/blob/v27.0.1/wgpu/src/api/device.rs#L310-L326) · [Metal HAL 包装](https://github.com/gfx-rs/wgpu/blob/v27.0.4/wgpu-hal/src/metal/device.rs#L335-L350)
3. 同一驻留帧可提交拓扑和有序 LUT 摘要一致的参数计划。GPU 的共享点运算使用 `textureLoad` 和 `textureStore`，在每个像素上检查输入、覆盖与输出。GPU 将异常置入一个共享的四字节状态字，宿主在完成栅栏后读取。重绑或显示过程中无需把整帧映射到 CPU。GPU 已产生像素的输出仍是未发布工作区，呈现 actor 应再次比较当前照片、版本和 revision 后再接收。[纹理执行器](../../../Modules/ImageEdit/src/gpu/metal_surface.rs) · [C 生命周期](../../../Modules/ImageEdit/src/metal_ffi.rs)
4. 帧句柄保留设备、编译程序、原生纹理和传入的宿主 lease。提交后取消或等待失败时，工作线程持有原生 `MTLCommandBuffer` 直至终态，再返回失败或过期状态。回收输出须等最后一位原生显示消费者结束。生产者来自独立原生队列时，工作线程可先等待生产者完成。后续若使用队列间 GPU 事件交接，须另测端到端延迟。[Metal 同步](https://developer.apple.com/documentation/metal/mtlsharedevent) · [原生显示所有权](../../../Sources/RAWMasterImaging/DevelopmentThumbnailStorage.swift)

## 实测和复现

首个 7×5 探针采用每行 128 字节的 RGBA32F 存储，有效像素占 112 字节。原生与导入后的 MTLTexture 指针、IOSurface ID 均相同，35 个含负值和 HDR 的像素逐位符合预期。正式图回放在一张真实湖景照片及其冻结天空蒙版的 160×107 采样格上运行，Vivid 37.5 与 43.75 两个参数分别匹配 CPU 至 1.20×10⁻⁷。通过同一输出 `CVPixelBuffer` 构造的 `CIImage` 按顶行优先读取时与 IOSurface 全图逐位相同，上下翻转的最大通道差为 1.1892。测后读取仅供核验，调用时复用已经驻留的表面。[逐次回执](image-metal-iosurface.json) · [执行回放](../../../Modules/ImageEdit/tests/metal_surface/check.sh)

回放另外让未触发的 `MTLSharedEvent` 阻挡 GPU 工作，取得真实的零期限 wgpu 等待超时，随后释放前置事件并等待原生终态。已完成但过期或超时的帧均未获发布权。测试覆盖 Apple M4 Max 单设备，跨物理 GPU、真实设备拔除和原生窗口延迟仍需单独实测。4K 的 32.7% 至 32.9% 驻留 P50 降幅来自生产缓冲区路径的融合对逐节点实验。[性能原始样本](image-production-performance.json)
