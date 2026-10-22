-- bushgen.lua
-- procedural pixel art bushes and plants
-- pure lua, no love dependency: returns a flat rgba array (values 0..1)
--
-- idea: every plant is built from simple 3d primitives (small spheres
-- and curved leaves) rasterized into a depth buffer. each pixel keeps a
-- shade value from a lambert light, the shade is then quantized into a
-- short colour ramp, and pixel-art rules (dark creases between parts,
-- selective outline, drop shadow) are applied on top.
--
-- stable randomness: every part (clump, leaf, stem) draws from its own
-- random stream, and per-pixel decisions use a hash of the pixel index.
-- so a small change of one parameter changes the picture only a little,
-- which makes smooth animation of parameters possible. counts are
-- fractional: the last part grows in from zero instead of popping in.

local bushgen = {}

local sqrt, floor, ceil, sin, cos, pi = math.sqrt, math.floor, math.ceil, math.sin, math.cos, math.pi
local max, min, abs = math.max, math.min, math.abs

-- light from top-left, slightly toward the viewer
local LX, LY, LZ = -0.55, -0.65, 0.55
do
	local l = sqrt(LX * LX + LY * LY + LZ * LZ)
	LX, LY, LZ = LX / l, LY / l, LZ / l
end

---------------------------------------------------------------- random

local M = 2147483647

-- park-miller, exact both in luajit doubles and lua 5.3+ integers
local function rngNew(seed)
	return {s = floor(seed) % (M - 1) + 1}
end

local function rnd(r)
	r.s = (r.s * 16807) % M
	return r.s / M
end

local function rrange(r, a, b)
	return a + (b - a) * rnd(r)
end

local function rint(r, a, b)
	return floor(a + (b - a + 1) * rnd(r))
end

-- exact (a * b) % M for a, b below 2^32 using doubles only: a is split
-- into 16 bit halves so no partial product exceeds 2^53
local function mulmod(a, b)
	local a1 = floor(a / 65536)
	local a0 = a - a1 * 65536
	return ((a1 * b) % M * 65536 + a0 * b) % M
end

-- hash of three integers to a number in 0..1; same inputs, same result.
-- squaring steps make it non-linear: a plain multiply would put hashed
-- points of consecutive inputs on straight lines
local function hashU(a, b, c)
	local h = (floor(a) % M + 1013904223) % M
	h = mulmod(h, h + 2654435)
	h = (h + floor(b) % M) % M
	h = mulmod(h + 7, h + 362437)
	h = (h + floor(c) % M) % M
	h = mulmod(h + 13, h + 521288629)
	h = mulmod(h, 16807)
	return h / M
end

-- independent random stream for part k of a plant
local function stream(seed, k)
	local r = rngNew(hashU(seed, k, 911) * (M - 2))
	rnd(r)
	rnd(r)
	return r
end

-- 1 for whole parts, 0..1 for the last part of a fractional count
local function fade(n, k)
	return max(0, min(1, n - k + 1))
end

---------------------------------------------------------------- colour

local function hsv(h, s, v)
	h = (h % 360) / 60
	local i = floor(h)
	local f = h - i
	local p = v * (1 - s)
	local q = v * (1 - s * f)
	local t = v * (1 - s * (1 - f))
	if i == 0 then return v, t, p
	elseif i == 1 then return q, v, p
	elseif i == 2 then return p, v, t
	elseif i == 3 then return p, q, v
	elseif i == 4 then return t, p, v
	end
	return v, p, q
end

-- hue-shifted ramp: shadows go cooler (bluer), lights go warmer (yellower)
local function makeRamp(pal, r)
	local dh = rrange(r, -7, 7)
	local ds = rrange(r, -0.05, 0.05)
	local ramp = {}
	for k = 0, pal.n - 1 do
		local t = k / (pal.n - 1)
		local h = pal.h0 + (pal.h1 - pal.h0) * t + dh
		local s = min(1, max(0, pal.s0 + (pal.s1 - pal.s0) * t + ds))
		local v = min(1, max(0, pal.v0 + (pal.v1 - pal.v0) * t))
		local cr, cg, cb = hsv(h, s, v)
		ramp[k + 1] = {cr, cg, cb}
	end
	local or_, og, ob = hsv(pal.h0 + 8 + dh, min(1, pal.s0 + 0.1), pal.v0 * 0.5)
	return ramp, {or_, og, ob}
end

---------------------------------------------------------------- canvas

-- w, h: design box the plant kinds are built in (about 32 x 32)
-- W, H: real sprite canvas, larger, so parts that reach out of the box
-- (leaf tips, outline, shadow) are not cut; the box sits in its middle
local function canvasNew(w, h, W, H, seed)
	local c = {w = w, h = h, W = W, H = H, depth = {}, shade = {}, id = {}, tone = {}, seed = seed}
	c.ox = floor((W - w) / 2)
	c.oy = floor((H - h) / 2)
	for i = 1, W * H do
		c.depth[i] = -1e9
		c.shade[i] = 0
		c.id[i] = 0
		c.tone[i] = 0
	end
	c.nextId = 1
	c.bark = {}
	return c
end

-- x, y in design box pixels
local function plot(c, x, y, d, sh, id, tone)
	x = x + c.ox
	y = y + c.oy
	if x < 0 or y < 0 or x >= c.W or y >= c.H then return end
	local i = y * c.W + x + 1
	if d > c.depth[i] then
		c.depth[i] = d
		c.shade[i] = sh
		c.id[i] = id
		c.tone[i] = tone
	end
end

-- half lambert, keeps the dark side readable
local function light(nx, ny, nz)
	local l = sqrt(nx * nx + ny * ny + nz * nz)
	if l < 1e-6 then return 0.5 end
	return 0.5 + 0.5 * (nx * LX + ny * LY + nz * LZ) / l
end

-- normal of the whole bush volume at a screen point (for blending)
local function bodyNormal(body, px, py)
	local bx = (px - body.cx) / body.r
	local by = (py - body.cy) / (body.r * body.sq)
	local d2 = min(1, bx * bx + by * by)
	return bx, by, sqrt(1 - d2)
end

---------------------------------------------------------------- spheres

-- s = {cx, cy, cz, r, sq, tone, fn, occ}; body is optional (bush volume
-- to blend with); fn is an optional fixed normal {x, y, z} (a face of a
-- block) blended in with mixBody, occ an extra darkening factor
local function drawSphere(c, s, body, mixBody)
	if s.r < 0.3 then return end
	local id = c.nextId
	c.nextId = id + 1
	local ry = s.r * s.sq
	local x0, x1 = floor(s.cx - s.r), floor(s.cx + s.r)
	local y0, y1 = floor(s.cy - ry), floor(s.cy + ry)
	for y = y0, y1 do
		for x = x0, x1 do
			local px, py = x + 0.5, y + 0.5
			local dx = (px - s.cx) / s.r
			local dy = (py - s.cy) / ry
			local d2 = dx * dx + dy * dy
			if d2 < 1 then
				local nz = sqrt(1 - d2)
				local nx, ny = dx, dy
				local occ = s.occ or 1
				if s.fn then
					local m = mixBody
					nx = nx * (1 - m) + s.fn[1] * m
					ny = ny * (1 - m) + s.fn[2] * m
					nz = nz * (1 - m) + s.fn[3] * m
				end
				if body then
					local bx, by, bz = bodyNormal(body, px, py)
					local m = mixBody
					nx = nx * (1 - m) + bx * m
					ny = ny * (1 - m) + by * m
					nz = nz * (1 - m) + bz * m
					-- lower part of the bush is darker (ambient occlusion)
					occ = 1 - 0.25 * max(0, by)
				end
				local sh = light(nx, ny, nz) * occ
				plot(c, x, y, s.cz + nz * s.r, sh, id, s.tone)
			end
		end
	end
end

---------------------------------------------------------------- leaves

local LEAF_SEGS = 12

-- width profile along the leaf, u in 0..1
local function leafProfile(lf, u)
	local w
	if lf.blade then
		w = (1 - u) ^ 0.8
	else
		w = sin(pi * (u ^ 0.7)) ^ 0.8
	end
	if lf.serration > 0 then
		local f = (u * lf.teeth) % 1
		w = w * (1 - lf.serration * f)
	end
	return w * lf.width
end

-- builds the midrib polyline in screen space
local function leafSpine(lf)
	local sx, sy, dep, sz = {}, {}, {}, {}
	local ca, sa = cos(lf.a), sin(lf.a)
	for k = 0, LEAF_SEGS do
		local u = k / LEAF_SEGS
		local gx = ca * lf.len * u
		local gy = sa * lf.len * u * lf.fy
		local z = lf.lift * sin(pi * u * lf.arc)
		-- tip droops a little
		z = z - lf.droop * u * u
		sx[k] = lf.x + gx
		sy[k] = lf.y + gy - z
		dep[k] = lf.dep0 + sa * lf.len * u * lf.depDir + z
		sz[k] = z
	end
	return sx, sy, dep, sz
end

