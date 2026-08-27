-- config.lua: 默认配置 + 校验 + 合并
-- 提供 M.defaults, M.validate, M.merge

local M = {}

-- 默认配置
M.defaults = {
  -- nil = 自动检测 (从打开文件路径向上找含 out 产物的目录)
  android_root = nil,
  -- jar 列表缓存目录 (避免每次打开 java 文件都全盘扫描)
  cache_dir = vim.fn.expand("~/.cache/nvim/aosp_dev"),
  java = {
    enabled = true,
    -- 无编译产物时 fallback 的 jar 目录 (由 :AospCollectJars 收集)
    jar_fallback_dir = vim.fn.expand("~/.usr/android_jars"),
    -- Soong output_tag 优先级 (Android 15+): combined(完整合并) > javac(编译) > turbine-combined(API签名合并)
    soong_tag_priority = { "combined", "javac", "turbine-combined" },
    -- 排除的 jar 名 (Lua 模式匹配, 用于 string:match)
    exclude_jars = {
      "^R%.jar$",
      "^stubs%.jar$",
      "^lint%.jar$",
      "^dex%.jar$",
      "^srcjars%d+%.jar$",
      "^kapt%-%w+%.jar$",
    },
    -- 排除的路径关键词 (包含该片段的 jar 路径会被排除, 普通字符串匹配)
    exclude_paths = {
      "linux_glibc_common",   -- host 编译工具, 看 Android 代码不需要
      "android_common_apex",  -- APEX 变体, 与 android_common 主产物重复
    },
    -- Make 构建系统 jar 优先级 (Android 14 及更早)
    make_jar_priority = { "classes.jar", "classes-header.jar", "javalib.jar" },
    -- Make 构建排除的 intermediates 目录名
    make_blacklist = { "android_stubs_current_intermediates" },
    -- 源码根目录扫描模式 (用于 find_source_paths)
    source_patterns = { "src", "java", "src/main/java" },
    -- 禁用 foldingRange (jdtls FoldingRangeHandler 在某些 token 上抛 NegativeArraySizeException)
    disable_folding_range = true,
    -- 禁用 Gradle/Maven 导入 (AOSP 非构建系统项目, 且无网工作站避免下载 checksums)
    disable_gradle_import = true,
    -- inlay hints: "auto" = 有 jar 时 off (避签名损坏 NPE), 无 jar 时 all
    inlay_hints_mode = "auto",
  },
  clang = {
    enabled = false,
  },
}

--- 校验配置
--- @param cfg table 合并后的配置
--- @return boolean ok
--- @return string|nil err 错误信息
function M.validate(cfg)
  if not cfg then
    return false, "config is nil"
  end

  -- cache_dir 必须非空
  if not cfg.cache_dir or cfg.cache_dir == "" then
    return false, "cache_dir must not be empty"
  end

  -- soong_tag_priority 非空 (java 启用时)
  if cfg.java and cfg.java.enabled then
    if not cfg.java.soong_tag_priority or #cfg.java.soong_tag_priority == 0 then
      return false, "java.soong_tag_priority must not be empty"
    end
  end

  return true
end

--- 合并用户配置到默认配置
--- @param user_opts table|nil 用户传入的配置
--- @return table 合并后的配置
function M.merge(user_opts)
  return vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

return M
