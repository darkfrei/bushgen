-- variety.lua
-- random recipes for bushgen, in two layers:
--   makeStyle(seed, t)           shared look of a set: palette, outline,
--                                texture, fringe, contrast, ornaments, bark
--   makePlant(style, seed, t, kind)
--                                one plant in that style: kind, size,
--                                proportions, counts, flowers, undergrowth;
--                                kind (a name from data_plants.lua) is
--                                optional, without it the kind is random
--   makeBlock(style, seed, t, opts)
--                                trimmed hedge cube for one map cell,
--                                opts = {shape, tile, depth, height, ...}
--   request(o)                   one call for any plant or cube, with the
--                                sprite size; returns the generated image
-- all ranges live in data_variety.lua
--
-- time: every continuous parameter follows its own smooth random curve
-- over t (one channel per parameter), so moving t a little changes the
-- plant a little: that is the mutation animation. choices that cannot
-- change smoothly (plant kind, outline mode, number of colours, flower
-- shape) are taken at fixed positions and do not change with t.

local bushgen = require("bushgen")
local plants = require("data_plants")
local ranges = require("data_variety")

local variety = {}

local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min
local hashU = bushgen.hash

local byName = {}
for _, p in ipairs(plants) do
	byName[p.name] = p
end

-- random kinds for makePlant: the weighted list without the cube, which is
-- made by makeBlock; request picks from the full list
local PLANT_KINDS = {}
for _, e in ipairs(ranges.plant.kinds) do
	local p = byName[e.name]
	if p and p.kind ~= "block" then PLANT_KINDS[#PLANT_KINDS + 1] = e end
end

---------------------------------------------------------------- smooth noise

-- catmull-rom through random values at whole numbers of t: smooth curve,
-- no stops at the knots; each channel is shifted so knots do not line up
local function curve(seed, ch, t)
	t = t + hashU(seed, ch, 99991) * 7
	local i = floor(t)
	local f = t - i
	local p0 = hashU(seed, ch, i - 1)
	local p1 = hashU(seed, ch, i)
	local p2 = hashU(seed, ch, i + 1)
	local p3 = hashU(seed, ch, i + 2)
	local v = 0.5 * ((2 * p1) + (-p0 + p2) * f
		+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f
		+ (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f)
	return max(0, min(1, v))
end

-- continuous parameter in a range {a, b}
local function cont(seed, ch, t, range)
	return range[1] + (range[2] - range[1]) * curve(seed, ch, t)
end

-- parameter that is mostly 0; when on it grows from 0 smoothly
local function contChance(seed, ch, t, chance, range)
	local u = curve(seed, ch, t)
	local on = max(0, (u - (1 - chance)) / chance)
	return range[2] * on
end

-- fixed choice, independent of t
local function fixed(seed, ch)
	return hashU(seed, ch, 424242)
end

local function pickU(list, u)
	return list[min(#list, 1 + floor(u * #list))]
end

local function pickWeightedU(list, u)
	local total = 0
	for _, e in ipairs(list) do total = total + e.weight end
	local v = u * total
	for _, e in ipairs(list) do
		v = v - e.weight
		if v <= 0 and e.weight > 0 then return e end
	end
	for k = #list, 1, -1 do
		if list[k].weight > 0 then return list[k] end
	end
	return list[#list]
end

local function intU(range, u)
	return min(range[2], range[1] + floor(u * (range[2] - range[1] + 1)))
end

-- moves hue a toward hue b along the shorter way round, f in 0..1;
-- the result is not wrapped, so a ramp from it interpolates correctly
local function lerpHue(a, b, f)
	local d = ((b - a + 540) % 360) - 180
	return a + d * f
end

local function copy(t)
	local q = {}
	for k, v in pairs(t) do q[k] = v end
	return q
end

local function scalePair(t, f, lo)
	lo = lo or 0
	return {max(lo, t[1] * f), max(lo, t[2] * f)}
end

---------------------------------------------------------------- style

local STYLE_FIELDS = {
	"palette", "outlineMode", "shadow", "crease", "gap", "fringe", "texture",
	"textureStep", "edgeTips", "noise", "contrast", "fold", "toneMix",
	"toneLight", "bodyMix", "clumpSquash", "spot", "snow",
}

function variety.makeStyle(seed, t)
	t = t or 0
	local s = ranges.style
	local st = {seed = seed}
	local group = pickWeightedU(s.hues, fixed(seed, 1))
	local hc = cont(seed, 2, t, group.h)
	st.palette = {
		h0 = lerpHue(hc, s.coolHue, cont(seed, 3, t, s.coolShift)),
		h1 = lerpHue(hc, s.warmHue, cont(seed, 4, t, s.warmShift)),
		s0 = cont(seed, 5, t, s.satDark),
		s1 = cont(seed, 6, t, s.satLight),
		v0 = cont(seed, 7, t, s.valDark),
		v1 = cont(seed, 8, t, s.valLight),
		n = intU(s.colours, fixed(seed, 9)),
	}
	st.outlineMode = pickU(s.outlineModes, fixed(seed, 10))
	st.shadow = cont(seed, 11, t, s.shadow)
	st.crease = intU(s.crease, fixed(seed, 12))
	st.gap = intU(s.gap, fixed(seed, 13))
	st.fringe = cont(seed, 14, t, s.fringe)
	st.texture = contChance(seed, 15, t, s.textureChance, s.texture)
	st.textureStep = intU(s.textureStep, fixed(seed, 16))
	st.edgeTips = contChance(seed, 17, t, s.edgeTipsChance, s.edgeTips)
	st.noise = cont(seed, 18, t, s.noise)
	st.contrast = cont(seed, 19, t, s.contrast)
	st.fold = cont(seed, 20, t, s.fold)
	st.toneMix = cont(seed, 21, t, s.toneMix)
	st.toneLight = cont(seed, 22, t, s.toneLight)
	st.bodyMix = cont(seed, 23, t, s.bodyMix)
	st.clumpSquash = cont(seed, 24, t, s.clumpSquash)
	st.grain = cont(seed, 25, t, s.grain)
	local spot = contChance(seed, 26, t, s.spotChance, s.spot)
	if spot > 0 then st.spot = spot end
	if fixed(seed, 27) < s.ornamentChance then
		local col = pickU(s.ornamentColours, fixed(seed, 28))
		st.ornament = {
			h = col[1], s = col[2], v = col[3],
			shape = pickU(s.ornamentShapes, fixed(seed, 29)),
			count = cont(seed, 30, t, s.ornamentCount),
		}
	end
	if fixed(seed, 40) < (s.snowChance or 0) then
		st.snow = cont(seed, 41, t, s.snow)
	end
	st.bark = {
		h = cont(seed, 31, t, s.barkHue),
		s = cont(seed, 32, t, s.barkSat),
		v = cont(seed, 33, t, s.barkVal),
	}
	return st
end

---------------------------------------------------------------- plant

-- largest scale that keeps this kind inside the tile
local function scaleCap(q, pr)
	local cap = 10
	if q.kind == "hedge" then
		cap = min(cap, 14 / (q.length[2] / 2 + q.radius[2]))
	elseif q.kind == "bramble" then
		cap = min(cap, 13 / (2.3 * q.stemLength[2]))
	elseif q.kind == "twigs" then
		cap = min(cap, 26 / (2.9 * q.stemLength[2]))
	elseif q.kind == "clumps" then
		cap = min(cap, pr.maxRadius / (q.spread2[2] * 0.8 + q.radius[2]))
	elseif q.kind == "topiary" then
		cap = min(cap, 11 / q.radius[2])
	elseif q.kind == "leafball" then
		cap = min(cap, (pr.maxRadius - 2) / q.radius[2])
	elseif q.radius then
		cap = min(cap, pr.maxRadius / q.radius[2])
	end
	if q.leafLength then
		cap = min(cap, pr.maxLeaf / q.leafLength[2])
	end
	return cap
end

-- k: size factor of the design box against the base box of 32 pixels;
-- 2 makes a plant twice as large with the same leaf size, so more leaves
function variety.makePlant(st, seed, t, kind, k)
	t = t or 0
	k = k or 1
	local pr = ranges.plant
	local base = byName[kind or pickWeightedU(PLANT_KINDS, fixed(seed, 101)).name]
	assert(base and base.kind ~= "block", "unknown plant kind: " .. tostring(kind))
	local q = copy(base)
	for _, f in ipairs(STYLE_FIELDS) do
		if st[f] ~= nil then q[f] = st[f] end
	end
	q.bark = st.bark

	-- size: s is the random size inside the box, S also includes the box
	local s = min(cont(seed, 102, t, pr.scale), scaleCap(q, pr))
	local S = s * k
	local g = st.grain * cont(seed, 103, t, {0.85, 1.15})
	local cf = cont(seed, 104, t, pr.count)
	local area = S * S / (g * g)
	if q.radius then q.radius = scalePair(q.radius, S) end
	if q.length then q.length = scalePair(q.length, S) end
	if q.stemLength then q.stemLength = scalePair(q.stemLength, S) end
	if q.spread2 then q.spread2 = scalePair(q.spread2, S) end
	if q.bumpRadius then q.bumpRadius = scalePair(q.bumpRadius, S) end
	if type(q.lift) == "table" then q.lift = scalePair(q.lift, S) end
	if q.carpet then
		-- leaves of carpet kinds keep their pixel size: a larger plant
		-- simply has more of them
		-- a leaf below 3 pixels no longer reads as a leaf, only as noise
		q.leafLength = scalePair(base.leafLength, g * (0.8 + 0.2 * s), base.leafMin or 3.0)
		q.leafWidth = scalePair(base.leafWidth, sqrt(g), 1.8)
		q.texture = 0
		q.fringe = (q.fringe or 0) * 0.3
		q.noise = min(q.noise or 0.1, 0.12)
		q.fold = min(q.fold or 0.5, 0.6)
		q.toneMix = min(q.toneMix or 0.1, 0.15)
		q.contrast = min(q.contrast or 1, 1.25)
	else
		if q.leafLength then q.leafLength = scalePair(q.leafLength, S) end
		if q.leafWidth then q.leafWidth = scalePair(q.leafWidth, sqrt(S * g), 1.1) end
	end
	if q.clumpRadius then q.clumpRadius = scalePair(q.clumpRadius, sqrt(s) * g, 1.3) end
	if q.leafletLength then q.leafletLength = q.leafletLength * S end
	if q.leafletWidth then q.leafletWidth = max(1.1, q.leafletWidth * sqrt(g)) end

	-- counts (fractional, the generator grows the last part in smoothly)
	if q.clumps then q.clumps = scalePair(q.clumps, cf * area, 3) end
	if q.leaves then
		if q.kind == "leafy" then
			q.leaves = scalePair(q.leaves, cf * area, 8)
		else
			q.leaves = scalePair(q.leaves, cf, 4)
		end
	end
	if q.stems then q.stems = scalePair(q.stems, cf, 1) end
	if q.parts then q.parts = scalePair(q.parts, cf, 1) end

	-- proportions
	if q.squash and q.kind ~= "tiered" and q.kind ~= "twigs" then
		q.squash = min(1.05, max(0.6, cont(seed, 105, t, pr.squash)))
	end
	if q.kind == "blob" then
		local sw = contChance(seed, 106, t, pr.stretchChance, {0, pr.stretch[2] - 1})
		q.stretch = 1 + sw
		q.radius = scalePair(q.radius, 1 / q.stretch)
	end
	if q.kind == "rosette" then
		q.droop = (q.droop or 1) * cont(seed, 107, t, {0.3, 1.8})
		q.innerShrink = cont(seed, 108, t, {0.0, 0.5})
	end
	if q.kind == "tiered" then
		q.taper = cont(seed, 109, t, {0.35, 0.8})
		q.tierHeight = cont(seed, 110, t, {0.3, 0.55})
	end
	if q.kind == "bramble" then
		q.fan = cont(seed, 111, t, {0.9, 1.7})
		q.jointLeaves = cont(seed, 112, t, {0.2, 0.8})
	end
	if q.forms then
		q.form = pickU(q.forms, fixed(seed, 121))
	end
	if q.kind == "twigs" then
		q.fan = cont(seed, 117, t, {1.9, 2.5})
		q.tipLeaves = cont(seed, 118, t, {0.2, 0.8})
		q.outlineMode = "none"
	end

	-- flowers or berries
	if st.ornament and fixed(seed, 113) < pr.ornamentChance then
		local o = copy(st.ornament)
		o.count = max(2, o.count * s * k * k)
		o.spacing = 3 + intU({0, 2}, fixed(seed, 114))
		q.ornament = o
	end

	-- grass at the base
	if pr.underKinds[q.kind] and fixed(seed, 115) < pr.underChance then
		local u = copy(byName.grass)
		local us = cont(seed, 116, t, {0.45, 0.75}) * k
		u.leafLength = scalePair(u.leafLength, us)
		u.lift = scalePair(u.lift, us)
		u.leafWidth = scalePair(u.leafWidth, 0.8, 1.1)
		u.leaves = {6 * k, 10 * k}
		u.dep0 = 14 * k
		u.baseOffset = 4 * k
		u.baseSpread = (1.5 + 3 * s) * k
		u.salt = 50
		q.under = u
	end
	return q
end

---------------------------------------------------------------- block

-- fields of opts that are copied onto the block recipe as they are
local BLOCK_OPTS = {"shape", "tile", "depth", "height", "margin", "sharp", "cover", "round", "join"}

function variety.makeBlock(st, seed, t, opts)
	t = t or 0
	opts = opts or {}
	local q = copy(byName.cube)
	for _, f in ipairs(STYLE_FIELDS) do
		if st[f] ~= nil then q[f] = st[f] end
	end
	q.bark = st.bark
	-- grain of the style sets the leaf size, varying a little per cell
	local g = st.grain * cont(seed, 201, t, {0.85, 1.15})
	q.leafLength = scalePair(q.leafLength, g, 1.4)
	q.leafWidth = scalePair(q.leafWidth, sqrt(g), 0.9)
	q.cover = q.cover * cont(seed, 203, t, {0.9, 1.15})
	q.round = q.round * cont(seed, 202, t, {0.7, 1.3})
	for _, f in ipairs(BLOCK_OPTS) do
		if opts[f] ~= nil then q[f] = opts[f] end
	end
	-- trimmed: leaves lie flat and close, few stray tips, soft creases
	local wild = 1 - max(0, min(1, q.sharp))
	q.lift = q.lift * (0.6 + 0.9 * wild)
	q.tilt = q.tilt * (0.6 + 1.2 * wild)
	q.edgeTips = (st.edgeTips or 0) * 0.3 + 0.35 * wild
	q.fringe = (st.fringe or 0) * 0.3
	q.texture = 0
	q.crease = 1
	q.gap = 9
	-- keep the face tones readable: little noise, moderate contrast
	q.noise = min(st.noise or 0.1, 0.1)
	q.contrast = max(1.0, min(st.contrast or 1, 1.25))
	-- flowers or berries, as many as fit the faces
	if st.ornament and fixed(seed, 204) < ranges.plant.ornamentChance then
		local o = copy(st.ornament)
		local area = q.tile * (q.depth and (q.height + q.depth) or q.tile) / (32 * 32)
		o.count = max(2, o.count * area)
		o.spacing = 3 + intU({0, 2}, fixed(seed, 205))
		q.ornament = o
	end
	return q
end

---------------------------------------------------------------- request

-- one call for any plant, cubes included. o is a table, all fields optional:
--   style   style seed (number, follows t) or a table from makeStyle; 1
--   seed    plant seed; 1
--   t       time; 0
--   kind    name from data_plants.lua ("round", "leafball", "cube", ...);
--           random by the weights in data_variety.lua when left out
--   size    sprite size in pixels; 48. plants are built in a box of 2/3 of
--           it (box = 32 for 48), cubes fill size - 2 * margin
--   box     design box for plants, overrides the 2/3 rule
--   view    cube only: "square" (Factorio style orthogonal) or "iso"
--   tile, height, depth, margin, join, sharp, round, cover: cube options,
--           see makeBlock; tile and margin follow size when left out
--   snow    0..1, snow caps on top edges; default: what the style says
--   form    topiary only: "ball", "cone", "cylinder" or "lollipop"
-- returns the result of bushgen.generate {w, h, ax, ay, pixels} and the recipe
function variety.request(o)
	o = o or {}
	local size = o.size or 48
	local t = o.t or 0
	local seed = o.seed or 1
	local st = o.style or 1
	if type(st) == "number" then st = variety.makeStyle(st, t) end
	local kind = o.kind or pickWeightedU(ranges.plant.kinds, fixed(seed, 101)).name
	local base = byName[kind]
	assert(base, "unknown plant kind: " .. tostring(kind))
	if base.kind == "block" then
		local opts = copy(o)
		opts.shape = o.view or o.shape or "square"
		opts.margin = o.margin or max(2, floor(size / 6 + 0.5))
		opts.tile = o.tile or (size - 2 * opts.margin)
		opts.height = o.height or floor(opts.tile * (opts.shape == "iso" and 0.4 or 0.375) + 0.5)
		local q = variety.makeBlock(st, seed, t, opts)
		if o.snow ~= nil then q.snow = o.snow end
		return bushgen.generate(q, seed), q
	end
	local box = o.box or floor(size * 2 / 3 + 0.5)
	local q = variety.makePlant(st, seed, t, kind, box / 32)
	if o.snow ~= nil then q.snow = o.snow end
	if o.form ~= nil then q.form = o.form end
	return bushgen.generate(q, seed, size, size, box), q
end

return variety
