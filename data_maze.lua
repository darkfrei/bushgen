-- data_maze.lua
-- demo map for the maze mode of main.lua: "#" is a hedge wall, "." is a path
-- the same map is shown twice, in square (orthogonal 3/4) and iso view

return {
	tile = 32,          -- cell width on screen in pixels
	squareHeight = 12,  -- front face height in the square view (top face = tile - this)
	isoHeight = 12,     -- hedge height in the iso view
	map = {
		"###########",
		"#.....#...#",
		"#.###.#.#.#",
		"#.#...#.#.#",
		"#.#.###.#.#",
		"#...#...#.#",
		"###.#.###.#",
		"#...#.....#",
		"#####.#####",
	},
}
