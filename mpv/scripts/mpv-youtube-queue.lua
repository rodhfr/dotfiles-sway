-- mpv-youtube-queue.lua
--
-- YouTube 'Add To Queue' for mpv
--
-- Copyright (C) 2023 sudacode
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.
local mp = require("mp")
mp.options = require("mp.options")
local utils = require("mp.utils")
local assdraw = require("mp.assdraw")
local styleOn = mp.get_property("osd-ass-cc/0")
local styleOff = mp.get_property("osd-ass-cc/1")
local YouTubeQueue = {}
local video_queue = {}
local MSG_DURATION = 1.5
local index = 0
local selected_index = 1
local display_offset = 0
local marked_index = nil
local current_video = nil
local destroyer = nil
local timeout
local debug = false

local options = {
	add_to_queue = "ctrl+a",
	download_current_video = "ctrl+d",
	download_selected_video = "ctrl+D",
	move_cursor_down = "ctrl+j",
	move_cursor_up = "ctrl+k",
	move_video = "ctrl+m",
	play_next_in_queue = "ctrl+n",
	open_video_in_browser = "ctrl+o",
	open_channel_in_browser = "ctrl+O",
	play_previous_in_queue = "ctrl+p",
	print_current_video = "ctrl+P",
	print_queue = "ctrl+q",
	remove_from_queue = "ctrl+x",
	play_selected_video = "ctrl+ENTER",
	browser = "firefox",
	clipboard_command = "wl-paste",
	cursor_icon = "➤",
	display_limit = 10,
	download_directory = "~/videos/YouTube",
	download_quality = "720p",
	downloader = "curl",
	font_name = "JetBrains Mono",
	font_size = 12,
	marked_icon = "⇅",
	menu_timeout = 5,
	show_errors = true,
	ytdlp_file_format = "mp4",
	ytdlp_output_template = "%(uploader)s/%(title)s.%(ext)s",
	use_history_db = false,
	backend_host = "http://localhost",
	backend_port = "42069",
	save_queue = "ctrl+s",
	save_queue_alt = "ctrl+S",
	default_save_method = "unwatched",
	load_queue = "ctrl+l",
}
mp.options.read_options(options, "mpv-youtube-queue")

local function destroy()
	timeout:kill()
	mp.set_osd_ass(0, 0, "")
	destroyer = nil
end

timeout = mp.add_periodic_timer(options.menu_timeout, destroy)

-- STYLE {{{
local colors = {
	error = "676EFF",
	selected = "F993BD",
	hover_selected = "FAA9CA",
	cursor = "FDE98B",
	header = "8CFAF1",
	hover = "F2F8F8",
	text = "BFBFBF",
	marked = "C679FF",
}

local notransparent = "\\alpha&H00&"
local semitransparent = "\\alpha&H40&"
local sortoftransparent = "\\alpha&H59&"

local style = {
	error = "{\\c&" .. colors.error .. "&" .. notransparent .. "}",
	selected = "{\\c&" .. colors.selected .. "&" .. semitransparent .. "}",
	hover_selected = "{\\c&" .. colors.hover_selected .. "&\\alpha&H33&}",
	cursor = "{\\c&" .. colors.cursor .. "&" .. notransparent .. "}",
	marked = "{\\c&" .. colors.marked .. "&" .. notransparent .. "}",
	reset = "{\\c&" .. colors.text .. "&" .. sortoftransparent .. "}",
	header = "{\\fn"
		.. options.font_name
		.. "\\fs"
		.. options.font_size * 1.5
		.. "\\u1\\b1\\c&"
		.. colors.header
		.. "&"
		.. notransparent
		.. "}",
	hover = "{\\c&" .. colors.hover .. "&" .. semitransparent .. "}",
	font = "{\\fn" .. options.font_name .. "\\fs" .. options.font_size .. "{" .. sortoftransparent .. "}",
}
-- }}}

