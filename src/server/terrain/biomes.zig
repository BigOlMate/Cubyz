const std = @import("std");
const Allocator = std.mem.Allocator;

const main = @import("root");
const blocks = main.blocks;
const Chunk = main.chunk.Chunk;
const JsonElement = main.JsonElement;
const terrain = main.server.terrain;

const StructureModel = struct {
	const VTable = struct {
		loadModel: *const fn(arenaAllocator: Allocator, parameters: JsonElement) Allocator.Error!*anyopaque,
		generate: *const fn(self: *anyopaque, x: i32, y: i32, z: i32, chunk: *Chunk, caveMap: terrain.CaveMap.CaveMapView, seed: *u64) Allocator.Error!void,
	};

	vtable: VTable,
	data: *anyopaque,
	chance: f32,

	pub fn initModel(parameters: JsonElement) !?StructureModel {
		const id = parameters.get([]const u8, "id", "");
		const vtable = modelRegistry.get(id) orelse {
			std.log.err("Couldn't find structure model with id {s}", .{id});
			return null;
		};
		return StructureModel {
			.vtable = vtable,
			.data = try vtable.loadModel(arena.allocator(), parameters),
			.chance = parameters.get(f32, "chance", 0.5),
		};
	}

	pub fn generate(self: StructureModel, x: i32, y: i32, z: i32, chunk: *Chunk, caveMap: terrain.CaveMap.CaveMapView, seed: *u64) Allocator.Error!void {
		try self.vtable.generate(self.data, x, y, z, chunk, caveMap, seed);
	}


	var modelRegistry: std.StringHashMapUnmanaged(VTable) = .{};
	var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(main.globalAllocator);

	pub fn reset() void {
		std.debug.assert(arena.reset(.free_all));
	}

	pub fn registerGenerator(comptime Generator: type) !void {
		var self: VTable = undefined;
		self.loadModel = @ptrCast(&Generator.loadModel);
		self.generate = @ptrCast(&Generator.generate);
		try modelRegistry.put(main.globalAllocator, Generator.id, self);
	}
};


pub const Interpolation = enum(u8) {
	none,
	linear,
	square,
};

/// A climate region with special ground, plants and structures.
pub const Biome = struct {
	const GenerationProperties = packed struct(u8) {
		// pairs of opposite properties. In-between values are allowed.
		hot: bool = false,
		cold: bool = false,

		inland: bool = false,
		ocean: bool = false,

		wet: bool = false,
		dry: bool = false,

		mountain: bool = false,
		antiMountain: bool = false, //???

		pub fn fromJson(json: JsonElement) GenerationProperties {
			var result: GenerationProperties = .{};
			for(json.toSlice()) |child| {
				const property = child.as([]const u8, "");
				inline for(@typeInfo(GenerationProperties).Struct.fields) |field| {
					if(std.mem.eql(u8, field.name, property)) {
						@field(result, field.name) = true;
					}
				}
			}
			return result;
		}
	};

	properties: GenerationProperties,
	isCave: bool,
	radius: f32,
	minHeight: i32,
	maxHeight: i32,
	interpolation: Interpolation,
	roughness: f32,
	hills: f32,
	mountains: f32,
	caves: f32,
	crystals: u32,
	stoneBlockType: u16,
	id: []const u8,
	structure: BlockStructure = undefined,
	/// Whether the starting point of a river can be in this biome. If false rivers will be able to flow through this biome anyways.
	supportsRivers: bool, // TODO: Reimplement rivers.
	/// The first members in this array will get prioritized.
	vegetationModels: []StructureModel = &.{},
	subBiomes: main.utils.AliasTable(*const Biome) = undefined,
	maxSubBiomeCount: f32,
	subBiomeTotalChance: f32 = 0,
	preferredMusic: []const u8, // TODO: Support multiple possibilities that are chosen based on time and danger.
	isValidPlayerSpawn: bool,
	chance: f32,

	pub fn init(self: *Biome, id: []const u8, json: JsonElement) !void {
		self.* = Biome {
			.id = try main.globalAllocator.dupe(u8, id),
			.properties = GenerationProperties.fromJson(json.getChild("properties")),
			.isCave = json.get(bool, "isCave", false),
			.radius = json.get(f32, "radius", 256),
			.stoneBlockType = blocks.getByID(json.get([]const u8, "stoneBlock", "cubyz:stone")),
			.roughness = json.get(f32, "roughness", 0),
			.hills = json.get(f32, "hills", 0),
			.mountains = json.get(f32, "mountains", 0),
			.interpolation = std.meta.stringToEnum(Interpolation, json.get([]const u8, "interpolation", "square")) orelse .square,
			.caves = json.get(f32, "caves", -0.375),
			.crystals = json.get(u32, "crystals", 0),
			.minHeight = json.get(i32, "minHeight", std.math.minInt(i32)),
			.maxHeight = json.get(i32, "maxHeight", std.math.maxInt(i32)),
			.supportsRivers = json.get(bool, "rivers", false),
			.preferredMusic = try main.globalAllocator.dupe(u8, json.get([]const u8, "music", "")),
			.isValidPlayerSpawn = json.get(bool, "validPlayerSpawn", false),
			.chance = json.get(f32, "chance", 1),
			.maxSubBiomeCount = json.get(f32, "maxSubBiomeCount", std.math.floatMax(f32)),
		};
		if(self.minHeight > self.maxHeight) {
			std.log.warn("Biome {s} has invalid height range ({}, {})", .{self.id, self.minHeight, self.maxHeight});
		}
		const parentBiomeList = json.getChild("parentBiomes");
		for(parentBiomeList.toSlice()) |parent| {
			const result = try unfinishedSubBiomes.getOrPutValue(main.globalAllocator, parent.get([]const u8, "id", ""), .{});
			try result.value_ptr.append(main.globalAllocator, .{.biomeId = self.id, .chance = parent.get(f32, "chance", 1)});
		}

		self.structure = try BlockStructure.init(main.globalAllocator, json.getChild("ground_structure"));
		
		const structures = json.getChild("structures");
		var vegetation = std.ArrayListUnmanaged(StructureModel){};
		defer vegetation.deinit(main.globalAllocator);
		for(structures.toSlice()) |elem| {
			if(try StructureModel.initModel(elem)) |model| {
				try vegetation.append(main.globalAllocator, model);
			}
		}
		self.vegetationModels = try main.globalAllocator.dupe(StructureModel, vegetation.items);
	}

	pub fn deinit(self: *Biome) void {
		self.subBiomes.deinit(main.globalAllocator);
		self.structure.deinit(main.globalAllocator);
		main.globalAllocator.free(self.vegetationModels);
		main.globalAllocator.free(self.preferredMusic);
		main.globalAllocator.free(self.id);
	}
};

