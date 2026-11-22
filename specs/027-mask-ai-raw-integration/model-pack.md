# 本机蒙版模型包

主体、背景和前景实例使用 macOS Vision。添加和减去画笔、已有蒙版重开及导出都可以离线工作。天空和水面共用一次场景计算。物体点选与框选共用单张照片的编码。两组可选模型当前支持 Apple Silicon 的 macOS 15 及以上系统。

| 操作 | 上游权重及许可 | 准入文件 |
| --- | --- | --- |
| 水面、天空候选 | Han Cai 发布的 EfficientViT-B2 ADE20K，Apache-2.0。从作者权重导出的 ONNX，opset 17。[权重](https://huggingface.co/han-cai/efficientvit-seg) · [本地导出与逐像素比对](../030-ai-retouching/evidence/landscape-upstream-parity.json) | SHA-256 以 `bdbe3961` 开头的本项目导出。旧研究样件以 `e6df30d2` 开头 |
| 物体点选与框选 | Zigeng Chen 等的 SlimSAM uniform-77 和 Xenova 提供的 Q8 ONNX，Apache-2.0。[原权重](https://huggingface.co/Zigeng/SlimSAM-uniform-77) · [固定 ONNX 修订](https://huggingface.co/Xenova/slimsam-77-uniform/tree/5850ab45f587c112167512ffef949107115e26a0/onnx) | 编码器 `cce23c7b`、解码器 `cb90b279` |
| 推理 | Microsoft ONNX Runtime 1.27.0，MIT。macOS arm64 dylib 来自固定 PyPI wheel。[上游](https://github.com/microsoft/onnxruntime) | dylib `49422a13`。两个可选模型共用 |

## 离线安装

准备本机已有的实验依赖目录。运行库和两个 SlimSAM 文件沿用 `experiments/MaskAI/Scripts/download-dependencies.sh` 中的固定地址与校验值。按已有 [导出脚本](../030-ai-retouching/evidence/export-efficientvit.py) 准备上述风光 ONNX。运行以下命令打包，需要哪组就传哪组参数。

```sh
scripts/build-mask-model-pack.sh --output /tmp/RAWMaster-MaskModels \
  --object --landscape /path/to/author-export/efficientvit-seg-b2-ade20k/model.onnx
```

在编辑器「蒙版 → 模型包」选择天空与水面或物体包，指定上一步生成的目录。应用逐文件校验完整 SHA-256，持有安装锁在同一文件系统准备完整副本，再原子切换至当前用户的 `~/Library/Application Support/RAWMaster/MaskAI/v1/`。提交前可取消。并发安装两组模型会按顺序保留结果。

蒙版面板可见时在后台检查运行库和各组件。对 inode、文件大小、修改时间或状态变更时间有变化的文件重新验证完整哈希。缺失或损坏的组件从工具列表移除，文件损坏可通过「模型包 → 修复」重新安装。推理在读取缓存前也校验当前组件。已采用的 Gray8 PNG 随原片配方留存。

天空需核对树枝、电线和屋顶。对于几乎没有确切前景的照片，程序返回未检出并提供画笔。雪、山体、人体部位和负点分别等待独立质量验收。[分项实测](../030-ai-retouching/mask-validation.md)