-- HELPERS {{{

--- surround string with single quotes if it does not already have them
--- @param s string - the string to surround with quotes
--- @return string | nil - the string surrounded with quotes
local function surround_with_quotes(s)
	if string.sub(s, 0, 1) == '"' and string.sub(s, -1) == '"' then
		return nil
	else
		return '"' .. s .. '"'
	end
end

--- return true if the input is null, empty, or 0
--- @param s any - the input to check for nullity
--- @return boolean - true if the input is null, false otherwise
local function isnull(s)
	if s == nil then
		return true
	elseif type(s) == "string" and s:match("^%s*$") then
		return true
	elseif type(s) == "number" and s == 0 then
		return true
	elseif type(s) == "table" and next(s) == nil then
		return true
	elseif type(s) == "boolean" and not s then
		return true
	end
	return false
end

-- remove single quotes, newlines, and carriage returns from a string
local function strip(s)
	return string.gsub(s, "['\n\r]", "")
end

-- print a message to the OSD
---@param message string - the message to print
---@param duration number - the duration to display the message
---@param s string - the style to use for the message
local function print_osd_message(message, duration, s)
	if s == style.error and not options.show_errors then
		return
	end
	destroy()
	if s == nil then
		s = style.font .. "{" .. notransparent .. "}"
	end
	if duration == nil then
		duration = MSG_DURATION
	end
	mp.osd_message(styleOn .. s .. message .. style.reset .. styleOff .. "\n", duration)
end

---returns true if the provided path exists and is a file
---@param filepath string - the path to check
---@return boolean - true if the path is a file, false otherwise
local function is_file(filepath)
	local result = utils.file_info(filepath)
	if debug and type(result) == "table" then
		print("IS_FILE() check: " .. tostring(result.is_file))
	end
	if result == nil or type(result) ~= "table" then
		return false
	end
	return true
end

---returns the filename given a path (eg. /home/user/file.txt -> file.txt)
---@param filepath string - the path to extract the filename from
---@return string | nil - the filename
local function split_path(filepath)
	if is_file(filepath) then
		return utils.split_path(filepath)
	end
end

--- returns the expanded path of a file. eg. ~/file.txt -> /home/user/file.txt
--- @param path string - the path to expand
--- @return string - the expanded path
local function expanduser(path)
	-- remove trailing slash if it exists
	if string.sub(path, -1) == "/" then
		path = string.sub(path, 1, -2)
	end
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME")
		if home then
			return home .. path:sub(2)
		else
			return path
		end
	else
		return path
	end
end

---Open a URL in the browser
---@param url string
local function open_url_in_browser(url)
	local command = options.browser .. " " .. surround_with_quotes(url)
	os.execute(command)
end

--- Opens the current video in the browser
local function open_video_in_browser()
	if current_video and current_video.video_url then
		open_url_in_browser(current_video.video_url)
	end
end

--- Opens the channel of the current video in the browser
local function open_channel_in_browser()
	if current_video and current_video.channel_url then
		open_url_in_browser(current_video.channel_url)
	end
end

-- Internal function to print the contents of the internal playlist to the console
local function print_internal_playlist()
	local count = mp.get_property_number("playlist-count")
	print("Playlist contents:")
	for i = 0, count - 1 do
		local uri = mp.get_property(string.format("playlist/%d/filename", i))
		print(string.format("%d: %s", i, uri))
	end
end

--- Helper function to build the OSD row for the queue
--- @param prefix string - the prefix to add to the row
--- @param s string - the style to apply to the row
--- @param i number - the index of the row
--- @param video_name string - the title of the video
--- @param channel_name string - the name of the channel
--- @return string - the OSD row
local function build_osd_row(prefix, s, i, video_name, channel_name)
	return prefix .. s .. i .. ". " .. video_name .. " - (" .. channel_name .. ")"
end

--- Helper function to determine display range for queue items
--- @param queue_length number Total number of items in queue
--- @param selected number Currently selected index
--- @param limit number Maximum items to display
--- @return number, number start and end indices
local function get_display_range(queue_length, selected, limit)
	local half_limit = math.floor(limit / 2)
	local start_index = selected <= half_limit and 1 or selected - half_limit
	local end_index = math.min(start_index + limit - 1, queue_length)
	return start_index, end_index
end

--- Helper function to get the style for a queue item
--- @param i number Current item index
--- @param current number Currently playing index
--- @param selected number Selected index
--- @return string Style to apply
local function get_item_style(i, current, selected)
	if i == current and i == selected then
		return style.hover_selected
	elseif i == current then
		return style.selected
	elseif i == selected then
		return style.hover
	end
	return style.reset
end

--- Toggle queue visibility
local function toggle_print()
	if destroyer ~= nil then
		destroyer()
	else
		YouTubeQueue.print_queue()
	end
end

-- Function to remove leading and trailing quotes from the first and last arguments of a command table in-place
local function remove_command_quotes(s)
	-- if the first character of the first argument is a quote, remove it
	if string.sub(s[1], 1, 1) == "'" or string.sub(s[1], 1, 1) == '"' then
		s[1] = string.sub(s[1], 2)
	end
	-- if the last character of the last argument is a quote, remove it
	if string.sub(s[#s], -1) == "'" or string.sub(s[#s], -1) == '"' then
		s[#s] = string.sub(s[#s], 1, -2)
	end
end

--- Function to split the clipboard_command into it's parts and return as a table
--- @param cmd string - the command to split
--- @return table - the split command as a table
local function split_command(cmd)
	local components = {}
	for arg in cmd:gmatch("%S+") do
		table.insert(components, arg)
	end
	remove_command_quotes(components)
	return components
end

--- Converts a key-value pair or a table of key-value pairs into a JSON string.
--- If the key is a table, it iterates over the table to construct a JSON object.
--- If the key is a single value, it constructs a JSON object with the provided key and value.
--- @param key any - A single key or a table of key-value pairs to convert.
--- @param val any - The value associated with the key, used only if the key is not a table.
--- @return string | nil - The resulting JSON string, or nil if the input is invalid.
local function convert_to_json(key, val)
	if type(key) == "table" then
		-- Handle the case where key is a table of key-value pairs
		local json = "{"
		local first = true
		for k, v in pairs(key) do
			if not first then
				json = json .. ", "
			end
			first = false

			local quoted_val = string.format('"%s"', v)
			json = json .. string.format('"%s": %s', k, quoted_val)
		end
		json = json .. "}"
		return json
	else
		if type(val) == "string" then
			return string.format('{"%s": "%s"}', key, val)
		else
			return string.format('{"%s": %s}', key, tostring(val))
		end
	end
end

-- }}}

-- QUEUE GETTERS AND SETTERS {{{

--- Gets the video at the specified index
--- @param idx number - the index of the video to get
--- @return table | nil - the video at the specified index
function YouTubeQueue.get_video_at(idx)
	if idx <= 0 or idx > #video_queue then
		print_osd_message("Invalid video index", MSG_DURATION, style.error)
		return nil
	end
	return video_queue[idx]
end

--- returns the content of the clipboard
--- @return string | nil - the content of the clipboard
function YouTubeQueue.get_clipboard_content()
	local command = split_command(options.clipboard_command)
	local res = mp.command_native({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = command,
	})

	if res.status ~= 0 then
		print_osd_message("Failed to get clipboard content", MSG_DURATION, style.error)
		return nil
	end

	local content = res.stdout:match("^%s*(.-)%s*$") -- Trim leading/trailing spaces
	if content:match("^https?://") then
		return content
	elseif content:match("^file://") or utils.file_info(content) then
		return content
	else
		print_osd_message("Clipboard content is not a valid URL or file path", MSG_DURATION, style.error)
		return nil
	end
end

--- Function to get the video info from the URL
--- @param url string - the URL to get the video info from
--- @return table | nil - a table containing the video information
function YouTubeQueue.get_video_info(url)
	print_osd_message("Getting video info...", MSG_DURATION * 2)
	local res = mp.command_native({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = {
			"yt-dlp",
			"--dump-single-json",
			"--ignore-config",
			"--no-warnings",
			"--skip-download",
			"--playlist-items",
			"1",
			url,
		},
	})

	if res.status ~= 0 or isnull(res.stdout) then
		print_osd_message("Failed to get video info (yt-dlp error)", MSG_DURATION, style.error)
		print("yt-dlp status: " .. res.status)
		return nil
	end

	local data = utils.parse_json(res.stdout)
	if isnull(data) then
		print_osd_message("Failed to parse JSON from yt-dlp", MSG_DURATION, style.error)
		return nil
	end

	local category = nil
	if data.categories then
		category = data.categories[1]
	else
		category = "Unknown"
	end
	local info = {
		channel_url = data.channel_url or "",
		channel_name = data.uploader or "",
		video_name = data.title or "",
		view_count = data.view_count or "",
		upload_date = data.upload_date or "",
		category = category or "",
		thumbnail_url = data.thumbnail or "",
		subscribers = data.channel_follower_count or 0,
	}

	if isnull(info.channel_url) or isnull(info.channel_name) or isnull(info.video_name) then
		print_osd_message("Missing metadata (channel_url, uploader, video_name) in JSON", MSG_DURATION, style.error)
		return nil
	end

	return info
end

--- Prints the currently playing video to the OSD
function YouTubeQueue.print_current_video()
	destroy()
	local current = current_video
	if current and current.vidro_url ~= "" and is_file(current.video_url) then
		print_osd_message("Playing: " .. current.video_url, 3)
	else
		if current and current.video_url then
			print_osd_message("Playing: " .. current.video_name .. " by " .. current.channel_name, 3)
		end
	end
end

-- }}}

-- QUEUE FUNCTIONS {{{

--- Function to set the next or previous video in the queue as the current video
--- direction can be "NEXT" or "PREV".  If nil, "next" is assumed
--- @param direction string - the direction to move in the queue
--- @return table | nil - the video at the new index
function YouTubeQueue.set_video(direction)
	local amt
	direction = string.upper(direction)
	if direction == "NEXT" or direction == nil then
		amt = 1
	elseif direction == "PREV" or direction == "PREVIOUS" then
		amt = -1
	else
		print_osd_message("Invalid direction: " .. direction, MSG_DURATION, style.error)
		return nil
	end
	if index + amt > #video_queue or index + amt == 0 then
		return nil
	end
	index = index + amt
	selected_index = index
	current_video = video_queue[index]
	return current_video
end

--- Function to check if a video is in the queue
--- @param url string - the URL to check
--- @return boolean - true if the video is in the queue, false otherwise
function YouTubeQueue.is_in_queue(url)
	for _, v in ipairs(video_queue) do
		if v.video_url == url then
			return true
		end
	end
	return false
end

--- Function to find the index of the currently playing video
--- @param update_history boolean - whether to update the history database
--- @return number | nil - the index of the currently playing video
function YouTubeQueue.update_current_index(update_history)
	if debug then
		print("Updating current index")
	end
	if #video_queue == 0 then
		return
	end
	if update_history == nil then
		update_history = false
	end
	local current_url = mp.get_property("path")
	for i, v in ipairs(video_queue) do
		if v.video_url == current_url then
			index = i
			selected_index = index
			---@class table
			current_video = YouTubeQueue.get_video_at(index)
			if update_history then
				YouTubeQueue.add_to_history_db(current_video)
			end
			return
		end
	end
	-- if not found, reset the index
	index = 0
end

--- Function to mark and move a video in the queue
--- If no video is marked, the currently selected video is marked
--- If a video is marked, it is moved to the selected position
function YouTubeQueue.mark_and_move_video()
	if marked_index == nil and selected_index ~= index then
		-- Mark the currently selected video for moving
		marked_index = selected_index
	else
		-- Move the previously marked video to the selected position
		---@diagnostic disable-next-line: param-type-mismatch
		YouTubeQueue.reorder_queue(marked_index, selected_index)
		-- print_osd_message("Video moved to the selected position.", 1.5)
		marked_index = nil -- Reset the marked index
	end
	-- Refresh the queue display
	YouTubeQueue.print_queue()
end

--- Function to reorder the queue
--- @param from_index number - the index to move from
--- @param to_index number - the index to move to
function YouTubeQueue.reorder_queue(from_index, to_index)
	if from_index == to_index or to_index == index then
		print_osd_message("No changes made.", 1.5)
		return
	end
	-- Check if the provided indices are within the bounds of the video_queue
	if from_index > 0 and from_index <= #video_queue and to_index > 0 and to_index <= #video_queue then
		-- move the video from the from_index to to_index in the internal playlist.
		-- playlist-move is 0-indexed
		if from_index < to_index and to_index == #video_queue then
			mp.commandv("playlist-move", from_index - 1, to_index)
			if to_index > index then
				index = index - 1
			end
		elseif from_index < to_index then
			mp.commandv("playlist-move", from_index - 1, to_index)
			if to_index > index then
				index = index - 1
			end
		else
			mp.commandv("playlist-move", from_index - 1, to_index - 1)
		end

		-- Remove from from_index and insert at to_index into YouTubeQueue
		local temp_video = video_queue[from_index]
		table.remove(video_queue, from_index)
		table.insert(video_queue, to_index, temp_video)
	else
		print_osd_message("Invalid indices for reordering. No changes made.", MSG_DURATION, style.error)
	end
end

--- Prints the queue to the OSD
--- @param duration number Optional duration to display the queue
function YouTubeQueue.print_queue(duration)
	-- Reset and prepare OSD
	timeout:kill()
	mp.set_osd_ass(0, 0, "")
	timeout:resume()

	if #video_queue == 0 then
		print_osd_message("No videos in the queue or history.", duration, style.error)
		destroyer = destroy
		return
	end

	local ass = assdraw.ass_new()
	ass:append(style.header .. "MPV-YOUTUBE-QUEUE{\\u0\\b0}" .. style.reset .. style.font .. "\n")

	local start_index, end_index = get_display_range(#video_queue, selected_index, options.display_limit)

	for i = start_index, end_index do
		local video = video_queue[i]
		if not video then
			break
		end
		local prefix = (i == selected_index) and style.cursor .. options.cursor_icon .. "\\h" .. style.reset
			or "\\h\\h\\h"
		local item_style = get_item_style(i, index, selected_index)
		local message = build_osd_row(prefix, item_style, i, video.video_name, video.channel_name) .. style.reset
		if i == marked_index then
			message = message .. " " .. style.marked .. options.marked_icon .. style.reset
		end
		ass:append(style.font .. message .. "\n")
	end
	mp.set_osd_ass(0, 0, ass.text)
	if duration then
		mp.add_timeout(duration, destroy)
	end
	destroyer = destroy
end

--- Function to move the cursor on the OSD by a specified amount.
--- Adjusts the selected index and updates the display offset to ensure
--- the selected item is visible within the display limits
--- @param amt number - the number of steps to move the cursor. Positive values move up, negative values move down.
function YouTubeQueue.move_cursor(amt)
	timeout:kill()
	timeout:resume()
	selected_index = selected_index - amt
	if selected_index < 1 then
		selected_index = 1
	elseif selected_index > #video_queue then
		selected_index = #video_queue
	end
	if amt == 1 and selected_index > 1 and selected_index < display_offset + 1 then
		display_offset = display_offset - math.abs(selected_index - amt)
	elseif amt == -1 and selected_index < #video_queue and selected_index > display_offset + options.display_limit then
		display_offset = display_offset + math.abs(selected_index - amt)
	end
	YouTubeQueue.print_queue()
end

--- play the video at the current index
function YouTubeQueue.play_video_at(idx)
	if idx <= 0 or idx > #video_queue then
		print_osd_message("Invalid video index", MSG_DURATION, style.error)
		return nil
	end
	index = idx
	selected_index = idx
	current_video = video_queue[index]
	mp.set_property_number("playlist-pos", index - 1) -- zero-based index
	YouTubeQueue.print_current_video()
	return current_video
end

--- play the next video in the queue
--- @param direction string - the direction to move in the queue
--- @return table | nil - the video at the new index
function YouTubeQueue.play_video(direction)
	direction = string.upper(direction)
	local video = YouTubeQueue.set_video(direction)
	if video == nil then
		print_osd_message("No video available.", MSG_DURATION, style.error)
		return
	end
	current_video = video
	selected_index = index
	-- if the current video is not the first in the queue, then play the video
	-- else, check if the video is playing and if not play the video with replace
	if direction == "NEXT" and #video_queue > 1 then
		YouTubeQueue.play_video_at(index)
	elseif direction == "NEXT" and #video_queue == 1 then
		local state = mp.get_property("core-idle")
		-- yes if the video is loaded but not currently playing
		if state == "yes" then
			mp.commandv("loadfile", video.video_url, "replace")
		end
	elseif direction == "PREV" or direction == "PREVIOUS" then
		mp.set_property_number("playlist-pos", index - 1)
	end
	YouTubeQueue.print_current_video()
end

--- add the video to the queue from the clipboard or call from script-message
--- updates the internal playlist by default, pass 0 to disable
--- @param url string - the URL to add to the queue
--- @param update_internal_playlist number - whether to update the internal playlist
--- @return table | nil - the video added to the queue
function YouTubeQueue.add_to_queue(url, update_internal_playlist)
	if update_internal_playlist == nil then
		update_internal_playlist = 0
	end
	if isnull(url) then
		--- @class string
		url = YouTubeQueue.get_clipboard_content()
		if url == nil then
			return
		end
	end
	if YouTubeQueue.is_in_queue(url) then
		print_osd_message("Video already in queue.", MSG_DURATION, style.error)
		return
	end

	local video, channel_url, video_name
	url = strip(url)
	if not is_file(url) then
		local info = YouTubeQueue.get_video_info(url)
		if info == nil then
			return nil
		end
		video_name = info.video_name
		video = info
		video["video_url"] = url
	else
		channel_url, video_name = split_path(url)
		if isnull(channel_url) or isnull(video_name) then
			print_osd_message("Error getting video info.", MSG_DURATION, style.error)
			return
		end
		video = {
			video_url = url,
			video_name = video_name,
			channel_url = channel_url,
			channel_name = "Local file",
			thumbnail_url = "",
			view_count = "",
			upload_date = "",
			category = "",
			subscribers = "",
		}
	end

	table.insert(video_queue, video)
	-- if the queue was empty, start playing the video
	-- otherwise, add the video to the playlist
	if not current_video then
		YouTubeQueue.play_video("NEXT")
	elseif update_internal_playlist == 0 then
		mp.commandv("loadfile", url, "append-play")
	end
	print_osd_message("Added " .. video_name .. " to queue.", MSG_DURATION)
end

--- Downloads the video at the specified index
--- @param idx number - the index of the video to download
--- @return boolean - true if the video was downloaded successfully, false otherwise
function YouTubeQueue.download_video_at(idx)
	if idx < 0 or idx > #video_queue then
		return false
	end
	local v = video_queue[idx]
	if is_file(v.video_url) then
		print_osd_message("Current video is a local file... doing nothing.", MSG_DURATION, style.error)
		return false
	end
	local o = options
	local q = o.download_quality:sub(1, -2)
	local dl_dir = expanduser(o.download_directory)

	print_osd_message("Downloading " .. v.video_name .. "...", MSG_DURATION)
	-- Run the download command
	mp.command_native_async({
		name = "subprocess",
		capture_stderr = true,
		detach = true,
		args = {
			"yt-dlp",
			"-f",
			"bestvideo[height<="
				.. q
				.. "][ext="
				.. options.ytdlp_file_format
				.. "]+bestaudio/best[height<="
				.. q
				.. "]/bestvideo[height<="
				.. q
				.. "]+bestaudio/best[height<="
				.. q
				.. "]",
			"-o",
			dl_dir .. "/" .. options.ytdlp_output_template,
			"--downloader",
			o.downloader,
			"--",
			v.video_url,
		},
	}, function(success, _, err)
		if success then
			print_osd_message("Finished downloading " .. v.video_name .. ".", MSG_DURATION)
		else
			print_osd_message("Error downloading " .. v.video_name .. ": " .. err, MSG_DURATION, style.error)
		end
	end)
	return true
end

--- Removes the video at the selected index from the queue
--- @return boolean - true if the video was removed successfully, false otherwise
function YouTubeQueue.remove_from_queue()
	if index == selected_index then
		print_osd_message("Cannot remove current video", MSG_DURATION, style.error)
		return false
	end
	table.remove(video_queue, selected_index)
	mp.commandv("playlist-remove", selected_index - 1)
	if current_video and current_video.video_name then
		print_osd_message("Deleted " .. current_video.video_name .. " from queue.", MSG_DURATION)
	end
	if selected_index > 1 then
		selected_index = selected_index - 1
	end
	index = index - 1
	YouTubeQueue.print_queue()
	return true
end

--- Returns a list of URLs in the queue from start_index to the end
--- @param start_index number - the index to start from
--- @return table | nil - a table of URLs
function YouTubeQueue.get_urls(start_index)
	if start_index < 0 or start_index > #video_queue then
		return nil
	end
	local urls = {}
	for i = start_index + 1, #video_queue do
		table.insert(urls, video_queue[i].video_url)
	end
	return urls
end
-- }}}

-- {{{ HISTORY DB

--- Add a video to the history database
--- @param v table - the video to add to the history database
--- @return boolean - true if the video was added successfully, false otherwise
function YouTubeQueue.add_to_history_db(v)
	if not options.use_history_db then
		return false
	end
	local url = options.backend_host .. ":" .. options.backend_port .. "/add_video"
	local json = convert_to_json(v)
	local command = { "curl", "-X", "POST", url, "-H", "Content-Type: application/json", "-d", json }
	if debug then
		print("Adding video to history")
		print("Command: " .. table.concat(command, " "))
	end
	print_osd_message("Adding video to history...", MSG_DURATION)
	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = command,
	}, function(success, _, err)
		if not success then
			print_osd_message("Failed to send video data to backend: " .. err, MSG_DURATION, style.error)
			return false
		end
	end)
	print_osd_message("Video added to history db", MSG_DURATION)
	return true
end

--- Saves the remainder of the videos in the queue
--- (all videos after the currently playing video) to the history database
--- @param idx number - the index to start saving from
--- @return boolean - true if the queue was saved successfully, false otherwise
function YouTubeQueue.save_queue(idx)
	if not options.use_history_db then
		return false
	end
	if idx == nil then
		idx = index
	end
	local url = options.backend_host .. ":" .. options.backend_port .. "/save_queue"
	local data = convert_to_json("urls", YouTubeQueue.get_urls(idx + 1))
	if data == nil or data == '{"urls": []}' then
		print_osd_message("Failed to save queue: No videos remaining in queue", MSG_DURATION, style.error)
		return false
	end
	if debug then
		print("Data: " .. data)
	end
	local command = { "curl", "-X", "POST", url, "-H", "Content-Type: application/json", "-d", data }
	if debug then
		print("Saving queue to history")
		print("Command: " .. table.concat(command, " "))
	end
	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = command,
	}, function(success, result, err)
		if not success then
			print_osd_message("Failed to save queue: " .. err, MSG_DURATION, style.error)
			return false
		end
		if debug then
			print("Status: " .. result.status)
		end
		if result.status == 0 then
			if idx > 1 then
				print_osd_message("Queue saved to history from index: " .. idx, MSG_DURATION)
			else
				print_osd_message("Queue saved to history.", MSG_DURATION)
			end
		end
	end)
	return true
end

-- loads the queue from the backend
function YouTubeQueue.load_queue()
	if not options.use_history_db then
		return false
	end
	local url = options.backend_host .. ":" .. options.backend_port .. "/load_queue"
	local command = { "curl", "-X", "GET", url }

	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = command,
	}, function(success, result, err)
		if not success then
			print_osd_message("Failed to load queue: " .. err, MSG_DURATION, style.error)
			return false
		else
			if result.status == 0 then
				-- split urls based on commas
				local urls = {}
				-- Remove the brackets from json list
				local l = result.stdout:sub(2, -3)
				local item
				for turl in l:gmatch("[^,]+") do
					item = turl:match("^%s*(.-)%s*$"):gsub('"', "'")
					table.insert(urls, item)
				end
				for _, turl in ipairs(urls) do
					YouTubeQueue.add_to_queue(turl, 0)
				end
				print_osd_message("Loaded queue from history.", MSG_DURATION)
			end
		end
	end)
end

-- }}}

