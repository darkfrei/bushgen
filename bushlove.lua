-- bushlove.lua
-- small bridge between bushgen (pure lua) and love2d
--
--   local sprite = bushlove.request({style = 7, seed = 1, kind = "leafball", size = 64})
--   local sprite = bushlove.plant(style, seed, t, kind)
--   local sprite = bushlove.block(style, seed, t, opts)
--   love.graphics.draw(sprite.image, x - sprite.ax, y - sprite.ay)
--
-- a sprite is {image, data, w, h, ax, ay}; (ax, ay) is the anchor: the
-- point of the sprite that belongs on your map position (centre of the
-- plant, or cell centre on the ground for blocks)

local bushgen = require("bushgen")
local variety = require("variety")

local bushlove = {}

-- result of bushgen.generate -> love ImageData
function bushlove.toImageData(img)
	local data = love.image.newImageData(img.w, img.h)
	local px = img.pixels
	local w = img.w
	for y = 0, img.h - 1 do
		for x = 0, w - 1 do
			local o = (y * w + x) * 4
			data:setPixel(x, y, px[o + 1], px[o + 2], px[o + 3], px[o + 4])
		end
	end
	return data
end

-- result of bushgen.generate -> sprite table with a nearest-filtered image
function bushlove.toSprite(img)
	local data = bushlove.toImageData(img)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest")
	return {image = image, data = data, w = img.w, h = img.h, ax = img.ax, ay = img.ay}
end

-- any plant or cube with one options table, see variety.request
function bushlove.request(o)
	local img = variety.request(o)
	return bushlove.toSprite(img)
end

-- free-standing plant; style is a table from variety.makeStyle or a style seed
-- kind is optional ("round", "hedge", "bigleaf", ...), t is time (default 0)
function bushlove.plant(style, seed, t, kind, w, h, box)
	if type(style) == "number" then style = variety.makeStyle(style, t) end
	local q = variety.makePlant(style, seed, t, kind)
	return bushlove.toSprite(bushgen.generate(q, seed, w or 48, h or 48, box or 32))
end

-- hedge cube for one map cell; opts = {shape, tile, depth, height, join, ...}
function bushlove.block(style, seed, t, opts)
	if type(style) == "number" then style = variety.makeStyle(style, t) end
	local q = variety.makeBlock(style, seed, t, opts)
	return bushlove.toSprite(bushgen.generate(q, seed))
end

return bushlove
