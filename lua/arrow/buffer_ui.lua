local M = {}

local preview_buffers = {}

local persist = require("arrow.buffer_persist")
local config = require("arrow.config")

local lastRow = 0
local has_current_line = false
local current_line_index = -1
local call_win = -1
local delete_mode = false
local note_mode = false
local current_highlight = nil
local to_delete = {}
local spawn_col = -1

local function update_everything(bufnr)
	persist.update(bufnr)
	persist.clear_buffer_ext_marks(bufnr)
	persist.redraw_bookmarks(bufnr, persist.get_bookmarks_by(bufnr))
	persist.sync_buffer_bookmarks(bufnr)
end

vim.api.nvim_create_autocmd({ "BufLeave", "BufWritePost" }, {
	callback = function(args)
		local bufnr = tonumber(args.buf)
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				if persist.get_bookmarks_by(bufnr) ~= nil then
					update_everything(bufnr)
				end
			end
		end, 10)
	end,
})

local function getActionsMenu(count)
	local mappings = config.getState("mappings")

	local return_mappings

	if count == 0 then
		return_mappings = {
			string.format("  %s Quit", mappings.quit),
		}
	else
		return_mappings = {
			string.format("  %s Delete Mode", mappings.delete_mode),
			string.format("  %s Clear All", mappings.clear_all_items),
			string.format("  %s Quit", mappings.quit),
			string.format("  %s Note", "n"),
		}
	end

	if has_current_line then
		table.insert(return_mappings, 1, string.format("  %s Remove Line", mappings.toggle))
	else
		table.insert(return_mappings, 1, string.format("  %s Save Line", mappings.toggle))
	end

	return return_mappings
end

function M.spawn_preview_window(buffer, index, bookmark, bookmark_count, ith, parent_win)
	-- 4,13,22
	local lines_count = config.getState("per_buffer_config").lines
	local height = math.ceil((vim.o.lines - 4) / 2)
	local row = 0
	if bookmark_count <= 3 then
		if bookmark_count == 1 then
			row = 10
		elseif bookmark_count == 2 then
			if index == 1 then
				row = 8
			elseif index == 2 then
				row = 17
			end
		elseif bookmark_count == 3 then
			if index == 1 then
				row = 4
			elseif index == 2 then
				row = 13
			elseif index == 3 then
				row = 22
			end
		end
	else
		row = height + (index - 1) * (lines_count + 2) - (bookmark_count - 1) * lines_count + 2
	end
	local width = vim.api.nvim_win_get_width(parent_win) - 20
	lastRow = row
	spawn_col = width

	local window_config = {
		win = parent_win,
		height = lines_count,
		-- noautocmd = true,
		width = width,
		row = row,
		col = -1,
		relative = "win",
		border = "solid",
		zindex = 11,
	}

	local displayIndex = config.getState("index_keys"):sub(index, index)

	local win = vim.api.nvim_open_win(buffer, true, window_config)

	local extra_title = ""

	if current_line_index == index then
		extra_title = "(Current) "
	end
	local title = {}
	table.insert(title, { displayIndex .. " " .. extra_title, "FloatTitle" })
	if bookmark.note ~= nil then
		table.insert(title, { bookmark.note, "ArrowBookmarkNote" })
	end
	vim.api.nvim_win_set_option(win, "scrolloff", 999)
	local footer = string.rep("─", vim.api.nvim_win_get_width(win))
	vim.api.nvim_win_set_cursor(win, { bookmark.line, 0 })
	vim.api.nvim_win_set_config(win, { title = title, title_pos = "left" })
	if ith < bookmark_count then
		vim.api.nvim_win_set_config(win, { footer = { { footer, "NvimTreeWinSeparator" } }, footer_pos = "left" })
	end
	vim.api.nvim_win_set_option(win, "number", true)
	table.insert(preview_buffers, { buffer = buffer, win = win, index = index })

	local ctx_config = config.getState("per_buffer_config").treesitter_context
	if ctx_config ~= nil and ctx_config.line_shift_down ~= nil then
		local shift = ctx_config.line_shift_down
		local win_view = vim.fn.winsaveview()
		vim.api.nvim_win_set_option(win, "scrolloff", 0)
		vim.fn.winrestview({ topline = win_view.topline - shift })
		local ok, _ = pcall(require, "treesitter-context")
		if not ok then
			vim.notify("you don't have treesitter-context installed", vim.log.levels.WARN)
			return
		end

		local context, context_lines = require("treesitter-context.context").get(buffer, win, 2)
		if context and #context > 0 then
			vim.defer_fn(function()
				require("treesitter-context.render").open(buffer, win, context, context_lines)
			end, 1)
		end
	end
