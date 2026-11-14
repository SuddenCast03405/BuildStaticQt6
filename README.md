# BuildStaticQt6

用 GitHub Actions 编译 **Qt 6.8 静态库（MSVC 2019 / v142 / x64，可选 /MT）**，一次运行产出可直接放进 `C:\Qt\...` 的安装目录。

设计目标是 **尽可能少消耗 Action**：只手动触发、单 job、只构建需要的模块、源码和产物都进缓存 —— 缓存命中时整个 workflow 只跑 1～2 分钟（仅校验 + 打包）。

---

## 1. 怎么用

网页端：仓库 **Actions → Build Qt 6.8 static (MSVC 2019 x64) → Run workflow**，保持默认参数直接跑。

命令行（gh CLI）：

```bash
# 默认：Qt 6.8.5 + 常用模块 + /MT，约 1.5~2.5 小时（4 vCPU 运行器）
gh workflow run build-qt-static.yml

# 只要 Core/Gui/Widgets，时间砍一半以上
gh workflow run build-qt-static.yml -f modules=qtbase

# 用 /MD（不加 -static-runtime）
gh workflow run build-qt-static.yml -f static_runtime=false
```

跑完在 job 页面底部下载产物 `qt-6.8.5-msvc2019-static-x64.7z`，解压到例如 `C:\Qt\Qt-6.8.5-msvc2019-static`。

## 2. 为什么它几乎不烧 Action 分钟数

| 手段 | 效果 |
| --- | --- |
| 仓库是 **public** | GitHub 对公开仓库的 Actions 免费且不限分钟（4 vCPU / 16 GB），私有仓库才会扣 2000 分钟/月 |
| 只有 `workflow_dispatch` | 推代码、发 PR 都不会触发；打 tag 自动构建那段是注释状态 |
| `concurrency` + `cancel-in-progress` | 重复点击只会保留最后一次，不会排队烧机器 |
| 单 job，无 matrix | 只起一次 Windows 运行器 |
| `init-repository --module-subset` | 不克隆也不编译 qtwebengine / qt3d / qtmultimedia 等十几个大模块 |
| `actions/cache` 缓存源码 + 安装目录 | 第二次运行直接命中产物缓存，跳过整个编译 |
| `timeout-minutes: 355` | 卡死时最多 6 小时自动结束，不会无限计费 |

反过来，如果你改的是私有仓库，又想彻底不花分钟数，把 `runs-on: ${{ inputs.runner }}` 的输入改成 `self-hosted`，在自己机器上跑即可（自建 runner 不消耗托管分钟数，而且 ccache/构建目录能留着复用）。

## 3. 产物怎么接进工程

```cmake
cmake_minimum_required(VERSION 3.21)
project(LightCpp LANGUAGES CXX)

# 静态 Qt 必须和工程的运行时一致：这里全部用 /MT
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)
qt_standard_project_setup()

qt_add_executable(app main.cpp)
target_link_libraries(app PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets)
```

配置时把前缀指过去：

```powershell
cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH=C:\Qt\Qt-6.8.5-msvc2019-static
```

要点：

- **运行时必须一致**：产物是 `/MT`（默认参数）时，工程也必须 `/MT`；否则链接期报 `LNK2038` / 运行期 `RuntimeLibrary` 不匹配。
- **不需要 windeployqt**：静态链接后没有 Qt DLL；但 Windows 平台插件要靠静态导入，用 `qt_add_executable` 时 CMake 会自动生成插件导入代码；若你手写构建脚本，需要 `Q_IMPORT_PLUGIN(QWindowsIntegrationPlugin)`。
- **`qmake.exe`、`moc.exe`、`rcc.exe` 在 `bin\` 下**，它们本身也是 `/MT` 的，可以直接随 IDE 一起发布。
- **许可证**：开源版 Qt 静态链接属于 LGPLv3 场景，分发二进制时需要提供可重新链接的目标文件（或改用商业许可）。自用/内部工具无此负担。

## 4. 本地跑

脚本不依赖 Actions，Windows 本机装了 VS2019（或 VS2022 + v142 组件）、CMake、Ninja、Perl 即可：

```powershell
# 完整构建
.\scripts\build-qt-static.ps1 -QtVersion 6.8.5 -StaticRuntime -Prefix C:\Qt\Qt-6.8.5-msvc2019-static

# 只校验已有产物（CI 命中缓存时走的就是这条）
.\scripts\build-qt-static.ps1 -VerifyOnly -Prefix C:\Qt\Qt-6.8.5-msvc2019-static -StaticRuntime
```

脚本会自己用 `vswhere` + `vcvarsall.bat -vcvars_ver=14.29` 初始化环境，并 **断言 `cl` 版本是 19.29.x**，避免机器上装了 VS2022 后被 v143 悄悄顶掉。

### 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-QtVersion` | `6.8.5` | Qt 版本，自动匹配 `v6.8.5` / `v6.8.5-lts-lgpl` 标签 |
| `-QtTag` | 空 | 显式指定 qt/qt5 标签 |
| `-Modules` | 见下 | 要构建的模块子集 |
| `-SrcRoot` | `C:\Qt\src\qt5` | 源码目录 |
| `-BuildDir` | `C:\Qt\build` | 构建目录 |
| `-Prefix` | `C:\Qt\Qt-<版本>-msvc2019-static` | 安装目录 |
| `-MsvcToolset` | `14.29` | vcvarsall 的 `-vcvars_ver`，即 v142 |
| `-StaticRuntime` | 关 | 加 `/MT`；对应 Qt 的 `-static-runtime` |
| `-Jobs` | 0（=CPU 核数） | 并行度 |
| `-VerifyOnly` | 关 | 只校验不编译 |
| `-Force` | 关 | 强制重新同步子模块 |

默认模块：`qtbase,qtdeclarative,qtsvg,qttools,qtshadertools,qtimageformats,qt5compat,qtlanguageserver`

> `qtshadertools` 是 `qtdeclarative` 的依赖，`qtlanguageserver` 是 `qttools` 的依赖，别删。

## 5. 常见坑

- **qtwebengine 不要进静态构建**：它要 Chromium 的 gn/ninja 全套流程，单次 6 小时都未必够，且授权复杂。默认已排除。
- **改了模块列表要先清缓存**：产物缓存的 key 里带了脚本文本哈希，但没带模块列表；换模块时用 `use_cache=false` 跑一次，或删掉仓库的 Actions cache。
- **Windows 运行器镜像会变**：`windows-2022` 目前自带 v142（`VC\Tools\MSVC\14.29.*`）。万一哪天被移除，workflow 的预检步骤会直接报错并给出两条路：换 `self-hosted`，或去掉 `14.29` 用 v143（v143 与 MSVC2019 ABI 兼容，只是不再是"MSVC2019 编译"）。
- **磁盘**：这份构建在运行器上大约占 20~30 GB，`windows-2022` 默认盘够用；Qt 全模块构建才需要额外清盘。
- **耗时参考**：4 vCPU 下 `qtbase` 约 35~50 分钟，加 `qtdeclarative` 到 1.5~2 小时，再加 `qttools/qtimageformats/qt5compat` 约 2~2.5 小时。

## 6. 文件

```
.github/workflows/build-qt-static.yml   # workflow：缓存 -> 构建 -> 校验 -> 打包 -> 上传
scripts/build-qt-static.ps1            # 实际干活：环境/源码/configure/build/install/校验
```
