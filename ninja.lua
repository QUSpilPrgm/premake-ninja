--
-- Name:        premake-ninja/ninja.lua
-- Purpose:     Define the ninja action.
-- Author:      Dmitry Ivanov
-- Created:     2015/07/04
-- Copyright:   (c) 2015 Dmitry Ivanov
--

local p = premake
local tree = p.tree
local project = p.project
local solution = p.solution
local config = p.config
local fileconfig = p.fileconfig
local sha1 = require('sha1')

premake.modules.ninja = {}
local ninja = p.modules.ninja

function ninja.esc(value)
	value = value:gsub("%$", "$$") -- TODO maybe there is better way
	value = value:gsub(":", "$:")
	value = value:gsub("\n", "$\n")
	value = value:gsub(" ", "$ ")
	return value
end

-- in some cases we write file names in rule commands directly
-- so we need to propely escape them
function ninja.shesc(value)
	if type(value) == "table" then
		local result = {}
		local n = #value
		for i = 1, n do
			table.insert(result, ninja.shesc(value[i]))
		end
		return result
	end

	if value:find(" ") then
		return "\"" .. value .. "\""
	end

	return value
end

-- generate solution that will call ninja for projects
function ninja.generateSolution(sln)
	p.w("# solution build file")
	p.w("# generated with premake ninja")
	p.w("")

	p.w("# build projects")
	local cfgs = {} -- key is concatanated name or variant name, value is string of outputs names
	local key = ""
	local cfg_first = nil
	local cfg_first_lib = nil

	for prj in solution.eachproject(sln) do
		for cfg in project.eachconfig(prj) do
			key = prj.name .. "_" .. cfg.buildcfg

			if cfg.platform ~= nil then key = key .. "_" .. cfg.platform end

			-- fill list of output files
			if not cfgs[key] then cfgs[key] = "" end
			cfgs[key] = p.esc(ninja.outputFilename(cfg)) .. " "

			if not cfgs[cfg.buildcfg] then cfgs[cfg.buildcfg] = "" end
			cfgs[cfg.buildcfg] = cfgs[cfg.buildcfg] .. p.esc(ninja.outputFilename(cfg)) .. " "

			-- set first configuration name
			if (cfg_first == nil) and (cfg.kind == p.CONSOLEAPP or cfg.kind == p.WINDOWEDAPP) then
				cfg_first = key
			end
			if (cfg_first_lib == nil) and (cfg.kind == p.STATICLIB or cfg.kind == p.SHAREDLIB) then
				cfg_first_lib = key
			end

			-- include other ninja file
			p.w("subninja " .. p.esc(ninja.projectCfgFilename(cfg, true)))
		end
	end

	if cfg_first == nil then cfg_first = cfg_first_lib end

	p.w("")

	p.w("# targets")
	for cfg, outputs in pairs(cfgs) do
		p.w("build " .. p.esc(cfg) .. ": phony " .. outputs)
	end
	p.w("")

	p.w("# default target")
	p.w("default " .. p.esc(cfg_first))
	p.w("")
end

function ninja.list(value)
	if #value > 0 then
		return " " .. table.concat(value, " ")
	else
		return ""
	end
end

function ninja.remove_identical_words(first, second)
	local relevant_index = 1
	repeat
		local first_index = string.find(first, " ", relevant_index + 1) or (string.len(first) + 1)
		local second_index = string.find(second, " ", relevant_index + 1) or (string.len(second) + 1)
		if (not (string.sub(first, 0, first_index - 1) == string.sub(second, 0, second_index - 1))) then
			break
		end
		relevant_index = first_index
	until (relevant_index >= string.len(first)) or (relevant_index >= string.len(second))
	return string.sub(first, relevant_index) .. second;
end

function ninja.dbg_get_struct_string(to_print, depth, max_depth)
	if type(to_print) == "table" then
		local result = string.rep("\r", depth) .. "{\n"
		for k,v in pairs(to_print) do
			if depth >= max_depth then
				return "{ ... }"
			end
			result = result .. string.rep("\r", depth + 1) .. tostring(k) .. " = " .. ninja.dbg_get_struct_string(v, depth + 1, max_depth) .. ", \n"
		end
		result = result .. string.rep("\r", depth) .. " }"
		local result_compressed = string.gsub(string.gsub(result, "\r", ""), "\n", "")
		if (string.len(result_compressed) <= 80) then
			return result_compressed
		else
			return string.gsub(result, "\r", "  ")
		end
	else
		return tostring(to_print)
	end
