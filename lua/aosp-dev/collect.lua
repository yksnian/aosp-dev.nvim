-- collect.lua: :AospCollectJars 命令实现
-- 从 AOSP out 目录收集 jar 供无编译产物的机器 fallback

local M = {}

--- 获取插件根目录 (通过 debug.getinfo 定位当前文件)
--- @return string
local function get_plugin_root()
  local info = debug.getinfo(1, "S")
  local source = info.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  -- collect.lua 在 lua/aosp-dev/ 下, 向上 3 级到插件根
  return vim.fn.fnamemodify(source, ":h:h:h")
end

--- 从 AOSP out 目录收集 jar
--- @param aosp_out string|nil AOSP 根目录 (nil=自动检测)
--- @param output_dir string|nil 输出目录 (nil=用配置的 jar_fallback_dir)
function M.collect_jars(aosp_out, output_dir)
  local aosp = require("aosp-dev")
  local cfg = aosp.config
  if not cfg then
    vim.notify("[aosp-dev] setup() not called", vim.log.levels.ERROR)
    return
  end

  local android_root_mod = require("aosp-dev.android_root")

  -- 自动检测 android_root
  if not aosp_out then
    aosp_out = cfg.android_root or android_root_mod.find_android_platform_root(vim.fn.getcwd())
  end

  if not aosp_out then
    vim.notify("[aosp-dev] cannot detect AOSP root, please specify: :AospCollectJars <aosp_root>", vim.log.levels.WARN)
    return
  end

  -- 检查 out 目录
  if vim.fn.isdirectory(aosp_out .. "/out") ~= 1 then
    vim.notify("[aosp-dev] no out/ directory found in: " .. aosp_out, vim.log.levels.WARN)
    return
  end

  output_dir = output_dir or cfg.java.jar_fallback_dir

  -- 定位脚本
  local plugin_root = get_plugin_root()
  local script = plugin_root .. "/scripts/collect_aosp_jars.sh"
  if vim.fn.filereadable(script) ~= 1 then
    vim.notify("[aosp-dev] collect script not found: " .. script, vim.log.levels.ERROR)
    return
  end

  -- 执行收集脚本
  vim.notify("[aosp-dev] collecting jars from " .. aosp_out .. " -> " .. output_dir, vim.log.levels.INFO)
  local result = vim.fn.systemlist({ "bash", script, aosp_out, output_dir })
  local shell_error = vim.v.shell_error

  -- 显示结果
  if shell_error ~= 0 then
    vim.notify("[aosp-dev] collect failed (exit " .. shell_error .. ")", vim.log.levels.ERROR)
    for i = math.max(1, #result - 5), #result do
      if result[i] and result[i] ~= "" then
        vim.notify("[aosp-dev] " .. result[i], vim.log.levels.ERROR)
      end
    end
    return
  end

  -- 成功: 打印最后几行摘要
  for i = math.max(1, #result - 5), #result do
    if result[i] and result[i] ~= "" then
      vim.notify("[aosp-dev] " .. result[i], vim.log.levels.INFO)
    end
  end

  -- 清除 jar 缓存 (收集后 fallback jar 可能变化)
  require("aosp-dev.java.jars").reset_cache()
  vim.notify("[aosp-dev] jar cache cleared, reopen java files to reload", vim.log.levels.INFO)
end

return M
