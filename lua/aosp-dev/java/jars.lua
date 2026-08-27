-- java/jars.lua: JAR 收集 (soong intermediates + make + fallback + 缓存)
-- 从 AOSP out 目录收集 jar 供 jdtls 索引, 支持文件缓存避免重复扫描

local M = {}

-- 模块级缓存状态 (从 jdtls.lua 迁移)
local _jars_cache = nil       -- 缓存的 jar 列表
local _jars_cache_root = nil  -- 缓存对应的 android_root
local _jars_computed = false  -- 是否已计算过

--- 获取当前配置 (setup 后有效, __index metatable 保证 setup 已调用)
local function get_cfg()
  return require("aosp-dev").config
end

--- 按完整路径去重添加 jar
--- @param path string jar 路径
--- @param jars table jar 列表
--- @param seen_paths table 已见路径集合
local function add_jar(path, jars, seen_paths)
  if not seen_paths[path] then
    seen_paths[path] = true
    table.insert(jars, path)
  end
end

--- 扫描 Soong intermediates 目录 (Android 15+)
--- 路径结构: <base>/<source_path>/<module>/<variant>/<output_tag>/<jar>
--- 按 <source_path>/<module>/<variant> 去重, output_tag 优先级高的先处理
--- @param base_dir string soong intermediates 根目录
--- @param jars table jar 列表 (追加)
--- @param seen_paths table 已见路径集合
--- @return boolean found_any
local function scan_soong_intermediates(base_dir, jars, seen_paths)
  local cfg = get_cfg()
  local java_cfg = cfg.java
  if vim.fn.isdirectory(base_dir) ~= 1 then return false end

  -- 构造 fd 正则和 find path glob
  local tag_alt = table.concat(java_cfg.soong_tag_priority, "|")
  -- fd: -p 全路径 regex; 前导 / 确保只匹配独立的 tag 目录 (不匹配 local-combined 等)
  local fd_regex = "/(" .. tag_alt .. ")/[^/]+\\.jar$"
  local find_globs = {}
  for _, tag in ipairs(java_cfg.soong_tag_priority) do
    find_globs[#find_globs + 1] = "*/" .. tag .. "/*.jar"
  end

  -- 调 util.fs.scan_files (fd 优先, find 备选)
  local fs = require("aosp-dev.util.fs")
  local all_matches = fs.scan_files(base_dir, fd_regex, find_globs)
  if not all_matches or #all_matches == 0 then return false end

  -- 按 tag 优先级排序: 高优先级 tag 的 jar 先处理, 同模块去重
  local tag_order = {}
  for i, tag in ipairs(java_cfg.soong_tag_priority) do
    tag_order[tag] = i
  end
  table.sort(all_matches, function(a, b)
    local ta = a:match("/([^/]+)/[^/]+$") or ""
    local tb = b:match("/([^/]+)/[^/]+$") or ""
    return (tag_order[ta] or 999) < (tag_order[tb] or 999)
  end)

  -- 按模块路径去重, 应用排除规则
  local seen_modules = {}
  local found_any = false

  for _, path in ipairs(all_matches) do
    if path ~= "" then
      local jar_name = vim.fn.fnamemodify(path, ":t")

      -- 排除 jar 名 (Lua 模式匹配)
      local excluded = false
      for _, pat in ipairs(java_cfg.exclude_jars) do
        if jar_name:match(pat) then excluded = true break end
      end
      -- 排除路径关键词 (普通字符串匹配)
      if not excluded then
        for _, kw in ipairs(java_cfg.exclude_paths) do
          if path:find(kw, 1, true) then excluded = true break end
        end
      end

      if not excluded then
        local rel = path:sub(#base_dir + 2)
        local module_path = rel:gsub("/[^/]+/[^/]+$", "")
        if not seen_modules[module_path] then
          seen_modules[module_path] = true
          add_jar(path, jars, seen_paths)
          found_any = true
        end
      end
    end
  end

  return found_any
end

--- 扫描 Make 构建系统 intermediates 目录 (Android 14 及更早)
--- 按 xxx_intermediates 目录名去重, 每目录按 jar 优先级取第一个
--- @param base_dir string JAVA_LIBRARIES 目录
--- @param jars table jar 列表 (追加)
--- @param seen_paths table 已见路径集合
--- @param seen_intermediates table 已见 intermediates 目录名集合
--- @return boolean found_any
local function scan_intermediates_base(base_dir, jars, seen_paths, seen_intermediates)
  local cfg = get_cfg()
  local java_cfg = cfg.java
  if vim.fn.isdirectory(base_dir) ~= 1 then return false end

  -- 黑名单集合
  local blacklist = {}
  for _, name in ipairs(java_cfg.make_blacklist) do
    blacklist[name] = true
  end

  local found_any = false

  -- 按 jar 优先级依次 glob, 高优先级先处理, 同名 intermediates 目录被低优先级跳过
  for _, jar_name in ipairs(java_cfg.make_jar_priority) do
    local matches = vim.fn.glob(base_dir .. "/*_intermediates/" .. jar_name, true, true)
    for _, path in ipairs(matches) do
      local dir = vim.fn.fnamemodify(path, ":h")
      local dirname = vim.fn.fnamemodify(dir, ":t")
      if not blacklist[dirname] and not seen_intermediates[dirname] then
        seen_intermediates[dirname] = true
        add_jar(path, jars, seen_paths)
        found_any = true
      end
    end
  end

  return found_any
end

--- 扫描 AOSP root 下的 common + 所有 product/* 目录
--- @param aosp_root string AOSP 根目录
--- @param jars table jar 列表 (追加)
--- @param seen_paths table 已见路径集合
--- @param seen_intermediates table 已见 intermediates 目录名集合
--- @return boolean found_any
local function scan_aosp_out(aosp_root, jars, seen_paths, seen_intermediates)
  local found_any = false

  -- common
  local out_common = aosp_root .. "/out/target/common/obj/JAVA_LIBRARIES"
  if scan_intermediates_base(out_common, jars, seen_paths, seen_intermediates) then
    found_any = true
  end

  -- product/*/obj/JAVA_LIBRARIES (编两次会有多个 product 目录, glob 全部匹配)
  local product_bases = vim.fn.glob(aosp_root .. "/out/target/product/*/obj/JAVA_LIBRARIES", true, true)
  for _, pbase in ipairs(product_bases) do
    if scan_intermediates_base(pbase, jars, seen_paths, seen_intermediates) then
      found_any = true
    end
  end

  return found_any
end

--- 主入口: 收集 AOSP jar 列表
--- 顺序: soong intermediates -> make JAVA_LIBRARIES -> fallback
--- 支持内存缓存 + 文件缓存
--- @return table jars jar 路径列表
function M.find_android_jars()
  local cfg = get_cfg()
  local java_cfg = cfg.java
  local android_root_mod = require("aosp-dev.android_root")

  local bufname = vim.api.nvim_buf_get_name(0)
  local android_root = cfg.android_root or android_root_mod.find_android_platform_root(bufname)

  -- 非 android 项目: 返回空 (不加载任何 android jar, 仅用 JDK 基础库)
  if not android_root then
    return {}
  end

  -- 命中内存缓存直接返回
  if _jars_computed and _jars_cache_root == android_root then
    return _jars_cache
  end

  local jars = {}
  local seen_paths = {}
  local seen_intermediates = {}
  local source_parts = {}

  -- 文件缓存: 避免每次首次打开都重新 find + Lua 处理 3000+ 路径
  -- 清除缓存: rm ~/.cache/nvim/aosp_dev/*.txt (AOSP 重新编译后需要)
  local cache_file = nil
  local from_cache = false
  if cfg.cache_dir and android_root then
    local cache_key = android_root:gsub("/", "-"):gsub("^-", "")
    cache_file = cfg.cache_dir .. "/" .. cache_key .. ".txt"
    if vim.fn.filereadable(cache_file) == 1 then
      local lines = vim.fn.readfile(cache_file)
      for _, line in ipairs(lines) do
        if line ~= "" and line:sub(1, 1) ~= "#" then
          if vim.fn.filereadable(line) == 1 then
            jars[#jars + 1] = line
            seen_paths[line] = true
          end
        end
      end
      if #jars > 0 then
        from_cache = true
        _jars_cache = jars
        _jars_cache_root = android_root
        _jars_computed = true
        vim.notify("[aosp-dev] JAR loaded from cache (" .. #jars .. " jars)", vim.log.levels.INFO)
        return jars
      end
    end
  end

  -- 尝试 1: soong intermediates (Android 15+, out/soong/.intermediates/)
  for _, soong_sub in ipairs({ "/out/soong/.intermediates", "/out/.soong/.intermediates" }) do
    if scan_soong_intermediates(android_root .. soong_sub, jars, seen_paths) then
      table.insert(source_parts, "soong")
      break
    end
  end

  -- 尝试 2: 旧 JAVA_LIBRARIES (Android 14 及更早)
  if #source_parts == 0 then
    if scan_aosp_out(android_root, jars, seen_paths, seen_intermediates) then
      table.insert(source_parts, "make")
    end
  end

  -- 尝试 3: fallback (jar_fallback_dir, 由 :AospCollectJars 收集)
  if #source_parts == 0 then
    for _, soong_sub in ipairs({ "/.soong/.intermediates", "/soong/.intermediates" }) do
      if scan_soong_intermediates(java_cfg.jar_fallback_dir .. soong_sub, jars, seen_paths) then
        table.insert(source_parts, "fallback")
        break
      end
    end
  end

  -- 通知降噪: 仅首次计算时提示来源
  local source_label = #source_parts > 0 and table.concat(source_parts, " + ") or nil
  if not _jars_computed then
    if source_label then
      vim.notify("[aosp-dev] JAR source -> " .. source_label .. " (" .. #jars .. " jars)", vim.log.levels.INFO)
    else
      vim.notify("[aosp-dev] android project detected but no JAR source found", vim.log.levels.WARN)
    end
  end

  -- 写文件缓存 (仅扫描到 jar 且非缓存加载时)
  if #jars > 0 and not from_cache and cache_file then
    local cache_lines = {
      "# android_root=" .. android_root,
      "# generated=" .. os.date("%Y-%m-%d %H:%M"),
      "# count=" .. #jars,
    }
    for _, j in ipairs(jars) do
      cache_lines[#cache_lines + 1] = j
    end
    vim.fn.mkdir(vim.fn.fnamemodify(cache_file, ":h"), "p")
    vim.fn.writefile(cache_lines, cache_file)
  end

  -- 更新内存缓存
  _jars_cache = jars
  _jars_cache_root = android_root
  _jars_computed = true

  return jars
end

--- 清除内存缓存 (:AospCollectJars 收集后调用, 也可手动调用)
function M.reset_cache()
  _jars_cache = nil
  _jars_cache_root = nil
  _jars_computed = false
end

--- 获取当前缓存状态 (供诊断)
--- @return table {computed, root, count}
function M.cache_status()
  return {
    computed = _jars_computed,
    root = _jars_cache_root,
    count = _jars_cache and #_jars_cache or 0,
  }
end

return M