-- lf: x, y, a, len, width, lift, arc, droop, fy, dep0, depDir, fold,
--     serration, teeth, blade, tone, spot, id; body optional
local function drawLeaf(c, lf, body, mixBody)
	if lf.len < 0.5 or lf.width < 0.3 then return end
	-- leaves can share an id (a fern frond with its leaflets), then no
	-- dark crease is drawn between them
	local id = lf.id
	if not id then
		id = c.nextId
		c.nextId = id + 1
	end
	local sx, sy, dep, sz = leafSpine(lf)
	local bx0, bx1, by0, by1 = 1e9, -1e9, 1e9, -1e9
	for k = 0, LEAF_SEGS do
		bx0 = min(bx0, sx[k]); bx1 = max(bx1, sx[k])
		by0 = min(by0, sy[k]); by1 = max(by1, sy[k])
	end
	local pad = lf.width + 1
	-- box of every segment grown by the leaf width: a pixel outside a box
	-- is too far from that segment to be inside the leaf, skip it quickly
	local sbx0, sbx1, sby0, sby1 = {}, {}, {}, {}
	for k = 0, LEAF_SEGS - 1 do
		sbx0[k] = min(sx[k], sx[k + 1]) - lf.width
		sbx1[k] = max(sx[k], sx[k + 1]) + lf.width
		sby0[k] = min(sy[k], sy[k + 1]) - lf.width
		sby1[k] = max(sy[k], sy[k + 1]) + lf.width
	end
	for y = floor(by0 - pad), floor(by1 + pad) do
		for x = floor(bx0 - pad), floor(bx1 + pad) do
			local px, py = x + 0.5, y + 0.5
			local best, bu, bside, bk, bt = 1e9, 0, 0, 0, 0
			for k = 0, LEAF_SEGS - 1 do
				if px >= sbx0[k] and px <= sbx1[k] and py >= sby0[k] and py <= sby1[k] then
				local ax, ay = sx[k], sy[k]
				local ex, ey = sx[k + 1] - ax, sy[k + 1] - ay
				local ll = ex * ex + ey * ey
				local t = 0
				if ll > 1e-9 then
					t = ((px - ax) * ex + (py - ay) * ey) / ll
					t = max(0, min(1, t))
				end
				local qx, qy = ax + ex * t - px, ay + ey * t - py
				local d = qx * qx + qy * qy
				if d < best then
					best = d
					bu = (k + t) / LEAF_SEGS
					bside = ex * (py - ay) - ey * (px - ax)
					bk, bt = k, t
				end
				end
			end
			local dist = sqrt(best)
			local w = leafProfile(lf, bu)
			if dist < w and bu > 0.0 and bu < 1.0 then
				-- local frame of the leaf
				local ex, ey = sx[bk + 1] - sx[bk], sy[bk + 1] - sy[bk]
				local el = sqrt(ex * ex + ey * ey)
				if el < 1e-6 then el = 1; ex = 1; ey = 0 end
				ex, ey = ex / el, ey / el
				local side = bside >= 0 and 1 or -1
				local across = dist / max(w, 0.01)
				-- leaf surface is a shallow ridge: each half tilts sideways
				local px2, py2 = -ey * side, ex * side
				local slope = (sz[bk + 1] - sz[bk]) * LEAF_SEGS / max(lf.len, 1)
				local nx = px2 * lf.fold * (0.4 + across) - ex * slope * 0.35
				local ny = py2 * lf.fold * (0.4 + across) - ey * slope * 0.35
				local nz = 0.8
				if body then
					local qx, qy, qz = bodyNormal(body, px, py)
					nx = nx * (1 - mixBody) + qx * mixBody
					ny = ny * (1 - mixBody) + qy * mixBody
					nz = nz * (1 - mixBody) + qz * mixBody
				end
				local sh = light(nx, ny, nz)
				-- base of the leaf sits in the shade of the plant
				sh = sh * (0.55 + 0.45 * min(1, bu * 2.2))
				-- higher parts catch more light
				if lf.lift > 0 then
					sh = sh + 0.08 * (sz[bk] / lf.lift)
				end
				-- midrib highlight
				if dist < 0.55 and bu > 0.12 and bu < 0.85 and not lf.blade then
					sh = sh + 0.14
				end
				-- glossy spot on the lit half of broad leaves
				if lf.spot and abs(bu - 0.4) < 0.12 and across > 0.2 and across < 0.7
					and px2 * LX + py2 * LY > 0 then
					sh = sh + lf.spot
				end
				local d = dep[bk] + (dep[bk + 1] - dep[bk]) * bt
				plot(c, x, y, d, sh, id, lf.tone)
			end
		end
	end
end

---------------------------------------------------------------- edge tips

-- grows 1-2 px leaf tips out of the silhouette, mostly on top and sides,
-- so the outline reads as leaves instead of a smooth curve
local TIP_DIRS = {{0, -1, 1.0}, {-1, 0, 0.6}, {1, 0, 0.6}, {0, 1, 0.15}}

local function edgeTips(c, chance)
	local w, h = c.W, c.H
	local src = {}
	for i = 1, w * h do src[i] = c.id[i] end
	for y = 1, h - 2 do
		for x = 1, w - 2 do
			local i = y * w + x + 1
			if src[i] ~= 0 then
				for di, d in ipairs(TIP_DIRS) do
					local qx, qy = x + d[1], y + d[2]
					local j = qy * w + qx + 1
					if src[j] == 0 and hashU(c.seed, j * 4 + di, 31) < chance * d[3] then
						c.id[j] = c.id[i]
						c.depth[j] = c.depth[i] - 0.5
						c.shade[j] = c.shade[i] + 0.04
						c.tone[j] = c.tone[i]
						local kx, ky = qx + d[1], qy + d[2]
						if kx >= 1 and ky >= 1 and kx < w - 1 and ky < h - 1 and hashU(c.seed, j, 37) < 0.3 then
							local k = ky * w + kx + 1
							if src[k] == 0 and c.id[k] == 0 then
								c.id[k] = c.id[i]
								c.depth[k] = c.depth[i] - 1
								c.shade[k] = c.shade[i]
								c.tone[k] = c.tone[i]
							end
						end
					end
				end
			end
		end
	end
end

---------------------------------------------------------------- branches

-- marks a thin branch line; it is only shown later where foliage is dark
local function markBranch(c, x0, y0, x1, y1)
	local steps = max(abs(x1 - x0), abs(y1 - y0))
	steps = max(1, floor(steps + 0.5))
	for k = 0, steps do
		local t = k / steps
		local x = floor(x0 + (x1 - x0) * t + 0.5) + c.ox
		local y = floor(y0 + (y1 - y0) * t + 0.5) + c.oy
		if x >= 0 and y >= 0 and x < c.W and y < c.H then
			c.bark[y * c.W + x + 1] = true
		end
	end
end

-- a few forked branches growing up from the base
local function growBranches(c, cx, base, spread, height, count)
	for k = 1, count do
		local e = stream(c.seed, 500 + k)
		local x0 = cx + rrange(e, -spread, spread)
		local x1 = x0 + rrange(e, -3, 3)
		local y1 = base - height * rrange(e, 0.5, 0.8)
		markBranch(c, x0, base, x1, y1)
		markBranch(c, x1, y1, x1 + rrange(e, -4, -1), y1 - rrange(e, 2, 4))
		markBranch(c, x1, y1, x1 + rrange(e, 1, 4), y1 - rrange(e, 2, 4))
	end
end

---------------------------------------------------------------- plant kinds

-- random tone of one part: mostly 0, sometimes one step darker or lighter
local function partTone(r, p)
	local v = rnd(r)
	if v < (p.toneMix or 0.12) then return -1 end
	if v > 1 - (p.toneLight or 0) then return 1 end
	return 0
end

-- p.stretch > 1 makes the body wider than tall
-- salt keeps the clump streams of different blobs of one plant apart
local function makeBlob(c, p, cx, cy, R, zbase, nClumps, salt)
	local sq = p.squash
	local st = max(1, p.stretch or 1)
	local body = {cx = cx, cy = cy, r = R * st, sq = sq / st}
	-- core fills the gaps between clumps; three cores spread with stretch
	for k = -1, 1 do
		drawSphere(c, {cx = cx + k * R * (st - 1), cy = cy, cz = zbase, r = R * 0.9, sq = sq, tone = 0}, body, 0.5)
	end
	for k = 1, ceil(nClumps) do
		local e = stream(c.seed, salt * 1000 + k)
		local lr = rrange(e, p.clumpRadius[1], p.clumpRadius[2]) * fade(nClumps, k)
		local ang = rrange(e, 0, 2 * pi)
		local rad = (R - lr * 0.55) * sqrt(rnd(e))
		local tone = partTone(e, p)
		local px = cx + cos(ang) * rad * st
		local py = cy + sin(ang) * rad * sq
		local zs = sqrt(max(0, R * R - rad * rad))
		drawSphere(c, {
			cx = px, cy = py, cz = zbase + zs - lr * 0.7,
			r = lr, sq = p.clumpSquash or 0.9, tone = tone,
		}, body, p.bodyMix or 0.3)
	end
end

local function genBlob(c, r, p)
	local R = rrange(r, p.radius[1], p.radius[2])
	local cx = c.w / 2 + rrange(r, -0.5, 0.5)
	local cy = c.h / 2 + 1
	makeBlob(c, p, cx, cy, R, 0, rrange(r, p.clumps[1], p.clumps[2]), 1)
end

-- one big sphere; foliage look comes from the fringe pass
local function genSphere(c, r, p)
	local R = rrange(r, p.radius[1], p.radius[2])
	local n = rrange(r, p.clumps[1], p.clumps[2])
	local cx, cy = c.w / 2, c.h / 2 + 1
	drawSphere(c, {cx = cx, cy = cy, cz = 0, r = R, sq = p.squash, tone = 0}, nil, 0)
	-- a few soft bumps break the perfect circle
	local body = {cx = cx, cy = cy, r = R, sq = p.squash}
	for k = 1, ceil(n) do
		local e = stream(c.seed, 2000 + k)
		local ang = rrange(e, pi * 0.9, pi * 2.1)
		local lr = rrange(e, p.clumpRadius[1], p.clumpRadius[2]) * fade(n, k)
		local rad = R - lr * 0.8
		drawSphere(c, {
			cx = cx + cos(ang) * rad, cy = cy + sin(ang) * rad * p.squash,
			cz = lr * 0.2, r = lr, sq = 0.9, tone = 0,
		}, body, 0.85)
	end
end

