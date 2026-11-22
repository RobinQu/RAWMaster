# LightFlow 后台窗口屏幕测量

在 Apple Silicon Mac 上，Electron 41.3.0 的 Chromium 将原版 LightFlow 编辑器渲染到一个独立的 WindowServer 窗口。窗口位于桌面图标上方，忽略鼠标事件，禁止激活。ScreenCaptureKit 按该窗口的 ID 采样，其他应用可保持前台。每轮使用临时浏览器配置、只读 RAW 和仓库的本地原版编辑器副本。

在仓库根目录运行下列命令。准备已校验的 Electron arm64 发行压缩包、Node N-API 头文件、具有屏幕录制权限的运行环境和安装了 websocket-client 的 Python 3.11 或以上版本。屏幕和缩放设置需要能够容纳完整的 2368 × 1579 像素照片。

```sh
python3 scripts/performance/lightflow-window/prepare.py --electron-zip "$ELECTRON_ZIP" \
  --node-headers "$NODE_INCLUDE" --output "$HOST_DIR"
swiftc -O -parse-as-library scripts/performance/CaptureCanvas.swift -o "$RECORDER"
python3 scripts/performance/lightflow-ui.py start --background-host "$HOST_DIR" \
  --site "$STOCK_LIGHTFLOW_SITE" --raw "$RAW" --session "$SESSION" &
host_process=$!
```

出现 Ready 后，从同一仓库运行采样。默认测 16 个控件，可用 `--operations effects-clarity` 单独采集一个控件。归档前关闭本轮测试主机。

```sh
python3 scripts/performance/lightflow-ui.py capture --session "$SESSION" --binary "$RECORDER" \
  --raw "$RAW" --output "$OBSERVATIONS" --frames "$FRAME_DIR" --samples 10 --settle 0.55
python3 scripts/performance/lightflow-ui.py close --session "$SESSION"
wait "$host_process"
(cd "$FRAME_DIR" && zip -q "$ABSOLUTE_ARCHIVE_PATH" *.bin *.json)
python3 scripts/performance/replay-lightflow-screen.py "$ABSOLUTE_ARCHIVE_PATH" \
  --source "$RAW" --output "$RESCORED_REPORT"
```

每个控件的前两次输入用于建立 A/B 像素参照。之后十次交替输入各自核对已提交数值、起始画面、首次到达 20% 目标变化的时间及最终画面。相同电脑、窗口几何、运行时、原片及参数的补测可以和首次归档按时间顺序一并传给复核程序。每项保留第一个完整通过的十次系列。归档包括宿主和采集器指纹、单调时钟事件，以及每次屏幕更新时照片中央区域的 96 × 64 RGB 样本。
