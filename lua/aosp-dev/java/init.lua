-- java/init.lua: configure(opts) 注入 AOSP 特化配置到 jdtls opts
-- 用法 (用户 jdtls spec):
--   opts = function(_, opts) return require("aosp-dev").java.configure(opts) end

local M = {}

--- 注入 AOSP 特化配置到 jdtls opts
--- 不覆盖用户已有配置 (deep_extend force 合并, AOSP 字段优先)
--- @param opts table jdtls opts
--- @return table opts 修改后的 opts
function M.configure(opts)
  local cfg = require("aosp-dev").config
  if not cfg or not cfg.java.enabled then
    return opts
  end

  local java_cfg = cfg.java
  -- 确保 settings/capabilities 表存在
  opts.settings = opts.settings or {}
  opts.capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()

  -- 1. JAR 收集
  local jars_mod = require("aosp-dev.java.jars")
  local jars = jars_mod.find_android_jars()

  -- 2. 源码根推断 (root_dir 可能是 function, 需调用)
  local bufname = vim.api.nvim_buf_get_name(0)
  local root_path = opts.root_dir
  if type(root_path) == "function" then
    root_path = root_path(bufname)
  end

  local source_paths_mod = require("aosp-dev.java.source_paths")
  local source_paths = source_paths_mod.find_source_paths(root_path, bufname)

  -- 3. inlay hints: android 项目 -> off (避签名损坏 NPE), 非 android -> all
  local cache = jars_mod.cache_status()
  local is_android = cache.root ~= nil
  local inlay_mode
  if java_cfg.inlay_hints_mode == "auto" then
    inlay_mode = is_android and "off" or "all"
  else
    inlay_mode = java_cfg.inlay_hints_mode
  end

  -- 4. 注入 capabilities (foldingRange=false 避 NegativeArraySizeException)
  if java_cfg.disable_folding_range then
    opts.capabilities = vim.tbl_deep_extend("force", opts.capabilities,
      { textDocument = { foldingRange = false } })
  end

  -- 5. 构造 AOSP 特化 settings
  local aosp_settings = {
    java = {
      project = {
        referencedLibraries = jars,
        sourcePaths = source_paths,
      },
      inlayHints = {
        enabled = inlay_mode,
      },
    },
  }

  -- 禁用 Gradle/Maven 导入 (AOSP 非构建系统项目, 且无网工作站避免下载 checksums)
  if java_cfg.disable_gradle_import then
    aosp_settings.java.import = {
      gradle = { enabled = false },
      maven = { enabled = false },
    }
  end

  -- 6. 深度合并: AOSP 字段优先, 但不覆盖用户其他 settings (如 completion, signatureHelp 等)
  opts.settings = vim.tbl_deep_extend("force", opts.settings, aosp_settings)

  return opts
end

return M
