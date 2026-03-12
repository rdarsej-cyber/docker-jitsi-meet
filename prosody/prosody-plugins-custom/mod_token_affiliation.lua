-- Custom token_affiliation v12 — block silent reconnect after end-meeting-for-all
local util = module:require 'util'
local is_admin = util.is_admin
local is_healthcheck_room = util.is_healthcheck_room
local timer = require 'util.timer'
local st = require 'util.stanza'

module:log('info', 'Custom token_affiliation v12 loaded')

local room_affiliations = {}
local rooms_destroying = {}
-- Track rooms destroyed via "end meeting for all" to block silent reconnect
local rooms_ended = {}

local function get_token_affiliation(session)
    if not session or not session.auth_token then return nil end
    local ctx = session.jitsi_meet_context_user
    if not ctx then return 'member' end
    local a = ctx['affiliation']
    if a == 'owner' or a == 'moderator' or a == 'teacher' then return 'owner' end
    if ctx['moderator'] == true or ctx['moderator'] == 'true' then return 'owner' end
    return 'member'
end

local function aff_to_role(aff)
    if aff == 'owner' then return 'moderator' end
    return 'participant'
end

local function fix_stanza_items(stanza, target_aff, target_role, bare_jid)
    local x = stanza:get_child('x', 'http://jabber.org/protocol/muc#user')
    if not x then return false end
    local item = x:get_child('item')
    if not item then return false end
    local old_aff = item.attr.affiliation
    local old_role = item.attr.role
    local changed = false
    if old_aff ~= target_aff then
        item.attr.affiliation = target_aff
        changed = true
    end
    if old_role ~= target_role then
        item.attr.role = target_role
        changed = true
    end
    if changed then
        module:log('info', 'stanza-fix: %s aff=%s->%s role=%s->%s',
            bare_jid, tostring(old_aff), target_aff, tostring(old_role), target_role)
    end
    return changed
end

-- Helper: check if room is being destroyed or already gone
local function is_room_alive(room_jid)
    if rooms_destroying[room_jid] then return false end
    if not room_affiliations[room_jid] then return false end
    return true
end

-- Correct event name is 'muc-pre-room-destroy' (NOT 'muc-room-pre-destroy').
-- Fires BEFORE destruction. We record the room name to block silent reconnects.
module:hook('muc-pre-room-destroy', function(event)
    local room = event.room
    local room_jid = room.jid
    module:log('info', 'pre-room-destroy: %s — marking as ended', room_jid)
    rooms_destroying[room_jid] = true

    -- Extract the room name (before @muc.meet.jitsi) to block reconnects
    local room_name = room_jid:match('^(.-)@')
    if room_name then
        rooms_ended[room_name] = os.time()
        module:log('info', 'pre-room-destroy: blocking reconnect for room: %s', room_name)
        -- Auto-cleanup after 30 seconds
        timer.add_task(30, function()
            rooms_ended[room_name] = nil
            module:log('info', 'room-ended block expired for: %s', room_name)
        end)
    end
end, 1000)

module:hook('muc-room-destroyed', function(event)
    local room_jid = event.room.jid
    room_affiliations[room_jid] = nil
    rooms_destroying[room_jid] = nil
    module:log('info', 'room-destroyed: %s — cleanup done', room_jid)
end)

-- Block room creation if the room was recently ended.
-- This prevents Jitsi's "silent reconnect" from re-creating the room.
module:hook('muc-room-pre-create', function(event)
    local room = event.room
    local room_name = room.jid:match('^(.-)@')
    if room_name and rooms_ended[room_name] then
        module:log('info', 'BLOCKED room creation (recently ended): %s', room.jid)
        local session = event.origin
        local stanza = event.stanza
        if session and stanza then
            local reply = st.error_reply(stanza, 'cancel', 'not-allowed',
                'Meeting has ended')
            session.send(reply)
        end
        return true -- block room creation
    end
end, 1000)