end

local function remove_preview_buffer_by_index(index)
	for i, buffer in ipairs(preview_buffers) do
		if buffer.index == index then
			table.insert(to_delete, i)
			vim.api.nvim_win_close(buffer.win, true)
		end
	end
end

local function restore_cursor()
	vim.cmd("highlight clear Cursor")

	vim.schedule(function()
		local old_hl = hl
		old_hl.blend = 0
		pcall(vim.api.nvim_set_hl, 0, "Cursor", old_hl)
		vim.opt.guicursor:remove("a:Cursor/lCursor")
	end)
end

local function hide_cursor()
	hl = vim.api.nvim_get_hl_by_name("Cursor", true)
	hl.blend = 100

	vim.opt.guicursor:append("a:Cursor/lCursor")

	pcall(vim.api.nvim_set_hl, 0, "Cursor", hl)
end

local function add_note_by_index(index, bufnr)
	for i, buffer in ipairs(preview_buffers) do
		if buffer.index == index then
			restore_cursor()
			vim.ui.input({ prompt = "Add notes: ", completion = "file", default = "" }, function(input)
				if input == nil then
					return
				end
				input = input .. " "
				persist.add_notes(i, input, bufnr)
				local win_config = vim.api.nvim_win_get_config(buffer.win)
				if win_config.title[2] ~= nil then
					win_config.title[2][1] = input
				else
					win_config.title[2] = { input, "ArrowBookmarkNote" }
				end
				vim.api.nvim_win_set_config(buffer.win, win_config)
				hide_cursor()
			end)
		end
	end
end

local function close_preview_windows()
	for _, buffer in ipairs(preview_buffers) do
		vim.schedule(function()
			if vim.api.nvim_win_is_valid(buffer.win) then
				vim.api.nvim_win_close(buffer.win, true)
			end
		end)
	end
	_G.no_animation()
end

local function reset_variables()
	lastRow = 0
	preview_buffers = {}
	has_current_line = false
	current_line_index = -1
	to_delete = {}
	call_win = -1
	delete_mode = false
	note_mode = false
	spawn_col = -1

	if current_highlight then
		pcall(vim.api.nvim_set_hl, 0, "FloatBorder", current_highlight)
	end
end

local function go_to_window()
	if vim.api.nvim_win_is_valid(call_win) then
		vim.api.nvim_set_current_win(call_win)
	end
end

local function render_highlights(buffer)
	vim.api.nvim_buf_clear_namespace(buffer, -1, 0, -1)

	local buffer_line_count = vim.api.nvim_buf_line_count(buffer)

	for i = 0, buffer_line_count - 1 do
		vim.api.nvim_buf_add_highlight(buffer, -1, "ArrowFileIndex", i, 0, 3)

		-- if line contains Delete Mode
		if string.match(vim.fn.getline(i + 1), "Delete Mode") and delete_mode then
			vim.api.nvim_buf_add_highlight(buffer, -1, "ArrowDeleteMode", i, 0, 3)
		end
	end
end

local function delete_marks_from_delete_mode(call_buffer)
	local reversely_sorted_to_delete = vim.fn.reverse(vim.fn.sort(to_delete))

	for _, index in ipairs(reversely_sorted_to_delete) do
		persist.remove(index, call_buffer)
	end
end

local function after_close(call_buffer)
	close_preview_windows()
	go_to_window()

	delete_marks_from_delete_mode(call_buffer)

	reset_variables()

	persist.clear_buffer_ext_marks(call_buffer)
	persist.redraw_bookmarks(call_buffer, persist.get_bookmarks_by(call_buffer))
end

local function closeMenu(actions_buffer, call_buffer)
	if vim.api.nvim_buf_is_valid(actions_buffer) then
		vim.api.nvim_buf_delete(actions_buffer, { force = true })
	end

	after_close(call_buffer)
end

local function go_to_bookmark(bookmark)
	vim.cmd("normal! m'")
	local win_height = vim.fn.winheight(0)
	local top_line = vim.fn.line("w0")

	vim.api.nvim_win_set_cursor(0, { bookmark.line, bookmark.col })

	if bookmark.line < top_line or bookmark.line >= top_line + win_height then
		vim.cmd("normal! zz")
		require("config.utils").adjust_view(0, 3)
	end
