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

local function run_helper(command)
    local marker = "__WISP_STATUS__"
    local wrapped = "{ " .. command .. "; } 2>&1; printf '\\n" .. marker .. ":%s' $?"
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

local workspace_root = os.getenv("WISP_WORKSPACE_ROOT") or "."
local helper_bin = os.getenv("WISP_CHAT_HELPER_BIN") or ""

local READ_MAX_LINES = 2000
local BASH_DEFAULT_TIMEOUT_MS = 15000

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

local function split_lines(text)
    local out = {}
    if text == "" then
        out[1] = ""
        return out
    end
    local normalized = (text or ""):gsub("\r\n", "\n")
    if normalized:sub(-1) ~= "\n" then
        normalized = normalized .. "\n"
    end
    for line in normalized:gmatch("(.-)\n") do
        out[#out + 1] = line
    end
    if #out == 0 then
        out[1] = ""
    end
    return out
end

local function contract(status_code, stdout, stderr, truncation_mode)
    return {
        status_code = tonumber(status_code or 0) or 0,
        stdout = stdout or "",
        stderr = stderr or "",
        truncation_mode = truncation_mode or "head"
    }
end

local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64_decode(data)
    if not data or data == "" then
        return ""
    end
    data = data:gsub("[^" .. b .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then
            return ""
        end
        local r, f = "", (b:find(x, 1, true) or 1) - 1
        for i = 6, 1, -1 do
            r = r .. ((f % 2 ^ i - f % 2 ^ (i - 1) > 0) and "1" or "0")
        end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then
            return ""
        end
        local c = 0
        for i = 1, 8 do
            c = c + ((x:sub(i, i) == "1") and 2 ^ (8 - i) or 0)
        end
        return string.char(c)
    end))
end

local function parse_helper_json_number(json, key)
    local pattern = "\"" .. key .. "\":(-?%d+)"
    return tonumber(json:match(pattern))
end

local function parse_helper_json_string(json, key)
    local pattern = "\"" .. key .. "\":\"([^\"]*)\""
    return json:match(pattern)
end

function bash(command, timeout)
    timeout = tonumber(timeout or BASH_DEFAULT_TIMEOUT_MS) or BASH_DEFAULT_TIMEOUT_MS
    if helper_bin == "" then
        error("bash: helper binary is not configured")
    end

    local tmp = os.tmpname()
    local cmd_file = io.open(tmp, "w")
    if not cmd_file then
        error("bash: could not create temp command file")
    end
    cmd_file:write(command or "")
    cmd_file:close()

    local helper_cmd = quoted(helper_bin)
        .. " --tool-bash --command-file " .. quoted(tmp)
        .. " --timeout-ms " .. tostring(timeout)
    local status, raw = run_helper(helper_cmd)
    os.remove(tmp)
    if status ~= 0 then
        error("bash: helper failed: " .. tostring(raw))
    end

    local tool_status = parse_helper_json_number(raw, "status_code") or 1
    local stdout_b64 = parse_helper_json_string(raw, "stdout_b64") or ""
    local stderr_b64 = parse_helper_json_string(raw, "stderr_b64") or ""
    local stdout = base64_decode(stdout_b64)
    local stderr = base64_decode(stderr_b64)
    return contract(tool_status, stdout, stderr, "tail")
end

