--[[
  Helix Swarm Extensions to replace triggers.

  This should be a full replacement of the trigger functionality, though
  it assumes that workflow is being used rather than the pre-workflow
  implementation so doesn't have the inbuilt strict checking that the
  Perl triggers had.
]]
--

local EXTENSION_VERSION = "2022.1/2268697"

local cjson = require "cjson"
local curl = require "cURL.safe"

local API_CHANGES = "api/v9/changes/"

local initDone = false
local initFailed = false
local config = {}

-- Configuration Constants

-- Global configuration.
local CFG_URL = "Swarm-URL"
local CFG_TOKEN = "Swarm-Token"
local CFG_SECURE = "Swarm-Secure"
local CFG_COOKIES = "Swarm-Cookies"

-- Debug level. 0 = Errors only, 1 = Warnings, 2 = Info, 3 = Debug, 9=Debug and send to client
local CFG_DEBUG = "Debug"

-- Instance
local CFG_PATH = "depot-path"
local CFG_WORKFLOW = "enableWorkflow"
local CFG_STRICT = "enableStrict"
local CFG_IGNORE_ERRORS = "ignoreErrors"
local CFG_IGNOREDUSERS = "ignoredUsers"
local CFG_TIMEOUT = "httpTimeout"

-- Remove leading and trailing whitespace from a string.
function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Split a path string into array elements.
-- The PATHSEP is expected to be / for Unix or \ for Windows.
function splitPath(path, PATHSEP)
    local tbl = {}

    path:gsub("[^" .. PATHSEP .. "]*", function(x) tbl[#tbl + 1] = x end)

    return tbl
end

-- Write a log message to the extension log, along with some user data.
function log(msg, content)
    local host = Helix.Core.Server.GetVar("clientip")
    local user = Helix.Core.Server.GetVar("user")
    Helix.Core.Server.log({ ["user"] = user, ["host"] = host, ["msg"] = msg, ["content"] = content })
    -- If the debug level is 9 or higher, output messages to the client.
    if (config[CFG_DEBUG] ~= nil and tonumber(config[CFG_DEBUG]) >= 9 and msg ~= nil)
    then
        Helix.Core.Server.ClientOutputText("SWARM_EXT: " .. msg .. "\n")
    end
end

-- Write a log message if debug is enabled.
function debug(msg, content)
    if (config[CFG_DEBUG] == nil or tonumber(config[CFG_DEBUG]) >= 3)
    then
        log(msg, content)
    end
end

-- Write a log message if info is enabled.
function info(msg)
    if (config[CFG_DEBUG] == nil or tonumber(config[CFG_DEBUG]) >= 2)
    then
        log(msg)
    end
end

-- Write a log message if warning is enabled.
function warn(msg)
    if (config[CFG_DEBUG] == nil or tonumber(config[CFG_DEBUG]) >= 1)
    then
        log(msg)
    end
end

-- Always write a log message for errors.
function error(msg)
    log(msg)
end

-- Check a value read from the config and perform some sanity checks on it.
-- The Extension spec doesn't like boolean types, so read them as strings and
-- convert to boolean after reading.
--
-- Otherwise, trim off any spaces from the ends of the string.
function value(k, v)
    if string.len(trim(v)) > 0 then
        if trim(v) == "true"
        then
            config[k] = true
        elseif trim(v) == "false"
        then
            config[k] = false
        else
            config[k] = trim(v)
        end
    else
        config[k] = ""
    end
end

-- Read the configuration settings the first time.
-- Read the global config first, then the instance config. The latter could
-- override the former if there are duplicate variable names. This is assumed
-- to be a desirable feature.
function init()
    if initDone == false then
        config[CFG_DEBUG] = 3

        for k, v in pairs(Helix.Core.Server.GetGlobalConfigData()) do
            value(k, v)
        end

        for k, v in pairs(Helix.Core.Server.GetInstanceConfigData()) do
            value(k, v)
        end

        if config[CFG_URL] == nil or config[CFG_TOKEN] == nil then
            Helix.Core.Server.ClientOutputText("Swarm extension is installed but not properly configured.\n")
            return false
        end

        if config[CFG_DEBUG] == nil then
            config[CFG_DEBUG] = "3"
        end

        -- We should only do this once.
        initDone = true

        -- Always output the following line.
        log("Initialised Helix Swarm extension for [" ..
            config[CFG_URL] .. "] at log level [" .. config[CFG_DEBUG] .. "]")
        for k, v in pairs(config)
        do
            debug("[" .. k .. "] = [" .. tostring(v) .. "]")
        end

        if config[CFG_SECURE] == nil then
            info("Secure setting is empty somehow")
            config[CFG_SECURE] = true
        end

        -- Check if the URL ends with a slash. If not, append one.
        if string.sub(config[CFG_URL], -1) ~= "/" then
            config[CFG_URL] = config[CFG_URL] .. "/"
            info("Append missing '/' to Swarm-URL [" .. config[CFG_URL] .. "]")
        end
    end
    return true
end

-- Check the configuration to see what the state is
function validateConfig()
    local initFailed = false

    debug("validateConfig:")

    if (config[CFG_URL] == nil or config[CFG_URL] == '')
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'Swarm-URL' is nil or empty\n")
    elseif not string.match(config[CFG_URL], "https?://.*/")
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'Swarm-URL' does not look like a valid URL\n")
    elseif not validateSwarmUrl()
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'Swarm-URL' does not appear correct, invalid response from web server\n")
        return
    end

    if (config[CFG_TOKEN] == nil or config[CFG_TOKEN] == '')
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'Swarm-Token' is nil or empty\n")
    end

    if (config[CFG_PATH] == nil or config[CFG_PATH] == '')
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'depot-path' is nil or empty\n")
    elseif not string.match(config[CFG_PATH], "//.*")
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'depot-path' does not look like a valid depot path\n")
    end

    if not config[CFG_WORKFLOW]
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'" .. CFG_WORKFLOW .. "' is not set, should be true or false\n")
    end
    if not config[CFG_STRICT]
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'" .. CFG_STRICT .. "' is not set, should be true or false\n")
    end
    if not config[CFG_TIMEOUT]
    then
        initFailed = true
        Helix.Core.Server.ClientOutputText("'" .. CFG_TIMEOUT .. "' is not set, should be timeout in seconds\n")
    end

    if not initFailed
    then
        Helix.Core.Server.ClientOutputText("Validates OK\n")
    end
end

-- Extension public
function GlobalConfigFields()
    return {
        [CFG_URL] = "http://localhost/",
        [CFG_TOKEN] = "... SWARM-TOKEN", -- Use ... so we know it hasn't been set
        [CFG_SECURE] = "true",
        [CFG_DEBUG] = "2"
    }
end

-- Extension public
function InstanceConfigFields()
    return {
        [CFG_PATH] = "//...",
        [CFG_WORKFLOW] = "true",
        [CFG_STRICT] = "true",
        [CFG_TIMEOUT] = "30",
        [CFG_IGNORE_ERRORS] = "false"
    }
end

-- Extension public
-- This is executed when the instance config is updated. There isn't an entry point for
-- updating the global config.
function InstanceConfigEvents()
    initDone = false

    info("InstanceConfigEvents")
    init()

    return {
        ["change-commit"] = config[CFG_PATH],
        ["change-submit"] = config[CFG_PATH],
        ["change-content"] = config[CFG_PATH],
        ["shelve-commit"] = config[CFG_PATH],
        ["shelve-submit"] = config[CFG_PATH],
        ["shelve-delete"] = config[CFG_PATH],
        ["form-commit"] = { "job", "user", "group" },
        ["form-save"] = { "change" },
        ["form-delete"] = { "user", "group" },
        ["extension-run"] = "unset"
    }
end

-- Return json data response
-- ok:   True of False. If True, data is json data, otherwise it is an error message.
-- code: HTTP status code
-- data: JSON data if ok is True, error message if ok is False
function curlResponseFmt(ok, code, data)
    if not ok then
        if data then
            return false, code, "Swarm returned an error (" .. tostring(data) .. ")"
        else
            return false, code, "Swarm returned an error"
        end
    end

    -- This might be a call to the version check, which has a different format.
    if data["version"] then
        return true, code, data
    end

    if data["error"] ~= nil then
        return false, code, "Swarm returned an error (" .. data["error"] .. ")"
    end

    return true, code, data
end

-- Make a GET request to the given URL.
-- Return: success, code, json
function get(url)
    local c = curl.easy()
    local rsp = ""
    local enforceSSL = config[CFG_SECURE]
    if enforceSSL == nil then
        enforceSSL = false
    end

    debug("GET " .. url)

    c:setopt(curl.OPT_URL, url)
    c:setopt(curl.OPT_WRITEFUNCTION, function(chunk) rsp = rsp .. chunk end)
    c:setopt(curl.OPT_SSL_VERIFYPEER, enforceSSL)
    c:setopt(curl.OPT_SSL_VERIFYHOST, enforceSSL)
    if config[CFG_TIMEOUT]
    then
        c:setopt(curl.OPT_TIMEOUT, tonumber(config[CFG_TIMEOUT]))
    end

    local cookies = "Swarm-Token=" .. config[CFG_TOKEN]
    if config[CFG_COOKIES] ~= nil then
        -- Any configured datapath cookie must be first in the list
        cookies = config[CFG_COOKIES] .. ";" .. cookies
    end
    c:setopt(curl.OPT_COOKIE, cookies)

    local response = c:perform()
    local code = c:getinfo(curl.INFO_RESPONSE_CODE)
    c:close()

    if not response
    then
        warn("GET request to [" .. url .. "] returning error " .. tostring(code))
        return false, nil, nil
    end
    debug("GET [" .. url .. "] [" .. rsp .. "]")

    local isjson, data = pcall(function()
        return cjson.decode(rsp)
    end)

    if isjson then
        return curlResponseFmt(true, code, data)
    else
        warn("Data from [" .. url .. "] is not JSON [" .. rsp .. "]")
        return false, code, "Unexpected response format"
    end
end

-- Make a POST request to the given URL with body content.
-- Format is always application/x-www-form-urlencoded
function postForm(url, content)
    return post(url, content, "application/x-www-form-urlencoded")
end

-- Make a POST request to the given URL with body content.
-- Format is always application/json.
function postJson(url, content)
    return post(url, content, "application/json")
end

-- Make a POST request to the given URL with body content and content type.
function post(url, content, ctype)
    local c = curl.easy()
    local rsp = ""
    local enforceSSL = config[CFG_SECURE]
    if enforceSSL == nil then
        enforceSSL = false
    end

    c:setopt(curl.OPT_URL, url)
    c:setopt(curl.OPT_WRITEFUNCTION, function(chunk) rsp = rsp .. chunk end)
    c:setopt(curl.OPT_SSL_VERIFYPEER, enforceSSL)
    c:setopt(curl.OPT_SSL_VERIFYHOST, enforceSSL)
    c:setopt(curl.OPT_HTTPHEADER, { "Content-Type: " .. ctype })
    c:setopt(curl.OPT_POSTFIELDS, content)
    if config[CFG_TIMEOUT]
    then
        c:setopt(curl.OPT_TIMEOUT, tonumber(config[CFG_TIMEOUT]))
    end
    debug("post [" .. content .. "]")

    if config[CFG_COOKIES] ~= nil then
        -- Add any configured datapath cookie
        c:setopt(curl.OPT_COOKIE, config[CFG_COOKIES])
    end

    local msg = ""
    local result = c:perform({
        writefunction = function(str)
            msg = msg .. str
        end
    })
    local code = c:getinfo(curl.INFO_RESPONSE_CODE)
    c:close()

    if result and code == 200 then
        return true, code, ""
    elseif not result then
        error("Unable to POST to [" .. url .. "], server not reachable")
        return false, nil, nil
    else
        if msg then
            msg = trim(c:unescape(msg))
            msg = string.gsub(msg, "&quot;", "'")
        else
            msg = ""
        end
        error("Unable to POST to [" .. url .. "], received error " .. code .. " (" .. msg .. ")")
        return false, code, msg
    end
end

-- Check that the URL specified is pointing at a proper instance of Swarm
function validateSwarmUrl()
    if not config[CFG_URL] then
        return nil
    end
    local url = config[CFG_URL] .. "api/version"

    debug("validateSwarmUrl: [" .. url .. "]")
    local ok, code, response = get(url)
    if ok then
        info("Connected with Swarm [" .. response.version .. "]")
        return response.version
    else
        error("Unable to communicate with Swarm server at [" .. config[CFG_URL] .. "]")
        return nil
    end
end

-- Collect all messages together from the response message array
-- and return a single string containing them all.
function CollectMessages(response)
    local msg = ""

    if response == nil then
        return ""
    end

    for i = 1, #response.messages do
        if i > 1 then
            msg = msg .. "; "
        end
        msg = msg .. response.messages[i]
    end

    return msg
end

-- Custom command for testing the configuration. Can be executed from the command line
-- with the following:
-- p4 extension --run swarm ping
--
-- Where 'swarm' is the name of the configuration instance, and ping is the command.
function RunCommand(args)
    init()

    local cmd = table.remove(args, 1)

    if (cmd == "ping") then
        info("Custom Command: ping")

        if not config[CFG_URL]
        then
            Helix.Core.Server.ClientOutputText("BAD (" .. CFG_URL .. " is not set)\n")
            return false
        end
        if not config[CFG_TOKEN]
        then
            Helix.Core.Server.ClientOutputText("BAD (" .. CFG_TOKEN .. " is not set)\n")
            return false
        end

        local ok, code, text = postForm(config[CFG_URL] .. "queue/add/" .. config[CFG_TOKEN], "ping,0")
        if ok and code == 200 then
            Helix.Core.Server.ClientOutputText("OK\n")
        elseif not ok and not code then
            Helix.Core.Server.ClientOutputText("BAD (Cannot reach '" .. config[CFG_URL] .. "')\n")
        else
            Helix.Core.Server.ClientOutputText("BAD (" .. text .. ")\n")
            return false
        end
    elseif (cmd == "version") then
        local swarmVersion = validateSwarmUrl()
        if swarmVersion then
            Helix.Core.Server.ClientOutputText("Swarm Version: " .. swarmVersion .. "\n")
        else
            Helix.Core.Server.ClientOutputText("Swarm Version: ?\n")
        end
        Helix.Core.Server.ClientOutputText("Extension Version: " .. EXTENSION_VERSION .. "\n")
    elseif (cmd == "validate") then
        validateConfig()
    end
    return true
end

-- Check if #noswarm is set on the changelist description.
function IsException()
    info("Checking if CL should be excluded from Swarm workflows (For large submits)")

    local change = Helix.Core.Server.GetVar("change")

    local p4 = P4.P4:new()
    p4:autoconnect()
    p4:connect()
    p4.ticket_file = "File-that-does-not-exist"
    local changelist = p4:run("describe", "-s", "-m", "1", change)
    info(changelist)

    -- Pattern matching for all exception tags
    local tags = { "#noswarm", "#no%-swarm", "#skipswarm", "#skip%-swarm" }

    for _, tag in ipairs(tags) do
        if changelist[1]["desc"]:find(tag) then
            info(string.format("Changelist description contains %s, skipping Swarm workflows", tag))
            return true
        end
    end

    return false
end

-- First step of the submit process, before file transfer.
-- This is used for the first workflow check, and provides fast fail.
function ChangeSubmit()
    info("ChangeSubmit event")
    if not init() then return false end

    if not config[CFG_WORKFLOW] then
        return true
    end

    if IsException() then
        return true
    end

    local change = Helix.Core.Server.GetVar("change")
    local user = Helix.Core.Server.GetVar("user")

    local u = config[CFG_URL] .. API_CHANGES .. change .. "/check?type=enforced&user=" .. user

    local ok, code, response = get(u)
    if ok then
        if response.isValid then
            -- Everything is okay, so nothing to do.
        else
            local msgs = CollectMessages(response)
            warn("ChangeSubmit Rejected: [" .. msgs .. "]")
            Helix.Core.Server.SetClientMsg(msgs)
            return false
        end
    else
        error("ChangeSubmit Error: Call to Swarm URL [" .. u .. "] failed")
        Helix.Core.Server.SetClientMsg(
            "ChangeSubmit error: Swarm workflow validation failed. Contact your administrator.")
        return false
    end

    return true
end

-- Second step of the submit process, after file transfer.
-- This is used for the second workflow check, and provides slower but more secure fail.
function ChangeContent()
    info("ChangeContent event")
    if not init() then return false end
    if not config[CFG_WORKFLOW] or not config[CFG_STRICT] then
        return true
    end

    if IsException() then
        return true
    end

    local change = Helix.Core.Server.GetVar("change")
    local user = Helix.Core.Server.GetVar("user")

    local u = config[CFG_URL] .. API_CHANGES .. change .. "/check?type=strict&user=" .. user

    local ok, code, response = get(u)
    if ok then
        if response.isValid then
            -- Everything is okay, so nothing to do.
        else
            local msgs = CollectMessages(response)
            warn("ChangeContent Rejected: [" .. msgs .. "]")
            Helix.Core.Server.SetClientMsg(msgs)
            return false
        end
    else
        error("ChangeContent Error: Call to Swarm URL [" .. u .. "] failed")
        Helix.Core.Server.SetClientMsg("ChangeContent Error: Call to Swarm failed. Contact your administrator.")
        return false
    end

    return true
end

-- First step of the submit process from a shelf, before file transfer.
-- This is used for the first workflow check, and provides fast fail.
function ShelveSubmit()
    info("ShelveSubmit event")
    if not init() then return false end

    if IsException() then
        return true
    end

    local change = Helix.Core.Server.GetVar("change")
    local user = Helix.Core.Server.GetVar("user")

    local u = config[CFG_URL] .. API_CHANGES .. change .. "/check?type=shelve&user=" .. user

    local ok, code, response = get(u)
    if ok then
        if response.isValid then
            -- Everything is okay, so nothing to do.
        else
            local msgs = CollectMessages(response)
            warn("ShelveSubmit Rejected: [" .. msgs .. "]")
            Helix.Core.Server.SetClientMsg(msgs)
            return false
        end
    else
        error("ShelveSubmit Error: Call to Swarm URL [" .. u .. "] failed")
        Helix.Core.Server.SetClientMsg("ShelveSubmit Error: Call to Swarm failed. Contact your administrator.")
        return false
    end

    return true
end

--
-- Add an item to the Swarm worker queue by making a POST request to the Swarm endpoint.
-- In the trigger world this is asynchronous, so doesn't block the client, so we don't
-- bother checking for errors.
--
function addToQueue(type, var)
    info("addToQueue: [" .. type .. "] [" .. var .. "]")
    if not config[CFG_URL] then
        Helix.Core.Server.SetClientMsg(
            "Swarm extension value 'Swarm-URL' has not been set. Contact your HelixCore administrator.")
        return false
    end
    if not config[CFG_TOKEN] then
        Helix.Core.Server.SetClientMsg(
            "Swarm extension value 'Swarm-Token' has not been set. Contact your HelixCore administrator.")
        return false
    end

    local value = Helix.Core.Server.GetVar(var)
    local url = config[CFG_URL] .. "/queue/add/" .. config[CFG_TOKEN]
    local content = type .. "," .. value
    local ok, code, msg = postForm(url, content)
    if not ok then
        if config[CFG_IGNORE_ERRORS] then
            error("addToQueue failed, ignoring error.")
            if msg then
                Helix.Core.Server.SetClientMsg("Warning: Swarm communication error (" .. msg .. ")")
            else
                Helix.Core.Server.SetClientMsg("Warning: Unable to communicate with Swarm server")
            end
            return true
        else
            error("addToQueue failed, returning error to client.")
            if msg then
                Helix.Core.Server.SetClientMsg("ERROR: Swarm communication error (" .. msg .. ")")
            else
                Helix.Core.Server.SetClientMsg("ERROR: Unable to communicate with Swarm server")
            end
            return false
        end
    else
        return true
    end
end

--
-- Final step of the commit process. The changelist has been committed, so add an
-- item to the Swarm worker queue to process it.
--
function ChangeCommit()
    info("ChangeCommit event")
    if not init() then return false end
    return addToQueue("commit", "change")
end

--
-- A changelist has been shelved, so add an item to the Swarm worker queue to process
-- this.
--
function ShelveCommit()
    info("ShelveCommit event")
    if not init() then return false end
    return addToQueue("shelve", "change")
end

--
-- A form has been committed. This can be called for a job, user or group.
-- All this needs to do is to put a task on the Swarm queue, with the type
-- of the form, and the entity that is applicable.
--
function FormCommit()
    info("FormCommit event")
    if not init() then return false end
    local type = Helix.Core.Server.GetVar("formtype")
    info("FormCommit executed for " .. type .. " for " .. Helix.Core.Server.GetVar("formname"))

    if type == "user"
    then
        return addToQueue("user", "formname")
    elseif type == "group"
    then
        return addToQueue("group", "formname")
    elseif type == "job"
    then
        return addToQueue("job", "formname")
    end

    return true
end

--
-- Called when a form is saved. This happens after the FormCommit() call.
-- Processes updates to a change description. Puts a task on the Swarm queue.
--
function FormSave()
    info("FormSave event")
    if not init() then return false end
    local type = Helix.Core.Server.GetVar("formtype")
    info("FormSave executed for " .. type .. " for " .. Helix.Core.Server.GetVar("formname"))

    if type == "change"
    then
        return addToQueue("changesave", "formname")
    end

    return true
end

--
-- Called when a form object is deleted. Used to handle user and group delete operations.
-- Puts a task on the Swarm queue.
--
function FormDelete()
    info("FormDelete event")
    if not init() then return false end
    local type = Helix.Core.Server.GetVar("formtype")
    info("FormDelete executed for " .. type .. " for " .. Helix.Core.Server.GetVar("formname"))

    if type == "group"
    then
        return addToQueue("groupdel", "formname")
    elseif type == "user"
    then
        return addToQueue("userdel", "formname")
    end

    return true
end

--
-- Get an array of files from the arguments passed to us. This requires that we
-- strip out any options that are also passed through.
--
-- Returns the array (one-indexed), plus a count of the number of files.
--
function getFileArgs(args)
    local files = {}
    local count = 0

    local skipNext = false
    for w in string.gmatch(args, "[^,]*,?") do
        w = trim(w)
        if string.len(w) > 0 and skipNext == false
        then
            w = string.gsub(w, ",$", "")
            if w == "-c" or w == "-a"
            then
                -- Ignore option and the following parameter
                skipNext = true
            elseif string.find(w, "-") == 1
            then
                -- Ignore other options
            else
                -- This must be one of the actual path we want.
                -- Path is quoted, so unquote any characters as necessary.
                w = string.gsub(w, "%%2C", ",")
                w = string.gsub(w, "%%25", "%")
                count = count + 1
                files[count] = w
            end
        elseif skipNext
        then
            skipNext = false
        end
    end

    return files, count
end

--
-- A file has been removed from a shelf. Make sure that we update the review
-- immediately rather than waiting for other files to be added.
-- We need to get a list of the files that have been removed, and pass them to
-- the Swarm server.
--
function ShelveDelete()
    info("ShelveDelete event")
    if not init() then return false end

    local cwd = Helix.Core.Server.GetVar("clientcwd")
    local user = Helix.Core.Server.GetVar("user")
    local client = Helix.Core.Server.GetVar("client")

    local files, count = getFileArgs(Helix.Core.Server.GetVar("argsQuoted"))
    local PATHSEP = "/"

    -- Try to figure out if the client is on Windows
    if cwd:find("/") ~= 1
    then
        debug("ShelveDelete: Assuming client is Windows")
        PATHSEP = "\\"
    end

    debug("ShelveDelete: Using CWD [" .. cwd .. "] with [" .. #files .. "] files")

    -- Counts the maximum number of .. elements in each of the file paths.
    -- This gives us the number of dir elements we need to shift the root
    -- up the directory tree.
    local maxParents = 0

    for i = 1, #files do
        local f = files[i]
        -- We need to ignore depot paths

        if string.find(f, "//") ~= 1
        then
            local dirs = splitPath(f, PATHSEP)
            local parents = 0

            debug("ShelveDelete: File [" .. f .. "] has [" .. #dirs .. "] elements")

            for p = 1, #dirs do
                if dirs[p] == ".."
                then
                    parents = parents + 1
                    if parents > maxParents
                    then
                        maxParents = parents
                    end
                else
                    break
                end
            end
        end
    end

    debug("ShelveDelete: Counted a total of [" .. maxParents .. "] parents")

    -- What are we trying to do here? I wrote the original Perl, and I'm having difficulty
    -- figuring it out, so will try to illustrate with a simple example.
    --
    --   User's cwd = /home/alice/project/src
    --   Files in the changelist:
    --      a/b/c.txt
    --      ../docs/c.html
    --      ../../Makefile
    --
    --   We need to change them all to be under a common root, which is /home/alice
    --
    --      a/b/c.txt       =>  project/src/a/b/c.txt
    --      ../docs/c.html  =>  project/docs/c.html
    --      ../../Makefile  =>  project/Makefile
    --
    --   maxParents has been defined as the deepest level of .. nesting in the changelist.
    --   For each file, find the difference between the levels for this file and the maximum.
    --   Take the 'diff' elements from the end of the cwd to get a prefix
    --   Remove all .. from the path, and prepend the prefix elements

    -- If we have at least one file with a .., then rename all files.
    if maxParents > 0
    then
        debug("We have some parents")
        -- For each file in the changelist, that is not an absolute depot path
        for p = 1, #files do
            local path = files[p]
            debug("ShelveDelete: [" .. p .. "] [" .. path .. "]")
            if string.find(path, "//") ~= 1
            then
                local pathTable = splitPath(path, PATHSEP) -- Split the path into a table (array)
                local numParents = 0
                debug("Path table is length " .. #pathTable)

                -- Perform a plain text find for .. text at the start and remove it
                while pathTable[1] ~= nil and string.find(pathTable[1], "..", 1, true) == 1
                do
                    debug("Split path has " .. pathTable[1])
                    table.remove(pathTable, 1)
                    numParents = numParents + 1
                end
                local diff = maxParents - numParents
                debug("max [" .. maxParents .. "] num [" .. numParents .. "] diff [" .. diff .. "]")
                if diff > 0
                then
                    -- Find the portion of the cwd that we need to copy in
                    local cwdTable = splitPath(cwd, PATHSEP)
                    while #cwdTable > diff
                    do
                        table.remove(cwdTable, 1)
                    end
                    while #cwdTable > 0
                    do
                        table.insert(pathTable, 1, cwdTable[#cwdTable])
                        table.remove(cwdTable, #cwdTable)
                    end
                end

                -- Put things back together
                files[p] = ""
                for i = 1, #pathTable
                do
                    if files[p] ~= ""
                    then
                        files[p] = files[p] .. PATHSEP
                    end
                    files[p] = files[p] .. pathTable[i]
                end
            end
        end

        -- Remove a 'maxParents' number of elements from the RHS of the cwd
        while maxParents > 0
        do
            cwd = string.gsub(cwd, PATHSEP .. "[^" .. PATHSEP .. "]*$", "")
            maxParents = maxParents - 1
        end
    end

    debug("CWD [" .. cwd .. "]")
    for p = 1, #files do
        debug(files[p])
    end

    local data = {}
    data["user"] = user
    data["client"] = client
    data["cwd"] = cwd
    data["files"] = files
    local jdata = cjson.encode(data)


    local value = Helix.Core.Server.GetVar("change")
    local type = "shelvedel"
    local url = config[CFG_URL] .. "/queue/add/" .. config[CFG_TOKEN]
    local content = type .. "," .. value .. "\n" .. jdata
    postJson(url, content)

    debug("ShelveDelete: Content is [" .. content .. "]")

    return true
end
