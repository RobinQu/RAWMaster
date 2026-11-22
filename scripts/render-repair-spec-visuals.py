from pathlib import Path
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "specs/029-repair-tools/assets"
OUT.mkdir(parents=True, exist_ok=True)

plt.rcParams["font.family"] = ["PingFang SC", "Hiragino Sans GB", "Arial Unicode MS", "DejaVu Sans"]
fig, ax = plt.subplots(figsize=(14, 8), dpi=180)
fig.patch.set_facecolor("#11151b")
ax.set_facecolor("#11151b")
ax.set_xlim(0, 14)
ax.set_ylim(0, 8)
ax.axis("off")

boxes = {
    "stroke": (0.5, 5.2, 2.4, 1.25, "笔划输入", "源空间坐标 · 压感\n大小 · 羽化 · 不透明度", "#334155"),
    "manual": (4.0, 5.2, 2.5, 1.25, "手动解析", "Heal / Clone / Remove\n自动或手动来源", "#164e63"),
    "candidate": (7.6, 5.2, 2.5, 1.25, "候选修补", "本地 AI / PatchMatch\n可取消 · 接受 · 拒绝", "#4c1d95"),
    "operation": (11.0, 5.2, 2.5, 1.25, "有序操作", "独立启停 · 移动\n换源 · 撤销 · 快照", "#14532d"),
    "basis": (1.2, 2.4, 3.0, 1.25, "依赖指纹", "前置配方 + 当前笔划\n相交的先前操作 + 模型", "#713f12"),
    "patch": (5.5, 2.4, 3.0, 1.25, "内容寻址补丁", "RGBA16F + 区域 + 哈希\nready / stale / missing", "#7f1d1d"),
    "render": (9.8, 2.4, 3.0, 1.25, "统一渲染", "交互代理近似\n全尺寸 canonical 输出", "#0c4a6e"),
}
for x, y, w, h, title, body, color in boxes.values():
    patch = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.035,rounding_size=0.12",
                           linewidth=1.2, edgecolor="#94a3b8", facecolor=color)
    ax.add_patch(patch)
    ax.text(x + w / 2, y + h * 0.72, title, ha="center", va="center", color="white", fontsize=13, weight="bold")
    ax.text(x + w / 2, y + h * 0.30, body, ha="center", va="center", color="#e2e8f0", fontsize=9.5, linespacing=1.45)

def arrow(a, b, label=None, rad=0.0):
    xa, ya, wa, ha, *_ = boxes[a]
    xb, yb, wb, hb, *_ = boxes[b]
    start = (xa + wa, ya + ha / 2) if xb >= xa else (xa + wa / 2, ya)
    end = (xb, yb + hb / 2) if xb >= xa else (xb + wb / 2, yb + hb)
    p = FancyArrowPatch(start, end, arrowstyle="-|>", mutation_scale=16, linewidth=1.5,
                        color="#cbd5e1", connectionstyle=f"arc3,rad={rad}")
    ax.add_patch(p)
    if label:
        ax.text((start[0] + end[0]) / 2, (start[1] + end[1]) / 2 + 0.18, label,
                ha="center", va="center", color="#f8fafc", fontsize=9)

arrow("stroke", "manual", "Healing")
arrow("manual", "candidate", "Remove / AI")
arrow("candidate", "operation", "接受")
arrow("operation", "basis", "变更时计算")
arrow("basis", "patch", "匹配才复用")
arrow("patch", "render", "按蒙版合成")
ax.text(7, 7.25, "RAWMaster 修复工具目标状态与数据契约", color="white", fontsize=19, weight="bold", ha="center")
ax.text(7, 0.85, "原则：选区与结果分离；旧配方按原版本重放；过期补丁可显示但不可静默导出；原片始终只读。",
        color="#cbd5e1", fontsize=11, ha="center")
fig.tight_layout(pad=0.6)
fig.savefig(OUT / "repair-state-model.png", facecolor=fig.get_facecolor(), bbox_inches="tight")
plt.close(fig)
print(OUT / "repair-state-model.png")
