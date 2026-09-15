# UCS — Apple Health / 微信运动步数注入工具

roothide deb package for modifying Apple Health & WeChat step count on jailbroken iOS devices.

## 核心逻辑（v3.0 重构）

**显示步数 = 当天真实步数 + 虚拟步数（替换式）**

- 真实步数：iPhone 自己计步器记录的步数，永远保留、绝不删除。
- 虚拟步数：在 App 里设定的一个增量值，点「生成」后写入 HealthKit 合成样本并同步给微信 tweak。
- 第二次设定新的虚拟值会**替换**掉上一次的虚拟值（先删旧合成样本再写新值），不会无限累加。

举例：

| 操作 | 真实步数 | 虚拟步数 | 显示步数 |
|------|----------|----------|----------|
| 第一次生成 | 100 | 100 | 200 |
| 第二次改成 200 再生成 | 100 | 200 | 300 |

健康 App 与微信运动显示一致。

## Features

- Modify **step count** (步数)：真实 + 虚拟
- Modify **walking/running distance** (步行距离)
- Modify **flights climbed** (已爬楼层数)
- Inject WeChat (`com.tencent.xin`) via StepFaker tweak
- Daily scheduled auto-generation

## Build

GitHub Actions (macos-latest) builds the single roothide `.deb` on every push to `main`.
Artifact name: `ucs-deb`.

## Install

1. Download `.deb` from Releases / CI artifact
2. Install via Sileo/Zebra
3. Open **UCS** app, set virtual steps, tap **生成运动数据**

## Technical Details

- Architecture: iphoneos-arm64e (roothide compatible)
- Minimum iOS: 13.0
- App: writes synthetic step samples to HealthKit (device source)
- Tweak: hooks WeChat pedometer / HealthKit reads, returns `real + virtual`
- License: MIT
