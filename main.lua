-- main.lua
-- viewer for bushgen with smooth mutation animation
--
-- every sprite has an anchor (ax, ay) and is drawn so the anchor lands on
-- its place in the scene: plants on the centre of a 32 px grid cell,
-- hedge blocks on the centre of their map cell on the ground. sprites are
-- larger than the cell and overlap, they are drawn back to front.
--
-- modes
--   styles:  every row is one random style, columns are different plants
--   focus:   the whole grid shows plants of the selected style
--   presets: every preset from data_plants.lua is one row (no animation)
--   maze:    the map from data_maze.lua as hedge blocks, square view on
--            the left, iso view on the right, in the selected style
--
-- keys
--   space          play / pause
--   left / right   rewind / forward while held (shift: faster)
--   r              reverse playback direction
--   home           back to time 0
--   + / -          animation speed
--   up / down      select style (styles: row; focus, maze: previous / next)
--   m              focus on the selected style / back to all styles
--   b              maze mode on / off
--   tab            presets mode on / off
--   n              new world (new seeds for everything)
--   [ / ]          smaller / larger sprites (32, 48, 64, 96 px)
--   s              save all sprites as a png sheet, e: same sheet 5x larger
--                  (each sprite in its own cell, no overlap)
--   f              fit the scene into the window
--   wheel          zoom at mouse, drag with left mouse to move
--   h              help on / off, esc: quit

local bushgen = require("bushgen")
local plants = require("data_plants")
local variety = require("variety")
local maze = require("data_maze")

local SIZES = {32, 48, 64, 96} -- sprite sizes to switch with [ and ]
local sizeIndex = 2
local SPRITE = 48   -- plant sprite size, larger than the box
local BOX = 32      -- design box of plants (2/3 of the sprite), also the grid step
local COLS = 8
local ROWS = 9
local BUDGET = 0.012 -- seconds of tile generation per frame
local EXPORT_SCALE = 5

local mode = "styles"
local lastGridMode = "styles"
local world = 1
local selected = 1
local t = 0
local speed = 0.01 -- time units per frame at 60 fps
local dir = 1
local playing = true
local showHelp = true

local view = {x = 0, y = 0, scale = 2}
local dragging = false
local tiles = {}
local floorCells = {} -- floor cells of the maze: {kind, x, y} in scene pixels
local cursor = 1
local exportSrc = nil

---------------------------------------------------------------- scene

local function styleSeed(row)
	return world * 1009 + row * 7919 + 17
end

local function gridRows()
	if mode == "presets" then return #plants end
	return ROWS
end

local function isWall(i, j)
	local row = maze.map[j + 1]
	return row ~= nil and i >= 0 and i < #row and row:sub(i + 1, i + 1) == "#"
end

local function joinOf(i, j)
	return {n = isWall(i, j - 1), e = isWall(i + 1, j), s = isWall(i, j + 1), w = isWall(i - 1, j)}
end

