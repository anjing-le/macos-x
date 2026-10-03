# 进程取样

`measure_process.py` 仅依赖 Python 3 标准库和 macOS `/bin/ps`，不修改目标进程。默认取样 10 秒、间隔 0.5 秒；目标退出或 PID 的启动时间/可执行文件变化时提前停止。

```sh
python3 tools/measure_process.py --pid 12345 --output /tmp/macos-x-idle.json
python3 tools/measure_process.py --pid 12345 --duration 30 --interval 0.5 --output /tmp/macos-x-warm.json
```

先等待启动和 OTA 检查结束，面板关闭时测 idle；再完成一次呼出/取消以预热，记录窗口数量、显示器和系统版本后测 warm。warm 取样期间实际执行重复呼出、选择、松键、取消、模块停用；两个文件代表调用者安排的场景，工具不会自动判断 idle 或 warm。

指定 `--output` 后每次取样都会原子替换 JSON，其他工具可以读取 `status` 和 `summary` 轮询进度；最终 JSON 同时写 stdout。长任务应由调用环境异步启动后轮询，勿用等待进程完成的操作阻塞主 UI。退出码：0 正常完成/目标退出，1 测量错误或初始 PID 不存在，130 手动中断。工具不跟踪子进程、WindowServer 或 Sparkle helper。

输出保留逐次取样和汇总：`rss_*_bytes` 为 `ps` 的 RSS 乘 1024；`interval_cpu_*_percent` 由累计 CPU 时间差除以墙钟时间差计算，100% 代表约占满一个逻辑核心，可超过 100%；`ps_cpu_sample_mean_percent` 是 `ps` 自身 CPU 百分比的样本均值。

**测量边界**：RSS 不是 physical footprint，也不等于“应用独占内存”；共享、压缩、图形和框架分配需要用 Instruments / `footprint` 单独核对。`ps` 的 CPU 百分比及累计 CPU 时间有平滑/分辨率限制，短时差分和简单样本均值只适合找趋势。取样会创建 `ps` 子进程并产生文件 I/O；密集取样本身增加系统负担，采样峰值也会漏掉两个样本之间的尖峰。

本工具不测按键到首帧、聚焦成功、跨桌面行为或动画流畅度。上述动作必须在目标 Mac 上实测，延迟需另加 signpost 并用 Instruments 检查；构建、进程启动和低 idle RSS 都不能证明窗口切换体验或 OTA 升级成功。[Apple 的响应性建议](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)要求把非 UI 工作移出主线程，并把约 100 ms 的离散交互和约 5 ms 的视图更新视为粗略预算，而非所有设备的保证。
