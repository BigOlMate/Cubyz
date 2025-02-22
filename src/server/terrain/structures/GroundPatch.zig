const std = @import("std");
const Allocator = std.mem.Allocator;

const main = @import("root");
const random = main.random;
const JsonElement = main.JsonElement;
const terrain = main.server.terrain;
const CaveMap = terrain.CaveMap;
const vec = main.vec;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec3i = vec.Vec3i;

pub const id = "cubyz:ground_patch";

const GroundPatch = @This();

blockType: u16,
width: f32,
variation: f32,
depth: i32,
smoothness: f32,

pub fn loadModel(arenaAllocator: Allocator, parameters: JsonElement) Allocator.Error!*GroundPatch {
	const self = try arenaAllocator.create(GroundPatch);
	self.* = .{
		.blockType = main.blocks.getByID(parameters.get([]const u8, "block", "")),
		.width = parameters.get(f32, "width", 5),
		.variation = parameters.get(f32, "variation", 1),
		.depth = parameters.get(i32, "depth", 2),
		.smoothness = parameters.get(f32, "smoothness", 0),
	};
	return self;
}

pub fn generate(self: *GroundPatch, x: i32, y: i32, z: i32, chunk: *main.chunk.Chunk, caveMap: terrain.CaveMap.CaveMapView, seed: *u64) Allocator.Error!void {
	const width = self.width + (random.nextFloat(seed) - 0.5)*self.variation;
	const orientation = 2*std.math.pi*random.nextFloat(seed);
	const ellipseParam = 1 + random.nextFloat(seed);

	// Orientation of the major and minor half axis of the ellipse.
	// For now simply use a minor axis 1/ellipseParam as big as the major.
	const xMain = @sin(orientation)/width;
	const zMain = @cos(orientation)/width;
	const xSecn = ellipseParam*@cos(orientation)/width;
	const zSecn = -ellipseParam*@sin(orientation)/width;

	const xMin = @max(0, x - @as(i32, @intFromFloat(@ceil(width))));
	const xMax = @min(chunk.width, x + @as(i32, @intFromFloat(@ceil(width))));
	const zMin = @max(0, z - @as(i32, @intFromFloat(@ceil(width))));
	const zMax = @min(chunk.width, z + @as(i32, @intFromFloat(@ceil(width))));

	var px = chunk.startIndex(xMin);
	while(px < xMax) : (px += 1) {
		var pz = chunk.startIndex(zMin);
		while(pz < zMax) : (pz += 1) {
			const mainDist = xMain*@as(f32, @floatFromInt(x - px)) + zMain*@as(f32, @floatFromInt(z - pz));
			const secnDist = xSecn*@as(f32, @floatFromInt(x - px)) + zSecn*@as(f32, @floatFromInt(z - pz));
			const dist = mainDist*mainDist + secnDist*secnDist;
			if(dist <= 1) {
				var startHeight = y;

				if(caveMap.isSolid(px, startHeight, pz)) {
					startHeight = caveMap.findTerrainChangeAbove(px, pz, startHeight) - 1;
				} else {
					startHeight = caveMap.findTerrainChangeBelow(px, pz, startHeight);
				}
				var py = chunk.startIndex(startHeight - self.depth + 1);
				while(py <= startHeight) : (py += chunk.pos.voxelSize) {
					if(dist <= self.smoothness or (dist - self.smoothness)/(1 - self.smoothness) < random.nextFloat(seed)) {
						if(chunk.liesInChunk(px, py, pz))  {
							chunk.updateBlockInGeneration(px, py, pz, .{.typ = self.blockType, .data = 0}); // TODO: Natural standard.
						}
					}
				}
			}
		}
	}
}