local function genCluster(c, r, p)
	local n = rrange(r, p.parts[1], p.parts[2])
	local cx0, cy0 = c.w / 2, c.h / 2 + 1
	-- parts overlap: distance from the centre follows their size
	local spread = (p.radius[1] + p.radius[2]) * 0.4
	for k = 1, ceil(n) do
		local e = stream(c.seed, 3000 + k)
		local R = rrange(e, p.radius[1], p.radius[2]) * fade(n, k)
		local jit = rrange(e, -0.5, 0.5)
		local dd = rrange(e, 0.6, 1.0)
		local nc = rrange(e, p.clumps[1], p.clumps[2])
		local ang = (k / max(1, n)) * 2 * pi + jit
		-- a single part sits in the middle, more parts spread out
		local d = spread * min(1, max(0, n - 1)) * dd
		local cx = cx0 + cos(ang) * d
		local cy = cy0 + sin(ang) * d * 0.6
		-- keep inside the tile
		cx = max(R + 2, min(c.w - R - 2, cx))
		cy = max(R * p.squash + 2, min(c.h - R * p.squash - 3, cy))
		-- parts lower on screen are closer to the viewer
		if R > 0.5 then
			makeBlob(c, p, cx, cy, R, (cy - cy0) * 1.5, nc, 10 + k)
		end
	end
end

local function genLeafy(c, r, p)
	local R = rrange(r, p.radius[1], p.radius[2])
	local n = rrange(r, p.leaves[1], p.leaves[2])
	local cx, cy = c.w / 2, c.h / 2 + 1
	local sq = p.squash
	local body = {cx = cx, cy = cy, r = R, sq = sq}
	drawSphere(c, {cx = cx, cy = cy, cz = 0, r = R * 0.85, sq = sq, tone = -1}, body, 0.5)
	for k = 1, ceil(n) do
		local e = stream(c.seed, 4000 + k)
		local f = fade(n, k)
		local ang = rrange(e, 0, 2 * pi)
		local rad = R * 0.75 * sqrt(rnd(e))
		local jitter = rrange(e, -0.7, 0.7)
		local free = rrange(e, 0, 2 * pi)
		local len = rrange(e, p.leafLength[1], p.leafLength[2]) * f
		local width = rrange(e, p.leafWidth[1], p.leafWidth[2]) * f
		local tone = partTone(e, p)
		local bx = cx + cos(ang) * rad
		local by = cy + sin(ang) * rad * sq
		local zs = sqrt(max(0, R * R - rad * rad))
		-- leaves point outward from the bush centre, with some jitter;
		-- near the centre the direction blends into a free one
		local cw = min(1, rad / (R * 0.2))
		local out = (ang + jitter) * cw + free * (1 - cw)
		drawLeaf(c, {
			x = bx, y = by, a = out, len = len, width = width,
			lift = 0.5, arc = 1, droop = 0.8, fy = sq,
			dep0 = zs, depDir = 0.3,
			serration = 0, teeth = 1, blade = false, fold = p.fold or 0.45,
			tone = tone, spot = p.spot,
		}, body, 0.4)
	end
end

local function genRosette(c, r, p)
	local cx, cy = c.w / 2, c.h / 2 + 2
	local n = rrange(r, p.leaves[1], p.leaves[2])
	local golden = pi * (3 - sqrt(5))
	local a0 = rrange(r, 0, 2 * pi)
	for k = 1, ceil(n) do
		local e = stream(c.seed, 5000 + k)
		-- golden angle spread, inner leaves shorter and more upright
		local inner = (k - 1) / max(1, n - 1)
		local f = fade(n, k)
		local a = a0 + k * golden + rrange(e, -0.25, 0.25)
		local len = rrange(e, p.leafLength[1], p.leafLength[2]) * (1 - (p.innerShrink or 0.35) * inner) * f
		drawLeaf(c, {
			x = cx + rrange(e, -0.6, 0.6), y = cy + rrange(e, -0.6, 0.6),
			a = a, len = len,
			width = rrange(e, p.leafWidth[1], p.leafWidth[2]) * (0.4 + 0.6 * f),
			lift = rrange(e, p.lift[1], p.lift[2]) * (1 + 0.6 * inner),
			arc = rrange(e, p.arc[1], p.arc[2]),
			droop = p.droop or 1.0, fy = p.foreshorten,
			dep0 = inner * 2, depDir = 1,
			serration = p.serration or 0, teeth = p.teeth or 1,
			blade = false, tone = partTone(e, p), fold = p.fold or 0.45, spot = p.spot,
		}, nil, 0)
	end
end

-- fern: each frond is a thin stem with small leaflets on both sides
local function genFern(c, r, p)
	local cx, cy = c.w / 2, c.h / 2 + 2
	local n = rrange(r, p.leaves[1], p.leaves[2])
	local golden = pi * (3 - sqrt(5))
	local a0 = rrange(r, 0, 2 * pi)
	for k = 1, ceil(n) do
		local e = stream(c.seed, 6000 + k)
		local inner = (k - 1) / max(1, n - 1)
		local fid = c.nextId
		c.nextId = fid + 1
		local frond = {
			id = fid, x = cx, y = cy,
			a = a0 + k * golden + rrange(e, -0.2, 0.2),
			len = rrange(e, p.leafLength[1], p.leafLength[2]) * (1 - 0.3 * inner) * fade(n, k),
			width = 0.7,
			lift = rrange(e, p.lift[1], p.lift[2]),
			arc = 1, droop = 1.5, fy = p.foreshorten,
			dep0 = inner * 3, depDir = 1,
			serration = 0, teeth = 1, blade = true, tone = -1, fold = 0.45,
		}
		drawLeaf(c, frond, nil, 0)
		local sx, sy, dep = leafSpine(frond)
		local steps = frond.len / 2.2
		for j = 1, ceil(steps) do
			local u = 0.12 + 0.85 * j / max(1, steps)
			if u < 0.98 then
				local fk = u * LEAF_SEGS
				local kk = min(LEAF_SEGS - 1, floor(fk))
				local t = fk - kk
				local bx = sx[kk] + (sx[kk + 1] - sx[kk]) * t
				local by = sy[kk] + (sy[kk + 1] - sy[kk]) * t
				local bd = dep[kk] + (dep[kk + 1] - dep[kk]) * t
				local ll = (p.leafletLength * (1 - u) ^ 0.6 + 1.2) * fade(steps, j)
				for side = -1, 1, 2 do
					drawLeaf(c, {
						id = fid, x = bx, y = by, a = frond.a + side * 1.05,
						len = ll, width = p.leafletWidth,
						lift = 0.3, arc = 1, droop = 0.4, fy = p.foreshorten,
						dep0 = bd + 0.2, depDir = 0.2,
						serration = 0, teeth = 1, blade = false, tone = 0, fold = p.fold or 0.45,
					}, nil, 0)
				end
			end
		end
	end
end

-- hedge: wide low body made of clumps along a line, with branches
local function genHedge(c, r, p)
	local cx, cy = c.w / 2, c.h / 2 + 2
	local halfLen = rrange(r, p.length[1], p.length[2]) / 2
	local R = rrange(r, p.radius[1], p.radius[2])
	local n = rrange(r, p.clumps[1], p.clumps[2])
	local sq = p.squash
	local body = {cx = cx, cy = cy, r = halfLen + R * 0.5, sq = sq * R / (halfLen + R * 0.5)}
	for k = 0, 4 do
		local t = k / 4
		drawSphere(c, {cx = cx - halfLen + 2 * halfLen * t, cy = cy, cz = 0, r = R * 0.9, sq = sq, tone = 0}, body, 0.4)
	end
	for k = 1, ceil(n) do
		local e = stream(c.seed, 7000 + k)
		local lr = rrange(e, p.clumpRadius[1], p.clumpRadius[2]) * fade(n, k)
		local px = cx + rrange(e, -halfLen, halfLen)
		local ang = rrange(e, 0, 2 * pi)
		local rad = (R - lr * 0.55) * sqrt(rnd(e))
		local tone = partTone(e, p)
		local py = cy + sin(ang) * rad * sq
		px = px + cos(ang) * rad * 0.5
		local zs = sqrt(max(0, R * R - rad * rad))
		drawSphere(c, {
			cx = px, cy = py, cz = zs - lr * 0.7,
			r = lr, sq = p.clumpSquash or 0.9, tone = tone,
		}, body, p.bodyMix or 0.3)
	end
	growBranches(c, cx, cy + R * sq - 1, halfLen * 0.7, R * sq * 1.6, 2 + floor(hashU(c.seed, 1, 41) * 2))
end

local function genTuft(c, r, p)
	local cx, cy = c.w / 2, c.h - (p.baseOffset or 8)
	local n = rrange(r, p.leaves[1], p.leaves[2])
	local spread = p.baseSpread or 2.5
	for k = 1, ceil(n) do
		local e = stream(c.seed, 8000 + k + (p.salt or 0))
		local f = fade(n, k)
		local a = rrange(e, 0, 2 * pi)
		local off = rrange(e, 0, spread)
		drawLeaf(c, {
			x = cx + cos(a) * off, y = cy + sin(a) * off * 0.5,
			a = a + rrange(e, -0.3, 0.3),
			len = rrange(e, p.leafLength[1], p.leafLength[2]) * f,
			width = rrange(e, p.leafWidth[1], p.leafWidth[2]),
			lift = rrange(e, p.lift[1], p.lift[2]) * f,
			arc = rrange(e, p.arc[1], p.arc[2]),
			droop = rrange(e, 0, 3), fy = p.foreshorten,
			dep0 = p.dep0 or 0, depDir = 1,
			serration = 0, teeth = 1, blade = true, fold = 0.45,
			tone = (k % 3 == 0) and -1 or 0,
		}, nil, 0)
	end
end