/// Stores the vertical ground structure of a biome from top to bottom.
pub const BlockStructure = struct {
	pub const BlockStack = struct {
		blockType: u16 = 0,
		min: u31 = 0,
		max: u31 = 0,

		fn init(self: *BlockStack, string: []const u8) !void {
			var tokenIt = std.mem.tokenize(u8, string, &std.ascii.whitespace);
			const first = tokenIt.next() orelse return error.@"String is empty.";
			var blockId: []const u8 = first;
			if(tokenIt.next()) |second| {
				self.min = try std.fmt.parseInt(u31, first, 0);
				if(tokenIt.next()) |third| {
					const fourth = tokenIt.next() orelse return error.@"Expected 1, 2 or 4 parameters, found 3.";
					if(!std.mem.eql(u8, second, "to")) return error.@"Expected layout '<min> to <max> <block>'. Missing 'to'.";
					self.max = try std.fmt.parseInt(u31, third, 0);
					blockId = fourth;
					if(tokenIt.next() != null) return error.@"Found too many parameters. Expected 1, 2 or 4.";
					if(self.max < self.min) return error.@"The max value must be bigger than the min value.";
				} else {
					self.max = self.min;
					blockId = second;
				}
			} else {
				self.min = 1;
				self.max = 1;
			}
			self.blockType = blocks.getByID(blockId);
		}
	};
	structure: []BlockStack,

	pub fn init(allocator: Allocator, jsonArray: JsonElement) !BlockStructure {
		const blockStackDescriptions = jsonArray.toSlice();
		const self = BlockStructure {
			.structure = try allocator.alloc(BlockStack, blockStackDescriptions.len),
		};
		for(blockStackDescriptions, self.structure) |jsonString, *blockStack| {
			blockStack.init(jsonString.as([]const u8, "That's not a json string.")) catch |err| {
				std.log.warn("Couldn't parse blockStack '{s}': {s} Removing it.", .{jsonString.as([]const u8, "That's not a json string."), @errorName(err)});
				blockStack.* = .{};
			};
		}
		return self;
	}

	pub fn deinit(self: BlockStructure, allocator: Allocator) void {
		allocator.free(self.structure);
	}

	pub fn addSubTerranian(self: BlockStructure, chunk: *Chunk, startingDepth: i32, minDepth: i32, x: i32, z: i32, seed: *u64) i32 {
		var depth = startingDepth;
		for(self.structure) |blockStack| {
			const total = blockStack.min + main.random.nextIntBounded(u32, seed, @as(u32, 1) + blockStack.max - blockStack.min);
			for(0..total) |_| {
				const block = blocks.Block{.typ = blockStack.blockType, .data = undefined};
				// TODO: block = block.mode().getNaturalStandard(block);
				if(chunk.liesInChunk(x, depth, z)) {
					chunk.updateBlockInGeneration(x, depth, z, block);
				}
				depth -%= chunk.pos.voxelSize;
				if(depth -% minDepth <= 0)
					return depth +% chunk.pos.voxelSize;
			}
		}
		return depth +% chunk.pos.voxelSize;
	}
};

