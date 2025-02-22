const std = @import("std");
const Allocator = std.mem.Allocator;

const blocks = @import("blocks.zig");
const Block = blocks.Block;
const game = @import("game.zig");
const graphics = @import("graphics.zig");
const c = graphics.c;
const Shader = graphics.Shader;
const SSBO = graphics.SSBO;
const lighting = @import("lighting.zig");
const main = @import("main.zig");
const models = @import("models.zig");
const renderer = @import("renderer.zig");
const settings = @import("settings.zig");
const vec = @import("vec.zig");
const Vec2f = vec.Vec2f;
const Vec3i = vec.Vec3i;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const Mat4f = vec.Mat4f;

pub const chunkShift: u5 = 5;
pub const chunkShift2: u5 = chunkShift*2;
pub const chunkSize: u31 = 1 << chunkShift;
pub const chunkSizeIterator: [chunkSize]u0 = undefined;
pub const chunkVolume: u31 = 1 << 3*chunkShift;
pub const chunkMask: i32 = chunkSize - 1;

/// Contains a bunch of constants used to describe neighboring blocks.
pub const Neighbors = struct { // TODO: Should this be an enum?
	/// How many neighbors there are.
	pub const neighbors: u3 = 6;
	/// Directions → Index
	pub const dirUp: u3 = 0;
	/// Directions → Index
	pub const dirDown: u3 = 1;
	/// Directions → Index
	pub const dirPosX: u3 = 2;
	/// Directions → Index
	pub const dirNegX: u3 = 3;
	/// Directions → Index
	pub const dirPosZ: u3 = 4;
	/// Directions → Index
	pub const dirNegZ: u3 = 5;
	/// Index to relative position
	pub const relX = [_]i32 {0, 0, 1, -1, 0, 0};
	/// Index to relative position
	pub const relY = [_]i32 {1, -1, 0, 0, 0, 0};
	/// Index to relative position
	pub const relZ = [_]i32 {0, 0, 0, 0, 1, -1};
	/// Index to bitMask for bitmap direction data
	pub const bitMask = [_]u6 {0x01, 0x02, 0x04, 0x08, 0x10, 0x20};
	/// To iterate over all neighbors easily
	pub const iterable = [_]u3 {0, 1, 2, 3, 4, 5};
	/// Marks the two dimension that are orthogonal
	pub const orthogonalComponents = [_]Vec3i {
		.{1, 0, 1},
		.{1, 0, 1},
		.{0, 1, 1},
		.{0, 1, 1},
		.{1, 1, 0},
		.{1, 1, 0},
	};
	pub const textureX = [_]Vec3i {
		.{1, 0, 0},
		.{-1, 0, 0},
		.{0, 0, -1},
		.{0, 0, 1},
		.{1, 0, 0},
		.{-1, 0, 0},
	};
	pub const textureY = [_]Vec3i {
		.{0, 0, 1},
		.{0, 0, 1},
		.{0, -1, 0},
		.{0, -1, 0},
		.{0, -1, 0},
		.{0, -1, 0},
	};

	pub const isPositive = [_]bool {true, false, true, false, true, false};
	pub const vectorComponent = [_]enum(u2){x = 0, y = 1, z = 2} {.y, .y, .x, .x, .z, .z};

	pub fn extractDirectionComponent(self: u3, in: anytype) @TypeOf(in[0]) {
		switch(self) {
			inline else => |val| {
				if(val >= 6) unreachable;
				return in[@intFromEnum(vectorComponent[val])];
			}
		}
	}
};

/// Gets the index of a given position inside this chunk.
pub fn getIndex(x: i32, y: i32, z: i32) u32 {
	std.debug.assert((x & chunkMask) == x and (y & chunkMask) == y and (z & chunkMask) == z);
	return (@as(u32, @intCast(x)) << chunkShift) | (@as(u32, @intCast(y)) << chunkShift2) | @as(u32, @intCast(z));
}
/// Gets the x coordinate from a given index inside this chunk.
fn extractXFromIndex(index: usize) i32 {
	return @intCast(index >> chunkShift & chunkMask);
}
/// Gets the y coordinate from a given index inside this chunk.
fn extractYFromIndex(index: usize) i32 {
	return @intCast(index >> chunkShift2 & chunkMask);
}
/// Gets the z coordinate from a given index inside this chunk.
fn extractZFromIndex(index: usize) i32 {
	return @intCast(index & chunkMask);
}

pub const ChunkPosition = struct {
	wx: i32,
	wy: i32,
	wz: i32,
	voxelSize: u31,
	
	pub fn hashCode(self: ChunkPosition) u32 {
		const shift: u5 = @truncate(@min(@ctz(self.wx), @ctz(self.wy), @ctz(self.wz)));
		return (((@as(u32, @bitCast(self.wx)) >> shift) *% 31 +% (@as(u32, @bitCast(self.wy)) >> shift)) *% 31 +% (@as(u32, @bitCast(self.wz)) >> shift)) *% 31 +% self.voxelSize; // TODO: Can I use one of zigs standard hash functions?
	}

	pub fn equals(self: ChunkPosition, other: anytype) bool {
		if(@typeInfo(@TypeOf(other)) == .Optional) {
			if(other) |notNull| {
				return self.equals(notNull);
			}
			return false;
		} else if(@typeInfo(@TypeOf(other)) == .Pointer) {
			return self.wx == other.pos.wx and self.wy == other.pos.wy and self.wz == other.pos.wz and self.voxelSize == other.pos.voxelSize;
		} else @compileError("Unsupported");
	}

	pub fn getMinDistanceSquared(self: ChunkPosition, playerPosition: Vec3d) f64 {
		const halfWidth: f64 = @floatFromInt(self.voxelSize*@divExact(chunkSize, 2));
		var dx = @abs(@as(f64, @floatFromInt(self.wx)) + halfWidth - playerPosition[0]);
		var dy = @abs(@as(f64, @floatFromInt(self.wy)) + halfWidth - playerPosition[1]);
		var dz = @abs(@as(f64, @floatFromInt(self.wz)) + halfWidth - playerPosition[2]);
		dx = @max(0, dx - halfWidth);
		dy = @max(0, dy - halfWidth);
		dz = @max(0, dz - halfWidth);
		return dx*dx + dy*dy + dz*dz;
	}

	pub fn getMaxDistanceSquared(self: ChunkPosition, playerPosition: Vec3d) f64 {
		const halfWidth: f64 = @floatFromInt(self.voxelSize*@divExact(chunkSize, 2));
		var dx = @abs(@as(f64, @floatFromInt(self.wx)) + halfWidth - playerPosition[0]);
		var dy = @abs(@as(f64, @floatFromInt(self.wy)) + halfWidth - playerPosition[1]);
		var dz = @abs(@as(f64, @floatFromInt(self.wz)) + halfWidth - playerPosition[2]);
		dx = dx + halfWidth;
		dy = dy + halfWidth;
		dz = dz + halfWidth;
		return dx*dx + dy*dy + dz*dz;
	}

	pub fn getCenterDistanceSquared(self: ChunkPosition, playerPosition: Vec3d) f64 {
		const halfWidth: f64 = @floatFromInt(self.voxelSize*@divExact(chunkSize, 2));
		const dx = @as(f64, @floatFromInt(self.wx)) + halfWidth - playerPosition[0];
		const dy = @as(f64, @floatFromInt(self.wy)) + halfWidth - playerPosition[1];
		const dz = @as(f64, @floatFromInt(self.wz)) + halfWidth - playerPosition[2];
		return dx*dx + dy*dy + dz*dz;
	}

	pub fn getPriority(self: ChunkPosition, playerPos: Vec3d) f32 {
		return -@as(f32, @floatCast(self.getMinDistanceSquared(playerPos)))/@as(f32, @floatFromInt(self.voxelSize*self.voxelSize)) + 2*@as(f32, @floatFromInt(std.math.log2_int(u31, self.voxelSize)*chunkSize*chunkSize));
	}
};