-- tiered: stacked flat layers, narrower toward the top, each upper
-- layer overhangs the one below and casts a dark band on it
local function genTiered(c, r, p)
	local T = rrange(r, p.tiers[1], p.tiers[2])
	local R0 = rrange(r, p.radius[1], p.radius[2])
	local jit = {}
	for k = 0, ceil(T) do jit[k] = rrange(r, -0.7, 0.7) end
	local cx = c.w / 2
	local bottom = c.h - 6
	local tierH = R0 * p.tierHeight
	local q = {
		squash = p.squash, clumpRadius = p.clumpRadius, toneMix = p.toneMix,
		toneLight = p.toneLight, clumpSquash = p.clumpSquash, bodyMix = p.bodyMix,
	}
	for k = 0, ceil(T) - 1 do
		local t = k / max(1, T - 1)
		local R = R0 * max(0.1, 1 - p.taper * t) * fade(T, k + 1)
		local cy = bottom - R0 * (1 - p.taper * min(1, t)) * p.squash - k * tierH
		local nc = max(3, p.clumps[1] * (1 - 0.5 * min(1, t)))
		if R > 0.5 then
			makeBlob(c, q, cx + jit[k], cy, R, k * 2.5, nc, 20 + k)
		end
	end
end

-- draws a visible stick into the canvas with the reserved bark id
local function drawStick(c, x0, y0, x1, y1, z, width)
	local steps = max(1, floor(max(abs(x1 - x0), abs(y1 - y0)) + 0.5))
	local lean = (x1 - x0) / max(1, steps)
	for k = 0, steps do
		local t = k / steps
		local x = floor(x0 + (x1 - x0) * t + 0.5)
		local y = floor(y0 + (y1 - y0) * t + 0.5)
		plot(c, x, y, z + 0.1, 0.35 - lean * 0.2, c.barkId, 0)
		if width > 1 then
			plot(c, x + 1, y, z, 0.25, c.barkId, 0)
		end
	end
end

-- recursive fork: a branch splits in two until depth runs out,
-- leaf clumps sit on the tips and some joints; every node draws the same
-- amount of random numbers, so parameter changes keep the shape stable
local function growTwig(c, e, p, x, y, ang, len, depth, z)
	local x1 = x + cos(ang) * len
	local y1 = y + sin(ang) * len
	local lr = rrange(e, p.clumpRadius[1], p.clumpRadius[2])
	local jv = rnd(e)
	local tone = partTone(e, p)
	drawStick(c, x, y, x1, y1, z, depth >= 3 and 2 or 1)
	if depth <= 1 then
		drawSphere(c, {cx = x1, cy = y1, cz = z + lr, r = lr, sq = 0.85, tone = tone}, nil, 0)
		return
	end
	-- joint leaves grow in smoothly as jointLeaves rises past jv
	local jl = max(0, min(1, (p.jointLeaves - jv) * 5)) * lr * 0.8
	drawSphere(c, {cx = x1, cy = y1, cz = z + jl + 1, r = jl, sq = 0.85, tone = tone}, nil, 0)
	local spread = rrange(e, 0.35, 0.75)
	local shrink = rrange(e, 0.62, 0.8)
	local z1 = rrange(e, -1, 2)
	local z2 = rrange(e, -1, 2)
	growTwig(c, e, p, x1, y1, ang - spread, len * shrink, depth - 1, z + z1)
	growTwig(c, e, p, x1, y1, ang + spread, len * shrink, depth - 1, z + z2)
end

-- bramble: open bush of visible branches with leaf clumps on the ends
local function genBramble(c, r, p)
	c.barkId = c.nextId
	c.nextId = c.nextId + 1
	local cx, base = c.w / 2, c.h - 5
	local n = rrange(r, p.stems[1], p.stems[2])
	for k = 1, ceil(n) do
		local e = stream(c.seed, 9000 + k)
		local t = n > 1 and (k - 1) / (n - 1) or 0.5
		local ang = -pi / 2 + (min(1, t) - 0.5) * p.fan + rrange(e, -0.15, 0.15)
		local x0 = cx + rrange(e, -2, 2)
		local len = rrange(e, p.stemLength[1], p.stemLength[2]) * fade(n, k)
		local z0 = rrange(e, 0, 2)
		if len > 0.5 then
			growTwig(c, e, p, x0, base, ang, len, p.depth, z0)
		end
	end
end

---------------------------------------------------------------- blocks

-- trimmed hedge blocks that fill one map cell, for tile based games
-- square: orthogonal 3/4 view; screen x = x, screen y = y - z
-- iso:    2:1 pixel isometric; screen x = x - y, screen y = (x + y) / 2 - z
-- world x, y lie on the ground, z goes up; the anchor (c.ax, c.ay) is the
-- screen point of the cell centre on the ground
-- map directions: e = +x (next column), w = -x, s = +y (next row), n = -y
-- p.join = {n, e, s, w} marks neighbour blocks: the hedge then grows a
-- little across that edge and draws no outline there, so walls are seamless

---------------------------------------------------------------- bare twigs

-- one twig node; every node draws the same amount of random numbers, so
-- the shape stays stable when parameters change. the tips may carry a
-- small bunch of leftover leaves.
-- thick: width of this branch in pixels (only main stems are thick)
local function growBareTwig(c, e, p, x, y, ang, len, depth, z, thick)
	local spread = rrange(e, 0.18, 0.45)
	local shrink = rrange(e, 0.66, 0.84)
	local z1, z2 = rrange(e, -1, 2), rrange(e, -1, 2)
	local lr = rrange(e, 0.9, 1.7)
	local lv = rnd(e)
	local tone = partTone(e, p)
	local bend = rrange(e, -0.15, 0.15)
	-- the bush is a dome a little lower than wide
	local x1 = x + cos(ang) * len
	local y1 = y + sin(ang) * len * (p.squash or 0.85)
	drawStick(c, x, y, x1, y1, z, thick)
	if depth <= 1 then
		if lv < (p.tipLeaves or 0.5) then
			drawSphere(c, {cx = x1, cy = y1, cz = z + 1.5, r = lr, sq = 0.9, tone = tone}, nil, 0)
		end
		return
	end
	growBareTwig(c, e, p, x1, y1, ang - spread + bend, len * shrink, depth - 1, z + z1, 1)
	growBareTwig(c, e, p, x1, y1, ang + spread + bend, len * shrink, depth - 1, z + z2, 1)
end

-- twigs: a winter bush of thin bare branches fanning up from the base
local function genTwigs(c, r, p)
	c.barkId = c.nextId
	c.nextId = c.nextId + 1
	local cx, base = c.w / 2, c.h - 4
	local n = rrange(r, p.stems[1], p.stems[2])
	for k = 1, ceil(n) do
		local e = stream(c.seed, 42000 + k)
		local t = n > 1 and (k - 1) / (n - 1) or 0.5
		local ang = -pi / 2 + (min(1, t) - 0.5) * p.fan + rrange(e, -0.12, 0.12)
		local x0 = cx + rrange(e, -1.5, 1.5)
		local len = rrange(e, p.stemLength[1], p.stemLength[2]) * fade(n, k)
		local z0 = rrange(e, 0, 3)
		if len > 0.5 then
			-- the two middle stems are the thick trunk pieces
			local mid = abs(t - 0.5) < 0.2
			growBareTwig(c, e, p, x0, base, ang, len, p.depth, z0, mid and 2 or 1)
		end
	end
end

---------------------------------------------------------------- leaf bodies

-- leafball and clumps: dark inner spheres (the shade inside the bush) with
-- a carpet of separate small leaves on top. every leaf grows out of the
-- surface, pointing outward and a little down, so at the silhouette the
-- leaves stand out radially and the outline gets spiky like real foliage.
-- the view is the plain front view of the plants: x right, y down, z to
-- the viewer, light() works on these normals directly.

-- one leaf; h = {x, y, z, nx, ny, nz, occ, headShade} is the surface point
-- it grows from. headShade is the light of the round body at that point;
-- p.headLight mixes it into the leaf light, so the body keeps its form
-- (lit top-left, dark bottom-right) and the leaves only add texture
local function drawFrontLeaf(c, p, id, h, e, f)
	local L = rrange(e, p.leafLength[1], p.leafLength[2]) * f
	local W = rrange(e, p.leafWidth[1], p.leafWidth[2]) * f
	local turn = rrange(e, -1, 1) * (p.spread or 0.8)
	local liftR = rnd(e)
	local ts = rrange(e, -1, 1) * (p.tilt or 0.3)
	local tone = partTone(e, p)
	if L < 0.8 then return end
	local x, y, z, nx, ny, nz, occ = h[1], h[2], h[3], h[4], h[5], h[6], h[7]
	-- outward plus gravity, flattened into the surface plane
	local dx, dy, dz = nx, ny + (p.gravity or 0.3), 0
	local dn = dx * nx + dy * ny + dz * nz
	dx, dy, dz = dx - nx * dn, dy - ny * dn, dz - nz * dn
	local dl = sqrt(dx * dx + dy * dy + dz * dz)
	if dl < 0.05 then
		-- surface faces the viewer straight on: let the leaf hang down
		dx, dy, dz = 0, 1 - ny * ny, -ny * nz
		dl = sqrt(dx * dx + dy * dy + dz * dz)
		if dl < 0.05 then dx, dy, dz, dl = 1, 0, 0, 1 end
	end
	dx, dy, dz = dx / dl, dy / dl, dz / dl
	-- turn around the normal by a random angle
	local bx, by, bz = ny * dz - nz * dy, nz * dx - nx * dz, nx * dy - ny * dx
	local ct, st = cos(turn), sin(turn)
	dx, dy, dz = dx * ct + bx * st, dy * ct + by * st, dz * ct + bz * st
	-- raise the leaf out of the surface
	local raise = p.raise or 0.5
	dx, dy, dz = dx + nx * raise, dy + ny * raise, dz + nz * raise
	dl = sqrt(dx * dx + dy * dy + dz * dz)
	dx, dy, dz = dx / dl, dy / dl, dz / dl
	-- side of the leaf (in the surface plane) and the leaf normal
	local sx_, sy_, sz_ = ny * dz - nz * dy, nz * dx - nx * dz, nx * dy - ny * dx
	local sl = sqrt(sx_ * sx_ + sy_ * sy_ + sz_ * sz_)
	if sl < 1e-6 then return end
	sx_, sy_, sz_ = sx_ / sl, sy_ / sl, sz_ / sl
	local lnx, lny, lnz = dy * sz_ - dz * sy_, dz * sx_ - dx * sz_, dx * sy_ - dy * sx_
	if lnx * nx + lny * ny + lnz * nz < 0 then lnx, lny, lnz = -lnx, -lny, -lnz end
	lnx, lny, lnz = lnx + sx_ * ts, lny + sy_ * ts, lnz + sz_ * ts
	-- the leaf starts at the surface and reaches outward
	local lift = (p.lift or 0.6) * (0.4 + 0.6 * liftR)
	local cx = x + nx * lift + dx * L * 0.4
	local cy = y + ny * lift + dy * L * 0.4
	local cz = z + nz * lift + dz * L * 0.4
	local ux, uy, ud = dx * L / 2, dy * L / 2, dz * L / 2
	local vx, vy, vd = sx_ * W / 2, sy_ * W / 2, sz_ * W / 2
	local det = ux * vy - uy * vx
	if abs(det) < 0.15 then return end
	local fold = (p.fold or 0.5) * 0.45
	local tip = p.tipLight or 0.08
	local bright = occ * (0.82 + 0.18 * liftR)
	local hm = p.headLight or 0
	local head = (h[8] or 0.5) * hm
	local bw, bh = abs(ux) + abs(vx), abs(uy) + abs(vy)
	for yy = floor(cy - bh), floor(cy + bh) do
		for xx = floor(cx - bw), floor(cx + bw) do
			local rx, ry = xx + 0.5 - cx, yy + 0.5 - cy
			local la = (rx * vy - ry * vx) / det
			local lb = (ux * ry - uy * rx) / det
			-- full leaf: round at the base, pointed at the tip
			local wmax = sqrt(max(0, 1 - la * la)) * (1 - 0.35 * max(0, la))
			if abs(la) <= 1 and abs(lb) <= wmax then
				local hs = lb > 0 and fold or -fold
				local sh = (light(lnx + sx_ * hs, lny + sy_ * hs, lnz + sz_ * hs) * (1 - hm) + head) * bright + tip * la
				plot(c, xx, yy, cz + la * ud + lb * vd, sh, id, tone)
			end
		end
	end
