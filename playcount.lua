---@class PlayCountPluginArgs
---@field enabled? boolean
---@field padding_factor_milliseconds? integer
---@field padding_factor_seconds? integer
---@field sticker_name? string
---@field from? "start" | "end"
---@field target_fraction? number
---@field target_percent? number
---@field loop? boolean

---@class PlayCountPlugin : RmpcdPlugin<PlayCountPluginArgs>
---@field enabled boolean
---@field timeout_handle table|nil
---@field last_incremented_song_id integer|nil
---@field padding_factor_ms integer
---@field from? "start" | "end"
---@field target_fraction number|nil
---@field sticker_name string
---@field loop boolean
---@field loop_state boolean
---@field loop_timer table|nil
---@field loop_saved_ms number|nil
---@field loop_song_id integer|nil

local DEFAULT_PADDING_FACTOR_MS = 15000 -- 15 seconds
local SAFETY_FACTOR_MS = 2000 -- 2 seconds
local LOOP_EXTRA_MS = 5000 -- 5 extra seconds added to loop timer
local DEFAULT_STICKER_NAME = "playCount";

---@class PlayCountPlugin
local M = {
    enabled = true;
    timeout_handle = nil;
    last_incremented_song_id = nil;
    padding_factor_ms = DEFAULT_PADDING_FACTOR_MS;
    from = "end";
    target_fraction = nil;
    sticker_name = DEFAULT_STICKER_NAME;
    loop = false;
    loop_state = false;
    loop_timer = nil;
    loop_saved_ms = nil;
    loop_song_id = nil;
}

-- Sometimes MPD has sond durations in ms, others in a { secs, nanos } structure. Here we handle both.
local function duration_in_ms(song_duration)
    if type(song_duration) == "number" then return song_duration end
    return song_duration.secs * 1000 + song_duration.nanos / 1000000
end