end

function ninja.tableIsEmpty(table_obj)
	for k,v in pairs(table_obj) do
		return false
	end
	return true
end
function ninja.mergeCfgs(base, add)
    local new_cfg = p.context.extent(base); -- copy the configuration
 
    -- merge all values present in 'add'
    for index, field in pairs(p.field._list) do -- Iterating only over the relevant entries in 'add' does not
        -- always work. It seems like generated tables do not properly work with for each loops.
        local add_value = add[field.name]
        if not ((add_value == nil) or ((type(add_value) == "table") and ninja.tableIsEmpty(add_value))) then -- ignore empty entries...
            local new_field = p.field.merge(field, base[field.name], add_value)
            new_cfg[field.name] = new_field
        end
    end
  
	-- debug...
	--print(ninja.dbg_get_struct_string(p.fields, 0, 2))
	--print(tostring(add["vectorextensions"]))
	--print(ninja.dbg_get_struct_string(base, 0, 2))  --> string
	--print(ninja.dbg_get_struct_string(add, 0, 2))  --> string
	--io.read()
  
	return new_cfg
end

-- generate project + config build file
function ninja.generateProjectCfg(cfg)
	local toolset_name = _OPTIONS.cc or cfg.toolset
	local system_name = os.get()

	if toolset_name == nil then -- TODO why premake doesn't provide default name always ?
		if system_name == "windows" then
			toolset_name = "msc"
		elseif system_name == "macosx" then
			toolset_name = "clang"
		elseif system_name == "linux" then
			toolset_name = "gcc"
		else
			toolset_name = "gcc"
			p.warnOnce("unknown_system", "no toolchain set and unknown system " .. system_name .. " so assuming toolchain is gcc")
		end
	end

	local prj = cfg.project
	local toolset = p.tools[toolset_name]

	p.w("# project build file")
	p.w("# generated with premake ninja")
	p.w("")

	-- premake-ninja relies on scoped rules
	-- and they were added in ninja v1.6
	p.w("ninja_required_version = 1.6")
	
	-- set build directory
	local obj_dir = project.getrelative(cfg.workspace, cfg.objdir)
	p.w("builddir = " .. p.esc(obj_dir))
	p.w("")

	---------------------------------------------------- figure out toolset executables
	local cc = ""
	local cxx = ""
	local ar = ""
	local link = ""
	
	if toolset_name == "msc" then
		-- TODO premake doesn't set tools names for msc, do we want to fix it ?
		cc = "cl"
		cxx = "cl"
		ar = "lib"
		link = "cl"
	else
		if (toolset_name == "gcc") and (not cfg.gccprefix) then cfg.gccprefix = "" end
		cc = toolset.gettoolname(cfg, "cc")
		cxx = toolset.gettoolname(cfg, "cxx")
		ar = toolset.gettoolname(cfg, "ar")
		link = toolset.gettoolname(cfg, iif(cfg.language == "C", "cc", "cxx"))
	end

	---------------------------------------------------- figure out settings
	local globalincludes = {}
	table.foreachi(cfg.includedirs, function(v)
		-- TODO this is a bit obscure and currently I have no idea why exactly it's working
		globalincludes[#globalincludes + 1] = project.getrelative(cfg.workspace, v)
	end)
	
	local buildopt = function(cfg) return ninja.list(cfg.buildoptions) end
	local cflags = function(cfg) return ninja.list(toolset.getcflags(cfg)) end
	local cppflags = function(cfg) return ninja.list(toolset.getcppflags(cfg)) end
	local cxxflags = function(cfg) return ninja.list(toolset.getcxxflags(cfg)) end
	local warnings = function(cfg) if toolset_name == "msc" then return ninja.list(toolset.getwarnings(cfg)) else return "" end end
	local defines = function(cfg) return ninja.list(table.join(toolset.getdefines(cfg.defines), toolset.getundefines(cfg.undefines))) end
	local includes = function(cfg) return ninja.list(toolset.getincludedirs(cfg, globalincludes, cfg.sysincludedirs)) end
	local forceincludes = function(cfg) return ninja.list(toolset.getforceincludes(cfg)) end -- TODO pch
	local ldflags = function(cfg) return ninja.list(table.join(toolset.getLibraryDirectories(cfg), toolset.getldflags(cfg), cfg.linkoptions)) end
	local all_cflags = function(cfg)
			return buildopt(cfg) .. cflags(cfg) .. warnings(cfg) .. defines(cfg) .. includes(cfg) .. forceincludes(cfg)
		end
	local all_cxxflags = function(cfg)
			return buildopt(cfg) .. ninja.remove_identical_words(cflags(cfg), cxxflags(cfg)) .. cppflags(cfg) .. warnings(cfg) .. defines(cfg) .. includes(cfg) .. forceincludes(cfg)
		end
	local all_cflags_default = cc .. all_cflags(cfg)
	local all_cxxflags_default = cxx .. all_cxxflags(cfg)
	local compile_getcommand = function(this_cfg, is_c)
	  local is_default = (this_cfg == cfg) or (not fileconfig.hasFileSettings(this_cfg))
	  if is_c then
		if is_default then
		  return all_cflags_default
		end
		return cc .. all_cflags(ninja.mergeCfgs(cfg, this_cfg))
	  else
		if is_default then
		  return all_cxxflags_default
		end
		return cxx .. all_cxxflags(ninja.mergeCfgs(cfg, this_cfg))
	  end
	end

	---------------------------------------------------- write compile rules
	p.w("# core rules for " .. cfg.name)
	local rules = {}
	local rule_compile_add = function(this_cfg, is_c)
		local rule_command = compile_getcommand(this_cfg, is_c)
		if not (rules[rule_command] == nil) then
			return nil
		end
	  
		-- figure out a suitable name for this rule...
		local rule_name
		if is_c then
		rule_name = "cc"
		else
			rule_name = "cxx"
		end
		if not (this_cfg == cfg) then
			rule_name = rule_name .. "_" .. sha1(rule_command)
		end
		rules[rule_command] = rule_name
	  
		-- this rule is not available yet. Let's add it...
		p.w("rule " .. rule_name)
		if toolset_name == "msc" then
			p.w("  command = " .. rule_command .. " /nologo -c $in /Fo$out")
			p.w("  description = " .. rule_name .. " $out")
			p.w("  deps = msvc")
		else
			p.w("  command = " .. rule_command .. " -MMD -MF $out.d -c -o $out $in")
			p.w("  description = " .. rule_name .. " $out")
			p.w("  depfile = $out.d")
			p.w("  deps = gcc") -- Clang does actually also uses this setting
		end
		p.w("")
		return
	end
	local rules_compile_get_name = function(this_cfg, is_c)
		local rule_command = compile_getcommand(this_cfg, is_c)
		local rule_name = rules[rule_command]
		assert(rule_name)
		return rule_name
	end

	rule_compile_add(cfg, true)
	rule_compile_add(cfg, false)
	tree.traverse(project.getsourcetree(prj), {
	onleaf = function(node, depth)
		local filecfg = fileconfig.getconfig(node, cfg)
		if path.iscppfile(filecfg.abspath) then
			rule_compile_add(filecfg, ninja.endsWith(filecfg.abspath, ".c"))
		end
	end,
	}, false, 1)

	---------------------------------------------------- write linking rule
	local all_ldflags
	if cc == link then 
	all_ldflags = buildopt(cfg) .. ldflags(cfg)
	else
	all_ldflags = ldflags(cfg)
	end
      
	-- we don't pass getlinks(cfg) through dependencies
	-- because system libraries are often not in PATH so ninja can't find them

	-- experimental feature, change install_name of shared libs
	--if (toolset_name == "clang") and (cfg.kind == p.SHAREDLIB) and ninja.endsWith(cfg.buildtarget.name, ".dylib") then
	--	ldflags = ldflags .. " -install_name " .. cfg.buildtarget.name
	--end
  
	p.w("rule link")
	if toolset_name == "msc" then
		p.w("  command = " .. link .. " $in " .. ninja.list(ninja.shesc(toolset.getlinks(cfg))) .. " kernel32.lib user32.lib gdi32.lib winspool.lib " ..
			"comdlg32.lib advapi32.lib shell32.lib ole32.lib oleaut32.lib uuid.lib odbc32.lib odbccp32.lib /link " .. all_ldflags .. " /nologo /out:$out")
		p.w("  description = link $out")
	else
		p.w("  command = " .. link .. " -o $out $in " .. ninja.list(ninja.shesc(toolset.getlinks(cfg, "system"))) .. " " .. all_ldflags)
		p.w("  description = link $out")
	end
	p.w("")

	---------------------------------------------------- build all files
	p.w("# build files")
	local intermediateExt = function(cfg, var)
		if (var == "c") or (var == "cxx") then
			return iif(toolset_name == "msc", ".obj", ".o")
		elseif var == "res" then
			-- TODO
			return ".res"
		elseif var == "link" then
			return cfg.targetextension
		end
	end
	local objfiles = {}
	tree.traverse(project.getsourcetree(prj), {
	onleaf = function(node, depth)
		local filecfg = fileconfig.getconfig(node, cfg)
		if fileconfig.hasCustomBuildRule(filecfg) then
			-- TODO
		elseif path.iscppfile(filecfg.abspath) then
			objfilename = obj_dir .. "/" .. node.objname .. intermediateExt(cfg, "cxx")
			objfiles[#objfiles + 1] = objfilename
			local rule_compile_name = rules_compile_get_name(filecfg, ninja.endsWith(filecfg.abspath, ".c"))
			p.w("build " .. p.esc(objfilename) .. ": " .. rule_compile_name .. " " .. p.esc(node.vpath)) -- vpath is the relative path
		elseif path.isresourcefile(filecfg.abspath) then
			-- TODO
		end
	end,
	}, false, 1)
	p.w("")

	---------------------------------------------------- build final target
	local output_path = ninja.list(p.esc(config.getlinks(cfg, "siblings", "fullpath")))
	if cfg.kind == p.STATICLIB then
		p.w("# link static lib")
		p.w("build " .. p.esc(ninja.outputFilename(cfg)) .. ": ar " .. table.concat(p.esc(objfiles), " ") .. " " .. output_path)

	elseif cfg.kind == p.SHAREDLIB then
		local output = ninja.outputFilename(cfg)
		p.w("# link shared lib")
		p.w("build " .. p.esc(output) .. ": link " .. table.concat(p.esc(objfiles), " ") .. " " .. output_path)

		-- TODO I'm a bit confused here, previous build statement builds .dll/.so file
		-- but there are like no obvious way to tell ninja that .lib/.a is also build there
		-- and we use .lib/.a later on as dependency for linkage
		-- so let's create phony build statements for this, not sure if it's the best solution
		-- UPD this can be fixed by https://github.com/martine/ninja/pull/989
		if ninja.endsWith(output, ".dll") then
			p.w("build " .. p.esc(ninja.noext(output, ".dll")) .. ".lib: phony " .. p.esc(output))
		elseif ninja.endsWith(output, ".so") then
			p.w("build " .. p.esc(ninja.noext(output, ".so")) .. ".a: phony " .. p.esc(output))
		elseif ninja.endsWith(output, ".dylib") then
			-- but in case of .dylib there are no corresponding .a file
		else
			p.error("unknown type of shared lib '" .. output .. "', so no idea what to do, sorry")
		end

	elseif (cfg.kind == p.CONSOLEAPP) or (cfg.kind == p.WINDOWEDAPP) then
		p.w("# link executable")
		p.w("build " .. p.esc(ninja.outputFilename(cfg)) .. ": link " .. table.concat(p.esc(objfiles), " ") .. " " .. output_path)

	else
		p.error("ninja action doesn't support this kind of target " .. cfg.kind)
	end

	p.w("")
end

-- return name of output binary relative to build folder
function ninja.outputFilename(cfg)
	return project.getrelative(cfg.workspace, cfg.buildtarget.directory) .. "/" .. cfg.buildtarget.name
end

-- return name of build file for configuration
function ninja.projectCfgFilename(cfg, relative)
	if relative ~= nil then
		relative = project.getrelative(cfg.workspace, cfg.location) .. "/"
	else
		relative = ""
	end
	
	local ninjapath = relative .. "build_" .. cfg.project.name  .. "_" .. cfg.buildcfg
	
	if cfg.platform ~= nil then ninjapath = ninjapath .. "_" .. cfg.platform end
	
	return ninjapath .. ".ninja"
end

-- check if string starts with string
function ninja.startsWith(str, starts)
	return str:sub(0, starts:len()) == starts
end

-- check if string ends with string
function ninja.endsWith(str, ends)
	return str:sub(-ends:len()) == ends
end

-- removes extension from string
function ninja.noext(str, ext)
	return str:sub(0, str:len() - ext:len())
end

-- generate all build files for every project configuration
function ninja.generateProject(prj)
	for cfg in project.eachconfig(prj) do
		p.generate(cfg, ninja.projectCfgFilename(cfg), ninja.generateProjectCfg)
	end
end

include("_preload.lua")

return ninja