pub const TreeNode = union(enum) {
	leaf: struct {
		totalChance: f64 = 0,
		aliasTable: main.utils.AliasTable(Biome) = undefined,
	},
	branch: struct {
		amplitude: f32,
		lowerBorder: f32,
		upperBorder: f32,
		children: [3]*TreeNode,
	},

	pub fn init(allocator: Allocator, currentSlice: []Biome, parameterShift: u5) !*TreeNode {
		const self = try allocator.create(TreeNode);
		if(currentSlice.len <= 1 or parameterShift >= @bitSizeOf(Biome.GenerationProperties)) {
			self.* = .{.leaf = .{}};
			for(currentSlice) |biome| {
				self.leaf.totalChance += biome.chance;
			}
			self.leaf.aliasTable = try main.utils.AliasTable(Biome).init(allocator, currentSlice);
			return self;
		}
		var chanceLower: f32 = 0;
		var chanceMiddle: f32 = 0;
		var chanceUpper: f32 = 0;
		for(currentSlice) |*biome| {
			var properties: u32 = @as(u8, @bitCast(biome.properties));
			properties >>= parameterShift;
			properties = properties & 3;
			if(properties == 0) {
				chanceMiddle += biome.chance;
			} else if(properties == 1) {
				chanceLower += biome.chance;
			} else if(properties == 2) {
				chanceUpper += biome.chance;
			} else unreachable;
		}
		const totalChance = chanceLower + chanceMiddle + chanceUpper;
		chanceLower /= totalChance;
		chanceMiddle /= totalChance;
		chanceUpper /= totalChance;

		self.* = .{
			.branch = .{
				.amplitude = 1024, // TODO!
				.lowerBorder = terrain.noise.ValueNoise.percentile(chanceLower),
				.upperBorder = terrain.noise.ValueNoise.percentile(chanceLower + chanceMiddle),
				.children = undefined,
			}
		};

		// Partition the slice:
		var lowerIndex: usize = 0;
		var upperIndex: usize = currentSlice.len - 1;
		var i: usize = 0;
		while(i <= upperIndex) {
			var properties: u32 = @as(u8, @bitCast(currentSlice[i].properties));
			properties >>= parameterShift;
			properties = properties & 3;
			if(properties == 0 or properties == 3) {
				i += 1;
			} else if(properties == 1) {
				const swap = currentSlice[i];
				currentSlice[i] = currentSlice[lowerIndex];
				currentSlice[lowerIndex] = swap;
				i += 1;
				lowerIndex += 1;
			} else if(properties == 2) {
				const swap = currentSlice[i];
				currentSlice[i] = currentSlice[upperIndex];
				currentSlice[upperIndex] = swap;
				upperIndex -= 1;
			} else unreachable;
		}

		self.branch.children[0] = try TreeNode.init(allocator, currentSlice[0..lowerIndex], parameterShift+2);
		self.branch.children[1] = try TreeNode.init(allocator, currentSlice[lowerIndex..upperIndex+1], parameterShift+2);
		self.branch.children[2] = try TreeNode.init(allocator, currentSlice[upperIndex+1..], parameterShift+2);

		return self;
	}

	pub fn deinit(self: *TreeNode, allocator: Allocator) void {
		switch(self.*) {
			.leaf => |leaf| {
				leaf.aliasTable.deinit(allocator);
			},
			.branch => |branch| {
				for(branch.children) |child| {
					child.deinit(allocator);
				}
			}
		}
		allocator.destroy(self);
	}

	pub fn getBiome(self: *const TreeNode, seed: *u64, x: f32, y: f32) *const Biome {
		switch(self.*) {
			.leaf => |leaf| {
				var biomeSeed = main.random.initSeed2D(seed.*, main.vec.Vec2i{@intFromFloat(x), @intFromFloat(y)});
				const result = leaf.aliasTable.sample(&biomeSeed);
				return result;
			},
			.branch => |branch| {
				const value = terrain.noise.ValueNoise.samplePoint2D(x/branch.amplitude, y/branch.amplitude, main.random.nextInt(u32, seed));
				var index: u2 = 0;
				if(value >= branch.lowerBorder) {
					if(value >= branch.upperBorder) {
						index = 2;
					} else {
						index = 1;
					}
				}
				return branch.children[index].getBiome(seed, x, y);
			}
		}
	}
};

