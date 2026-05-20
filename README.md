# llvm-cygwin

LLVM/Clang/LLD 交叉编译工具链，目标为 **Cygwin** (x86_64-pc-cygwin)。

类似 [llvm-mingw](https://github.com/mstorsjo/llvm-mingw)，但使用 Cygwin 运行时 (cygwin1.dll)
而非 MinGW-w64，为 Windows 提供完整的 POSIX 兼容性。

## 项目结构

```
llvm-cygwin/
├── build.sh                     # 一键构建脚本
├── config/clang/
│   └── x86_64-pc-cygwin.cfg     # Clang 配置文件
├── cmake/
│   └── x86_64-pc-cygwin.cmake   # CMake 工具链文件（用户项目使用）
├── scripts/
│   ├── fetch-patches.sh         # 从 Cygwin 仓库下载补丁
│   ├── fetch-sysroot.sh         # 下载并创建 Cygwin sysroot
│   └── wine-cygwin.sh           # Wine 测试 wrapper
├── patches/custom/              # 自定义补丁（唯一需要版本控制的补丁）
│   └── 0001-cygwin-direct-lld-linker.patch
├── sysroot/                     # (gitignored) Cygwin 头文件和库
├── toolchain/                   # (gitignored) 编译产物
└── build/                       # (gitignored) 构建目录
```

## 快速开始

### 1. 下载 Cygwin 补丁

```bash
./scripts/fetch-patches.sh
```

### 2. 下载 Cygwin sysroot

```bash
./scripts/fetch-sysroot.sh
```

### 3. 构建工具链

```bash
./build.sh
```

构建完成后，工具链在 `toolchain/`，sysroot 在 `sysroot/`。

### 4. 使用

```bash
export PATH="$PWD/toolchain/bin:$PATH"

# 编译静态链接的 Cygwin 可执行文件
x86_64-pc-cygwin-clang++ -static hello.cpp -o hello.exe

# 查看 DLL 依赖
x86_64-pc-cygwin-ldd hello.exe

# 用 Wine 测试（需要安装 wine）
wine-cygwin hello.exe
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `JOBS` | `nproc` | 并行编译任务数 |
| `PROXY` | `http://127.0.0.1:7897` | HTTP 代理 |
| `CYGWIN_MIRROR` | `mirrors.kernel.org` | Cygwin 镜像地址 |
| `SKIP_CLONE` | 空 | 设为 1 跳过 LLVM clone（开发用） |

> **注意**：libiconv / libintl 的二进制包现在已整合到 `fetch-sysroot.sh` 中，
> 随 sysroot 一起直接下载，不再需要手动编译。

## Wine 测试

```bash
# 自动查找 cygwin1.dll 并用 Wine 运行
./scripts/wine-cygwin.sh hello.exe

# 指定 sysroot
./scripts/wine-cygwin.sh --sysroot=./sysroot myapp.exe arg1 arg2
```

## 技术细节

- **链接器**: 通过自定义 patch（`patches/custom/`），Cygwin 驱动直接调用 `ld.lld`，无需 GCC
- **默认 C++ 标准库**: libc++（通过 `x86_64-pc-windows-cygnus.cfg` 自动配置）
- **LDD**: 使用 `llvm-readobj --needed-libs` 实现 PE/COFF 依赖分析
- **补丁来源**: Cygwin 官方源码包（https://cygwin.com/git/cygwin-packages/）

## 要求

- Linux x86_64 主机
- cmake, ninja, git, wget, gcc, g++
- (可选) wine — 用于测试编译产物
