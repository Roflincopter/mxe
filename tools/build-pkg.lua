#!/usr/bin/env lua

--[[
This file is part of MXE.
See index.html for further information.

build-pkg, Build binary packages from MXE packages
Instructions: http://pkg.mxe.cc

Requirements: MXE, lua, fakeroot, dpkg-deb.
Usage: lua tools/build-pkg.lua
Packages are written to `*.tar.xz` files.
Debian packages are written to `*.deb` files.

Build in directory /usr/lib/mxe
This directory can not be changed in .deb packages
To change this directory, set environment variable
MXE_DIR to other directory.

To prevent build-pkg from creating deb packages,
set environment variable MXE_NO_DEBS to 1
In this case fakeroot and dpkg-deb are not needed.

To limit number of packages being built to x,
set environment variable MXE_MAX_ITEMS to x,

The following error:
> fakeroot, while creating message channels: Invalid argument
> This may be due to a lack of SYSV IPC support.
> fakeroot: error while starting the `faked' daemon.
can be caused by leaked ipc resources originating in fakeroot.
How to remove them: http://stackoverflow.com/a/4262545
]]

local max_items = tonumber(os.getenv('MXE_MAX_ITEMS'))
local no_debs = os.getenv('MXE_NO_DEBS')

local TODAY = os.date("%Y%m%d")

local MXE_DIR = os.getenv('MXE_DIR') or '/usr/lib/mxe'

local GIT = 'git --work-tree=./usr/ --git-dir=./usr/.git '
local GIT_USER = '-c user.name="build-pkg" ' ..
    '-c user.email="build-pkg@mxe" '

local BLACKLIST = {
    '^usr/installed/check%-requirements$',
    -- usr/share/cmake is useful
    '^usr/share/doc/',
    '^usr/share/info/',
    '^usr/share/man/',
    '^usr/share/gcc',
    '^usr/lib/nonetwork.so',
    '^usr/[^/]+/share/doc/',
    '^usr/[^/]+/share/info/',
}

local TARGETS = {
    'i686-w64-mingw32.static',
    'x86_64-w64-mingw32.static',
    'i686-w64-mingw32.shared',
    'x86_64-w64-mingw32.shared',
}

local function echo(fmt, ...)
    print(fmt:format(...))
    io.stdout:flush()
end

local function log(fmt, ...)
    echo('[build-pkg]\t' .. fmt, ...)
end

-- based on http://lua-users.org/wiki/SplitJoin
local function split(self, sep, nMax, plain)
    if not sep then
        sep = '%s+'
    end
    assert(sep ~= '')
    assert(nMax == nil or nMax >= 1)
    local aRecord = {}
    if self:len() > 0 then
        nMax = nMax or -1
        local nField = 1
        local nStart = 1
        local nFirst, nLast = self:find(sep, nStart, plain)
        while nFirst and nMax ~= 0 do
            aRecord[nField] = self:sub(nStart, nFirst - 1)
            nField = nField + 1
            nStart = nLast + 1
            nFirst, nLast = self:find(sep, nStart, plain)
            nMax = nMax - 1
        end
        aRecord[nField] = self:sub(nStart)
    end
    return aRecord
end

local function trim(str)
    local text = str:gsub("%s+$", "")
    text = text:gsub("^%s+", "")
    return text
end

local function isInArray(element, array)
    for _, member in ipairs(array) do
        if member == element then
            return true
        end
    end
    return false
end

local function sliceArray(list, nelements)
    nelements = nelements or #list
    local new_list = {}
    for i = 1, nelements do
        new_list[i] = list[i]
    end
    return new_list
end

local function concatArrays(...)
    local result = {}
    for _, array in ipairs({...}) do
        for _, elem in ipairs(array) do
            table.insert(result, elem)
        end
    end
    return result
end

local function isInString(substring, string)
    return string:find(substring, 1, true)
end

local function shell(cmd)
    local f = io.popen(cmd, 'r')
    local text = f:read('*all')
    f:close()
    return text
end

local function execute(cmd)
    if _VERSION == 'Lua 5.1' then
        return os.execute(cmd) == 0
    else
        -- Lua >= 5.2
        return os.execute(cmd)
    end
end

-- for tar, try gtar and gnutar first
local tools = {}
local function tool(name)
    if tools[name] then
        return tools[name]
    end
    if execute(("g%s --help > /dev/null 2>&1"):format(name)) then
        tools[name] = 'g' .. name
    elseif execute(("gnu%s --help > /dev/null 2>&1"):format(name)) then
        tools[name] = 'gnu' .. name
    else
        tools[name] = name
    end
    return tools[name]
end

local function fileExists(name)
    local f = io.open(name, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
end

local function writeFile(filename, data)
    local file = io.open(filename, 'w')
    file:write(data)
    file:close()
end

local NATIVE_TARGET = trim(shell("ext/config.guess"))
local function isCross(target)
    return target ~= NATIVE_TARGET
end

local function getArch()
    local cmd = "dpkg-architecture -qDEB_BUILD_ARCH 2> /dev/null"
    return trim(shell(cmd))
end
local ARCH = getArch()

-- return target and package from item name
local function parseItem(item)
    return item:match("([^~]+)~([^~]+)")
end

-- return item name from target and package
local function makeItem(target, package)
    return target .. '~' .. package
end

-- return several tables describing packages for all targets
-- * list of items
-- * map from item to list of deps (which are also items)
-- * map from item to version
-- Item is a string like "target~pkg"
local function getItems()
    local items = {}
    local item2deps = {}
    local item2ver = {}
    local cmd = '%s print-deps-for-build-pkg MXE_TARGETS=%q'
    cmd = cmd:format(tool 'make', table.concat(TARGETS, ' '))
    local make = io.popen(cmd)
    for line in make:lines() do
        local deps = split(trim(line))
        if deps[1] == 'for-build-pkg' then
            -- first value is marker 'for-build-pkg'
            table.remove(deps, 1)
            -- first value is name of package which depends on
            local item = table.remove(deps, 1)
            -- second value is version of package
            local ver = table.remove(deps, 1)
            table.insert(items, item)
            item2deps[item] = deps
            item2ver[item] = ver
            local target, _ = parseItem(item)
            for _, dep_item in ipairs(deps) do
                local target2, _ = parseItem(dep_item)
                if isCross(target2) and target2 ~= target then
                    log("Cross-target dependency %s -> %s",
                        target2, target)
                end
            end
        end
    end
    make:close()
    return items, item2deps, item2ver
end

local function getInstalled()
    local installed = {}
    local f = io.popen('ls usr/*/installed/*')
    local pattern = '/([^/]+)/installed/([^/]+)'
    for file in f:lines() do
        local target, pkg = assert(file:match(pattern))
        table.insert(installed, makeItem(target, pkg))
    end
    f:close()
    return installed
end

-- graph is a map from item to a list of destinations
local function transpose(graph)
    local transposed = {}
    for item, destinations in pairs(graph) do
        for _, dest in ipairs(destinations) do
            if not transposed[dest] then
                transposed[dest] = {}
            end
            table.insert(transposed[dest], item)
        end
    end
    return transposed
end

local function reverse(list)
    local n = #list
    local reversed = {}
    for i = 1, n do
        reversed[i] = list[n - i + 1]
    end
    return reversed
end

-- return items ordered in build order
-- this means, if item depends on item2, then
-- item2 preceeds item1 in the list
local function sortForBuild(items, item2deps)
    local n = #items
    local item2followers = transpose(item2deps)
    -- Tarjan's algorithm
    -- https://en.wikipedia.org/wiki/Topological_sorting
    local build_list_reversed = {}
    local marked_permanently = {}
    local marked_temporarily = {}
    local function visit(item1)
        assert(not marked_temporarily[item1], 'not a DAG')
        if not marked_permanently[item1] then
            marked_temporarily[item1] = true
            local followers = item2followers[item1] or {}
            for _, item2 in ipairs(followers) do
                visit(item2)
            end
            marked_permanently[item1] = true
            marked_temporarily[item1] = false
            table.insert(build_list_reversed, item1)
        end
    end
    for _, item in ipairs(items) do
        if not marked_permanently[item] then
            visit(item)
        end
    end
    assert(#build_list_reversed == n)
    local build_list = reverse(build_list_reversed)
    assert(#build_list == n)
    return build_list
end

local function makeItem2Index(build_list)
    local item2index = {}
    for index, item in ipairs(build_list) do
        assert(not item2index[item], 'Duplicate item')
        item2index[item] = index
    end
    return item2index
end

-- return if build_list is ordered topologically
local function isTopoOrdered(build_list, items, item2deps)
    if #build_list ~= #items then
        return false, 'Length of build_list is wrong'
    end
    local item2index = makeItem2Index(build_list)
    for item, deps in pairs(item2deps) do
        for _, dep in ipairs(deps) do
            if item2index[item] < item2index[dep] then
                return false, 'Item ' .. item ..
                    'is built before its dependency ' ..
                    dep
            end
        end
    end
    return true
end

local function isListed(file, list)
    for _, pattern in ipairs(list) do
        if file:match(pattern) then
            return true
        end
    end
    return false
end

local function isBlacklisted(file)
    return isListed(file, BLACKLIST)
end

local GIT_INITIAL = 'initial'
local GIT_ALL = 'first-all'

local function itemToBranch(item)
    return 'first-' .. item:gsub('~', '_')
end

-- creates git repo in ./usr
local function gitInit()
    os.execute('mkdir -p ./usr')
    os.execute(GIT .. 'init --quiet')
end

local function gitTag(name)
    os.execute(GIT .. 'tag ' .. name)
end

local function gitConflicts()
    local cmd = GIT .. 'diff --name-only --diff-filter=U'
    local f = io.popen(cmd, 'r')
    local conflicts = {}
    for conflict in f:lines() do
        table.insert(conflicts, conflict)
    end
    f:close()
    return conflicts
end

-- git commits changes in ./usr
local function gitCommit(message)
    local cmd = GIT .. GIT_USER .. 'commit -a -m %q --quiet'
    assert(execute(cmd:format(message)))
end

local function gitCheckout(new_branch, deps, item2index)
    local main_dep = deps[1]
    if main_dep then
        main_dep = itemToBranch(main_dep)
    else
        main_dep = GIT_INITIAL
    end
    local cmd = '%s checkout -q -b %s %s'
    assert(execute(cmd:format(GIT, new_branch, main_dep)))
    -- merge with other dependencies
    for i = 2, #deps do
        local message = 'Merge with ' .. deps[i]
        local cmd2 = '%s %s merge -q %s -m %q'
        if not execute(cmd2:format(GIT,
            GIT_USER,
            itemToBranch(deps[i]),
            message))
        then
            -- probably merge conflict
            local conflicts = table.concat(gitConflicts(), ' ')
            log('Merge conflicts: %s', conflicts)
            local cmd3 = '%s checkout --ours %s'
            assert(execute(cmd3:format(GIT, conflicts)))
            gitCommit(message)
        end
    end
    if #deps > 0 then
        -- prevent accidental rebuilds
        -- touch usr/*/installed/* files in build order
        -- see https://git.io/vuDJY
        local installed = getInstalled()
        table.sort(installed, function(x, y)
            return item2index[x] < item2index[y]
        end)
        for _, item in ipairs(installed) do
            local target, pkg = assert(parseItem(item))
            local cmd4 = 'touch -c usr/%s/installed/%s'
            execute(cmd4:format(target, pkg))
        end
    end
end

local function gitAdd()
    os.execute(GIT .. 'add .')
end

-- return two lists of filepaths under ./usr/
-- 1. new files
-- 2. changed files
local function gitStatus()
    local new_files = {}
    local changed_files = {}
    local git_st = io.popen(GIT .. 'status --porcelain', 'r')
    for line in git_st:lines() do
        local status, file = line:match('(..) (.*)')
        status = trim(status)
        if file:sub(1, 1) == '"' then
            -- filename with a space is quoted by git
            file = file:sub(2, -2)
        end
        file = 'usr/' .. file
        if not fileExists(file) then
            log('Missing file: %q', file)
        elseif not isBlacklisted(file) then
            if status == 'A' then
                table.insert(new_files, file)
            elseif status == 'M' then
                table.insert(changed_files, file)
            else
                log('Strange git status: %q of %q',
                    status, file)
            end
        end
    end
    git_st:close()
    return new_files, changed_files
end

local function isValidBinary(target, file)
    local cmd = './usr/bin/%s-objdump -t %s > /dev/null 2>&1'
    return execute(cmd:format(target, file))
end

local function checkFile(file, item)
    local target, _ = parseItem(item)
    -- if it is PE32 file, it must have '.exe' in name
    local ext = file:sub(-4):lower()
    local cmd = 'file --dereference --brief %q'
    local file_type = trim(shell(cmd:format(file)))
    if ext == '.exe' then
        if not file_type:match('PE32') then
            log('File %s (%s) is %q. Remove .exe',
                file, item, file_type)
        end
    elseif ext == '.dll' then
        if not file_type:match('PE32.*DLL') then
            log('File %s (%s) is %q. Remove .dll',
                file, item, file_type)
        end
    elseif ext ~= '.bin' then
        -- .bin can be an executable or something else (font)
        if file_type:match('PE32') then
            log('File %s (%s) is %q. Add exe or dll',
                file, item, file_type)
        end
    end
    for _, t in ipairs(TARGETS) do
        if t ~= target and isInString(t, file) then
            log('File %s (%s): other target %s in name',
                file, item, t)
        end
    end
    if file:match('/lib/.*%.dll$') then
        log('File %s (%s): DLL in /lib/', file, item)
    end
    if file:match('%.dll$') or file:match('%.a$') then
        if isInString(target, file) and isCross(target) then
            -- cross-compiled
            if not isValidBinary(target, file) then
                log('File %s (%s): not recognized library',
                    file, item)
            end
        end
    end
end

local function checkFileList(files, item)
    local target, _ = parseItem(item)
    if target:match('shared') then
        local has_a, has_dll
        for _, file in ipairs(files) do
            file = file:lower()
            if file:match('%.a') then
                has_a = true
            end
            if file:match('%.dll') then
                has_dll = true
            end
        end
        if has_a and not has_dll then
            log('Shared item %s installs .a file ' ..
                'but no .dll', item)
        end
    end
end

local function removeEmptyDirs(item)
    -- removing an empty dir can reveal another one (parent)
    local go_on = true
    while go_on do
        go_on = false
        local f = io.popen('find usr/* -empty -type d', 'r')
        for dir in f:lines() do
            log("Remove empty directory %s created by %s",
                dir, item)
            os.remove(dir)
            go_on = true
        end
        f:close()
    end
end

-- builds package, returns list of new files
local function buildItem(item, item2deps, file2item, item2index)
    gitCheckout(itemToBranch(item), item2deps[item], item2index)
    local target, pkg = parseItem(item)
    local cmd = '%s %s MXE_TARGETS=%s --jobs=1'
    os.execute(cmd:format(tool 'make', pkg, target))
    gitAdd()
    local new_files, changed_files = gitStatus()
    if #new_files + #changed_files > 0 then
        gitCommit(("Build %s"):format(item))
    end
    for _, file in ipairs(new_files) do
        checkFile(file, item)
        file2item[file] = item
    end
    for _, file in ipairs(changed_files) do
        checkFile(file, item)
        -- add a dependency on a package created this file
        local creator_item = assert(file2item[file])
        if not isInArray(creator_item, item2deps[item]) then
            table.insert(item2deps[item], creator_item)
        end
        log('Item %s changes %s, created by %s',
            item, file, creator_item)
    end
    checkFileList(concatArrays(new_files, changed_files), item)
    removeEmptyDirs(item)
    return new_files
end

local function nameToDebian(item)
    item = item:gsub('[~_]', '-')
    local name = 'mxe-%s'
    return name:format(item)
end

local function protectVersion(ver)
    ver = ver:gsub('_', '.')
    if ver:sub(1, 1):match('%d') then
        return ver
    else
        -- version number does not start with digit
        return '0.' .. ver
    end
end

local CONTROL = [[Package: %s
Version: %s
Section: devel
Priority: optional
Architecture: %s%s
Maintainer: Boris Nagaev <bnagaev@gmail.com>
Homepage: http://mxe.cc
Description: %s
 MXE (M cross environment) is a Makefile that compiles
 a cross compiler and cross compiles many free libraries
 such as SDL and Qt for various target platforms (MinGW).
 .
 %s
]]

local function debianControl(options)
    local deb_deps_str = ''
    if #options.deps >= 1 then
        deb_deps_str = '\n' .. 'Depends: ' ..
            table.concat(options.deps, ', ')
    end
    local version = options.version .. '-' .. TODAY
    return CONTROL:format(
        options.package,
        version,
        options.arch,
        deb_deps_str,
        options.description1,
        options.description2
    )
end

local function makePackage(name, files, deps, ver, d1, d2, dst)
    dst = dst or '.'
    local dirname = ('%s/%s_%s'):format(dst, name,
        protectVersion(ver))
    -- make .list file
    local list_path = ('%s/%s.list'):format(dst, name)
    writeFile(list_path, table.concat(files, "\n") .. "\n")
    -- make .tar.xz file
    local tar_name = dirname .. '.tar.xz'
    local cmd1 = '%s -T %s --owner=root --group=root -cJf %s'
    os.execute(cmd1:format(tool 'tar', list_path, tar_name))
    -- update list of files back from .tar.xz (see #1067)
    local cmd2 = '%s -tf %s'
    cmd2 = cmd2:format(tool 'tar', tar_name)
    local tar_reader = io.popen(cmd2, 'r')
    local files_str = tar_reader:read('*all')
    tar_reader:close()
    writeFile(list_path, files_str)
    -- make DEBIAN/control file
    local control_text = debianControl {
        package = name,
        version = protectVersion(ver),
        arch = ARCH,
        deps = deps,
        description1 = d1,
        description2 = d2,
    }
    writeFile(dirname .. ".deb-control", control_text)
    if not no_debs then
        -- unpack .tar.xz to the path for Debian
        local usr = dirname .. MXE_DIR
        os.execute(('mkdir -p %s'):format(usr))
        os.execute(('mkdir -p %s/DEBIAN'):format(dirname))
        -- use tar to copy files with paths
        local cmd3 = '%s -C %s -xf %s'
        cmd3 = 'fakeroot -s deb.fakeroot ' .. cmd3
        os.execute(cmd3:format(tool 'tar', usr, tar_name))
        -- make DEBIAN/control file
        local control_fname = dirname .. '/DEBIAN/control'
        writeFile(control_fname, control_text)
        -- make .deb file
        local cmd4 = 'dpkg-deb -Zxz -b %s'
        cmd4 = 'fakeroot -i deb.fakeroot ' .. cmd4
        os.execute(cmd4:format(dirname))
        -- cleanup
        os.execute(('rm -fr %s deb.fakeroot'):format(dirname))
    end
end

local D1 = "MXE package %s for %s"
local D2 = "This package contains the files for MXE package %s"

local function makeDeb(item, files, deps, ver)
    local target, pkg = parseItem(item)
    local deb_pkg = nameToDebian(item)
    local d1 = D1:format(pkg, target)
    local d2 = D2:format(pkg)
    local deb_deps = {'mxe-requirements', 'mxe-source'}
    for _, dep in ipairs(deps) do
        table.insert(deb_deps, nameToDebian(dep))
    end
    makePackage(deb_pkg, files, deb_deps, ver, d1, d2)
end

local function isBuilt(item, files)
    local target, pkg = parseItem(item)
    local INSTALLED = 'usr/%s/installed/%s'
    local installed = INSTALLED:format(target, pkg)
    for _, file in ipairs(files) do
        if file == installed then
            return true
        end
    end
    return false
end

local function findForeignInstalls(item, files)
    for _, file in ipairs(files) do
        local pattern = 'usr/([^/]+)/installed/([^/]+)'
        local t, p = file:match(pattern)
        if t and p ~= '.gitkeep' then
            local item1 = makeItem(t, p)
            if item1 ~= item then
                log('Item %s built item %s', item, item1)
            end
        end
    end
end

-- script building HUGE_TIMES from MXE main log
-- https://gist.github.com/starius/3ea9d953b0c30df88aa7
local HUGE_TIMES = {
    [7] = {"ocaml-native", "ffmpeg", "boost"},
    [9] = {"openssl", "qtdeclarative", "ossim", "wxwidgets"},
    [12] = {"ocaml-core", "itk", "wt"},
    [19] = {"gcc", "qtbase", "llvm"},
    [24] = {"vtk", "vtk6", "openscenegraph"},
    [36] = {"openblas", "pcl", "oce"},
    [51] = {"qt"},
}

local PROGRESS = "[%3d/%d] " ..
    "The build is expected to complete in %0.1f hours, " ..
    "on %s"

local function progressPrinter(items)
    local pkg2time = {}
    for time, pkgs in pairs(HUGE_TIMES) do
        for _, pkg in ipairs(pkgs) do
            pkg2time[pkg] = time
        end
    end
    --
    local started_at = os.time()
    local sums = {}
    for i, item in ipairs(items) do
        local _, pkg = parseItem(item)
        local expected_time = pkg2time[pkg] or 1
        sums[i] = (sums[i - 1] or 0) + expected_time
    end
    local total_time = sums[#sums]
    local time_done = 0
    local pkgs_done = 0
    local printer = {}
    --
    function printer.advance(_, i)
        pkgs_done = i
        time_done = sums[i]
    end
    function printer.status(_)
        local now = os.time()
        local spent = now - started_at
        local predicted_duration = spent * total_time / time_done
        local predicted_end = started_at + predicted_duration
        local predicted_end_str = os.date("%c", math.floor(predicted_end + 0.5))
        local predicted_wait = predicted_end - now
        local predicted_wait_hours = predicted_wait / 3600.0
        return PROGRESS:format(pkgs_done, #items,
             predicted_wait_hours, predicted_end_str)
    end
    return printer
end

local function isEmpty(files)
    return #files == 1
end

-- build all packages, save filelist to list file
local function buildPackages(items, item2deps)
    local broken = {}
    local unbroken = {}
    local file2item = {}
    local item2files = {}
    local function brokenDep(item)
        for _, dep in ipairs(item2deps[item]) do
            if broken[dep] then
                return dep
            end
        end
        return false
    end
    local item2index = makeItem2Index(items)
    local progress_printer = progressPrinter(items)
    for i, item in ipairs(items) do
        if not brokenDep(item) then
            local files = buildItem(item, item2deps,
                file2item, item2index)
            findForeignInstalls(item, files)
            if isBuilt(item, files) then
                item2files[item] = files
                table.insert(unbroken, item)
            else
                -- broken package
                broken[item] = true
                log('Item is broken: %s', item)
            end
        else
            broken[item] = true
            log('Item %s depends on broken item %s',
                item, brokenDep(item))
        end
        progress_printer:advance(i)
        echo(progress_printer:status())
    end
    return unbroken, item2files
end

local function makeDebs(items, item2deps, item2ver, item2files)
    -- start from building non-empty packages
    local to_build = {}
    for _, item in ipairs(items) do
        local files = assert(item2files[item], item)
        if not isEmpty(files) then
            table.insert(to_build, item)
        end
    end
    local built = {}
    repeat
        local missing_deps_set = {}
        for _, item in ipairs(to_build) do
            local deps = assert(item2deps[item], item)
            local ver = assert(item2ver[item], item)
            local files = assert(item2files[item], item)
            for _, dep in ipairs(deps) do
                local dep_files = item2files[dep]
                if isEmpty(dep_files) then
                    log('Item %s depends on ' ..
                        'empty item %s', item, dep)
                    missing_deps_set[dep] = true
                end
            end
            makeDeb(item, files, deps, ver)
            built[item] = true
        end
        -- empty packages built to satisfy non-empty
        to_build = {}
        for item in pairs(missing_deps_set) do
            if not built[item] then
                table.insert(to_build, item)
            end
        end
    until #to_build == 0
end

local function getMxeVersion()
    local index_html = io.open 'index.html'
    local text = index_html:read('*all')
    index_html:close()
    return text:match('Release ([^<]+)')
end

local MXE_REQUIREMENTS_DESCRIPTION2 =
[[This package depends on all Debian dependencies of MXE.
 Other MXE packages depend on this package.]]

local function makeMxeRequirementsPackage(release)
    os.execute(('mkdir -p %s'):format(release))
    local name = 'mxe-requirements'
    local ver = getMxeVersion() .. release
    -- dependencies
    local deps = {
        'autoconf', 'automake', 'autopoint', 'bash', 'bison',
        'bzip2', 'cmake', 'flex', 'gettext', 'git', 'g++',
        'gperf', 'intltool', 'libffi-dev', 'libtool',
        'libltdl-dev', 'libssl-dev', 'libxml-parser-perl',
        'make', 'openssl', 'patch', 'perl', 'p7zip-full',
        'pkg-config', 'python', 'ruby', 'scons', 'sed',
        'unzip', 'wget', 'xz-utils',
        'g++-multilib', 'libc6-dev-i386',
    }
    if release ~= 'wheezy' then
        -- Jessie+
        table.insert(deps, 'libtool-bin')
    end
    local dummy_name = 'mxe-requirements.dummy.' .. release
    local dummy = io.open(dummy_name, 'w')
    dummy:close()
    local files = {dummy_name}
    local d1 = "MXE requirements package"
    local d2 = MXE_REQUIREMENTS_DESCRIPTION2
    local dst = release
    makePackage(name, files, deps, ver, d1, d2, dst)
    os.remove(dummy_name)
end

local MXE_SOURCE_DESCRIPTION2 =
[[This package contains MXE source files.
 Other MXE packages depend on this package.]]

local function makeMxeSourcePackage()
    local name = 'mxe-source'
    local ver = getMxeVersion()
    -- dependencies
    local deps = {}
    local files = {
        'CNAME',
        'LICENSE.md',
        'Makefile',
        'patch.mk',
        'README.md',
        'assets',
        'doc',
        'ext',
        'index.html',
        'src',
        'plugins',
        'tools',
        'versions.json',
    }
    local d1 = "MXE source"
    local d2 = MXE_SOURCE_DESCRIPTION2
    makePackage(name, files, deps, ver, d1, d2)
end

assert(not io.open('usr/.git'), 'Remove usr/')
assert(trim(shell('pwd')) == MXE_DIR,
    "Clone MXE to " .. MXE_DIR)
gitInit()
assert(execute(("%s check-requirements MXE_TARGETS=%q"):format(
    tool 'make', table.concat(TARGETS, ' '))))
if not max_items then
    local cmd = ('%s download -j 6 -k'):format(tool 'make')
    while not execute(cmd) do end
end
gitAdd()
gitCommit('Initial commit')
gitTag(GIT_INITIAL)
local items, item2deps, item2ver = getItems()
local build_list = sortForBuild(items, item2deps)
assert(isTopoOrdered(build_list, items, item2deps))
build_list = sliceArray(build_list, max_items)
local unbroken, item2files = buildPackages(build_list, item2deps)
gitCheckout(GIT_ALL, unbroken, makeItem2Index(build_list))
makeDebs(unbroken, item2deps, item2ver, item2files)
if not no_debs then
    makeMxeRequirementsPackage('wheezy')
    makeMxeRequirementsPackage('jessie')
end
makeMxeSourcePackage()
if #unbroken < #build_list then
    local code = 1
    local close = true
    os.exit(code, close)
end
