# 030 · 复核 PoC

两张输入、两个任务、每种提供方三张未筛选候选。湖景第二次是独立请求。冻结的无损 PNG 可离线复算指标和审阅图。以下命令从仓库根目录执行。[实验提示词](poc/cases.json) · [评分定义与判定](research.md)

新增的去干扰、人像重打光、风光参考与两套真实 SDXL LoRA 有单独的[图文报告与离线复算命令](../../docs/research/generative-retouching-field-review.md)。含 4 次本机 FLUX、2 次北京 Seedream 双图请求、8 次有／无 LoRA 对照以及污点注入的小试。下文保留早期 1 MP 单输入配对基准。

## 复算冻结证据

本工作区已有研究用 Python，依赖为 Pillow 13.0.0、NumPy 2.5.5、SciPy 1.18.1 和 scikit-image 0.26.0。在其他环境使用含这些版本的 Python。湖景 JPEG 已随证据保留，人像 PNG 随 scikit-image 提供。脚本先校验两张源图的 SHA-256。

```sh
SPEC=specs/030-ai-retouching
RUN=output/research/030-ai-retouching/recheck
PY=output/research/ai-retouching-rea/spektra-venv/bin/python
"$PY" "$SPEC/poc/fixtures.py" --lake "$SPEC/evidence/mountain-lake.jpg" --out "$RUN/inputs"
"$PY" "$SPEC/poc/evaluate.py" --inputs "$RUN/inputs" --evidence "$SPEC/evidence" --out "$RUN/review"
cmp "$SPEC/evidence/paired-metrics.json" "$RUN/review/paired-metrics.json"
```

`evaluate.py` 在尺寸不匹配或合成后的保护区出现非零差值时中止。审阅图为 JPEG，各指标从源 PNG 计算。[湖景首次候选](evidence/lake-comparison.jpg) · [人像首次候选](evidence/portrait-comparison.jpg) · [评分与哈希](evidence/paired-metrics.json)

## 重跑推理

本地使用已有固定版本 MLX Q8 环境与模型。在 Apple Silicon 上用全新的输出目录运行，依次得到 lake、portrait、lake-repeat。前两次 seed 8521，第三次 8522。运行器关闭模型联网获取。机器、代码修订、权重身份和计时边界见 [FLUX 记录](flux-validation.md)。

```sh
FLUX=output/research/flux3-klein
"$FLUX/venv/bin/python" "$SPEC/evidence/flux-run.py" --model-dir "$FLUX/models/q8" \
  --inputs "$RUN/inputs" --out "$RUN/flux"
```

方舟命令会发起三次实际计费的单图编辑。它只向北京端点传送已准备的两张公开测试图和相应提示，读取环境中的 `ARK_API_KEY` 或在终端隐藏输入。每次单独落盘收据，输出目录已有同名收据时退出。复发请求可得到不同的像素，归档对拍使用前述已保存候选。

```sh
"$PY" "$SPEC/poc/seedream.py" --inputs "$RUN/inputs" --out "$RUN/seedream" lake portrait lake-repeat
```

## 蒙版与源码

标注集的取得方式、样本选择、二值阈值与可复现命令见 [蒙版报告](mask-validation.md)。原有独立服务的性能套件会清空自己的基准快照目录，复跑时使用独立工作目录保留发布时的证据。上游仓库提交、LightFlow 模块哈希和 REA 证据见 [源码复核](source-review.md)。

## 早期对话方案研究存档

上一版 T004 的 13 项离线合同探针保留在此，便于复查当时的判断。对话式修图已移出本期研发，旧 T012 和 SC-06 随该方案归档。本期场景卡、参考张和恢复验收见[当前任务](tasks.md)。如需复核历史探针，使用上文的目录变量执行以下两行。

```sh
python3 "$SPEC/poc/agent_contract.py" > "$RUN/agent-contract.json"
cmp "$SPEC/evidence/agent-contract.json" "$RUN/agent-contract.json"
```

## 图片来源

- 湖景由 Pietro De Grandi 摄于意大利 Pragser Wildsee。测试沿用 MaskAI 已冻结的 1600×1067 版本，中心裁切，叠加红色标牌。干净源图可以查验相应被遮住的真实水纹。[摄影师原作](https://unsplash.com/photos/three-brown-wooden-boat-on-blue-lake-water-taken-at-daytime-T7K4aEPoGGk) · [MaskAI 样本来源](../../experiments/MaskAI/Fixtures/Sources.md)
- 人像是 NASA 宇航员 Eileen Collins 的公开照片，scikit-image 随包提供 512×512 版本。实验使用 Lanczos 放大到 1024×1024，再人为压暗脸部。参考图的源分辨率限制了对毛孔与高频细节真实性的判断。[图像来源与权利说明](https://scikit-image.org/docs/stable/api/skimage.data.html#skimage.data.astronaut)