module:hook('muc-occupant-pre-join', function(event)
    local room = event.room
    local occupant = event.occupant
    local session = event.origin
    local room_jid = room.jid
    if is_healthcheck_room(room_jid) or is_admin(occupant.bare_jid) then return end
    if not is_room_alive(room_jid) and room_affiliations[room_jid] == nil then
        -- First join — initialize cache
    end
    local aff = get_token_affiliation(session)
    if not aff then return end
    if not room_affiliations[room_jid] then room_affiliations[room_jid] = {} end
    room_affiliations[room_jid][occupant.bare_jid] = aff
    occupant.role = aff_to_role(aff)
    room:set_affiliation(true, occupant.bare_jid, aff)
    module:log('info', 'pre-join: %s -> aff=%s role=%s', occupant.bare_jid, aff, occupant.role)
end, 200)

module:hook('muc-occupant-joined', function(event)
    local room = event.room
    local occupant = event.occupant
    local room_jid = room.jid
    if is_healthcheck_room(room_jid) or is_admin(occupant.bare_jid) then return end
    if not is_room_alive(room_jid) then return end
    local cache = room_affiliations[room_jid]
    local aff = cache and cache[occupant.bare_jid]
    if not aff then return end
    local bare = occupant.bare_jid
    local target_role = aff_to_role(aff)
    local i = 0
    local function retry()
        -- Guard: stop if room is destroying or destroyed
        if not is_room_alive(room_jid) then
            module:log('info', 'retry aborted: room %s is destroying/destroyed', room_jid)
            return
        end

        local current_aff = room:get_affiliation(bare)
        if current_aff and current_aff ~= aff then
            room:set_affiliation(true, bare, aff)
            module:log('info', 'post-join retry %d: %s aff %s->%s', i, bare, tostring(current_aff), aff)
        end

        local occ = room:get_occupant_by_real_jid(occupant.jid)
        if occ and occ.role ~= target_role then
            local ok, err = pcall(function()
                room:set_role(true, occ.nick, target_role, 'Token affiliation enforcement')
            end)
            if ok then
                module:log('info', 'post-join retry %d: %s set_role -> %s', i, bare, target_role)
            else
                module:log('warn', 'post-join retry %d: %s set_role failed: %s', i, bare, tostring(err))
            end
        end

        if i > 3 then return end
        i = i + 1
        timer.add_task(0.5 * i, retry)
    end
    timer.add_task(0.3, retry)
end)

module:hook('muc-build-occupant-presence', function(event)
    local room = event.room
    local occupant = event.occupant
    local stanza = event.stanza
    local room_jid = room.jid
    if is_healthcheck_room(room_jid) or is_admin(occupant.bare_jid) then return end
    -- CRITICAL: do not touch presence during room destruction
    if rooms_destroying[room_jid] then return end
    local cache = room_affiliations[room_jid]
    local aff = cache and cache[occupant.bare_jid]
    if not aff then return end
    local target_role = aff_to_role(aff)
    if occupant.role ~= target_role then
        occupant.role = target_role
    end
    if stanza then
        fix_stanza_items(stanza, aff, target_role, occupant.bare_jid)
    end
end, 200)

module:hook('muc-broadcast-presence', function(event)
    local room = event.room
    local stanza = event.stanza
    local occupant = event.occupant
    local room_jid = room.jid
    if not occupant or is_healthcheck_room(room_jid) or is_admin(occupant.bare_jid) then return end
    -- CRITICAL: do not touch broadcast during room destruction
    if rooms_destroying[room_jid] then return end
    local cache = room_affiliations[room_jid]
    local aff = cache and cache[occupant.bare_jid]
    if not aff then return end
    if stanza then
        fix_stanza_items(stanza, aff, aff_to_role(aff), occupant.bare_jid)
    end
end, 200)

module:hook('muc-occupant-left', function(event)
    local cache = room_affiliations[event.room.jid]
    if cache then cache[event.occupant.bare_jid] = nil end
end)