end

local function toggle_delete_mode(action_buffer)
	if delete_mode then
		delete_mode = false

		pcall(vim.api.nvim_set_hl, 0, "FloatBorder", current_highlight)
	else
		delete_mode = true

		current_highlight = vim.api.nvim_get_hl_by_name("FloatBorder", true)
		local arrow_delete_mode = vim.api.nvim_get_hl_by_name("ArrowDeleteMode", true)

		vim.api.nvim_set_hl(0, "FloatBorder", { fg = arrow_delete_mode.bg or "red" })
	end

	render_highlights(action_buffer)
end

local function toggle_note_mode(action_buffer)
	if note_mode then
		note_mode = false

		pcall(vim.api.nvim_set_hl, 0, "FloatBorder", current_highlight)
	else
		note_mode = true

		current_highlight = vim.api.nvim_get_hl_by_name("FloatBorder", true)
		local arrow_note_mode = vim.api.nvim_get_hl_by_name("ArrowNoteMode", true)
		-- __AUTO_GENERATED_PRINT_VAR_START__
		-- print([==[toggle_note_mode#if arrow_note_mode:]==], vim.inspect(arrow_note_mode.bg)) -- __AUTO_GENERATED_PRINT_VAR_END__
		vim.api.nvim_set_hl(0, "FloatBorder", { fg = arrow_note_mode.background or "red" })
	end

	render_highlights(action_buffer)
end

function M.next_item(bufnr, line_nr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	update_everything(bufnr)

	local bookmarks = persist.get_bookmarks_by(bufnr) or {}

	if #bookmarks == 0 then
		return
	end

	-- find closest bookmark after the line_nr, if exists, go to it, if not, go to first

	local sorted_by_line_bookmarks = vim.fn.sort(bookmarks, function(a, b)
		return a.line > b.line
	end)

	for _, bookmark in ipairs(sorted_by_line_bookmarks) do
		if bookmark.line > line_nr then
			return go_to_bookmark(bookmark)
		end
	end

	go_to_bookmark(sorted_by_line_bookmarks[1])
end

function M.prev_item(bufnr, line_nr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	update_everything(bufnr)

	local bookmarks = persist.get_bookmarks_by(bufnr) or {}

	if #bookmarks == 0 then
		return
	end

	local sorted_by_line_bookmarks = vim.fn.sort(bookmarks, function(a, b)
		return a.line < b.line
	end)

	for _, bookmark in ipairs(sorted_by_line_bookmarks) do
		if bookmark.line < line_nr then
			return go_to_bookmark(bookmark)
		end
	end

	go_to_bookmark(sorted_by_line_bookmarks[#sorted_by_line_bookmarks])
end

function M.toggle_line(call_buffer, line_nr, col_nr)
	local is_saved

	for i, bookmark in ipairs(persist.get_bookmarks_by(call_buffer)) do
		if bookmark.line == line_nr then
			is_saved = i
		end
	end

	if is_saved ~= nil then
		persist.remove(is_saved, call_buffer)
	else
		persist.save(call_buffer, line_nr, col_nr)
	end
end

function M.spawn_action_windows(call_buffer, bookmarks, line_nr, col_nr, call_window, index)
	local actions_buffer = vim.api.nvim_create_buf(false, true)

	hl = vim.api.nvim_get_hl_by_name("Cursor", true)
	hl.blend = 100

	vim.opt.guicursor:append("a:Cursor/lCursor")

	pcall(vim.api.nvim_set_hl, 0, "Cursor", hl)

	local lines_count = config.getState("per_buffer_config").lines

	local width = math.ceil(vim.o.columns / 2)

	local window_config

	local nvim10 = vim.fn.has("nvim-0.10") > 0
	if #bookmarks == 0 then
		window_config = {
			height = 2,
			width = 15,
			row = math.ceil((vim.o.lines - 2) / 2),
			col = math.ceil((vim.o.columns - 15) / 2),
			style = "minimal",
			zindex = 11,
			relative = "editor",
			border = "solid",
		}
	else
		window_config = {
			height = 5,
			width = 17,
			row = lastRow + lines_count + 2,
			col = width - spawn_col / 2,
			style = "minimal",
			zindex = 11,
			relative = "editor",
			border = "solid",
		}
		if nvim10 then
			window_config.hide = true
		end
	end
	vim.api.nvim_open_win(actions_buffer, true, window_config)

	local mappings = config.getState("mappings")

	local lines = getActionsMenu(#bookmarks)

	local menuKeymapOpts = { noremap = true, silent = true, buffer = actions_buffer, nowait = true }

	vim.api.nvim_buf_set_option(actions_buffer, "modifiable", true)

	vim.api.nvim_buf_set_lines(actions_buffer, 0, -1, false, lines)

	vim.keymap.set("n", config.getState("leader_key"), function()
		closeMenu(actions_buffer, call_buffer)

		vim.schedule(function()
			require("arrow.ui").openMenu()
		end)
	end, menuKeymapOpts)

	vim.keymap.set("n", mappings.quit, function()
		closeMenu(actions_buffer, call_buffer)
	end, menuKeymapOpts)

	vim.keymap.set("n", "<Esc>", function()
		closeMenu(actions_buffer, call_buffer)
	end, menuKeymapOpts)

	vim.keymap.set("n", config.getState("buffer_leader_key"), function()
		closeMenu(actions_buffer, call_buffer)
	end, menuKeymapOpts)

	vim.keymap.set("n", mappings.clear_all_items, function()
		persist.clear(call_buffer)
		closeMenu(actions_buffer, call_buffer)
	end, menuKeymapOpts)

	vim.keymap.set("n", "n", function()
		if #bookmarks > 0 then
			toggle_note_mode(actions_buffer)
		end
	end, menuKeymapOpts)

	vim.keymap.set("n", mappings.delete_mode, function()
		if #bookmarks > 0 then
			toggle_delete_mode(actions_buffer)
		end
	end, menuKeymapOpts)

	if not has_current_line then
		vim.keymap.set("n", mappings.toggle, function()
			persist.save(call_buffer, line_nr, col_nr)
			closeMenu(actions_buffer, call_buffer)
		end, menuKeymapOpts)
	else
		vim.keymap.set("n", mappings.toggle, function()
			persist.remove(current_line_index, call_buffer)
			closeMenu(actions_buffer, call_buffer)
		end, menuKeymapOpts)
	end

	local indexes = config.getState("index_keys")

	for i, bookmark in ipairs(bookmarks) do
		vim.keymap.set("n", indexes:sub(i, i), function()
			local found = false
			for _, deleted in ipairs(to_delete) do
				if i == deleted then
					found = true
				end
			end

			if not found then
				if delete_mode then
					remove_preview_buffer_by_index(i)
				elseif note_mode then
					add_note_by_index(i, call_buffer)
				else
					closeMenu(actions_buffer, call_buffer)
					go_to_bookmark(bookmark)
				end
			end
		end, menuKeymapOpts)
	end

	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = 0,
		once = true,
		desc = "Disable Cursor",
		callback = function()
			vim.cmd("highlight clear Cursor")

			close_preview_windows()
			vim.schedule(function()
				local old_hl = hl
				old_hl.blend = 0
				pcall(vim.api.nvim_set_hl, 0, "Cursor", old_hl)

				if vim.api.nvim_buf_is_valid(actions_buffer) then
					closeMenu(actions_buffer, call_buffer)
				end

				vim.opt.guicursor:remove("a:Cursor/lCursor")
			end)
		end,
	})

	render_highlights(actions_buffer)
end

function M.openMenu(bufnr)
	local parent_win = vim.api.nvim_get_current_win()
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	persist.update()
	persist.sync_buffer_bookmarks()
	persist.redraw_bookmarks(bufnr, persist.get_bookmarks_by(bufnr))
	local bookmarks = persist.get_bookmarks_by()

	if not bookmarks then
		bookmarks = {}
	end

	local line_nr = vim.api.nvim_win_get_cursor(0)[1]
	local col_nr = vim.api.nvim_win_get_cursor(0)[2]

	call_win = vim.api.nvim_get_current_win()

	local opts_for_spawn = {}

	for index, bookmark in ipairs(bookmarks or {}) do
		if bookmark.line == line_nr then
			has_current_line = true
			current_line_index = index
		end

		table.insert(opts_for_spawn, { bufnr, index, bookmark })
	end

	for i, opt in ipairs(opts_for_spawn) do
		M.spawn_preview_window(opt[1], opt[2], opt[3], #bookmarks, i, parent_win)
	end

	M.spawn_action_windows(bufnr, bookmarks, line_nr, col_nr, cur_win)
end

return M