pub const Chunk = struct {
	pos: ChunkPosition,
	blocks: [chunkVolume]Block = undefined,

	wasChanged: bool = false,
	/// When a chunk is cleaned, it won't be saved by the ChunkManager anymore, so following changes need to be saved directly.
	wasCleaned: bool = false,
	generated: bool = false,

	width: u31,
	voxelSizeShift: u5,
	voxelSizeMask: i32,
	widthShift: u5,
	mutex: std.Thread.Mutex,

	pub fn init(self: *Chunk, pos: ChunkPosition) void {
		std.debug.assert((pos.voxelSize - 1 & pos.voxelSize) == 0);
		std.debug.assert(@mod(pos.wx, pos.voxelSize) == 0 and @mod(pos.wy, pos.voxelSize) == 0 and @mod(pos.wz, pos.voxelSize) == 0);
		const voxelSizeShift: u5 = @intCast(std.math.log2_int(u31, pos.voxelSize));
		self.* = Chunk {
			.pos = pos,
			.width = pos.voxelSize*chunkSize,
			.voxelSizeShift = voxelSizeShift,
			.voxelSizeMask = pos.voxelSize - 1,
			.widthShift = voxelSizeShift + chunkShift,
			.mutex = std.Thread.Mutex{},
		};
	}

	pub fn setChanged(self: *Chunk) void {
		self.wasChanged = true;
		{
			self.mutex.lock();
			if(self.wasCleaned) {
				self.save();
			}
			self.mutex.unlock();
		}
	}

	pub fn clean(self: *Chunk) void {
		{
			self.mutex.lock();
			self.wasCleaned = true;
			self.save();
			self.mutex.unlock();
		}
	}

	pub fn unclean(self: *Chunk) void {
		{
			self.mutex.lock();
			self.wasCleaned = false;
			self.save();
			self.mutex.unlock();
		}
	}

	/// Checks if the given relative coordinates lie within the bounds of this chunk.
	pub fn liesInChunk(self: *const Chunk, x: i32, y: i32, z: i32) bool {
		return x >= 0 and x < self.width
			and y >= 0 and y < self.width
			and z >= 0 and z < self.width;
	}

	/// This is useful to convert for loops to work for reduced resolution:
	/// Instead of using
	/// for(int x = start; x < end; x++)
	/// for(int x = chunk.startIndex(start); x < end; x += chunk.getVoxelSize())
	/// should be used to only activate those voxels that are used in Cubyz's downscaling technique.
	pub fn startIndex(self: *const Chunk, start: i32) i32 {
		return start+self.voxelSizeMask & ~self.voxelSizeMask; // Rounds up to the nearest valid voxel coordinate.
	}

	/// Updates a block if current value is air or the current block is degradable.
	/// Does not do any bound checks. They are expected to be done with the `liesInChunk` function.
	pub fn updateBlockIfDegradable(self: *Chunk, _x: i32, _y: i32, _z: i32, newBlock: Block) void {
		const x = _x >> self.voxelSizeShift;
		const y = _y >> self.voxelSizeShift;
		const z = _z >> self.voxelSizeShift;
		const index = getIndex(x, y, z);
		if (self.blocks[index].typ == 0 or self.blocks[index].degradable()) {
			self.blocks[index] = newBlock;
		}
	}

	/// Updates a block if it is inside this chunk.
	/// Does not do any bound checks. They are expected to be done with the `liesInChunk` function.
	pub fn updateBlock(self: *Chunk, _x: i32, _y: i32, _z: i32, newBlock: Block) void {
		const x = _x >> self.voxelSizeShift;
		const y = _y >> self.voxelSizeShift;
		const z = _z >> self.voxelSizeShift;
		const index = getIndex(x, y, z);
		self.blocks[index] = newBlock;
	}

	/// Updates a block if it is inside this chunk. Should be used in generation to prevent accidently storing these as changes.
	/// Does not do any bound checks. They are expected to be done with the `liesInChunk` function.
	pub fn updateBlockInGeneration(self: *Chunk, _x: i32, _y: i32, _z: i32, newBlock: Block) void {
		const x = _x >> self.voxelSizeShift;
		const y = _y >> self.voxelSizeShift;
		const z = _z >> self.voxelSizeShift;
		const index = getIndex(x, y, z);
		self.blocks[index] = newBlock;
	}

	/// Gets a block if it is inside this chunk.
	/// Does not do any bound checks. They are expected to be done with the `liesInChunk` function.
	pub fn getBlock(self: *const Chunk, _x: i32, _y: i32, _z: i32) Block {
		const x = _x >> self.voxelSizeShift;
		const y = _y >> self.voxelSizeShift;
		const z = _z >> self.voxelSizeShift;
		const index = getIndex(x, y, z);
		return self.blocks[index];
	}

	pub fn getNeighbors(self: *const Chunk, x: i32, y: i32, z: i32, neighborsArray: *[6]Block) void {
		std.debug.assert(neighborsArray.length == 6);
		x &= chunkMask;
		y &= chunkMask;
		z &= chunkMask;
		for(Neighbors.relX, 0..) |_, i| {
			const xi = x + Neighbors.relX[i];
			const yi = y + Neighbors.relY[i];
			const zi = z + Neighbors.relZ[i];
			if (xi == (xi & chunkMask) and yi == (yi & chunkMask) and zi == (zi & chunkMask)) { // Simple double-bound test for coordinates.
				neighborsArray[i] = self.getBlock(xi, yi, zi);
			} else {
				// TODO: What about other chunks?
//				NormalChunk ch = world.getChunk(xi + wx, yi + wy, zi + wz);
//				if (ch != null) {
//					neighborsArray[i] = ch.getBlock(xi & chunkMask, yi & chunkMask, zi & chunkMask);
//				} else {
//					neighborsArray[i] = 1; // Some solid replacement, in case the chunk isn't loaded. TODO: Properly choose a solid block.
//				}
			}
		}
	}

	pub fn updateFromLowerResolution(self: *Chunk, other: *const Chunk) void {
		const xOffset = if(other.wx != self.wx) chunkSize/2 else 0; // Offsets of the lower resolution chunk in this chunk.
		const yOffset = if(other.wy != self.wy) chunkSize/2 else 0;
		const zOffset = if(other.wz != self.wz) chunkSize/2 else 0;
		
		var x: i32 = 0;
		while(x < chunkSize/2): (x += 1) {
			var y: i32 = 0;
			while(y < chunkSize/2): (y += 1) {
				var z: i32 = 0;
				while(z < chunkSize/2): (z += 1) {
					// Count the neighbors for each subblock. An transparent block counts 5. A chunk border(unknown block) only counts 1.
					var neighborCount: [8]u32 = undefined;
					var octantBlocks: [8]Block = undefined;
					var maxCount: u32 = 0;
					var dx: i32 = 0;
					while(dx <= 1): (dx += 1) {
						var dy: i32 = 0;
						while(dy <= 1): (dy += 1) {
							var dz: i32 = 0;
							while(dz <= 1): (dz += 1) {
								const index = getIndex(x*2 + dx, y*2 + dy, z*2 + dz);
								const i = dx*4 + dz*2 + dy;
								octantBlocks[i] = other.blocks[index];
								if(octantBlocks[i] == 0) continue; // I don't care about air blocks.
								
								var count: u32 = 0;
								for(Neighbors.iterable) |n| {
									const nx = x*2 + dx + Neighbors.relX[n];
									const ny = y*2 + dy + Neighbors.relY[n];
									const nz = z*2 + dz + Neighbors.relZ[n];
									if((nx & chunkMask) == nx and (ny & chunkMask) == ny and (nz & chunkMask) == nz) { // If it's inside the chunk.
										const neighborIndex = getIndex(nx, ny, nz);
										if(other.blocks[neighborIndex].transparent()) {
											count += 5;
										}
									} else {
										count += 1;
									}
								}
								maxCount = @max(maxCount, count);
								neighborCount[i] = count;
							}
						}
					}
					// Uses a specific permutation here that keeps high resolution patterns in lower resolution.
					const permutationStart = (x & 1)*4 + (z & 1)*2 + (y & 1);
					const block = Block{.typ = 0, .data = 0};
					for(0..8) |i| {
						const appliedPermutation = permutationStart ^ i;
						if(neighborCount[appliedPermutation] >= maxCount - 1) { // Avoid pattern breaks at chunk borders.
							block = blocks[appliedPermutation];
						}
					}
					// Update the block:
					const thisIndex = getIndex(x + xOffset, y + yOffset, z + zOffset);
					self.blocks[thisIndex] = block;
				}
			}
		}
		
		self.setChanged();
	}

	pub fn save(self: *Chunk, world: *main.server.ServerWorld) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		if(self.wasChanged) {
//		TODO:	ChunkIO.storeChunkToFile(world, this);
			self.wasChanged = false;
			// Update the next lod chunk:
			if(self.pos.voxelSize != 1 << settings.highestLOD) {
				var pos = self.pos;
				pos.wx &= ~pos.voxelSize;
				pos.wy &= ~pos.voxelSize;
				pos.wz &= ~pos.voxelSize;
				pos.voxelSize *= 2;
				const nextHigherLod = world.chunkManager.getOrGenerateChunk(pos);
				nextHigherLod.updateFromLowerResolution(self);
			}
		}
	}
};