end

-- leaves fall on random sprite points; the ones that land on the body
-- (hit, indexed by canvas pixel) grow there. the count depends only on the
-- sprite size, so it is stable in animation
local function carpetLeaves(c, p, hit)
	local la = (p.leafLength[1] + p.leafLength[2]) / 2
	local lw = (p.leafWidth[1] + p.leafWidth[2]) / 2
	local n = c.W * c.H * (p.cover or 1.4) / (pi * la * lw / 4)
	for k = 1, ceil(n) do
		local e = stream(c.seed, 30000 + k)
		local sx = floor(rnd(e) * c.W)
		local sy = floor(rnd(e) * c.H)
		local h = hit[sy * c.W + sx + 1]
		if h then
			local id = c.nextId
			c.nextId = id + 1
			drawFrontLeaf(c, p, id, h, e, fade(n, k))
		end
	end
end

-- spheres: list of {cx, cy, cz, r, sq}; sticks: list of {x0, y0, x1, y1, z, w}
local function leafBody(c, p, spheres, sticks)
	if #sticks > 0 then
		c.barkId = c.nextId
		c.nextId = c.nextId + 1
		for _, s in ipairs(sticks) do
			drawStick(c, s[1], s[2], s[3], s[4], s[5], s[6])
		end
	end
	-- vertical extent of the whole body, for darkening the lower part
	local top, bottom = 1e9, -1e9
	for _, s in ipairs(spheres) do
		top = min(top, s.cy - s.r * s.sq)
		bottom = max(bottom, s.cy + s.r * s.sq)
	end
	local mid = (top + bottom) / 2
	local half = max(1, (bottom - top) / 2)
	local inside = p.inside or 0.5
	local rim = p.rim or 0.25
	local hitZ, hit = {}, {}
	for _, s in ipairs(spheres) do
		if s.r > 0.5 then
			local id = c.nextId
			c.nextId = id + 1
			local ry = s.r * s.sq
			for y = floor(s.cy - ry), floor(s.cy + ry) do
				for x = floor(s.cx - s.r), floor(s.cx + s.r) do
					local px, py = x + 0.5, y + 0.5
					local ddx = (px - s.cx) / s.r
					local ddy = (py - s.cy) / ry
					local d2 = ddx * ddx + ddy * ddy
					if d2 < 1 then
						local nz = sqrt(1 - d2)
						local z = s.cz + nz * s.r
						-- lower part darker; each head also darkens toward its rim,
						-- so heads that meet are parted by a shaded seam
						local occ = (1 - 0.3 * max(0, min(1, (py - mid) / half))) * (1 - rim * (1 - nz))
						local hl = light(ddx, ddy, nz)
						plot(c, x, y, z, hl * inside * occ, id, 0)
						local i = (y + c.oy) * c.W + x + c.ox + 1
						if z > (hitZ[i] or -1e9) then
							hitZ[i] = z
							hit[i] = {px, py, z, ddx, ddy, nz, occ, hl}
						end
					end
				end
			end
		end
	end
	carpetLeaves(c, p, hit)
end

-- leafball: one round body of leaves with a few bumps in the silhouette
local function genLeafball(c, r, p)
	local R = rrange(r, p.radius[1], p.radius[2])
	local nb = rrange(r, p.bumps[1], p.bumps[2])
	local cx, cy = c.w / 2, c.h / 2 + 1
	local spheres = {{cx = cx, cy = cy, cz = 0, r = R, sq = p.squash}}
	for k = 1, ceil(nb) do
		local e = stream(c.seed, 40000 + k)
		local ang = rrange(e, pi * 0.85, pi * 2.15)
		local br = rrange(e, p.bumpRadius[1], p.bumpRadius[2]) * fade(nb, k)
		local rad = R - br * 0.6
		spheres[#spheres + 1] = {
			cx = cx + cos(ang) * rad, cy = cy + sin(ang) * rad * p.squash,
			cz = -br * 0.2, r = br, sq = 0.9,
		}
	end
	leafBody(c, p, spheres, {})
end

