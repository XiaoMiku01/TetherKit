// swift-tools-version: 5.9
//
// TetherKit 的图形界面。
//
// ★ 为什么是 SwiftPM 而不是 CMake 或 Xcode 工程 ★
//
//   * CMake 的 Swift 支持只在 Ninja / Xcode 生成器下可用，而本仓库用的是
//     Unix Makefiles，硬换生成器会打扰现有的 C++ 构建流程；
//   * Xcode 工程文件是不可读、不可靠地手写的 XML，进版本库只会带来合并冲突；
//   * SwiftPM 只需要一个 Package.swift，`swift build` 即可，和源码分发
//     （Homebrew formula）的路线也一致。
//
//   .app 包由 Scripts/build-gui.sh 组装 —— SwiftPM 只产出可执行文件，
//   Info.plist、图标、内嵌 dylib 都在脚本里拼。
//
// ★ 怎么找到 libtetherkit ★
//
//   C++ 侧先构建，产物在 <repo>/build/lib。路径通过环境变量传进来：
//
//     export TETHERKIT_LIB_DIR=$PWD/build/lib
//     swift build --package-path gui
//
//   Scripts/build-gui.sh 会替你设好。没设时退回仓库默认的 build/lib，
//   这样在仓库里直接 `swift build` 也能用。
import Foundation
import PackageDescription

/// libtetherkit 所在目录。
///
/// 用绝对路径：SwiftPM 的工作目录随调用方式变化，相对路径会在
/// `swift build --package-path gui` 与 `cd gui && swift build` 之间给出不同结果。
let libraryDirectory: String = {
    if let fromEnvironment = ProcessInfo.processInfo.environment["TETHERKIT_LIB_DIR"],
       !fromEnvironment.isEmpty {
        return fromEnvironment
    }
    // Package.swift 位于 <repo>/gui，因此 ../build/lib 就是默认产物目录。
    let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return packageDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("build/lib")
        .path
}()

/// 链接 libtetherkit 所需的全部标志。
///
/// 这里必须用 unsafeFlags —— SwiftPM 没有「加一个库搜索路径」的安全接口。
/// 本包是根包、不会被别人依赖，unsafeFlags 的限制不适用。
let tetherkitLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(libraryDirectory)",
        // rpath 必须用 -Xlinker 逐段传给链接器。
        // 写成 gcc 风格的 "-Wl,-rpath,..." 会被 swiftc 当成自己的参数，
        // 报「unknown argument」—— 这不是链接错误，而是驱动层就拒了。
        //
        // 三条 rpath 各有用途，**顺序有讲究**（dyld 按声明顺序逐条试）：
        //   1. ../Frameworks —— 装进 .app 之后 dylib 在那里；
        //   2. 可执行文件同级 —— helper 是裸可执行文件，dylib 就在它旁边；
        //   3. 构建产物目录 —— 开发时 `swift run` 直接能跑。
        //
        // 构建目录必须排在**最后**：它是一个绝对路径，在开发机上一定存在。
        // 排在前面的话，打好包的 .app 在本机加载的仍是构建目录里的那份，
        // 内嵌的副本永远得不到验证 —— 等换台机器才暴露，而那时已经晚了。
        // （Scripts/build-gui.sh 还会把这条 rpath 从发布产物里彻底删掉。）
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
        "-Xlinker", "-rpath", "-Xlinker", libraryDirectory,
    ]),
    .linkedLibrary("tetherkit"),
]

let package = Package(
    name: "TetherKitGUI",
    // macOS 14：@Observable 与 ContentUnavailableView 需要它。命令行部分仍然
    // 支持 13.3，两者是各自独立的产物，不必对齐。
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TetherKitApp", targets: ["TetherKitApp"]),
        .executable(name: "tetherkit-helper", targets: ["TetherKitHelper"]),
    ],
    targets: [
        // C ABI 的模块映射。头文件是指向 include/tetherkit/capi/tetherkit_c.h
        // 的符号链接，因此永远和 C++ 侧同步，不需要任何生成步骤。
        .target(name: "CTetherKit"),

        // App 与 helper 共享的 XPC 协议与数据模型。
        // 两边靠同一份源码保持一致，而不是各自抄一遍。
        .target(name: "TetherKitIPC"),

        // C ABI 的 Swift 封装：把 tk_* 翻译成 Swift 的类型与错误。
        .target(name: "TetherKitCore",
                dependencies: ["CTetherKit", "TetherKitIPC"],
                linkerSettings: tetherkitLinkerSettings),

        // 以 root 运行的特权 helper。
        .executableTarget(name: "TetherKitHelper",
                          dependencies: ["TetherKitCore", "TetherKitIPC"]),

        // 用户看到的 SwiftUI App（普通用户身份运行）。
        .executableTarget(name: "TetherKitApp",
                          dependencies: ["TetherKitCore", "TetherKitIPC"]),

        // IPC 的纯逻辑测试。会话与网卡配置的测试在 C++ 侧
        // （tests/test_capi.cc），不在这里重复。
        .testTarget(name: "TetherKitIPCTests", dependencies: ["TetherKitIPC"]),
        // 原生菜单栏排版与生命周期回归：不连 helper、不启动 USB 会话。
        .testTarget(name: "TetherKitAppTests", dependencies: ["TetherKitApp"]),
    ])