pub const meshing = struct {
	var shader: Shader = undefined;
	var transparentShader: Shader = undefined;
	const UniformStruct = struct {
		projectionMatrix: c_int,
		viewMatrix: c_int,
		modelPosition: c_int,
		screenSize: c_int,
		ambientLight: c_int,
		@"fog.color": c_int,
		@"fog.density": c_int,
		texture_sampler: c_int,
		emissionSampler: c_int,
		reflectionMap: c_int,
		reflectionMapSize: c_int,
		visibilityMask: c_int,
		voxelSize: c_int,
		zNear: c_int,
		zFar: c_int,
	};
	pub var uniforms: UniformStruct = undefined;
	pub var transparentUniforms: UniformStruct = undefined;
	var vao: c_uint = undefined;
	var vbo: c_uint = undefined;
	var faces: std.ArrayList(u32) = undefined;
	pub var faceBuffer: graphics.LargeBuffer(FaceData) = undefined;
	pub var quadsDrawn: usize = 0;
	pub var transparentQuadsDrawn: usize = 0;

	pub fn init() !void {
		shader = try Shader.initAndGetUniforms("assets/cubyz/shaders/chunks/chunk_vertex.vs", "assets/cubyz/shaders/chunks/chunk_fragment.fs", &uniforms);
		transparentShader = try Shader.initAndGetUniforms("assets/cubyz/shaders/chunks/chunk_vertex.vs", "assets/cubyz/shaders/chunks/transparent_fragment.fs", &transparentUniforms);

		var rawData: [6*3 << (3*chunkShift)]u32 = undefined; // 6 vertices per face, maximum 3 faces/block
		const lut = [_]u32{0, 1, 2, 2, 1, 3};
		for(0..rawData.len) |i| {
			rawData[i] = @as(u32, @intCast(i))/6*4 + lut[i%6];
		}

		c.glGenVertexArrays(1, &vao);
		c.glBindVertexArray(vao);
		c.glGenBuffers(1, &vbo);
		c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, vbo);
		c.glBufferData(c.GL_ELEMENT_ARRAY_BUFFER, rawData.len*@sizeOf(u32), &rawData, c.GL_STATIC_DRAW);
		c.glBindVertexArray(0);

		faces = try std.ArrayList(u32).initCapacity(main.globalAllocator, 65536);
		try faceBuffer.init(main.globalAllocator, 1 << 20, 3);
	}

	pub fn deinit() void {
		shader.deinit();
		transparentShader.deinit();
		c.glDeleteVertexArrays(1, &vao);
		c.glDeleteBuffers(1, &vbo);
		faces.deinit();
		faceBuffer.deinit();
	}

	pub fn beginRender() !void {
		try faceBuffer.beginRender();
	}

	pub fn endRender() void {
		faceBuffer.endRender();
	}

	fn bindCommonUniforms(locations: *UniformStruct, projMatrix: Mat4f, ambient: Vec3f) void {
		c.glUniformMatrix4fv(locations.projectionMatrix, 1, c.GL_TRUE, @ptrCast(&projMatrix));

		c.glUniform1i(locations.texture_sampler, 0);
		c.glUniform1i(locations.emissionSampler, 1);
		c.glUniform1i(locations.reflectionMap, 2);
		c.glUniform1f(locations.reflectionMapSize, renderer.reflectionCubeMapSize);

		c.glUniformMatrix4fv(locations.viewMatrix, 1, c.GL_TRUE, @ptrCast(&game.camera.viewMatrix));

		c.glUniform3f(locations.ambientLight, ambient[0], ambient[1], ambient[2]);

		c.glUniform1f(locations.zNear, renderer.zNear);
		c.glUniform1f(locations.zFar, renderer.zFar);
	}

	pub fn bindShaderAndUniforms(projMatrix: Mat4f, ambient: Vec3f) void {
		shader.bind();

		bindCommonUniforms(&uniforms, projMatrix, ambient);

		c.glBindVertexArray(vao);
	}

	pub fn bindTransparentShaderAndUniforms(projMatrix: Mat4f, ambient: Vec3f) void {
		transparentShader.bind();

		c.glUniform3fv(transparentUniforms.@"fog.color", 1, @ptrCast(&game.fog.color));
		c.glUniform1f(transparentUniforms.@"fog.density", game.fog.density);

		bindCommonUniforms(&transparentUniforms, projMatrix, ambient);

		c.glBindVertexArray(vao);
	}

	pub const FaceData = extern struct {
		position: packed struct(u32) {
			x: u5,
			y: u5,
			z: u5,
			padding: u4 = 0,
			isBackFace: bool,
			normal: u3,
			permutation: u6,
			padding2: u3 = 0,
		},
		blockAndModel: packed struct(u32) {
			typ: u16,
			modelIndex: u16,
		},
		light: [4]u32 = .{0, 0, 0, 0},
	};

	const PrimitiveMesh = struct {
		coreFaces: std.ArrayListUnmanaged(FaceData) = .{},
		neighborFacesSameLod: [6]std.ArrayListUnmanaged(FaceData) = [_]std.ArrayListUnmanaged(FaceData){.{}} ** 6,
		neighborFacesHigherLod: [6]std.ArrayListUnmanaged(FaceData) = [_]std.ArrayListUnmanaged(FaceData){.{}} ** 6,
		completeList: []FaceData = &.{},
		coreLen: u32 = 0,
		sameLodLens: [6]u32 = .{0} ** 6,
		higherLodLens: [6]u32 = .{0} ** 6,
		mutex: std.Thread.Mutex = .{},
		bufferAllocation: graphics.SubAllocation = .{.start = 0, .len = 0},
		vertexCount: u31 = 0,
		wasChanged: bool = false,

		fn deinit(self: *PrimitiveMesh) void {
			faceBuffer.free(self.bufferAllocation) catch unreachable;
			self.coreFaces.deinit(main.globalAllocator);
			for(&self.neighborFacesSameLod) |*neighborFaces| {
				neighborFaces.deinit(main.globalAllocator);
			}
			for(&self.neighborFacesHigherLod) |*neighborFaces| {
				neighborFaces.deinit(main.globalAllocator);
			}
			main.globalAllocator.free(self.completeList);
		}

		fn reset(self: *PrimitiveMesh) void {
			self.coreFaces.clearRetainingCapacity();
			for(&self.neighborFacesSameLod) |*neighborFaces| {
				neighborFaces.clearRetainingCapacity();
			}
			for(&self.neighborFacesHigherLod) |*neighborFaces| {
				neighborFaces.clearRetainingCapacity();
			}
		}

		fn appendCore(self: *PrimitiveMesh, face: FaceData) !void {
			try self.coreFaces.append(main.globalAllocator, face);
		}

		fn appendNeighbor(self: *PrimitiveMesh, face: FaceData, neighbor: u3, comptime isLod: bool) !void {
			if(isLod) {
				try self.neighborFacesHigherLod[neighbor].append(main.globalAllocator, face);
			} else {
				try self.neighborFacesSameLod[neighbor].append(main.globalAllocator, face);
			}
		}

		fn clearNeighbor(self: *PrimitiveMesh, neighbor: u3, comptime isLod: bool) void {
			if(isLod) {
				self.neighborFacesHigherLod[neighbor].clearRetainingCapacity();
			} else {
				self.neighborFacesSameLod[neighbor].clearRetainingCapacity();
			}
		}

		fn finish(self: *PrimitiveMesh, parent: *ChunkMesh) !void {
			var len: usize = self.coreFaces.items.len;
			for(self.neighborFacesSameLod) |neighborFaces| {
				len += neighborFaces.items.len;
			}
			for(self.neighborFacesHigherLod) |neighborFaces| {
				len += neighborFaces.items.len;
			}
			const completeList = try main.globalAllocator.alloc(FaceData, len);
			var i: usize = 0;
			@memcpy(completeList[i..][0..self.coreFaces.items.len], self.coreFaces.items);
			i += self.coreFaces.items.len;
			for(self.neighborFacesSameLod) |neighborFaces| {
				@memcpy(completeList[i..][0..neighborFaces.items.len], neighborFaces.items);
				i += neighborFaces.items.len;
			}
			for(self.neighborFacesHigherLod) |neighborFaces| {
				@memcpy(completeList[i..][0..neighborFaces.items.len], neighborFaces.items);
				i += neighborFaces.items.len;
			}
			for(completeList) |*face| {
				face.light = getLight(parent, face.position.x, face.position.y, face.position.z, face.position.normal);
			}
			self.mutex.lock();
			const oldList = self.completeList;
			self.completeList = completeList;
			self.coreLen = @intCast(self.coreFaces.items.len);
			for(self.neighborFacesSameLod, 0..) |neighborFaces, j| {
				self.sameLodLens[j] = @intCast(neighborFaces.items.len);
			}
			for(self.neighborFacesHigherLod, 0..) |neighborFaces, j| {
				self.higherLodLens[j] = @intCast(neighborFaces.items.len);
			}
			self.mutex.unlock();
			main.globalAllocator.free(oldList);
		}

		fn getValues(mesh: *ChunkMesh, wx: i32, wy: i32, wz: i32) [6]u8 {
			const x = (wx >> mesh.chunk.voxelSizeShift) & chunkMask;
			const y = (wy >> mesh.chunk.voxelSizeShift) & chunkMask;
			const z = (wz >> mesh.chunk.voxelSizeShift) & chunkMask;
			const index = getIndex(x, y, z);
			return .{
				mesh.lightingData.*[0].data[index].load(.Unordered),
				mesh.lightingData.*[1].data[index].load(.Unordered),
				mesh.lightingData.*[2].data[index].load(.Unordered),
				mesh.lightingData.*[3].data[index].load(.Unordered),
				mesh.lightingData.*[4].data[index].load(.Unordered),
				mesh.lightingData.*[5].data[index].load(.Unordered),
			};
		}

		fn getLightAt(parent: *ChunkMesh, x: i32, y: i32, z: i32) [6]u8 {
			const wx = parent.pos.wx +% x*parent.pos.voxelSize;
			const wy = parent.pos.wy +% y*parent.pos.voxelSize;
			const wz = parent.pos.wz +% z*parent.pos.voxelSize;
			if(x == x & chunkMask and y == y & chunkMask and z == z & chunkMask) {
				return getValues(parent, wx, wy, wz);
			}
			const neighborMesh = renderer.RenderStructure.getMeshFromAnyLodAndIncreaseRefCount(wx, wy, wz, parent.pos.voxelSize) orelse return .{0, 0, 0, 0, 0, 0};
			defer neighborMesh.decreaseRefCount();
			// TODO: If the neighbor mesh has a higher lod the transition isn't seamless.
			return getValues(neighborMesh, wx, wy, wz);
		}

		fn getLight(parent: *ChunkMesh, x: i32, y: i32, z: i32, normal: u3) [4]u32 {
			// TODO: Add a case for non-full cube models. This requires considering more light values along the normal.
			const pos = Vec3i{x, y, z};
			var rawVals: [3][3][6]u8 = undefined;
			var dx: i32 = -1;
			while(dx <= 1): (dx += 1) {
				var dy: i32 = -1;
				while(dy <= 1): (dy += 1) {
					const lightPos = pos +% Neighbors.textureX[normal]*@as(Vec3i, @splat(dx)) +% Neighbors.textureY[normal]*@as(Vec3i, @splat(dy));
					rawVals[@intCast(dx + 1)][@intCast(dy + 1)] = getLightAt(parent, lightPos[0], lightPos[1], lightPos[2]);
				}
			}
			var interpolatedVals: [6][4]u32 = undefined;
			for(0..6) |channel| {
				for(0..2) |destX| {
					for(0..2) |destY| {
						var val: u32 = 0;
						for(0..2) |sourceX| {
							for(0..2) |sourceY| {
								val += rawVals[destX+sourceX][destY+sourceY][channel];
							}
						}
						interpolatedVals[channel][destX*2 + destY] = @intCast(val >> 2+3);
					}
				}
			}
			var result: [4]u32 = undefined;
			for(0..4) |i| {
				result[i] = (
					interpolatedVals[0][i] << 25 |
					interpolatedVals[1][i] << 20 |
					interpolatedVals[2][i] << 15 |
					interpolatedVals[3][i] << 10 |
					interpolatedVals[4][i] << 5 |
					interpolatedVals[5][i] << 0
				);
			}
			return result;
		}

		fn uploadData(self: *PrimitiveMesh, isNeighborLod: [6]bool) !void {
			self.mutex.lock();
			defer self.mutex.unlock();
			var len: u32 = self.coreLen;
			var offset: u32 = self.coreLen;
			var list: [6][]FaceData = undefined;
			for(0..6) |i| {
				const neighborLen = self.sameLodLens[i];
				if(!isNeighborLod[i]) {
					list[i] = self.completeList[offset..][0..neighborLen];
					len += neighborLen;
				}
				offset += neighborLen;
			}
			for(0..6) |i| {
				const neighborLen = self.higherLodLens[i];
				if(isNeighborLod[i]) {
					list[i] = self.completeList[offset..][0..neighborLen];
					len += neighborLen;
				}
				offset += neighborLen;
			}
			const fullBuffer = try faceBuffer.allocateAndMapRange(len, &self.bufferAllocation);
			defer faceBuffer.unmapRange(fullBuffer);
			@memcpy(fullBuffer[0..self.coreLen], self.completeList[0..self.coreLen]);
			var i: usize = self.coreLen;
			for(0..6) |n| {
				@memcpy(fullBuffer[i..][0..list[n].len], list[n]);
				i += list[n].len;
			}
			self.vertexCount = @intCast(6*fullBuffer.len);
			self.wasChanged = true;
		}

		fn addFace(self: *PrimitiveMesh, faceData: FaceData, fromNeighborChunk: ?u3) !void {
			if(fromNeighborChunk) |neighbor| {
				try self.neighborFacesSameLod[neighbor].append(main.globalAllocator, faceData);
			} else {
				try self.coreFaces.append(main.globalAllocator, faceData);
			}
		}

		fn removeFace(self: *PrimitiveMesh, faceData: FaceData, fromNeighborChunk: ?u3) void {
			if(fromNeighborChunk) |neighbor| {
				var pos: usize = std.math.maxInt(usize);
				for(self.neighborFacesSameLod[neighbor].items, 0..) |item, i| {
					if(std.meta.eql(faceData, item)) {
						pos = i;
						break;
					}
				}
				_ = self.neighborFacesSameLod[neighbor].swapRemove(pos);
			} else {
				var pos: usize = std.math.maxInt(usize);
				for(self.coreFaces.items, 0..) |item, i| {
					if(std.meta.eql(faceData, item)) {
						pos = i;
						break;
					}
				}
				_ = self.coreFaces.swapRemove(pos);
			}
		}
	};

	pub const ChunkMesh = struct {
		const SortingData = struct {
			face: FaceData,
			distance: u32,
			isBackFace: bool,
			shouldBeCulled: bool,

			pub fn update(self: *SortingData, chunkDx: i32, chunkDy: i32, chunkDz: i32) void {
				const x: i32 = self.face.position.x;
				const y: i32 = self.face.position.y;
				const z: i32 = self.face.position.z;
				const dx = x + chunkDx;
				const dy = y + chunkDy;
				const dz = z + chunkDz;
				const normal = self.face.position.normal;
				self.isBackFace = self.face.position.isBackFace;
				switch(Neighbors.vectorComponent[normal]) {
					.x => {
						self.shouldBeCulled = (dx < 0) == (Neighbors.relX[normal] < 0);
						if(dx == 0) {
							self.shouldBeCulled = false;
						}
					},
					.y => {
						self.shouldBeCulled = (dy < 0) == (Neighbors.relY[normal] < 0);
						if(dy == 0) {
							self.shouldBeCulled = false;
						}
					},
					.z => {
						self.shouldBeCulled = (dz < 0) == (Neighbors.relZ[normal] < 0);
						if(dz == 0) {
							self.shouldBeCulled = false;
						}
					},
				}
				const fullDx = dx - Neighbors.relX[normal];
				const fullDy = dy - Neighbors.relY[normal];
				const fullDz = dz - Neighbors.relZ[normal];
				self.distance = @abs(fullDx) + @abs(fullDy) + @abs(fullDz);
			}
		};
		const BoundingRectToNeighborChunk = struct {
			min: Vec3i = @splat(std.math.maxInt(i32)),
			max: Vec3i = @splat(0),

			fn adjustToBlock(self: *BoundingRectToNeighborChunk, block: Block, pos: Vec3i, neighbor: u3) void {
				if(block.viewThrough()) {
					self.min = @min(self.min, pos);
					self.max = @max(self.max, pos + Neighbors.orthogonalComponents[neighbor]);
				}
			}
		};
		pos: ChunkPosition,
		size: i32,
		chunk: *Chunk,
		lightingData: *[6]lighting.ChannelChunk,
		opaqueMesh: PrimitiveMesh,
		transparentMesh: PrimitiveMesh,
		lastNeighborsSameLod: [6]?*const ChunkMesh = [_]?*const ChunkMesh{null} ** 6,
		lastNeighborsHigherLod: [6]?*const ChunkMesh = [_]?*const ChunkMesh{null} ** 6,
		isNeighborLod: [6]bool = .{false} ** 6,
		visibilityMask: u8 = 0xff,
		currentSorting: []SortingData = &.{},
		sortingOutputBuffer: []FaceData = &.{},
		culledSortingCount: u31 = 0,
		lastTransparentUpdatePos: Vec3i = Vec3i{0, 0, 0},
		refCount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
		needsLightRefresh: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
		needsMeshUpdate: bool = false,
		finishedMeshing: bool = false,
		mutex: std.Thread.Mutex = .{},

		chunkBorders: [6]BoundingRectToNeighborChunk = [1]BoundingRectToNeighborChunk{.{}} ** 6,

		pub fn init(self: *ChunkMesh, pos: ChunkPosition, chunk: *Chunk) !void {
			const lightingData = try main.globalAllocator.create([6]lighting.ChannelChunk);
			try lightingData[0].init(chunk, .sun_red);
			try lightingData[1].init(chunk, .sun_green);
			try lightingData[2].init(chunk, .sun_blue);
			try lightingData[3].init(chunk, .red);
			try lightingData[4].init(chunk, .green);
			try lightingData[5].init(chunk, .blue);
			self.* = ChunkMesh{
				.pos = pos,
				.size = chunkSize*pos.voxelSize,
				.opaqueMesh = .{},
				.transparentMesh = .{},
				.chunk = chunk,
				.lightingData = lightingData,
			};
		}

		pub fn deinit(self: *ChunkMesh) void {
			std.debug.assert(self.refCount.load(.Monotonic) == 0);
			self.opaqueMesh.deinit();
			self.transparentMesh.deinit();
			main.globalAllocator.free(self.currentSorting);
			main.globalAllocator.free(self.sortingOutputBuffer);
			main.globalAllocator.destroy(self.chunk);
			main.globalAllocator.destroy(self.lightingData);
		}

		pub fn increaseRefCount(self: *ChunkMesh) void {
			const prevVal = self.refCount.fetchAdd(1, .Monotonic);
			std.debug.assert(prevVal != 0);
		}

		/// In cases where it's not certain whether the thing was cleared already.
		pub fn tryIncreaseRefCount(self: *ChunkMesh) bool {
			var prevVal = self.refCount.load(.Monotonic);
			while(prevVal != 0) {
				prevVal = self.refCount.cmpxchgWeak(prevVal, prevVal + 1, .Monotonic, .Monotonic) orelse return true;
			}
			return false;
		}

		pub fn decreaseRefCount(self: *ChunkMesh) void {
			const prevVal = self.refCount.fetchSub(1, .Monotonic);
			std.debug.assert(prevVal != 0);
			if(prevVal == 1) {
				renderer.RenderStructure.addMeshToClearListAndDecreaseRefCount(self) catch @panic("Out of Memory");
			}
		}

		pub fn scheduleLightRefreshAndDecreaseRefCount(self: *ChunkMesh) !void {
			if(!self.needsLightRefresh.swap(true, .AcqRel)) {
				try LightRefreshTask.scheduleAndDecreaseRefCount(self);
			} else {
				self.decreaseRefCount();
			}
		}
		const LightRefreshTask = struct {
			mesh: *ChunkMesh,

			pub const vtable = main.utils.ThreadPool.VTable{
				.getPriority = @ptrCast(&getPriority),
				.isStillNeeded = @ptrCast(&isStillNeeded),
				.run = @ptrCast(&run),
				.clean = @ptrCast(&clean),
			};

			pub fn scheduleAndDecreaseRefCount(mesh: *ChunkMesh) !void {
				const task = try main.globalAllocator.create(LightRefreshTask);
				task.* = .{
					.mesh = mesh,
				};
				try main.threadPool.addTask(task, &vtable);
			}

			pub fn getPriority(_: *LightRefreshTask) f32 {
				return 1000000;
			}

			pub fn isStillNeeded(_: *LightRefreshTask) bool {
				return true; // TODO: Is it worth checking for this?
			}

			pub fn run(self: *LightRefreshTask) Allocator.Error!void {
				if(self.mesh.needsLightRefresh.swap(false, .AcqRel)) {
					self.mesh.mutex.lock();
					try self.mesh.finishData();
					self.mesh.mutex.unlock();
					try renderer.RenderStructure.addToUpdateListAndDecreaseRefCount(self.mesh);
				} else {
					self.mesh.decreaseRefCount();
				}
				main.globalAllocator.destroy(self);
			}

			pub fn clean(self: *LightRefreshTask) void {
				self.mesh.decreaseRefCount();
				main.globalAllocator.destroy(self);
			}
		};

		pub fn isEmpty(self: *const ChunkMesh) bool {
			return self.opaqueMesh.vertexCount == 0 and self.transparentMesh.vertexCount == 0;
		}

		fn canBeSeenThroughOtherBlock(block: Block, other: Block, neighbor: u3) bool {
			const rotatedModel = blocks.meshes.model(block);
			const model = &models.models.items[rotatedModel.modelIndex];
			const freestandingModel = rotatedModel.modelIndex != models.fullCube and switch(rotatedModel.permutation.permuteNeighborIndex(neighbor)) {
				Neighbors.dirNegX => model.min[0] != 0,
				Neighbors.dirPosX => model.max[0] != 16, // TODO: Use a bitfield inside the models or something like that.
				Neighbors.dirDown => model.min[1] != 0,
				Neighbors.dirUp => model.max[1] != 16,
				Neighbors.dirNegZ => model.min[2] != 0,
				Neighbors.dirPosZ => model.max[2] != 16,
				else => unreachable,
			};
			return block.typ != 0 and (
				freestandingModel
				or other.typ == 0
				or (!std.meta.eql(block, other) and other.viewThrough())
				or blocks.meshes.model(other).modelIndex != 0 // TODO: make this more strict to avoid overdraw.
			);
		}

		pub fn regenerateMainMesh(self: *ChunkMesh) !void {
			try renderer.RenderStructure.addMeshToStorage(self);
			self.mutex.lock();
			self.opaqueMesh.reset();
			self.transparentMesh.reset();
			var lightEmittingBlocks = std.ArrayList([3]u8).init(main.globalAllocator);
			defer lightEmittingBlocks.deinit();
			var n: u32 = 0;
			var x: u8 = 0;
			while(x < chunkSize): (x += 1) {
				var y: u8 = 0;
				while(y < chunkSize): (y += 1) {
					var z: u8 = 0;
					while(z < chunkSize): (z += 1) {
						const block = (&self.chunk.blocks)[getIndex(x, y, z)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
						if(block.light() != 0) try lightEmittingBlocks.append(.{x, y, z});
						if(block.typ == 0) continue;
						// Check all neighbors:
						for(Neighbors.iterable) |i| {
							n += 1;
							const x2 = x + Neighbors.relX[i];
							const y2 = y + Neighbors.relY[i];
							const z2 = z + Neighbors.relZ[i];
							if(x2&chunkMask != x2 or y2&chunkMask != y2 or z2&chunkMask != z2) continue; // Neighbor is outside the chunk.
							const neighborBlock = (&self.chunk.blocks)[getIndex(x2, y2, z2)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
							if(canBeSeenThroughOtherBlock(block, neighborBlock, i)) {
								if(block.transparent()) {
									if(block.hasBackFace()) {
										try self.transparentMesh.appendCore(constructFaceData(block, i ^ 1, x, y, z, true));
									}
									try self.transparentMesh.appendCore(constructFaceData(block, i, x2, y2, z2, false));
								} else {
									try self.opaqueMesh.appendCore(constructFaceData(block, i, x2, y2, z2, false)); // TODO: Create multiple faces for non-cube meshes.
								}
							}
						}
					}
				}
			}
			// Check out the borders:
			x = 0;
			while(x < chunkSize): (x += 1) {
				var y: u8 = 0;
				while(y < chunkSize): (y += 1) {
					self.chunkBorders[Neighbors.dirNegX].adjustToBlock((&self.chunk.blocks)[getIndex(0, x, y)], .{0, x, y}, Neighbors.dirNegX); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirPosX].adjustToBlock((&self.chunk.blocks)[getIndex(chunkSize-1, x, y)], .{chunkSize, x, y}, Neighbors.dirPosX); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirDown].adjustToBlock((&self.chunk.blocks)[getIndex(x, 0, y)], .{x, 0, y}, Neighbors.dirDown); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirUp].adjustToBlock((&self.chunk.blocks)[getIndex(x, chunkSize-1, y)], .{x, chunkSize, y}, Neighbors.dirUp); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirNegZ].adjustToBlock((&self.chunk.blocks)[getIndex(x, y, 0)], .{x, y, 0}, Neighbors.dirNegZ); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirPosZ].adjustToBlock((&self.chunk.blocks)[getIndex(x, y, chunkSize-1)], .{x, y, chunkSize}, Neighbors.dirPosZ); // TODO: Wait for the compiler bug to get fixed.
				}
			}
			self.mutex.unlock();
			for(self.lightingData[3..]) |*lightingData| {
				try lightingData.propagateLights(lightEmittingBlocks.items, true);
			}
			// TODO: Sunlight propagation
			try self.finishNeighbors(false);
		}

		fn addFace(self: *ChunkMesh, faceData: FaceData, fromNeighborChunk: ?u3, transparent: bool) !void {
			if(transparent) {
				try self.transparentMesh.addFace(faceData, fromNeighborChunk);
			} else {
				try self.opaqueMesh.addFace(faceData, fromNeighborChunk);
			}
		}

		fn removeFace(self: *ChunkMesh, faceData: FaceData, fromNeighborChunk: ?u3, transparent: bool) void {
			if(transparent) {
				self.transparentMesh.removeFace(faceData, fromNeighborChunk);
			} else {
				self.opaqueMesh.removeFace(faceData, fromNeighborChunk);
			}
		}

		pub fn updateBlock(self: *ChunkMesh, _x: i32, _y: i32, _z: i32, newBlock: Block) !void {
			self.mutex.lock();
			const x = _x & chunkMask;
			const y = _y & chunkMask;
			const z = _z & chunkMask;
			const oldBlock = self.chunk.blocks[getIndex(x, y, z)];
			self.chunk.blocks[getIndex(x, y, z)] = newBlock;
			self.mutex.unlock();
			if(newBlock.light() != 0) {
				for(self.lightingData[3..]) |*lightingData| {
					try lightingData.propagateLights(&.{.{@intCast(x), @intCast(y), @intCast(z)}}, true);
				}
			}
			self.mutex.lock();
			defer self.mutex.unlock();
			for(Neighbors.iterable) |neighbor| {
				var neighborMesh = self;
				var nx = x + Neighbors.relX[neighbor];
				var ny = y + Neighbors.relY[neighbor];
				var nz = z + Neighbors.relZ[neighbor];
				if(nx & chunkMask != nx or ny & chunkMask != ny or nz & chunkMask != nz) { // Outside this chunk.
					neighborMesh = renderer.RenderStructure.getNeighborFromRenderThread(self.pos, self.pos.voxelSize, neighbor) orelse continue;
				}
				if(neighborMesh != self) {
					self.mutex.unlock();
					deadlockFreeDoubleLock(&self.mutex, &neighborMesh.mutex);
				}
				defer if(neighborMesh != self) neighborMesh.mutex.unlock();
				nx &= chunkMask;
				ny &= chunkMask;
				nz &= chunkMask;
				const neighborBlock = neighborMesh.chunk.blocks[getIndex(nx, ny, nz)];
				{ // TODO: Batch all the changes and apply them in one go for more efficiency.
					{ // The face of the changed block
						const newVisibility = canBeSeenThroughOtherBlock(newBlock, neighborBlock, neighbor);
						const oldVisibility = canBeSeenThroughOtherBlock(oldBlock, neighborBlock, neighbor);
						if(oldVisibility) { // Removing the face
							const faceData = constructFaceData(oldBlock, neighbor, nx, ny, nz, false);
							if(neighborMesh == self) {
								self.removeFace(faceData, null, oldBlock.transparent());
							} else {
								neighborMesh.removeFace(faceData, neighbor ^ 1, oldBlock.transparent());
							}
							if(oldBlock.hasBackFace()) {
								const backFaceData = constructFaceData(oldBlock, neighbor ^ 1, x, y, z, true);
								if(neighborMesh == self) {
									self.removeFace(backFaceData, null, true);
								} else {
									self.removeFace(backFaceData, neighbor, true);
								}
							}
						}
						if(newVisibility) { // Adding the face
							const faceData = constructFaceData(newBlock, neighbor, nx, ny, nz, false);
							if(neighborMesh == self) {
								try self.addFace(faceData, null, newBlock.transparent());
							} else {
								try neighborMesh.addFace(faceData, neighbor ^ 1, newBlock.transparent());
							}
							if(newBlock.hasBackFace()) {
								const backFaceData = constructFaceData(newBlock, neighbor ^ 1, x, y, z, true);
								if(neighborMesh == self) {
									try self.addFace(backFaceData, null, true);
								} else {
									try self.addFace(backFaceData, neighbor, true);
								}
							}
						}
					}
					{ // The face of the neighbor block
						const newVisibility = canBeSeenThroughOtherBlock(neighborBlock, newBlock, neighbor ^ 1);
						if(canBeSeenThroughOtherBlock(neighborBlock, oldBlock, neighbor ^ 1) != newVisibility) {
							if(newVisibility) { // Adding the face
								const faceData = constructFaceData(neighborBlock, neighbor ^ 1, x, y, z, false);
								if(neighborMesh == self) {
									try self.addFace(faceData, null, neighborBlock.transparent());
								} else {
									try self.addFace(faceData, neighbor, neighborBlock.transparent());
								}
								if(neighborBlock.hasBackFace()) {
									const backFaceData = constructFaceData(neighborBlock, neighbor, nx, ny, nz, true);
									if(neighborMesh == self) {
										try self.addFace(backFaceData, null, true);
									} else {
										try neighborMesh.addFace(backFaceData, neighbor ^ 1, true);
									}
								}
							} else { // Removing the face
								const faceData = constructFaceData(neighborBlock, neighbor ^ 1, x, y, z, false);
								if(neighborMesh == self) {
									self.removeFace(faceData, null, neighborBlock.transparent());
								} else {
									self.removeFace(faceData, neighbor, neighborBlock.transparent());
								}
								if(neighborBlock.hasBackFace()) {
									const backFaceData = constructFaceData(neighborBlock, neighbor, nx, ny, nz, true);
									if(neighborMesh == self) {
										self.removeFace(backFaceData, null, true);
									} else {
										neighborMesh.removeFace(backFaceData, neighbor ^ 1, true);
									}
								}
							}
						}
					}
				}
				if(neighborMesh != self) {
					_ = neighborMesh.needsLightRefresh.swap(false, .AcqRel);
					try neighborMesh.finishData();
					try neighborMesh.uploadData();
				}
			}
			_ = self.needsLightRefresh.swap(false, .AcqRel);
			try self.finishData();
			try self.uploadData();
		}

		pub inline fn constructFaceData(block: Block, normal: u3, x: i32, y: i32, z: i32, comptime backFace: bool) FaceData {
			const model = blocks.meshes.model(block);
			return FaceData {
				.position = .{.x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .normal = normal, .permutation = model.permutation.toInt(), .isBackFace = backFace},
				.blockAndModel = .{.typ = block.typ, .modelIndex = model.modelIndex},
			};
		}

		fn clearNeighbor(self: *ChunkMesh, neighbor: u3, comptime isLod: bool) void {
			self.opaqueMesh.clearNeighbor(neighbor, isLod);
			self.transparentMesh.clearNeighbor(neighbor, isLod);
		}

		pub fn finishData(self: *ChunkMesh) !void {
			std.debug.assert(!self.mutex.tryLock());
			try self.opaqueMesh.finish(self);
			try self.transparentMesh.finish(self);
		}

		pub fn uploadData(self: *ChunkMesh) !void {
			try self.opaqueMesh.uploadData(self.isNeighborLod);
			try self.transparentMesh.uploadData(self.isNeighborLod);
		}

		pub fn changeLodBorders(self: *ChunkMesh, isNeighborLod: [6]bool) !void {
			if(!std.meta.eql(isNeighborLod, self.isNeighborLod)) {
				self.isNeighborLod = isNeighborLod;
				try self.uploadData();
			}
		}

		fn deadlockFreeDoubleLock(m1: *std.Thread.Mutex, m2: *std.Thread.Mutex) void {
			if(@intFromPtr(m1) < @intFromPtr(m2)) {
				m1.lock();
				m2.lock();
			} else {
				m2.lock();
				m1.lock();
			}
		}

		fn finishNeighbors(self: *ChunkMesh, comptime inRenderThread: bool) !void {
			const getNeighborMesh: fn(ChunkPosition, u31, u3) ?*ChunkMesh = if(inRenderThread) renderer.RenderStructure.getNeighborFromRenderThread else renderer.RenderStructure.getNeighborAndIncreaseRefCount;
			for(Neighbors.iterable) |neighbor| {
				const nullNeighborMesh = getNeighborMesh(self.pos, self.pos.voxelSize, neighbor);
				if(nullNeighborMesh) |neighborMesh| sameLodBlock: {
					defer if(!inRenderThread) neighborMesh.decreaseRefCount();
					std.debug.assert(neighborMesh != self);
					deadlockFreeDoubleLock(&self.mutex, &neighborMesh.mutex);
					defer self.mutex.unlock();
					defer neighborMesh.mutex.unlock();
					if(self.lastNeighborsSameLod[neighbor] == neighborMesh) break :sameLodBlock;
					self.lastNeighborsSameLod[neighbor] = neighborMesh;
					neighborMesh.lastNeighborsSameLod[neighbor ^ 1] = self;
					self.clearNeighbor(neighbor, false);
					neighborMesh.clearNeighbor(neighbor ^ 1, false);
					const x3: i32 = if(neighbor & 1 == 0) chunkMask else 0;
					var x1: i32 = 0;
					while(x1 < chunkSize): (x1 += 1) {
						var x2: i32 = 0;
						while(x2 < chunkSize): (x2 += 1) {
							var x: i32 = undefined;
							var y: i32 = undefined;
							var z: i32 = undefined;
							if(Neighbors.relX[neighbor] != 0) {
								x = x3;
								y = x1;
								z = x2;
							} else if(Neighbors.relY[neighbor] != 0) {
								x = x1;
								y = x3;
								z = x2;
							} else {
								x = x2;
								y = x1;
								z = x3;
							}
							const otherX = x+%Neighbors.relX[neighbor] & chunkMask;
							const otherY = y+%Neighbors.relY[neighbor] & chunkMask;
							const otherZ = z+%Neighbors.relZ[neighbor] & chunkMask;
							const block = (&self.chunk.blocks)[getIndex(x, y, z)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
							const otherBlock = (&neighborMesh.chunk.blocks)[getIndex(otherX, otherY, otherZ)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
							if(canBeSeenThroughOtherBlock(block, otherBlock, neighbor)) {
								if(block.transparent()) {
									if(block.hasBackFace()) {
										try self.transparentMesh.appendNeighbor(constructFaceData(block, neighbor ^ 1, x, y, z, true), neighbor, false);
									}
									try neighborMesh.transparentMesh.appendNeighbor(constructFaceData(block, neighbor, otherX, otherY, otherZ, false), neighbor ^ 1, false);
								} else {
									try neighborMesh.opaqueMesh.appendNeighbor(constructFaceData(block, neighbor, otherX, otherY, otherZ, false), neighbor ^ 1, false);
								}
							}
							if(canBeSeenThroughOtherBlock(otherBlock, block, neighbor ^ 1)) {
								if(otherBlock.transparent()) {
									if(otherBlock.hasBackFace()) {
										try neighborMesh.transparentMesh.appendNeighbor(constructFaceData(otherBlock, neighbor, otherX, otherY, otherZ, true), neighbor ^ 1, false);
									}
									try self.transparentMesh.appendNeighbor(constructFaceData(otherBlock, neighbor ^ 1, x, y, z, false), neighbor, false);
								} else {
									try self.opaqueMesh.appendNeighbor(constructFaceData(otherBlock, neighbor ^ 1, x, y, z, false), neighbor, false);
								}
							}
						}
					}
					_ = neighborMesh.needsLightRefresh.swap(false, .AcqRel);
					try neighborMesh.finishData();
					if(inRenderThread) {
						try neighborMesh.uploadData();
					} else {
						neighborMesh.increaseRefCount();
						try renderer.RenderStructure.addToUpdateListAndDecreaseRefCount(neighborMesh);
					}
				} else {
					self.mutex.lock();
					defer self.mutex.unlock();
					if(self.lastNeighborsSameLod[neighbor] != null) {
						self.clearNeighbor(neighbor, false);
						self.lastNeighborsSameLod[neighbor] = null;
					}
				}
				// lod border:
				if(self.pos.voxelSize == 1 << settings.highestLOD) continue;
				const neighborMesh = getNeighborMesh(self.pos, 2*self.pos.voxelSize, neighbor) orelse {
					self.mutex.lock();
					defer self.mutex.unlock();
					if(self.lastNeighborsHigherLod[neighbor] != null) {
						self.clearNeighbor(neighbor, true);
						self.lastNeighborsHigherLod[neighbor] = null;
					}
					continue;
				};
				deadlockFreeDoubleLock(&self.mutex, &neighborMesh.mutex);
				defer self.mutex.unlock();
				defer neighborMesh.mutex.unlock();
				defer if(!inRenderThread) neighborMesh.decreaseRefCount();
				if(self.lastNeighborsHigherLod[neighbor] == neighborMesh) continue;
				self.lastNeighborsHigherLod[neighbor] = neighborMesh;
				self.clearNeighbor(neighbor, true);
				const x3: i32 = if(neighbor & 1 == 0) chunkMask else 0;
				const offsetX = @divExact(self.pos.wx, self.pos.voxelSize) & chunkSize;
				const offsetY = @divExact(self.pos.wy, self.pos.voxelSize) & chunkSize;
				const offsetZ = @divExact(self.pos.wz, self.pos.voxelSize) & chunkSize;
				var x1: i32 = 0;
				while(x1 < chunkSize): (x1 += 1) {
					var x2: i32 = 0;
					while(x2 < chunkSize): (x2 += 1) {
						var x: i32 = undefined;
						var y: i32 = undefined;
						var z: i32 = undefined;
						if(Neighbors.relX[neighbor] != 0) {
							x = x3;
							y = x1;
							z = x2;
						} else if(Neighbors.relY[neighbor] != 0) {
							x = x1;
							y = x3;
							z = x2;
						} else {
							x = x2;
							y = x1;
							z = x3;
						}
						const otherX = (x+%Neighbors.relX[neighbor]+%offsetX >> 1) & chunkMask;
						const otherY = (y+%Neighbors.relY[neighbor]+%offsetY >> 1) & chunkMask;
						const otherZ = (z+%Neighbors.relZ[neighbor]+%offsetZ >> 1) & chunkMask;
						const block = (&self.chunk.blocks)[getIndex(x, y, z)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
						const otherBlock = (&neighborMesh.chunk.blocks)[getIndex(otherX, otherY, otherZ)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
						if(canBeSeenThroughOtherBlock(otherBlock, block, neighbor ^ 1)) {
							if(otherBlock.transparent()) {
								try self.transparentMesh.appendNeighbor(constructFaceData(otherBlock, neighbor ^ 1, x, y, z, false), neighbor, true);
							} else {
								try self.opaqueMesh.appendNeighbor(constructFaceData(otherBlock, neighbor ^ 1, x, y, z, false), neighbor, true);
							}
						}
						if(block.hasBackFace()) {
							if(canBeSeenThroughOtherBlock(block, otherBlock, neighbor)) {
								try self.transparentMesh.appendNeighbor(constructFaceData(block, neighbor ^ 1, x, y, z, true), neighbor, true);
							}
						}
					}
				}
			}
			self.mutex.lock();
			defer self.mutex.unlock();
			_ = self.needsLightRefresh.swap(false, .AcqRel);
			try self.finishData();
		}

		pub fn render(self: *ChunkMesh, playerPosition: Vec3d) void {
			if(self.opaqueMesh.vertexCount == 0) return;
			c.glUniform3f(
				uniforms.modelPosition,
				@floatCast(@as(f64, @floatFromInt(self.pos.wx)) - playerPosition[0]),
				@floatCast(@as(f64, @floatFromInt(self.pos.wy)) - playerPosition[1]),
				@floatCast(@as(f64, @floatFromInt(self.pos.wz)) - playerPosition[2])
			);
			c.glUniform1i(uniforms.visibilityMask, self.visibilityMask);
			c.glUniform1i(uniforms.voxelSize, self.pos.voxelSize);
			quadsDrawn += self.opaqueMesh.vertexCount/6;
			c.glDrawElementsBaseVertex(c.GL_TRIANGLES, self.opaqueMesh.vertexCount, c.GL_UNSIGNED_INT, null, self.opaqueMesh.bufferAllocation.start*4);
		}

		pub fn renderTransparent(self: *ChunkMesh, playerPosition: Vec3d) !void {
			if(self.transparentMesh.vertexCount == 0) return;

			var needsUpdate: bool = false;
			if(self.transparentMesh.wasChanged) {
				self.transparentMesh.wasChanged = false;
				self.transparentMesh.mutex.lock();
				defer self.transparentMesh.mutex.unlock();
				var len: usize = self.transparentMesh.coreLen;
				var offset: usize = self.transparentMesh.coreLen;
				var list: [6][]FaceData = undefined;
				for(0..6) |i| {
					const neighborLen = self.transparentMesh.sameLodLens[i];
					if(!self.isNeighborLod[i]) {
						list[i] = self.transparentMesh.completeList[offset..][0..neighborLen];
						len += neighborLen;
					}
					offset += neighborLen;
				}
				for(0..6) |i| {
					const neighborLen = self.transparentMesh.higherLodLens[i];
					if(self.isNeighborLod[i]) {
						list[i] = self.transparentMesh.completeList[offset..][0..neighborLen];
						len += neighborLen;
					}
					offset += neighborLen;
				}
				self.sortingOutputBuffer = try main.globalAllocator.realloc(self.sortingOutputBuffer, len);
				self.currentSorting = try main.globalAllocator.realloc(self.currentSorting, len);
				for(0..self.transparentMesh.coreLen) |i| {
					self.currentSorting[i].face = self.transparentMesh.completeList[i];
				}
				offset = self.transparentMesh.coreLen;
				for(0..6) |n| {
					for(0..list[n].len) |i| {
						self.currentSorting[offset + i].face = list[n][i];
					}
					offset += list[n].len;
				}

				needsUpdate = true;
			}

			var relativePos = Vec3d {
				@as(f64, @floatFromInt(self.pos.wx)) - playerPosition[0],
				@as(f64, @floatFromInt(self.pos.wy)) - playerPosition[1],
				@as(f64, @floatFromInt(self.pos.wz)) - playerPosition[2]
			}/@as(Vec3d, @splat(@as(f64, @floatFromInt(self.pos.voxelSize))));
			relativePos = @min(relativePos, @as(Vec3d, @splat(0)));
			relativePos = @max(relativePos, @as(Vec3d, @splat(-32)));
			const updatePos: Vec3i = @intFromFloat(relativePos);
			if(@reduce(.Or, updatePos != self.lastTransparentUpdatePos)) {
				self.lastTransparentUpdatePos = updatePos;
				needsUpdate = true;
			}
			if(needsUpdate) {
				for(self.currentSorting) |*val| {
					val.update(
						updatePos[0],
						updatePos[1],
						updatePos[2],
					);
				}

				// Sort by back vs front face:
				{
					var backFaceStart: usize = 0;
					var i: usize = 0;
					var culledStart: usize = self.currentSorting.len;
					while(culledStart > 0) {
						if(!self.currentSorting[culledStart-1].shouldBeCulled) {
							break;
						}
						culledStart -= 1;
					}
					while(i < culledStart): (i += 1) {
						if(self.currentSorting[i].shouldBeCulled) {
							culledStart -= 1;
							std.mem.swap(SortingData, &self.currentSorting[i], &self.currentSorting[culledStart]);
							while(culledStart > 0) {
								if(!self.currentSorting[culledStart-1].shouldBeCulled) {
									break;
								}
								culledStart -= 1;
							}
						}
						if(!self.currentSorting[i].isBackFace) {
							std.mem.swap(SortingData, &self.currentSorting[i], &self.currentSorting[backFaceStart]);
							backFaceStart += 1;
						}
					}
					self.culledSortingCount = @intCast(culledStart);
				}

				// Sort it using bucket sort:
				var buckets: [34*3]u32 = undefined;
				@memset(&buckets, 0);
				for(self.currentSorting[0..self.culledSortingCount]) |val| {
					buckets[34*3 - 1 - val.distance] += 1;
				}
				var prefixSum: u32 = 0;
				for(&buckets) |*val| {
					const copy = val.*;
					val.* = prefixSum;
					prefixSum += copy;
				}
				// Move it over into a new buffer:
				for(0..self.culledSortingCount) |i| {
					const bucket = 34*3 - 1 - self.currentSorting[i].distance;
					self.sortingOutputBuffer[buckets[bucket]] = self.currentSorting[i].face;
					buckets[bucket] += 1;
				}

				// Upload:
				try faceBuffer.uploadData(self.sortingOutputBuffer[0..self.culledSortingCount], &self.transparentMesh.bufferAllocation);
			}

			c.glUniform3f(
				transparentUniforms.modelPosition,
				@floatCast(@as(f64, @floatFromInt(self.pos.wx)) - playerPosition[0]),
				@floatCast(@as(f64, @floatFromInt(self.pos.wy)) - playerPosition[1]),
				@floatCast(@as(f64, @floatFromInt(self.pos.wz)) - playerPosition[2])
			);
			c.glUniform1i(transparentUniforms.visibilityMask, self.visibilityMask);
			c.glUniform1i(transparentUniforms.voxelSize, self.pos.voxelSize);
			transparentQuadsDrawn += self.culledSortingCount;
			c.glDrawElementsBaseVertex(c.GL_TRIANGLES, self.culledSortingCount*6, c.GL_UNSIGNED_INT, null, self.transparentMesh.bufferAllocation.start*4);
		}
	};
};