-- clumps: round heads of leaves piled like a mound: a lower row of larger
-- heads in front, an upper row of smaller ones behind. lower heads are
-- clearly closer, so where heads meet the front one covers the back one and
-- a dark seam parts them. branches run from the base to every head and
-- show in the gaps.
local function genClumps(c, r, p)
	local n = rrange(r, p.parts[1], p.parts[2])
	local spread = rrange(r, p.spread2[1], p.spread2[2])
	local Rm = (p.radius[1] + p.radius[2]) / 2
	local cx0, cy0 = c.w / 2, c.h / 2 + 1
	local nLow = ceil(ceil(n) / 2 + 0.01)
	local heads = {}
	local lowest = -1e9
	for k = 1, ceil(n) do
		local e = stream(c.seed, 41000 + k)
		local low = k <= nLow
		local row = low and nLow or max(1, ceil(n) - nLow)
		local idx = low and k or (k - nLow)
		local R = rrange(e, p.radius[1], p.radius[2]) * fade(n, k) * (low and 1 or 0.85)
		local jx, jy, jz = rrange(e, -1, 1), rrange(e, -1, 1), rrange(e, 0, 1)
		local bx = rrange(e, -2, 2)
		-- heads of a row spread evenly across the bush width
		local u = row > 1 and ((idx - 1) / (row - 1) - 0.5) or 0
		local x = cx0 + u * spread * (low and 1.6 or 1.2) + jx * Rm * 0.2
		local y = cy0 + (low and Rm * 0.45 or -Rm * 0.6) + jy * Rm * 0.15
		local z = (low and Rm * 1.6 or 0) + jz * Rm * 0.3
		heads[#heads + 1] = {x = x, y = y, z = z, r = R, bx = bx}
		lowest = max(lowest, y + R * 0.92)
	end
	-- the branches start a little above the lowest head bottom
	local base = lowest - 1
	local spheres, sticks = {}, {}
	for k, hd in ipairs(heads) do
		if hd.r > 0.5 then
			spheres[#spheres + 1] = {cx = hd.x, cy = hd.y, cz = hd.z, r = hd.r, sq = 0.92}
			sticks[#sticks + 1] = {cx0 + hd.bx, base, hd.x, hd.y, hd.z - hd.r * 0.3, k <= 2 and 2 or 1}
		end
	end
	leafBody(c, p, spheres, sticks)
end

---------------------------------------------------------------- topiary

-- trimmed garden shapes. the shape is a distance field in the world
-- (x right, y toward the viewer, z up, ground at z = 0), seen by an
-- orthographic camera tipped down by the angle VIEW_TILT, so a ball stays
-- round and the top of a cylinder shows as an ellipse. every pixel is
-- traced into the shape; the hit is turned into the front view of the
-- plants and gets the same leaf carpet as leafball.

local VIEW_TILT = 0.5
local TS, TC = sin(VIEW_TILT), cos(VIEW_TILT)

-- distance to the shape t = {form, r, h, ballZ, rr}
local function topiaryDist(t, x, y, z)
	if t.form == "cone" then
		-- capped cone: base radius r at z = 0, small top radius at z = h
		local q = sqrt(x * x + y * y)
		local hh = t.h / 2
		local zz = z - hh
		local r1, r2 = t.r, t.r * 0.08
		local cax = q - min(q, zz < 0 and r1 or r2)
		local cay = abs(zz) - hh
		local k2x, k2y = r2 - r1, 2 * hh
		local f = ((r2 - q) * k2x + (hh - zz) * k2y) / (k2x * k2x + k2y * k2y)
		f = max(0, min(1, f))
		local cbx = q - r2 + k2x * f
		local cby = zz - hh + k2y * f
		local sgn = (cbx < 0 and cay < 0) and -1 or 1
		return sgn * sqrt(min(cax * cax + cay * cay, cbx * cbx + cby * cby))
	elseif t.form == "cylinder" then
		-- cylinder with rounded edges
		local rr = t.rr
		local dx = sqrt(x * x + y * y) - (t.r - rr)
		local dz = abs(z - t.h / 2) - (t.h / 2 - rr)
		local ox, oz = max(dx, 0), max(dz, 0)
		return sqrt(ox * ox + oz * oz) + min(max(dx, dz), 0) - rr
	end
	-- ball, also the head of the lollipop
	local dz = z - t.ballZ
	return sqrt(x * x + y * y + dz * dz) - t.r
end

local function genTopiary(c, r, p)
	local R = rrange(r, p.radius[1], p.radius[2])
	local form = p.form or "ball"
	local t = {form = form, r = R, rr = R * 0.25}
	local top, stem = 0, 0
	if form == "cone" then
		t.h = R * rrange(r, p.coneHeight[1], p.coneHeight[2])
		top = t.h
	elseif form == "cylinder" then
		t.h = R * rrange(r, p.cylinderHeight[1], p.cylinderHeight[2])
		top = t.h
	elseif form == "lollipop" then
		t.r = R * 0.8
		stem = R * rrange(r, p.stemHeight[1], p.stemHeight[2])
		t.ballZ = stem + t.r
		top = t.ballZ + t.r
	else
		t.ballZ = R
		top = 2 * R
	end
	-- ground centre on screen, chosen so the shape sits in the middle
	local gx = c.w / 2
	local gy = c.h / 2 + (top * TC - R * TS) / 2
	if stem > 0 then
		c.barkId = c.nextId
		c.nextId = c.nextId + 1
		drawStick(c, gx, gy, gx, gy - (stem + t.r * 0.5) * TC, 0, 2)
	end
	local id = c.nextId
	c.nextId = id + 1
	local inside = p.inside or 0.6
	local hit = {}
	local span = top + R + 2
	for y = -2, c.h + 1 do
		for x = -2, c.w + 1 do
			local sx, sy = x + 0.5 - gx, y + 0.5 - gy
			-- ray of this pixel: P = sx * X + sy * down + d * toward
			local d = span
			for _ = 1, 64 do
				local wx, wy, wz = sx, sy * TS + d * TC, -sy * TC + d * TS
				local dist = topiaryDist(t, wx, wy, wz)
				if dist < 0.02 then
					if wz >= 0 then
						-- normal from the distance field, then into screen space
						local e = 0.05
						local nx = topiaryDist(t, wx + e, wy, wz) - topiaryDist(t, wx - e, wy, wz)
						local ny = topiaryDist(t, wx, wy + e, wz) - topiaryDist(t, wx, wy - e, wz)
						local nz = topiaryDist(t, wx, wy, wz + e) - topiaryDist(t, wx, wy, wz - e)
						local nl = sqrt(nx * nx + ny * ny + nz * nz)
						if nl > 1e-9 then
							nx, ny, nz = nx / nl, ny / nl, nz / nl
							local snx, sny, snz = nx, ny * TS - nz * TC, ny * TC + nz * TS
							local occ = 0.78 + 0.22 * max(0, min(1, wz / max(1, top)))
							local hl = light(snx, sny, snz)
							plot(c, x, y, d, hl * inside * occ, id, 0)
							hit[(y + c.oy) * c.W + x + c.ox + 1] = {x + 0.5, y + 0.5, d, snx, sny, snz, occ, hl}
						end
					end
					break
				end
				d = d - dist
				if d < -span then break end
			end
		end
	end
	carpetLeaves(c, p, hit)
end

-- a block is a box with slightly rounded edges, traced per pixel along the
-- view direction, so its faces are flat and evenly lit like a trimmed hedge.
-- the box itself is drawn dark: it is the deep inside of the hedge. on top
-- of it lies a dense carpet of small leaves; each leaf is a tiny lens shape
-- in the surface plane, a little tilted, with a lit and a shaded half. the
-- gaps between leaves show the dark inside, which reads as foliage depth.

-- brightness of the faces, chosen like a pixel artist would: the top is
-- light, the side toward the light mid, the side away from it dark. in
-- between (rounded edges, tilted leaves) the tones blend by the squared
-- normal, so every face keeps one clear tone with a little texture.
-- x, y, z: tone of a face whose world normal points along that axis
local FACE_TONES = {
	square = {x = 0.7, y = 0.52, z = 0.92},
	iso = {x = 0.36, y = 0.62, z = 0.92},
}

local function faceShade(shape, nx, ny, nz)
	local f = FACE_TONES[shape] or FACE_TONES.square
	local l = nx * nx + ny * ny + nz * nz
	if l < 1e-9 then return f.z end
	return (f.x * nx * nx + f.y * ny * ny + f.z * nz * nz) / l
end

-- screen height of the top face of a square block; by default the top and
-- the front face together are exactly one tile high (Factorio style)
local function blockDepth(p)
	return p.depth or max(2, p.tile - p.height)
end

-- half sizes of the block in world units
-- square: footprint is tile wide and blockDepth deep on screen
-- iso: footprint diamond is tile wide and tile / 2 high on screen
local function blockHalf(p)
	if p.shape == "iso" then
		return p.tile / 4, p.tile / 4
	end
	return p.tile / 2, blockDepth(p) / 2
end

-- world point to screen point and depth (bigger depth = closer)
local function project(c, shape, x, y, z)
	if shape == "iso" then
		return c.ax + (x - y), c.ay + (x + y) * 0.5 - z, x + y + z
	end
	return c.ax + x, c.ay + y - z, y + z
end

-- world vector to screen vector and depth change (no anchor)
local function projectVec(shape, x, y, z)
	if shape == "iso" then
		return x - y, (x + y) * 0.5 - z, x + y + z
	end
	return x, y - z, y + z
end

-- signed distance to the rounded box b = {cx, cy, cz, ex, ey, ez, r}
-- (ex, ey, ez: half sizes of the inner box, r: edge radius)
local function boxDist(b, x, y, z)
	local qx = abs(x - b.cx) - b.ex
	local qy = abs(y - b.cy) - b.ey
	local qz = abs(z - b.cz) - b.ez
	local ox, oy, oz = max(qx, 0), max(qy, 0), max(qz, 0)
	return sqrt(ox * ox + oy * oy + oz * oz) + min(max(qx, max(qy, qz)), 0) - b.r
end

local function boxNormal(b, x, y, z)
	local dx, dy, dz = x - b.cx, y - b.cy, z - b.cz
	local qx = max(abs(dx) - b.ex, 0)
	local qy = max(abs(dy) - b.ey, 0)
	local qz = max(abs(dz) - b.ez, 0)
	if dx < 0 then qx = -qx end
	if dy < 0 then qy = -qy end
	if dz < 0 then qz = -qz end
	local l = sqrt(qx * qx + qy * qy + qz * qz)
	if l < 1e-6 then return 0, 0, 1 end
	return qx / l, qy / l, qz / l
end

-- traces the ray of one pixel; (a, k) is the pixel centre relative to the
-- anchor. points of the ray are O + s * D with z = s, so tracing starts
-- above the box and walks down to the ground. returns the hit or nil.
local function traceBox(b, clip, shape, a, k, H)
	local ox, oy, dx, dy, len
	if shape == "iso" then
		ox, oy, dx, dy, len = a / 2 + k, k - a / 2, 1, 1, 1.7320508
	else
		ox, oy, dx, dy, len = a, k, 0, 1, 1.4142136
	end
	local s = H + 1
	for _ = 1, 64 do
		local x, y = ox + dx * s, oy + dy * s
		local d = boxDist(b, x, y, s)
		if d < 0.02 then
			if x < clip.x0 or x > clip.x1 or y < clip.y0 or y > clip.y1 or s < 0 then
				return nil
			end
			return x, y, s
		end
		s = s - d / len
		if s < 0 then return nil end
	end
	return nil
end

-- canvas size and anchor of a block sprite; fixed for a given shape, tile,
-- depth, height and margin, so the sprite size does not change in animation
-- returns w, h, ax, ay (anchor for the user) and gy, the screen y of the
-- footprint centre on the ground, which the projection is built around
--   square: anchor is the centre of the block on screen, that is the centre
--           of its map cell (top face + front face fill the cell)
--   iso:    anchor is the centre of the cell diamond on the ground
local function blockCanvas(p)
	local m = p.margin or 8
	local H = p.height
	local w, h, ax, ay, gy
	if p.shape == "iso" then
		w = p.tile + 2 * m
		h = p.tile / 2 + H + 2 * m
		ax = m + p.tile / 2
		ay = m + H + p.tile / 4
		gy = ay
	else
		local d = blockDepth(p)
		w = p.tile + 2 * m
		h = d + H + 2 * m
		ax = m + p.tile / 2
		ay = m + (d + H) / 2
		gy = m + H + d / 2
	end
	return ceil(w), ceil(h), ax, ay, gy
end

-- true when the pixel is outside the cell on a joined side; the outline is
-- left out there. the pixel is mapped back to the top plane of the block.
local function joinedSide(c, x, y)
	local b = c.blk
	local px, py = x + 0.5, y + 0.5
	local wx, wy
	if b.shape == "iso" then
		local a = px - c.ax
		local d = (py - c.ay + b.H) * 2
		wx, wy = (a + d) / 2, (d - a) / 2
	else
		wx, wy = px - c.ax, py - c.ay + b.H
	end
	local j = b.join
	return (j.w and wx < -b.hx) or (j.e and wx > b.hx) or (j.n and wy < -b.hy) or (j.s and wy > b.hy)
end

-- darker toward the ground on the sides
local function blockOcc(z, H)
	return 0.84 + 0.16 * max(0, min(1, z / max(1, H)))
end

-- one leaf of the carpet; hit point (x, y, z) with surface normal n
local function drawCarpetLeaf(c, p, id, x, y, z, nx, ny, nz, e, f)
	local shape = p.shape
	local L = rrange(e, p.leafLength[1], p.leafLength[2]) * f
	local W = rrange(e, p.leafWidth[1], p.leafWidth[2]) * f
	local ang = rrange(e, 0, 2 * pi)
	local liftR = rnd(e)
	local ta = rrange(e, -1, 1) * p.tilt
	local ts = rrange(e, -1, 1) * p.tilt
	local tone = partTone(e, p)
	if L < 0.6 then return end
	-- tangent frame of the surface
	local hx_, hy_, hz_ = 0, 0, 1
	if abs(nz) > 0.9 then hx_, hy_, hz_ = 1, 0, 0 end
	local t1x, t1y, t1z = hy_ * nz - hz_ * ny, hz_ * nx - hx_ * nz, hx_ * ny - hy_ * nx
	local tl = sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
	t1x, t1y, t1z = t1x / tl, t1y / tl, t1z / tl
	local t2x, t2y, t2z = ny * t1z - nz * t1y, nz * t1x - nx * t1z, nx * t1y - ny * t1x
	-- leaf direction and side in the surface plane
	local ca, sa = cos(ang), sin(ang)
	local dx, dy, dz = t1x * ca + t2x * sa, t1y * ca + t2y * sa, t1z * ca + t2z * sa
	local sx_, sy_, sz_ = ny * dz - nz * dy, nz * dx - nx * dz, nx * dy - ny * dx
	-- centre lifted off the dark inside
	local lift = p.lift * (0.4 + 0.6 * liftR)
	local px, py, pz = x + nx * lift, y + ny * lift, z + nz * lift
	local scx, scy, sd = project(c, shape, px, py, pz)
	local ux, uy, ud = projectVec(shape, dx * L / 2, dy * L / 2, dz * L / 2)
	local vx, vy, vd = projectVec(shape, sx_ * W / 2, sy_ * W / 2, sz_ * W / 2)
	local det = ux * vy - uy * vx
	if abs(det) < 0.12 then return end
	-- tilted leaf normal, its two halves fold a little
	local lnx, lny, lnz = nx + dx * ta + sx_ * ts, ny + dy * ta + sy_ * ts, nz + dz * ta + sz_ * ts
	local fold = (p.fold or 0.5) * 0.35
	local occ = blockOcc(pz, p.height) * (0.86 + 0.14 * liftR)
	local bw, bh = abs(ux) + abs(vx), abs(uy) + abs(vy)
	for yy = floor(scy - bh), floor(scy + bh) do
		for xx = floor(scx - bw), floor(scx + bw) do
			local rx, ry = xx + 0.5 - scx, yy + 0.5 - scy
			local la = (rx * vy - ry * vx) / det
			local lb = (ux * ry - uy * rx) / det
			if abs(la) <= 1 and abs(lb) <= 1 - la * la then
				local hs = lb > 0 and fold or -fold
				local sh = faceShade(shape, lnx + sx_ * hs, lny + sy_ * hs, lnz + sz_ * hs) * occ
				plot(c, xx, yy, sd + la * ud + lb * vd + 0.05, sh, id, tone)
			end
		end
	end
end

local function genBlock(c, r, p)
	local hx, hy = blockHalf(p)
	local H = p.height
	local j = p.join or {}
	local shape = p.shape
	-- how far the hedge reaches across a joined edge, kept inside the margin
	local ext = min(3, (p.margin or 8) - 4)
	local rr = max(0.3, min(p.round or 1.5, H * 0.4, hx * 0.8, hy * 0.8))
	-- square cells are top + front on screen, so in the world the next cell
	-- to the south starts height pixels after this footprint ends; a joined
	-- south side bridges that gap, the front face then hides behind the
	-- neighbour and the wall reads as one long top
	local gapS = (shape ~= "iso" and j.s) and H or 0
	-- joined sides reach across the edge without rounding, the bottom goes
	-- under the ground so only the upper edges are round
	local x0 = j.w and -(hx + ext + rr + 1) or -hx
	local x1 = j.e and (hx + ext + rr + 1) or hx
	local y0 = j.n and -(hy + ext + rr + 1) or -hy
	local y1 = j.s and (hy + gapS + ext + rr + 1) or hy
	local z0, z1 = -rr - 1, H
	local b = {
		cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, cz = (z0 + z1) / 2,
		ex = (x1 - x0) / 2 - rr, ey = (y1 - y0) / 2 - rr, ez = (z1 - z0) / 2 - rr, r = rr,
	}
	local clip = {
		x0 = j.w and -(hx + ext) or -1e9, x1 = j.e and (hx + ext) or 1e9,
		y0 = j.n and -(hy + ext) or -1e9, y1 = j.s and (hy + gapS + ext) or 1e9,
	}
	if p.join then
		c.blk = {join = j, hx = hx, hy = hy, H = H, shape = shape}
	end
	-- dark inside: the box surface, one id
	local baseId = c.nextId
	c.nextId = baseId + 1
	local W, Hc = c.W, c.H
	local hit = {}
	local inside = p.inside or 0.62
	for y = 0, Hc - 1 do
		for x = 0, W - 1 do
			local wx, wy, wz = traceBox(b, clip, shape, x + 0.5 - c.ax, y + 0.5 - c.ay, H)
			if wx then
				local nx, ny, nz = boxNormal(b, wx, wy, wz)
				local sh = faceShade(shape, nx, ny, nz) * blockOcc(wz, H) * inside
				local _, _, dep = project(c, shape, wx, wy, wz)
				plot(c, x, y, dep, sh, baseId, 0)
				hit[y * W + x + 1] = {wx, wy, wz, nx, ny, nz}
			end
		end
	end
	-- leaf carpet: leaves fall on random sprite points, the ones that land
	-- on the hedge are drawn; the count depends only on the sprite size,
	-- so it is stable in animation
	local la = (p.leafLength[1] + p.leafLength[2]) / 2
	local lw = (p.leafWidth[1] + p.leafWidth[2]) / 2
	local n = W * Hc * (p.cover or 1.4) / (pi * la * lw / 4)
	for k = 1, ceil(n) do
		local e = stream(c.seed, 20000 + k)
		local sx = floor(rnd(e) * W)
		local sy = floor(rnd(e) * Hc)
		local h = hit[sy * W + sx + 1]
		if h then
			local id = c.nextId
			c.nextId = id + 1
			drawCarpetLeaf(c, p, id, h[1], h[2], h[3], h[4], h[5], h[6], e, fade(n, k))
		end
	end
end

local GENERATORS = {
	blob = genBlob,
	cluster = genCluster,
	sphere = genSphere,
	hedge = genHedge,
	leafy = genLeafy,
	rosette = genRosette,
	tuft = genTuft,
	fern = genFern,
	tiered = genTiered,
	bramble = genBramble,
	block = genBlock,
	leafball = genLeafball,
	clumps = genClumps,
	twigs = genTwigs,
	topiary = genTopiary,
}

---------------------------------------------------------------- finishing

local function filled(c, x, y)
	if x < 0 or y < 0 or x >= c.W or y >= c.H then return false end
	return c.id[y * c.W + x + 1] ~= 0
end

local NB = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}}

-- tiny leaf stamp pointing down, as ramp step offsets:
-- lit top, lit tip, dark notch under and right of the tip
local LEAFLET = {
	{-1, 0, 1}, {0, 0, 1}, {0, 1, 1},
	{1, 1, -1}, {0, 2, -1},
}

-- ornaments (flowers, berries): stamps of colour on top of foliage
-- colour index: 1 main, 2 light, 3 dark, 4 flower centre
local ORNAMENTS = {
	dot = {{0, 0, 1}},
	bud = {{0, 0, 2}, {0, 1, 3}},
	berry = {{0, 0, 2}, {1, 0, 1}, {0, 1, 1}, {1, 1, 3}},
	flower = {{0, 0, 4}, {-1, 0, 1}, {1, 0, 1}, {0, -1, 2}, {0, 1, 3}},
}

local function ornamentColours(o)
	local cols = {}
	local mr, mg, mb = hsv(o.h, o.s, o.v)
	local lr, lg, lb = hsv(o.h + 15, o.s * 0.55, min(1, o.v + 0.25))
	local dr, dg, db = hsv(o.h - 20, min(1, o.s + 0.1), o.v * 0.55)
	local cr, cg, cb = hsv(50, 0.65, 1)
	cols[1] = {mr, mg, mb}
	cols[2] = {lr, lg, lb}
	cols[3] = {dr, dg, db}
	cols[4] = {cr, cg, cb}
	return cols
end

-- places ornaments on lit, non-crease foliage, keeping some spacing;
-- candidate spots come from a fixed hashed list, so they stay put
local function placeOrnaments(c, level, crease, n, o)
	local orn = {}
	if not o then return orn end
	local w, h = c.W, c.H
	local shape = ORNAMENTS[o.shape] or ORNAMENTS.dot
	local cols = ornamentColours(o)
	local placed = {}
	local want = floor(o.count + 0.5)
	local minLevel = floor(n * 0.35)
	for k = 1, 120 do
		if #placed >= want then break end
		local x = 1 + floor(hashU(c.seed, k, 71) * (w - 2))
		local y = 1 + floor(hashU(c.seed, k, 73) * (h - 2))
		local i = y * w + x + 1
		if level[i] and not crease[i] and c.id[i] ~= c.barkId and level[i] >= minLevel then
			local ok = true
			for _, q in ipairs(placed) do
				if abs(q[1] - x) + abs(q[2] - y) < (o.spacing or 4) then ok = false end
			end
			if ok then
				placed[#placed + 1] = {x, y}
				for _, d in ipairs(shape) do
					local qx, qy = x + d[1], y + d[2]
					local j = qy * w + qx + 1
					if qx >= 0 and qy >= 0 and qx < w and qy < h and level[j] then
						orn[j] = cols[d[3]]
					end
				end
			end
		end
	end
	return orn
end

-- snow colours: 1 shaded, 2 mid, 3 lit
local SNOW = {}
do
	local r1, g1, b1 = hsv(222, 0.22, 0.7)
	local r2, g2, b2 = hsv(215, 0.12, 0.86)
	local r3, g3, b3 = hsv(210, 0.04, 0.98)
	SNOW[1] = {r1, g1, b1}
	SNOW[2] = {r2, g2, b2}
	SNOW[3] = {r3, g3, b3}
end

local function finish(c, ramp, outline, p, bark)
	local w, h = c.W, c.H
	local n = #ramp
	local seed = c.seed
	local level = {}
	-- quantize shade into ramp levels with a little per-pixel noise
	local noise = p.noise or 0.2
	local contrast = p.contrast or 1
	for i = 1, w * h do
		if c.id[i] ~= 0 then
			local sh = 0.5 + (c.shade[i] - 0.5) * contrast
			local v = sh * n + (hashU(seed, i, 1) * 2 - 1) * noise
			level[i] = max(0, min(n - 1, floor(v) + c.tone[i]))
		end
	end
	-- dark crease where a part is overlapped by a closer part
	local crease = {}
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local i = y * w + x + 1
			if c.id[i] ~= 0 then
				for _, d in ipairs(NB) do
					local qx, qy = x + d[1], y + d[2]
					if filled(c, qx, qy) then
						local j = qy * w + qx + 1
						if c.id[j] ~= c.id[i] and c.depth[j] > c.depth[i] + 0.6 then
							crease[i] = true
						end
					end
				end
			end
		end
	end
	-- crease drops the level, gap caps it: deep dark gaps between parts
	local drop = p.crease or 2
	local gap = p.gap or (n - 1)
	for i, _ in pairs(crease) do
		level[i] = max(0, min(gap, level[i] - drop))
	end
	-- fringe: light pixels hang down into the darker band below as
	-- 1-2 px leaf tips, which turns smooth shading bands into foliage
	local fr = p.fringe or 0
	if fr > 0 then
		local src = {}
		for i, v in pairs(level) do src[i] = v end
		for y = 0, h - 2 do
			for x = 0, w - 1 do
				local i = y * w + x + 1
				local j = i + w
				if src[i] and src[j] and src[j] < src[i] and not crease[j] and hashU(seed, j, 2) < fr then
					level[j] = src[i]
					local k = j + w
					if y + 2 < h and src[k] and src[k] < src[i] and hashU(seed, k, 3) < 0.35 then
						level[k] = src[i] - 1
					end
				end
			end
		end
	end
	-- leaflet texture on a staggered grid, applied in ramp steps so it
	-- survives quantization; stamps read the level before any stamping
	local tx = p.texture or 0
	if tx > 0 then
		local base = {}
		for i, v in pairs(level) do base[i] = v end
		local step = p.textureStep or 3
		local row = 0
		for gy = 0, h - 1, step do
			local shift = (row % 2) * floor(step / 2)
			for gx = shift, w - 1, step do
				local cell = row * 1000 + gx
				local x = gx + floor(hashU(seed, cell, 4) * 3) - 1
				local y = gy + floor(hashU(seed, cell, 5) * 2)
				local i = y * w + x + 1
				if x >= 0 and x < w and y < h and base[i] and not crease[i] and hashU(seed, cell, 6) < tx then
					local l0 = base[i]
					for _, d in ipairs(LEAFLET) do
						local qx, qy = x + d[1], y + d[2]
						if qx >= 0 and qy >= 0 and qx < w and qy < h then
							local j = qy * w + qx + 1
							if base[j] and not crease[j] then
								level[j] = max(0, min(n - 1, l0 + d[3]))
							end
						end
					end
				end
			end
			row = row + 1
		end
	end
	-- remove lonely highlight pixels (single pixels brighter than all 4 neighbours)
	for y = 1, h - 2 do
		for x = 1, w - 2 do
			local i = y * w + x + 1
			if level[i] then
				local brighter = true
				for _, d in ipairs(NB) do
					local j = (y + d[2]) * w + x + d[1] + 1
					if not level[j] or level[j] >= level[i] then brighter = false end
				end
				if brighter then level[i] = level[i] - 1 end
			end
		end
	end
	local orn = placeOrnaments(c, level, crease, n, p.ornament)
	-- snow: caps on every top edge open to the sky (nothing above, or only
	-- a part further back), one or two pixels thick; on lit parts bright,
	-- on shaded parts bluish grey
	local snowAt = {}
	local sn = p.snow or 0
	if sn > 0 then
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local i = y * w + x + 1
				if c.id[i] ~= 0 then
					local j = i - w
					local open = y == 0 or c.id[j] == 0 or (c.id[j] ~= c.id[i] and c.depth[j] < c.depth[i] - 0.6)
					-- decided per 2 pixel wide cell, so snow lies in short dashes
					-- instead of single grains; on foliage only where it is lit,
					-- branches catch snow wherever they face up
					local isBark = c.barkId ~= nil and c.id[i] == c.barkId
					local chance = isBark and min(1, sn + 0.25) or sn
					local lit = isBark or level[i] >= n * 0.35
					if open and lit and hashU(seed, floor(x / 2) + y * 1000, 81) < chance then
						snowAt[i] = level[i] >= n * 0.45 and 3 or 2
						local k = i + w
						if y < h - 1 and c.id[k] == c.id[i] and hashU(seed, i, 82) < sn * 0.55 then
							snowAt[k] = 1
						end
					end
				end
			end
		end
	end
	-- outline and drop shadow
	-- outline modes: dark (all around), ramp (darkest foliage colour),
	-- selective (lit top-left edge uses foliage colour), soft (no outline
	-- on the lit top-left edge), none
	local mode = p.outlineMode or "dark"
	local shadowA = p.shadow or 0.28
	local soft = ramp[min(n, 2)]
	local out = {}
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local i = y * w + x + 1
			local o = (i - 1) * 4
			if c.id[i] ~= 0 then
				local col = ramp[level[i] + 1]
				if orn[i] then col = orn[i] end
				if c.barkId and c.id[i] == c.barkId then
					col = c.shade[i] > 0.3 and bark[2] or bark[1]
				end
				if snowAt[i] then col = SNOW[snowAt[i]] end
				-- branches show only through the dark parts of the foliage
				if bark and c.bark[i] and level[i] <= (p.barkShow or 2) then
					if c.bark[i - 1] and x > 0 then col = bark[2] else col = bark[1] end
					if level[i] <= 0 then col = bark[1] end
				end
				out[o + 1], out[o + 2], out[o + 3], out[o + 4] = col[1], col[2], col[3], 1
			else
				local edge = false
				for _, d in ipairs(NB) do
					if filled(c, x + d[1], y + d[2]) then edge = true end
				end
				-- lit side: the shape lies to the right of or below this pixel
				local litSide = filled(c, x + 1, y) or filled(c, x, y + 1)
				local col = outline
				if mode == "ramp" then col = soft end
				if mode == "selective" and litSide then col = soft end
				if mode == "none" or (mode == "soft" and litSide) then edge = false end
				if c.blk and joinedSide(c, x, y) then edge = false end
				if edge then
					out[o + 1], out[o + 2], out[o + 3], out[o + 4] = col[1], col[2], col[3], 1
				elseif shadowA > 0 and (filled(c, x - 1, y - 2) or filled(c, x, y - 2) or filled(c, x - 1, y - 1)) then
					out[o + 1], out[o + 2], out[o + 3], out[o + 4] = 0, 0, 0, shadowA
				else
					out[o + 1], out[o + 2], out[o + 3], out[o + 4] = 0, 0, 0, 0
				end
			end
		end
	end
	return out
end

---------------------------------------------------------------- api

-- sprite size and anchor of a recipe, without generating it
-- plants: w, h is the sprite (default 48), box the design box (default 32),
--   the anchor is the centre of the design box
-- blocks: size comes from shape, tile, depth, height and margin; w, h, box
--   are ignored; the anchor is the cell centre (see blockCanvas)
function bushgen.size(preset, w, h, box)
	if preset.kind == "block" then
		local bw, bh, ax, ay = blockCanvas(preset)
		return bw, bh, ax, ay
	end
	w = w or 48
	h = h or w
	box = box or 32
	return w, h, floor((w - box) / 2) + box / 2, floor((h - box) / 2) + box / 2
end

-- preset: one entry from data_plants.lua, or a recipe from variety.lua
-- returns {w, h, ax, ay, pixels}: pixels is a flat rgba array (1-based,
-- values 0..1, row by row), ax, ay the anchor in sprite pixels (see size)
function bushgen.generate(preset, seed, w, h, box)
	box = box or 32
	local ax, ay
	w, h, ax, ay = bushgen.size(preset, w, h, box)
	local ramp, outline = makeRamp(preset.palette, stream(seed, 1))
	local c
	if preset.kind == "block" then
		c = canvasNew(w, h, w, h, seed)
		local _, _, _, _, gy = blockCanvas(preset)
		c.ax, c.ay = ax, gy
	else
		c = canvasNew(box, box, w, h, seed)
	end
	-- optional undergrowth (grass at the base), drawn with the same palette
	if preset.under then
		GENERATORS[preset.under.kind](c, stream(seed, 2), preset.under)
	end
	GENERATORS[preset.kind](c, stream(seed, 3), preset)
	if preset.edgeTips and preset.edgeTips > 0 then
		edgeTips(c, preset.edgeTips)
	end
	local bark = nil
	if preset.bark or c.barkId then
		bark = {}
		for k = 1, 2 do
			local b = preset.bark or {h = 22, s = 0.55, v = 0.45}
			local cr, cg, cb = hsv(b.h, b.s, b.v * (k == 1 and 0.6 or 1))
			bark[k] = {cr, cg, cb}
		end
	end
	local pixels = finish(c, ramp, outline, preset, bark)
	return {w = w, h = h, ax = ax, ay = ay, pixels = pixels}
end

-- helpers for other modules (variety.lua)
bushgen.rng = {new = rngNew, next = rnd, range = rrange, int = rint}
bushgen.hash = hashU

return bushgen
