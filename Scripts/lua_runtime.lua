local function now_ms()
    return math.floor(os.clock() * 1000)
end

local function json_escape(str)
    return str
        :gsub("\\", "\\\\")
        :gsub("\"", "\\\"")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
end

local function stringify(value, seen)
    seen = seen or {}
    local t = type(value)
    if t == "nil" then
        return "nil"
    elseif t == "string" then
        return value
    elseif t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "table" then
        if seen[value] then
            return "<circular>"
        end
        seen[value] = true
        local parts = {}
        for k, v in pairs(value) do
            parts[#parts + 1] = tostring(k) .. "=" .. stringify(v, seen)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    else
        return "<" .. t .. ">"
    end
end

local function is_array(tbl)
    if type(tbl) ~= "table" then
        return false
    end
    local max = 0
    local count = 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
            return false
        end
        if k > max then
            max = k
        end
        count = count + 1
    end
    return max == count
end

local function json_encode(value, seen)
    seen = seen or {}
    local t = type(value)
    if t == "nil" then
        return "null"
    elseif t == "string" then
        return "\"" .. json_escape(value) .. "\""
    elseif t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "table" then
        if seen[value] then
            return "\"<circular>\""
        end
        seen[value] = true
        if is_array(value) then
            local parts = {}
            for i = 1, #value do
                parts[#parts + 1] = json_encode(value[i], seen)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, v in pairs(value) do
            parts[#parts + 1] = "\"" .. json_escape(tostring(k)) .. "\":" .. json_encode(v, seen)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    else
        return "\"" .. json_escape("<" .. t .. ">") .. "\""
    end
end

local function quoted(arg)
    return "'" .. tostring(arg):gsub("'", "'\\''") .. "'"
end

local function run_shell(command)
    local marker = "__WISP_STATUS__"
    local wrapped = command .. " 2>&1; printf '\\n" .. marker .. ":%s' $?"
    local pipe = io.popen(wrapped)
    if not pipe then
        return 1, "failed to start shell command"
    end
    local raw = pipe:read("*a") or ""
    pipe:close()
    local idx = raw:match(".*()" .. marker .. ":%d+")
    if not idx then
        return 1, raw
    end
    local body = raw:sub(1, idx - 1)
    local status = tonumber(raw:match(marker .. ":(%d+)")) or 1
    return status, body
end

local function normalize_search_result(status, text)
    local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if status == 1 and trimmed == "" then
        return 0, "No matches found."
    end
    return status, text
end

local function detect_workspace_root()
    local status, text = run_shell("pwd -P")
    local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if status ~= 0 or trimmed == "" then
        return "."
    end
    return trimmed
end

local workspace_root = detect_workspace_root()

local function resolve_path(path)
    local raw = tostring(path or "")
    local combined = raw
    if raw:sub(1, 1) ~= "/" then
        if workspace_root:sub(-1) == "/" then
            combined = workspace_root .. raw
        else
            combined = workspace_root .. "/" .. raw
        end
    end

    local normalized = {}
    for part in combined:gmatch("[^/]+") do
        if part == "." or part == "" then
            -- skip
        elseif part == ".." then
            if #normalized > 0 then
                table.remove(normalized)
            end
        else
            normalized[#normalized + 1] = part
        end
    end
    return "/" .. table.concat(normalized, "/")
end

local function ensure_writable_path(path, tool_name)
    local resolved = resolve_path(path)
    if resolved == workspace_root or resolved:sub(1, #workspace_root + 1) == workspace_root .. "/" then
        return resolved
    end
    error(tool_name .. ": refusing write outside workspace root: " .. workspace_root)
end

function terminal(command)
    local started = now_ms()
    local status, text = run_shell(command)
    return {
        status_code = status,
        text = text,
        duration_ms = now_ms() - started
    }
end

function read_file(path, offset, limit)
    offset = tonumber(offset or 0) or 0
    limit = tonumber(limit or 200) or 200
    local file = io.open(path, "r")
    if not file then
        error("read_file: cannot open path: " .. tostring(path))
    end
    local full = file:read("*a") or ""
    file:close()

    local all_lines = {}
    if full == "" then
        all_lines[1] = ""
    else
        full = full:gsub("\r\n", "\n")
        if full:sub(-1) ~= "\n" then
            full = full .. "\n"
        end
        for line in full:gmatch("(.-)\n") do
            all_lines[#all_lines + 1] = line
        end
        if #all_lines == 0 then
            all_lines[1] = ""
        end
    end

    local lines = {}
    local total = #all_lines
    local start_idx = math.max(offset + 1, 1)
    local end_idx = math.min(start_idx + math.max(limit, 0) - 1, total)
    for i = start_idx, end_idx do
        lines[#lines + 1] = all_lines[i]
    end

    return { content = table.concat(lines, "\n"), total_lines = total }
end

function write_file(path, content)
    local resolved_path = ensure_writable_path(path, "write_file")
    local file = io.open(resolved_path, "w")
    if not file then
        error("write_file: cannot open path: " .. tostring(resolved_path))
    end
    file:write(content or "")
    file:close()
    return { ok = true, bytes = #(content or "") }
end

function patch(spec)
    if type(spec) ~= "table" then
        error("patch: expected table spec")
    end
    local path = spec.path
    local find = spec.find
    local replace = spec.replace or ""
    local all = spec.all ~= false
    if not path or not find then
        error("patch: path and find are required")
    end
    local resolved_path = ensure_writable_path(path, "patch")

    local file = io.open(resolved_path, "r")
    if not file then
        error("patch: cannot open path: " .. tostring(resolved_path))
    end
    local content = file:read("*a")
    file:close()

    local escaped = find:gsub("([^%w])", "%%%1")
    local count
    if all then
        content, count = content:gsub(escaped, replace)
    else
        content, count = content:gsub(escaped, replace, 1)
    end

    local out = io.open(resolved_path, "w")
    if not out then
        error("patch: cannot write path: " .. tostring(resolved_path))
    end
    out:write(content)
    out:close()

    return { ok = true, replacements = count }
end

function search_files(pattern, root)
    root = root or "."
    if root == "/" then
        return { status_code = 1, text = "Refusing search_files on '/'. Use a narrower root path." }
    end
    local cmd = "rg --line-number --no-heading --color never " .. quoted(pattern) .. " " .. quoted(root)
    local status, text = run_shell(cmd)
    status, text = normalize_search_result(status, text)
    return { status_code = status, text = text }
end

function list_files(root)
    root = root or "."
    if root == "/" then
        return { status_code = 1, text = "Refusing list_files on '/'. Use a narrower root path." }
    end
    local cmd = "find " .. quoted(root) .. " -mindepth 1 -print 2>/dev/null"
    local status, text = run_shell(cmd)
    return { status_code = status, text = text }
end

function find_files(pattern, root)
    root = root or "."
    if root == "/" then
        return { status_code = 1, text = "Refusing find_files on '/'. Use a narrower root path." }
    end
    local cmd = "find " .. quoted(root) .. " -mindepth 1 -print 2>/dev/null | rg --fixed-strings --color never " .. quoted(pattern)
    local status, text = run_shell(cmd)
    status, text = normalize_search_result(status, text)
    return { status_code = status, text = text }
end

local function emit(status_code, text, runtime_duration_ms)
    local json = string.format(
        "{\"status_code\":%d,\"text\":\"%s\",\"runtime_duration_ms\":%d}",
        status_code,
        json_escape(text or ""),
        runtime_duration_ms
    )
    print(json)
end

local start_ms = now_ms()
local code = io.read("*a") or ""

local env = {
    terminal = terminal,
    read_file = read_file,
    write_file = write_file,
    patch = patch,
    search_files = search_files,
    list_files = list_files,
    find_files = find_files,
    ipairs = ipairs,
    math = math,
    next = next,
    pairs = pairs,
    string = string,
    table = table,
    tonumber = tonumber,
    tostring = tostring,
    type = type
}

local chunk, load_err = load(code, "model_code", "t", env)
if not chunk then
    emit(1, load_err, now_ms() - start_ms)
    os.exit(0)
end

local ok, result = pcall(chunk)
if not ok then
    emit(1, result, now_ms() - start_ms)
    os.exit(0)
end

if result == nil then
    emit(1, "Lua code returned nil. Use `return <runtime_command>(...)` so tool output is captured.", now_ms() - start_ms)
elseif type(result) == "table" and result.status_code ~= nil and result.text ~= nil then
    emit(tonumber(result.status_code) or 0, tostring(result.text), now_ms() - start_ms)
elseif type(result) == "table" then
    emit(0, json_encode(result), now_ms() - start_ms)
else
    emit(0, stringify(result), now_ms() - start_ms)
end
