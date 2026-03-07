-- Custom token_affiliation - overrides the contrib version
-- Sets MUC affiliation based on JWT token context
local LOGLEVEL = "info"

local util = module:require 'util';
local is_admin = util.is_admin;
local is_healthcheck_room = util.is_healthcheck_room
local timer = require "util.timer"
local jid_bare = require "util.jid".bare;
local json = require "cjson.safe"

module:log(LOGLEVEL, "Custom token_affiliation v2 loaded")

local function get_session_and_affiliation(occupant, stanza)
    local dominated_jid = jid_bare(occupant.bare_jid)

    -- Find c2s session with the token
    local session = nil
    if stanza then
        session = prosody.full_sessions[stanza.attr.from]
    end
    if not session then
        for full_jid, s in pairs(prosody.full_sessions) do
            if jid_bare(full_jid) == dominated_jid then
                session = s
                break
            end
        end
    end

    if not session then
        module:log(LOGLEVEL, "No session found for %s", occupant.bare_jid)
        return nil, "member"
    end

    if not session.auth_token then
        module:log(LOGLEVEL, "No auth_token for %s", occupant.bare_jid)
        return session, "member"
    end

    local context_user = session.jitsi_meet_context_user
    module:log(LOGLEVEL, "context_user for %s: %s", occupant.bare_jid, json.encode(context_user) or "nil")

    local affiliation = "member"

    if context_user then
        local aff_value = context_user["affiliation"]
        module:log(LOGLEVEL, "JWT affiliation field for %s: %s (type: %s)", occupant.bare_jid, tostring(aff_value), type(aff_value))

        if aff_value == "owner" or aff_value == "moderator" or aff_value == "teacher" then
            affiliation = "owner"
        end
    end

    return session, affiliation
end

-- Hook into pre-join to set affiliation BEFORE the occupant enters
module:hook("muc-occupant-pre-join", function (event)
    local room, occupant, stanza = event.room, event.occupant, event.stanza

    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        module:log(LOGLEVEL, "skip affiliation for admin/healthcheck: %s", occupant.jid)
        return
    end

    local session, affiliation = get_session_and_affiliation(occupant, stanza)
    if not session then return end

    module:log(LOGLEVEL, "Pre-join: Setting affiliation for %s to %s", occupant.bare_jid, affiliation)
    room:set_affiliation(true, occupant.bare_jid, affiliation)
end, 2)

-- Post-join backup with retry
module:hook("muc-occupant-joined", function (event)
    local room, occupant = event.room, event.occupant

    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        return
    end

    local session, affiliation = get_session_and_affiliation(occupant, nil)
    if not session then return end

    local i = 0
    local function setAffiliation()
        room:set_affiliation(true, occupant.bare_jid, affiliation)
        if i > 4 then return end
        i = i + 1
        timer.add_task(0.5 * i, setAffiliation)
    end
    setAffiliation()

    module:log(LOGLEVEL, "Post-join: affiliation for %s set to %s", occupant.bare_jid, affiliation)
end)