function read(path, offset, limit)
    offset = tonumber(offset or 0) or 0
    if offset < 0 then
        offset = 0
    end
    limit = tonumber(limit or READ_MAX_LINES) or READ_MAX_LINES
    if limit < 0 then
        limit = 0
    end
    local resolved = resolve_path(path)
    local file = io.open(resolved, "r")
    if not file then
        error("read: cannot open path: " .. tostring(resolved))
    end
    local full = file:read("*a") or ""
    file:close()

    local all_lines = split_lines(full)
    local total = #all_lines
    local start_idx = math.max(offset + 1, 1)
    local end_idx = math.min(start_idx + limit - 1, total)
    local selected = {}
    for i = start_idx, end_idx do
        selected[#selected + 1] = all_lines[i]
    end
    local content = table.concat(selected, "\n")
    return contract(0, content, "", "head")
end

function write(path, content)
    if helper_bin == "" then
        error("write: helper binary is not configured")
    end

    local data = content or ""
    local tmp = os.tmpname()
    local content_file = io.open(tmp, "w")
    if not content_file then
        error("write: could not create temp content file")
    end
    content_file:write(data)
    content_file:close()

    local helper_cmd = quoted(helper_bin)
        .. " --tool-write --path " .. quoted(path or "")
        .. " --content-file " .. quoted(tmp)
    local status, raw = run_helper(helper_cmd)
    os.remove(tmp)
    if status ~= 0 then
        error("write: helper failed: " .. tostring(raw))
    end

    local tool_status = parse_helper_json_number(raw, "status_code") or 1
    local stdout_b64 = parse_helper_json_string(raw, "stdout_b64") or ""
    local stderr_b64 = parse_helper_json_string(raw, "stderr_b64") or ""
    local stdout = base64_decode(stdout_b64)
    local stderr = base64_decode(stderr_b64)
    return contract(tool_status, stdout, stderr, "head")
end

local function build_diff(path, old_content, new_content)
    local old_lines = split_lines(old_content)
    local new_lines = split_lines(new_content)
    local old_count = #old_lines
    local new_count = #new_lines

    local prefix = 0
    local prefix_max = math.min(old_count, new_count)
    while prefix < prefix_max and old_lines[prefix + 1] == new_lines[prefix + 1] do
        prefix = prefix + 1
    end

    local suffix = 0
    while suffix < (old_count - prefix) and suffix < (new_count - prefix)
        and old_lines[old_count - suffix] == new_lines[new_count - suffix] do
        suffix = suffix + 1
    end

    local old_start = prefix + 1
    local new_start = prefix + 1
    local old_end = old_count - suffix
    local new_end = new_count - suffix
    local old_span = math.max(0, old_end - old_start + 1)
    local new_span = math.max(0, new_end - new_start + 1)

    local out = {
        "--- " .. path,
        "+++ " .. path,
        "@@ -" .. tostring(old_start) .. "," .. tostring(old_span)
            .. " +" .. tostring(new_start) .. "," .. tostring(new_span) .. " @@"
    }
    for i = old_start, old_end do
        out[#out + 1] = "-" .. old_lines[i]
    end
    for i = new_start, new_end do
        out[#out + 1] = "+" .. new_lines[i]
    end
    return table.concat(out, "\n")
end

function edit(path, old_text, new_text)
    local resolved = resolve_path(path)
    local file = io.open(resolved, "r")
    if not file then
        error("edit: cannot open path: " .. tostring(resolved))
    end
    local current = file:read("*a") or ""
    file:close()

    local needle = old_text or ""
    local replacement = new_text or ""
    if needle == "" then
        error("edit: old_text must be non-empty")
    end

    local first_start, first_end = current:find(needle, 1, true)
    if not first_start then
        error("edit: old_text not found in path: " .. tostring(resolved))
    end
    local second_start = current:find(needle, first_end + 1, true)
    if second_start then
        error("edit: old_text matched multiple locations in path: " .. tostring(resolved))
    end

    local updated = current:sub(1, first_start - 1) .. replacement .. current:sub(first_end + 1)
    local write_result = write(path, updated)
    return contract(
        write_result.status_code,
        build_diff(resolved, current, updated),
        write_result.stderr,
        "head"
    )
end

local function emit(status_code, runtime_duration_ms, stdout, stderr, truncation_mode)
    local payload = {
        status_code = tonumber(status_code or 0) or 0,
        stdout = stdout or "",
        stderr = stderr or "",
        truncation_mode = truncation_mode or "head",
        runtime_duration_ms = tonumber(runtime_duration_ms or 0) or 0
    }
    print(json_encode(payload))
end

local start_ms = now_ms()
local code = io.read("*a") or ""

local env = {
    bash = bash,
    read = read,
    write = write,
    edit = edit,
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
    emit(1, now_ms() - start_ms, "", load_err, "head")
    os.exit(0)
end

local ok, result = pcall(chunk)
if not ok then
    emit(1, now_ms() - start_ms, "", tostring(result), "head")
    os.exit(0)
end

if result == nil then
    emit(1, now_ms() - start_ms, "", "Lua code returned nil. Use `return <tool>(...)` so tool output is captured.", "head")
elseif type(result) == "table" and result.status_code ~= nil then
    emit(
        tonumber(result.status_code) or 0,
        now_ms() - start_ms,
        result.stdout,
        result.stderr,
        result.truncation_mode
    )
elseif type(result) == "table" then
    emit(0, now_ms() - start_ms, json_encode(result), "", "head")
else
    emit(0, now_ms() - start_ms, stringify(result), "", "head")
end
