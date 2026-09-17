# tk_capi —— C ABI 层
#
# 全项目**唯一**的 extern "C" 边界，存在的唯一理由是给 Swift GUI 用。
# 它站在依赖链的最顶端（和 app 同层），依赖 core 及其下的全部模块。
#
# 编成 OBJECT 库而不是 STATIC，是为了让共享库 libtetherkit 能拿到**全部**目标
# 文件。若编成静态库，链接器只会挑「有人引用的」成员，而 C ABI 的导出函数在
# 库内部无人引用 —— 结果会是一个空的 dylib，且没有任何报错。
# （另一条路是 -force_load，但 OBJECT 库是 CMake 里更直白的表达。）

add_library(
  tk_capi OBJECT
  capi_support.cc
  core_foundation_support.cc
  environment.cc
  log_ring.cc
  managed_network_service.cc
  net_config.cc
  orphan_cleanup.cc
  process_runner.cc
  session.cc)

target_link_libraries(tk_capi PUBLIC tetherkit_base tk_version tk_core)

# 网卡 IP 配置要回读 configd 的动态存储（真实生效的网关与 DNS），只能走
# SystemConfiguration。这是 tk_capi 独有的依赖 —— 下层模块一概不碰 configd。
target_link_libraries(tk_capi PUBLIC "-framework CoreFoundation"
                                     "-framework SystemConfiguration")

# ------------------------------------------------------------------------------
# libtetherkit —— 对外分发的共享库
#
# Swift 只能链接共享库或系统库，链接不了一堆 CMake 静态目标，所以必须有这一层。
# ------------------------------------------------------------------------------
if(TETHERKIT_BUILD_SHARED_LIB)
  add_library(tetherkit_shared SHARED)
  target_link_libraries(tetherkit_shared PRIVATE tk_capi)

  set_target_properties(
    tetherkit_shared
    PROPERTIES OUTPUT_NAME tetherkit
               VERSION "${PROJECT_VERSION}"
               SOVERSION "${PROJECT_VERSION_MAJOR}"
               # 让依赖方按 @rpath 加载，而不是烧死绝对路径 —— .app 内嵌
               # 这个 dylib 时才不用事后 install_name_tool 改（改完还得重签，
               # 见 docs/GUI-SPIKE.md 第 7 节踩过的坑）。
               INSTALL_NAME_DIR "@rpath")

  # 只导出 C ABI，其余符号（含 C++ 重整名）一律隐藏。理由见白名单文件。
  target_link_options(tetherkit_shared PRIVATE
                      "-Wl,-exported_symbols_list,${PROJECT_SOURCE_DIR}/cmake/tetherkit_exports.txt")

  install(TARGETS tetherkit_shared LIBRARY DESTINATION lib)
endif()

# C ABI 头对外安装：Homebrew formula 装完之后，别的项目也能拿它做绑定。
install(DIRECTORY "${PROJECT_SOURCE_DIR}/include/tetherkit/capi"
        DESTINATION include/tetherkit
        FILES_MATCHING
        PATTERN "*.h")
