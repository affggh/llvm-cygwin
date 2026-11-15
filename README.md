# llvm-cygwin

LLVM/Clang/LLD 交叉编译工具链，目标为 **Cygwin** (x86_64-pc-cygwin)。

类似 [llvm-mingw](https://github.com/mstorsjo/llvm-mingw)，但使用 Cygwin 运行时 (cygwin1.dll)
而非 MinGW-w64，为 Windows 提供完整的 POSIX 兼容性。

## 项目结构

```
llvm-cygwin/
├── build.sh                     # 一键构建脚本
├── cmake/
│   └── x86_64-pc-cygwin.cmake   # CMake 工具链文件（用户项目使用）
├── scripts/
│   ├── fetch-patches.sh         # 从 Cygwin 仓库下载补丁
│   ├── fetch-sysroot.sh         # 下载并创建 Cygwin sysroot
│   └── wine-cygwin.sh           # Wine 测试 wrapper
├── patches/custom/              # 自定义补丁（唯一需要版本控制的补丁）
│   ├── 0001-coff-reload-automatic-imports-after-lto.patch
│   └── 0003-cygwin-per-triple-tree.patch
├── toolchain/                   # (gitignored) 唯一的产物根目录（= sysroot，llvm-mingw 式）
│   ├── bin/                         # clang、ld.lld、x86_64-pc-cygwin-* 包装器、*.cfg
│   ├── lib/clang/23/                # resource dir
│   ├── share/                       # clang、man、scan-build、scan-view、opt-viewer、cygwin/
│   ├── generic-pc-cygwin/include/   # 全部 Cygwin/w32api/libc++ 头文件
│   ├── x86_64-pc-cygwin/            # include 软链、bin/cygwin1.dll、lib/
│   └── i686-pc-cygwin/include       # -> ../generic-pc-cygwin/include
└── build/                       # (gitignored) 构建目录
```

## 快速开始

### 1. 下载 Cygwin 补丁

```bash
./scripts/fetch-patches.sh
```

### 2. 下载 Cygwin sysroot（解压进 toolchain 根目录）

```bash
./scripts/fetch-sysroot.sh
```

### 3. 构建工具链

```bash
./build.sh                # 构建 + 打包
./build.sh --build-only   # 只构建，不打包
./build.sh --clean        # 强制重新 configure（保留源码与补丁）
```

`build.sh` **支持断点续建**：再次运行时不会删除已有的 `build/llvm-project`、
`build/llvm-build`、`build/runtime-build`，而是直接 `ninja` 增量续建，几分钟即可
继续。只有主动传 `--clean` 或删除相应目录才会重新 configure。

构建完成后一切都在这一个 `toolchain/` 目录里（工具链 + sysroot 合并，可直接整目录打包/拷贝）。

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
| `JOBS` | `nproc --all` | 并行编译任务数；默认用满所有 CPU，内存受限主机可用 `JOBS=8 ./build.sh` 降低 |
| `PROXY` | `http://127.0.0.1:7897` | HTTP 代理 |
| `CYGWIN_MIRROR` | `mirrors.kernel.org` | Cygwin 镜像地址 |
| `SKIP_CLONE` | 空 | 设为 1 跳过 LLVM clone（开发用） |

> **升级 LLVM 版本**：只需改 `build.sh` 里的 `LLVM_VERSION`（当前 `23.1.1`），
> 然后重新运行 `./scripts/fetch-patches.sh`（默认按该版本从 Cygwin 取补丁）
> 和 `./build.sh`。`build.sh` 检测到 `build/llvm-project` 是别的 tag 时会自动
> 重新 clone，并清掉旧的 build 缓存和补丁标记。

> **注意**：libiconv / libintl 的二进制包现在已整合到 `fetch-sysroot.sh` 中，
> 随 sysroot 一起直接下载，不再需要手动编译。

## Wine 测试

```bash
# 自动查找 cygwin1.dll 并用 Wine 运行
./scripts/wine-cygwin.sh hello.exe

# 指定根目录（默认自动找 ./toolchain）
./scripts/wine-cygwin.sh --sysroot=./toolchain myapp.exe arg1 arg2
```

## 技术细节

- **链接器**: Cygwin 补丁（`patches/clang/0104-*`）让 Cygwin 驱动直接调用 `ld.lld`，无需 GCC
- **默认运行库**: 与 llvm-mingw 一致——`-rtlib=compiler-rt -unwindlib=libunwind
  -stdlib=libc++ -fuse-ld=lld`（写在 `toolchain/bin/cygwin-common.cfg`，
  `x86_64-pc-windows-cygnus.cfg` / `i686-pc-windows-cygnus.cfg` 用 `-target` +
  `@cygwin-common.cfg` 引入）。compiler-rt 只编静态 builtins，装到
  `lib/clang/23/lib/x86_64-pc-windows-cygnus/libclang_rt.builtins.a`，并额外塞入
  `emutls.o`（`__emutls_get_address`）和 `chkstk.o`（`___chkstk_ms`）——Cygwin 的
  compiler-rt 补丁把这两者放到 cygwin1.dll/共享 builtins 里，交叉编译拿不到。
  `libgcc.a` 仍留在 sysroot 里只备用（`-rtlib=libgcc` 也能用）
- **LDD**: 使用 `llvm-readobj --needed-libs` 实现 PE/COFF 依赖分析
- **目录布局**: 参考 llvm-mingw，工具链与 sysroot 合并成一个根目录——头文件集中在
  `generic-pc-cygwin/include`，各 triple 目录的 `include` 是指向它的相对软链，
  `bin`/`lib` 放在 triple 目录里，Cygwin 的运行时数据（`cygwin.ldif`）并入顶层
  `share/cygwin`。目标树里**没有** `usr/`、`etc/`：clang 的 Cygwin 驱动由
  `patches/custom/0003-cygwin-per-triple-tree.patch` 改成直接搜索
  `<root>/<triple>/{include,include/w32api,lib,lib/w32api}` 和
  `<root>/<triple>/include/c++/v1`（libc++），GCC 运行时目录（crt*.o、libgcc.a）被摊平进
  `<root>/<triple>/lib`，其私有头（omp.h、quadmath.h 等）以不覆盖的方式并入共享头目录。
  默认 sysroot 编译成相对路径 `..`（相对 `<root>/bin`），因此整个目录可搬移
- **TLS**: `__thread` / `thread_local` 走 emulated TLS（Cygwin 驱动强制 `-femulated-tls`），
  POD 和带构造/析构的类型都可用（`__cxa_thread_atexit` 由打过补丁的 libc++abi 提供）。
  产物里没有原生 PE TLS 目录，且 emutls 状态是每个 DLL 各一份——跨 DLL 访问同一个 TLS
  变量会得到不同地址，需要共享时请用 `pthread_getspecific` 之类的显式接口
- **补丁来源**: Cygwin 官方源码包（https://cygwin.com/git/cygwin-packages/）

## 要求

- Linux x86_64 主机
- cmake, ninja, git, wget, gcc, g++
- (可选) wine — 用于测试编译产物