-- LISTENERS {{{
-- Function to be called when the end-file event is triggered
-- This function is called when the current file ends or when moving to the
-- next or previous item in the internal playlist
local function on_end_file(event)
	if debug then
		print("End file event triggered: " .. event.reason)
	end
	if event.reason == "eof" then -- The file ended normally
		YouTubeQueue.update_current_index(true)
	end
end

-- Function to be called when the track-changed event is triggered
local function on_track_changed()
	if debug then
		print("Track changed event triggered.")
	end
	YouTubeQueue.update_current_index()
end

local function on_file_loaded()
	if debug then
		print("Load file event triggered.")
	end
	YouTubeQueue.update_current_index(true)
end

-- Function to be called when the playback-restart event is triggered
local function on_playback_restart()
	if debug then
		print("Playback restart event triggered.")
	end
	if current_video == nil then
		local url = mp.get_property("path")
		YouTubeQueue.add_to_queue(url)
		---@diagnostic disable-next-line: param-type-mismatch
		YouTubeQueue.add_to_history_db(current_video)
	end
end

-- }}}

-- KEY BINDINGS {{{
mp.add_key_binding(options.add_to_queue, "add_to_queue", YouTubeQueue.add_to_queue)
mp.add_key_binding(options.play_next_in_queue, "play_next_in_queue", function()
	YouTubeQueue.play_video("NEXT")
end)
mp.add_key_binding(options.play_previous_in_queue, "play_prev_in_queue", function()
	YouTubeQueue.play_video("PREV")
end)
mp.add_key_binding(options.print_queue, "print_queue", toggle_print)
mp.add_key_binding(options.move_cursor_up, "move_cursor_up", function()
	YouTubeQueue.move_cursor(1)
end, {
	repeatable = true,
})
mp.add_key_binding(options.move_cursor_down, "move_cursor_down", function()
	YouTubeQueue.move_cursor(-1)
end, {
	repeatable = true,
})
mp.add_key_binding(options.play_selected_video, "play_selected_video", function()
	YouTubeQueue.play_video_at(selected_index)
end)
mp.add_key_binding(options.open_video_in_browser, "open_video_in_browser", open_video_in_browser)
mp.add_key_binding(options.print_current_video, "print_current_video", YouTubeQueue.print_current_video)
mp.add_key_binding(options.open_channel_in_browser, "open_channel_in_browser", open_channel_in_browser)
mp.add_key_binding(options.download_current_video, "download_current_video", function()
	YouTubeQueue.download_video_at(index)
end)
mp.add_key_binding(options.download_selected_video, "download_selected_video", function()
	YouTubeQueue.download_video_at(selected_index)
end)
mp.add_key_binding(options.move_video, "move_video", YouTubeQueue.mark_and_move_video)
mp.add_key_binding(options.remove_from_queue, "delete_video", YouTubeQueue.remove_from_queue)
mp.add_key_binding(options.save_queue, "save_queue", function()
	if options.default_save_method == "unwatched" then
		YouTubeQueue.save_queue(index)
	else
		YouTubeQueue.save_queue(0)
	end
end)
mp.add_key_binding(options.save_queue_alt, "save_queue_alt", function()
	if options.default_save_method == "unwatched" then
		YouTubeQueue.save_queue(0)
	else
		YouTubeQueue.save_queue(index)
	end
end)
mp.add_key_binding(options.load_queue, "load_queue", YouTubeQueue.load_queue)

mp.register_event("end-file", on_end_file)
mp.register_event("track-changed", on_track_changed)
mp.register_event("playback-restart", on_playback_restart)
mp.register_event("file-loaded", on_file_loaded)

-- keep for backwards compatibility
mp.register_script_message("add_to_queue", YouTubeQueue.add_to_queue)
mp.register_script_message("print_queue", YouTubeQueue.print_queue)

mp.register_script_message("add_to_youtube_queue", YouTubeQueue.add_to_queue)
mp.register_script_message("toggle_youtube_queue", toggle_print)
mp.register_script_message("print_internal_playlist", print_internal_playlist)
mp.register_script_message("reorder_youtube_queue", YouTubeQueue.reorder_queue)
-- }}}