var finishedLoading: bool = false;
var biomes: std.ArrayList(Biome) = undefined;
var caveBiomes: std.ArrayList(Biome) = undefined;
var biomesById: std.StringHashMap(*Biome) = undefined;
pub var byTypeBiomes: *TreeNode = undefined;
const UnfinishedSubBiomeData = struct {
	biomeId: []const u8,
	chance: f32,
	pub fn getItem(self: UnfinishedSubBiomeData) *const Biome {
		return getById(self.biomeId);
	}
};
var unfinishedSubBiomes: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(UnfinishedSubBiomeData)) = .{};

pub fn init() !void {
	biomes = std.ArrayList(Biome).init(main.globalAllocator);
	caveBiomes = std.ArrayList(Biome).init(main.globalAllocator);
	biomesById = std.StringHashMap(*Biome).init(main.globalAllocator);
	const list = @import("structures/_list.zig");
	inline for(@typeInfo(list).Struct.decls) |decl| {
		try StructureModel.registerGenerator(@field(list, decl.name));
	}
}

pub fn reset() void {
	StructureModel.reset();
	finishedLoading = false;
	for(biomes.items) |*biome| {
		biome.deinit();
	}
	for(caveBiomes.items) |*biome| {
		biome.deinit();
	}
	biomes.clearRetainingCapacity();
	caveBiomes.clearRetainingCapacity();
	biomesById.clearRetainingCapacity();
	byTypeBiomes.deinit(main.globalAllocator);
}

pub fn deinit() void {
	for(biomes.items) |*biome| {
		biome.deinit();
	}
	biomes.deinit();
	caveBiomes.deinit();
	biomesById.deinit();
	// TODO? byTypeBiomes.deinit(main.globalAllocator);
	StructureModel.modelRegistry.clearAndFree(main.globalAllocator);
}

pub fn register(id: []const u8, json: JsonElement) !void {
	std.log.debug("Registered biome: {s}", .{id});
	std.debug.assert(!finishedLoading);
	var biome: Biome = undefined;
	try biome.init(id, json);
	if(biome.isCave) {
		try caveBiomes.append(biome);
	} else {
		try biomes.append(biome);
	}
}

pub fn finishLoading() !void {
	std.debug.assert(!finishedLoading);
	finishedLoading = true;
	// Sort the biomes by id, so they have a deterministic order when randomly sampling them based on the seed:
	std.mem.sortUnstable(Biome, biomes.items, {}, struct {fn lessThan(_: void, lhs: Biome, rhs: Biome) bool {
		return std.mem.order(u8, lhs.id, rhs.id) == .lt;
	}}.lessThan);
	byTypeBiomes = try TreeNode.init(main.globalAllocator, biomes.items, 0);
	for(biomes.items) |*biome| {
		try biomesById.put(biome.id, biome);
	}
	for(caveBiomes.items) |*biome| {
		try biomesById.put(biome.id, biome);
	}
	var subBiomeIterator = unfinishedSubBiomes.iterator();
	while(subBiomeIterator.next()) |subBiomeData| {
		const parentBiome = biomesById.get(subBiomeData.key_ptr.*) orelse {
			std.log.warn("Couldn't find biome with id {s}. Cannot add sub-biomes.", .{subBiomeData.key_ptr.*});
			continue;
		};
		const subBiomeDataList = subBiomeData.value_ptr;
		for(subBiomeDataList.items) |item| {
			parentBiome.subBiomeTotalChance += item.chance;
		}
		parentBiome.subBiomes = try main.utils.AliasTable(*const Biome).initFromContext(main.globalAllocator, subBiomeDataList.items);
		subBiomeDataList.deinit(main.globalAllocator);
	}
	unfinishedSubBiomes.clearAndFree(main.globalAllocator);
}

pub fn getById(id: []const u8) *const Biome {
	std.debug.assert(finishedLoading);
	return biomesById.get(id) orelse {
		std.log.warn("Couldn't find biome with id {s}. Replacing it with some other biome.", .{id});
		return &biomes.items[0];
	};
}

pub fn getRandomly(typ: Biome.Type, seed: *u64) *const Biome {
	return byTypeBiomes[@intFromEnum(typ)].getRandomly(seed);
}

pub fn getCaveBiomes() []const Biome {
	return caveBiomes.items;
}