-- Will be called when new song starts playing, and in other situations where the existing timeout
-- should be canceled (usually because it's being replaced by a new one)
function M:cancel_timeout()
    if self.timeout_handle then
        self.timeout_handle.cancel()
        self.timeout_handle = nil
    end
end

function M:cancel_loop_timer()
    if self.loop_timer then
        self.loop_timer.cancel()
        self.loop_timer = nil
    end
end

-- Arms (or re-arms) the loop timer. remaining_ms defaults to "time left in current song plus 5 seconds".
---@param remaining_ms number|nil
function M:arm_loop_timer(remaining_ms)
    if not self.loop or not self.loop_state then return end
    self:cancel_loop_timer()

    if remaining_ms == nil then
        local status = mpd.get_status()
        local song = mpd.get_current_song()
        if not (status and song) then
            self.loop_state = false
            return
        end
        remaining_ms = duration_in_ms(song.duration) - status.elapsed
    end
    if remaining_ms <= 0 then remaining_ms = 0 end

    local cur = mpd.get_current_song()
    if not cur then
        self.loop_state = false
        return
    end
    self.loop_song_id = cur.id
    self.loop_saved_ms = remaining_ms
    -- For short songs, adding the full 5s bonus would make the timer fire long after the
    -- song ended. Cap the bonus so the timer fires at (or just after) the song boundary.
    -- The 250ms floor keeps very short clips from re-arming the timer in a tight loop.
    local bonus = math.min(LOOP_EXTRA_MS, math.max(remaining_ms / 2, 250))
    self.loop_timer = sync.set_timeout(remaining_ms + bonus, function()
        self.loop_timer = nil
        local now = mpd.get_current_song()
        -- Safety check: only re-increment if it's still the same song
        if now and now.id == self.loop_song_id then
            -- Bypass the "don't double-count same song_id" guard, since looping is intentional
            self.last_incremented_song_id = nil
            self:increment_playcount(now.file, now.id)
            -- If increment_playcount didn't re-arm (e.g. increment failed), re-arm here
            if self.loop_state and not self.loop_timer then
                self:arm_loop_timer()
            end
        else
            self.loop_state = false
        end
    end)
end

--- @param file string
--- @param song_id number
function M:increment_playcount(file, song_id)
    -- Do this first to ensure we won't be called again and possibly double-increment
    self:cancel_timeout()
    if song_id == self.last_incremented_song_id then
        -- This can happen if you pause and resume a song repeatedly within its last 15 seconds
        -- If that happens, we still only want to count a single play of the song
        return
    end
    self.last_incremented_song_id = song_id
    local oldsticker, err = mpd.get_song_sticker(file, self.sticker_name)
    if err then
        log.error("Could not increment play count for " .. file .. " because of an error while trying to look up the " .. self.sticker_name .. " sticker: " .. err)
    else
        local oldcount = tonumber(oldsticker) or 0
        mpd.set_song_sticker(file, self.sticker_name, tostring(oldcount + 1))
        log.info(file .. " has now been played " .. (oldcount + 1) .. " times.")
        -- Loop mode: the first successful increment arms the loop timer
        if self.loop and not self.loop_state then
            self.loop_state = true
            self:arm_loop_timer()
        end
    end
end

-- Calculate the target position in the song. Returns a negative value if target position would be past end of song.
-- Calling code will interpret negative values as "already reached, increment immediately if we haven't already"
---@param song_duration_ms number
function M:calculate_target_position(song_duration_ms)
    -- Short songs get play count incremented right away, no waiting
    if self.padding_factor_ms >= song_duration_ms then return -1 end
    if self.target_fraction ~= nil then
        -- Target desired fraction of song, but ensure at least padding_factor remaining
        local target = song_duration_ms * self.target_fraction
        return math.min(target, song_duration_ms - math.max(self.padding_factor_ms, SAFETY_FACTOR_MS))
    end
    -- No fraction specified, so just return the requested distance from start/end of song
    -- (Though leave at least 2 seconds before end of song, just for safety's sake)
    if self.from == "start" then
        local target = self.padding_factor_ms
        return math.min(target, song_duration_ms - SAFETY_FACTOR_MS)
    else
        return song_duration_ms - math.max(self.padding_factor_ms, SAFETY_FACTOR_MS)
    end
end

---@param song_duration_ms number
---@param already_elapsed_ms number
function M:calculate_time_to_wait(song_duration_ms, already_elapsed_ms)
    local target = self:calculate_target_position(song_duration_ms)
    return target - already_elapsed_ms
end

-- Set up the timeout for N (configurable, default 15) seconds before the end of the song
-- Once the timeout fires, we will increment the song's playCount sticker
---@param song QueuedSong
---@param already_elapsed_ms number
function M:setup_timeout(song, already_elapsed_ms)
    self:cancel_timeout()
    already_elapsed_ms = already_elapsed_ms or 0
    local time_to_wait_ms = self:calculate_time_to_wait(duration_in_ms(song.duration), already_elapsed_ms)
    if time_to_wait_ms <= 0 then
        -- Already past target time: either it was a short song, or we were paused and unpaused.
        -- Either way, increment now without waiting
        self:increment_playcount(song.file, song.id)
    else
        -- Wait until chosen target time (by default, when song has 15 seconds (or less) to go), then increment play count
        self.timeout_handle = sync.set_timeout(time_to_wait_ms, function ()
            self:increment_playcount(song.file, song.id)
        end)
    end
end

-- Will be called when we unpause *or* when plugin starts up
-- In both cases, we want to check whether a song is already playing,
-- because the song's elapsed time needs to be taken into account when setting up the timeout
function M:resume_after_pause()
    local status = mpd.get_status()
    if status and status.state == "play" then
        local song = mpd.get_current_song()
        if song then
            self:setup_timeout(song, status.elapsed)
        end
    end
end

--- @param _old_song QueuedSong
--- @param new_song QueuedSong
-- Will be called when a song changes.
-- Note: in repeat+single mode (one song loops forever) this only fires once, when the song is first
-- played. That's fine here: the loop timer handles repeated plays of the same song_id by design.
function M:song_change(_old_song, new_song)
    -- Loop resets on song change
    self:cancel_loop_timer()
    self.loop_state = false
    self.loop_saved_ms = nil

    if not self.enabled or new_song == nil or not new_song.file then
        self:cancel_timeout()
        return
    end

    self:setup_timeout(new_song, 0)
end

-- Will be called when playback is started, stopped or paused. A few cases need to be handled:
-- Stopping playback = cancel the timeout if it hasn't fired yet, and cancel the loop timer
-- Pausing playback = save remaining loop duration, cancel loop timer (restored on unpause)
-- Unpausing playback = restart both the timeout and the loop timer
-- Starting playback = same as unpausing
function M:state_change(old, new)
    if not self.enabled then
        self:cancel_timeout()
        self:cancel_loop_timer()
        self.loop_state = false
        return
    end

    if new == "pause" or new == "stop" then
        self:cancel_timeout()
        -- Save remaining loop duration before canceling, so it can be restored on resume
        if self.loop_state then
            local status = mpd.get_status()
            local song = mpd.get_current_song()
            if status and song then
                self.loop_saved_ms = duration_in_ms(song.duration) - status.elapsed
                if self.loop_saved_ms < 0 then self.loop_saved_ms = 0 end
            end
            self:cancel_loop_timer()
        end
    end
    if new == "play" then
        self:resume_after_pause()
        -- Restart loop timer with the duration saved when we paused
        if self.loop_state and self.loop_saved_ms then
            self:arm_loop_timer(self.loop_saved_ms)
            self.loop_saved_ms = nil
        end
    end
end

--- @param value number
--- @param warning string
function M:clamp_between_0_and_1(value, warning)
    if value < 0 then
        log.warn(warning)
        return 0
    elseif value > 1 then
        log.warn(warning)
        return 1
    end
    return value
end

function M:parse_fraction(fractionStr)
    local slash = string.find(fractionStr, "/")
    if slash ~= nil then
        local numerator = string.sub(fractionStr, 0, slash-1)
        local denominator = string.sub(fractionStr, slash+1)
        return tonumber(numerator) / tonumber(denominator)
    else
        -- No slash? Maybe it's one number written like 0.75
        return tonumber(fractionStr)
    end
end

function M:setup(args)
    self.enabled = (args.enabled ~= nil) and args.enabled or true
    if args.padding_factor_milliseconds ~= nil and args.padding_factor_seconds ~= nil then
        log.warn("Both milliseconds and seconds were set for padding_factor. Using milliseconds and *IGNORING* seconds. Padding factor will be set to " .. args.padding_factor_milliseconds .. " ms, which is " .. args.padding_factor_milliseconds / 1000 .. " seconds.")
    end
    if args.padding_factor_seconds ~= nil then
        self.padding_factor_ms = args.padding_factor_seconds * 1000
    end
    if args.padding_factor_milliseconds ~= nil then
        self.padding_factor_ms = args.padding_factor_milliseconds
    end
    if args.target_fraction ~= nil then
        if args.target_percent ~= nil then
            log.warn("Both target_percent and target_fraction were set. Using target_fraction and *IGNORING* target_percent.")
        end
        self.target_fraction = self:clamp_between_0_and_1(args.target_fraction, "The target_fraction parameter should be between 0 and 1.")
    elseif args.target_percent ~= nil then
        self.target_fraction = self:clamp_between_0_and_1(args.target_percent / 100, "The target_percent parameter should be between 0 and 100.")
    end
    if args.sticker_name then
        self.sticker_name = args.sticker_name
    end
    if args.from then
        if args.from == "start" or args.from == "end" then
            self.from = args.from
        else
            log.warn("\"from\" parameter should be either \"start\" or \"end\" (default \"end\"). Ignoring unknown value \"" .. args.from .. "\"")
        end
    end
    if args.loop ~= nil then
        self.loop = args.loop
    end

    -- Same logic for resiming after pause (check times elapsed, etc) works here too, so just reuse it
    -- However, resume_after_pause needs to call mpd.get_status(), and during plugin setup, rmpcd isn't running yet
    -- But by setting a timeout of 0, we ensure we get queued up to run immediately after rmpcd setup completes
    -- This neatly solves the chicken-and-egg problem
    sync.set_timeout(0, function ()
      self:resume_after_pause()
    end)
end

-- We subscribe to both playCount and playcount channels in case someone mistypes the name
M.subscribed_channels = { "rmpcd.playcount", "rmpcd.playCount" }

-- We can ignore the channel here because we're only subscribed to our own comm channels
function M:message(_channel, message)
    -- Turning plugin on/off
    if message == "enable" then
        log.info("Enabling playcount plugin")
        self.enabled = true
    elseif message == "disable" then
        log.info("Disabling playcount plugin")
        self.enabled = false
    elseif message == "toggle" then
        local newstate = not self.enabled
        local first_word = newstate and "Enabling" or "Disabling"
        log.info(first_word .. " playcount plugin")
        self.enabled = newstate

    -- Changing parameters on-the-fly: padding factor
    -- Syntax: send either "padding_factor_seconds:15" or "padding_factor_milliseconds:15000"
    elseif string.find(message, "padding_factor_seconds:") == 1 then
        local len = string.len("padding_factor_seconds:")
        local seconds = tonumber(string.sub(message, len))
        if seconds ~= nil then
            self.padding_factor_ms = seconds * 1000
        end
    elseif string.find(message, "padding_factor_milliseconds:") == 1 then
        local len = string.len("padding_factor_milliseconds:")
        local ms = tonumber(string.sub(message, len))
        if ms ~= nil then
            self.padding_factor_ms = ms
        end
    -- Changing parameters on-the-fly: target fraction
    elseif string.find(message, "target_fraction:") == 1 then
        local len = string.len("target_fraction:")
        local fractionStr = string.sub(message, len) -- Do not call tonumber yet
        local fractionValue = self:parse_fraction(fractionStr)
        if fractionValue ~= nil then
            self.target_fraction = self:clamp_between_0_and_1(fractionValue, "The target_fraction parameter should be between 0 and 1.")
        else
            log.warn("target_fraction message should have payload that is either a fraction like 2/3 (two numbers separated by a slash, with no spaces), or else a single number between 0 and 1 (like 0.75). Instead, found " .. fractionStr)
        end
    -- Changing parameters on-the-fly: target percent
    elseif string.find(message, "target_percent:") == 1 then
        local len = string.len("target_percent:")
        local percent = tonumber(string.sub(message, len))
        if percent ~= nil then
            self.target_fraction = self:clamp_between_0_and_1(percent / 100, "The target_percent parameter should be between 0 and 100.")
        end
    -- Changing parameters on-the-fly: sticker name
    -- CAUTION: No attempt is made to validate the new name. Make sure you spelled it the way you want it to be spelled!
    elseif string.find(message, "sticker_name:") == 1 then
        local len = string.len("sticker_name:")
        local new_name = string.sub(message, len)
        if new_name ~= nil then
            self.sticker_name = new_name
        end
    elseif string.find(message, "from:") == 1 then
        local len = string.len("from:")
        local new_from = string.sub(message, len)
        if new_from ~= nil and (new_from == "start" or new_from == "end") then
            self.from = new_from
        end
    end
end

return M