local function addTile(tl)
	tl.doneT = nil
	tiles[#tiles + 1] = tl
end

local function buildGridTiles()
	for row = 1, gridRows() do
		for col = 1, COLS do
			local tl = {cx = (col - 1) * BOX + BOX / 2, cy = (row - 1) * BOX + BOX / 2, row = row}
			local seed = world * 100003 + row * 1301 + col * 97 + 5
			if mode == "presets" then
				tl.preset = plants[row]
				tl.seed = seed
			elseif mode == "focus" then
				local index = (row - 1) * COLS + col
				tl.style = styleSeed(selected)
				tl.seed = world * 100003 + selected * 1301 + index * 97 + 5
			else
				tl.style = styleSeed(row)
				tl.seed = seed
			end
			addTile(tl)
		end
	end
end

-- iso walls are drawn in order of i + j, so closer cells come later
local function isoOrder(a, b)
	if a.depth ~= b.depth then return a.depth < b.depth end
	return a.j < b.j
end

local function buildMazeTiles()
	local T = maze.tile
	local rows = #maze.map
	local cols = #maze.map[1]
	local st = styleSeed(selected)
	-- square view: cell (i, j) centre at (i * T + T / 2, j * T + T / 2)
	for j = 0, rows - 1 do
		for i = 0, cols - 1 do
			local cx, cy = i * T + T / 2, j * T + T / 2
			if isWall(i, j) then
				addTile({cx = cx, cy = cy, style = st, seed = world * 7777 + j * 131 + i,
						block = {shape = "square", tile = T, height = maze.squareHeight, join = joinOf(i, j)}})
			else
				floorCells[#floorCells + 1] = {kind = "square", x = cx, y = cy, odd = (i + j) % 2 == 1}
			end
		end
	end
	-- iso view to the right: cell (i, j) centre at (ox + (i - j) * T / 2, (i + j) * T / 4)
	local ox = cols * T + T + rows * T / 2
	local oy = T / 4
	local iso = {}
	for j = 0, rows - 1 do
		for i = 0, cols - 1 do
			local cx, cy = ox + (i - j) * T / 2, oy + (i + j) * T / 4
			if isWall(i, j) then
				iso[#iso + 1] = {cx = cx, cy = cy, style = st, seed = world * 7777 + j * 131 + i,
					depth = i + j, j = j,
					block = {shape = "iso", tile = T, height = maze.isoHeight, join = joinOf(i, j)}}
			else
				floorCells[#floorCells + 1] = {kind = "iso", x = cx, y = cy, odd = (i + j) % 2 == 1}
			end
		end
	end
	table.sort(iso, isoOrder)
	for _, tl in ipairs(iso) do addTile(tl) end
end

local function buildScene()
	tiles = {}
	floorCells = {}
	if mode == "maze" then
		buildMazeTiles()
	else
		buildGridTiles()
	end
	cursor = 1
end

---------------------------------------------------------------- rendering

local function renderTile(tl)
	local img
	if tl.preset then
		img = bushgen.generate(tl.preset, tl.seed, SPRITE, SPRITE, BOX)
	elseif tl.block then
		local st = variety.makeStyle(tl.style, t)
		img = bushgen.generate(variety.makeBlock(st, tl.seed, t, tl.block), tl.seed)
	else
		img = variety.request({style = tl.style, seed = tl.seed, t = t, size = SPRITE, box = BOX})
	end
	if not tl.data or tl.w ~= img.w or tl.h ~= img.h then
		tl.data = love.image.newImageData(img.w, img.h)
		tl.image = love.graphics.newImage(tl.data)
		tl.image:setFilter("nearest", "nearest")
		tl.w, tl.h = img.w, img.h
	end
	tl.ax, tl.ay = img.ax, img.ay
	local px = img.pixels
	for y = 0, img.h - 1 do
		for x = 0, img.w - 1 do
			local o = (y * img.w + x) * 4
			tl.data:setPixel(x, y, px[o + 1], px[o + 2], px[o + 3], px[o + 4])
		end
	end
	tl.image:replacePixels(tl.data)
	tl.doneT = t
end

-- renders tiles that are behind the current time, round robin, until
-- the frame budget is used; presets do not depend on time
local function updateTiles()
	local start = love.timer.getTime()
	local n = #tiles
	for _ = 1, n do
		local tl = tiles[cursor]
		cursor = cursor % n + 1
		local stale = tl.doneT == nil or (not tl.preset and tl.doneT ~= t)
		if stale then
			renderTile(tl)
			if love.timer.getTime() - start > BUDGET then break end
		end
	end
end

---------------------------------------------------------------- view

-- scene bounds from anchors; sprites reach about one cell around them
local function sceneBounds()
	local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
	for _, tl in ipairs(tiles) do
		x0 = math.min(x0, tl.cx - BOX)
		x1 = math.max(x1, tl.cx + BOX)
		y0 = math.min(y0, tl.cy - BOX * 1.5)
		y1 = math.max(y1, tl.cy + BOX)
	end
	return x0, y0, x1, y1
end

local function fitView()
	local w, h = love.graphics.getDimensions()
	local x0, y0, x1, y1 = sceneBounds()
	local left = mode == "maze" and 20 or 90
	view.scale = math.max(1, math.floor(math.min((w - left - 20) / (x1 - x0), (h - 70) / (y1 - y0))))
	view.x = math.floor(left + (w - left - 20 - (x1 - x0) * view.scale) / 2 - x0 * view.scale)
	view.y = math.floor(30 + (h - 70 - (y1 - y0) * view.scale) / 2 - y0 * view.scale)
end

---------------------------------------------------------------- export

local function upscalePixel(x, y)
	return exportSrc:getPixel(math.floor(x / EXPORT_SCALE), math.floor(y / EXPORT_SCALE))
end

-- sheet of whole sprites, one per cell, transparent background
local function saveSheet(factor)
	local cw, ch, count = 1, 1, 0
	for _, tl in ipairs(tiles) do
		if tl.data then
			cw = math.max(cw, tl.w)
			ch = math.max(ch, tl.h)
			count = count + 1
		end
	end
	if count == 0 then return end
	local cols = COLS
	local rows = math.ceil(count / cols)
	local sheet = love.image.newImageData(cols * cw, rows * ch)
	local k = 0
	for _, tl in ipairs(tiles) do
		if tl.data then
			local x = (k % cols) * cw + math.floor((cw - tl.w) / 2)
			local y = math.floor(k / cols) * ch + (ch - tl.h)
			sheet:paste(tl.data, x, y, 0, 0, tl.w, tl.h)
			k = k + 1
		end
	end
	local name = string.format("bushgen_%s_w%d_t%.2f", mode, world, t)
	if factor > 1 then
		exportSrc = sheet
		local big = love.image.newImageData(sheet:getWidth() * factor, sheet:getHeight() * factor)
		big:mapPixel(upscalePixel)
		sheet = big
		name = name .. "_x" .. factor
	end
	name = name .. ".png"
	sheet:encode("png", name)
	print("saved " .. love.filesystem.getSaveDirectory() .. "/" .. name)
end

---------------------------------------------------------------- love

function love.load()
	love.graphics.setDefaultFilter("nearest", "nearest")
	local dw, dh = love.window.getDesktopDimensions()
	love.window.setMode(math.floor(dw * 0.85), math.floor(dh * 0.85), {resizable = true})
	love.window.setTitle("bushgen")
	buildScene()
	fitView()
end

function love.update(dt)
	local step = speed * dt * 60
	local fast = love.keyboard.isDown("lshift", "rshift") and 5 or 1
	if love.keyboard.isDown("left") then
		t = t - step * 4 * fast
	elseif love.keyboard.isDown("right") then
		t = t + step * 4 * fast
	elseif playing and mode ~= "presets" then
		t = t + step * dir
	end
	updateTiles()
end

function love.keypressed(key)
	if key == "space" then
		playing = not playing
	elseif key == "r" then
		dir = -dir
	elseif key == "home" then
		t = 0
	elseif key == "=" or key == "+" or key == "kp+" then
		speed = math.min(0.2, speed * 1.5)
	elseif key == "-" or key == "kp-" then
		speed = math.max(0.0005, speed / 1.5)
	elseif key == "up" or key == "down" then
		local d = key == "up" and -1 or 1
		if mode == "focus" or mode == "maze" then
			selected = math.max(1, selected + d)
			buildScene()
		elseif mode == "styles" then
			selected = math.max(1, math.min(ROWS, selected + d))
		end
	elseif key == "m" then
		if mode == "styles" then
			mode = "focus"
		elseif mode == "focus" then
			mode = "styles"
			selected = math.min(selected, ROWS)
		end
		buildScene()
	elseif key == "b" then
		if mode == "maze" then
			mode = lastGridMode
			selected = math.min(selected, ROWS)
		else
			if mode ~= "presets" then lastGridMode = mode end
			mode = "maze"
		end
		buildScene()
		fitView()
	elseif key == "tab" then
		mode = mode == "presets" and "styles" or "presets"
		selected = math.min(selected, ROWS)
		buildScene()
		fitView()
	elseif key == "n" then
		world = world + 1
		buildScene()
	elseif key == "[" or key == "]" then
		sizeIndex = math.max(1, math.min(#SIZES, sizeIndex + (key == "]" and 1 or -1)))
		SPRITE = SIZES[sizeIndex]
		BOX = math.floor(SPRITE * 2 / 3 + 0.5)
		buildScene()
		fitView()
	elseif key == "f" then
		fitView()
	elseif key == "s" then
		saveSheet(1)
	elseif key == "e" then
		saveSheet(EXPORT_SCALE)
	elseif key == "h" then
		showHelp = not showHelp
	elseif key == "escape" then
		love.event.quit()
	end
end

-- zoom in integer steps, keeping the point under the mouse in place
function love.wheelmoved(_, dy)
	local mx, my = love.mouse.getPosition()
	local old = view.scale
	local new = math.max(1, math.min(32, old + (dy > 0 and 1 or -1)))
	if new == old then return end
	local wx, wy = (mx - view.x) / old, (my - view.y) / old
	view.x = math.floor(mx - wx * new + 0.5)
	view.y = math.floor(my - wy * new + 0.5)
	view.scale = new
end

function love.mousepressed(_, _, button)
	if button == 1 then dragging = true end
end

function love.mousereleased(_, _, button)
	if button == 1 then dragging = false end
end

function love.mousemoved(_, _, dx, dy)
	if dragging then
		view.x = view.x + dx
		view.y = view.y + dy
	end
end

local function drawFloor(s)
	local T = maze.tile
	for _, f in ipairs(floorCells) do
		if f.odd then
			love.graphics.setColor(0.47, 0.5, 0.39)
		else
			love.graphics.setColor(0.5, 0.53, 0.42)
		end
		local x, y = view.x + f.x * s, view.y + f.y * s
		if f.kind == "square" then
			love.graphics.rectangle("fill", x - T / 2 * s, y - T / 2 * s, T * s, T * s)
		else
			love.graphics.polygon("fill", x, y - T / 4 * s, x + T / 2 * s, y, x, y + T / 4 * s, x - T / 2 * s, y)
		end
	end
end

local function drawLabels(s)
	for row = 1, gridRows() do
		local y = view.y + (row - 1) * BOX * s
		local label
		if mode == "presets" then
			label = plants[row].name
		elseif mode == "focus" then
			label = row == 1 and ("style " .. selected) or ""
		else
			label = "style " .. row
		end
		if mode == "styles" and row == selected then
			love.graphics.setColor(1, 1, 0.6)
			love.graphics.rectangle("line", view.x - 1, y - 1, COLS * BOX * s + 2, BOX * s + 2)
		else
			love.graphics.setColor(0.1, 0.1, 0.1)
		end
		love.graphics.print(label, view.x - 16 * s - 70, y + BOX * s / 2 - 6)
	end
end

function love.draw()
	if mode == "maze" then
		love.graphics.clear(0.36, 0.4, 0.3)
	else
		love.graphics.clear(0.5, 0.5, 0.5)
	end
	local s = view.scale
	if mode == "maze" then drawFloor(s) end
	-- sprites in list order, which is back to front
	love.graphics.setColor(1, 1, 1)
	for _, tl in ipairs(tiles) do
		if tl.image then
			love.graphics.draw(tl.image, view.x + (tl.cx - tl.ax) * s, view.y + (tl.cy - tl.ay) * s, 0, s, s)
		end
	end
	if mode ~= "maze" then drawLabels(s) end
	-- status line
	love.graphics.setColor(0.08, 0.08, 0.08)
	local h = love.graphics.getHeight()
	local state = playing and (dir > 0 and "play" or "play back") or "pause"
	local styleInfo = (mode == "maze" or mode == "focus") and ("   style " .. selected) or ""
	love.graphics.print(string.format("%s%s   t %.2f   speed %.4f   %s   world %d   zoom %dx   sprite %d",
			mode, styleInfo, t, speed, state, world, s, SPRITE), 10, h - 22)
	if showHelp then
		love.graphics.print("space play/pause   left/right rewind/forward (shift faster)   r reverse   home t=0   +/- speed\n"
			.. "up/down style   m focus style   b maze   tab presets   n new world   [ ] sprite size   s save sheet   e save x5   f fit   wheel zoom, drag move   h help",
			10, 8)
	end
end
