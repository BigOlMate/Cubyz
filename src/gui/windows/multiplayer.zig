const std = @import("std");
const Allocator = std.mem.Allocator;

const main = @import("root");
const ConnectionManager = main.network.ConnectionManager;
const settings = main.settings;
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiComponent = gui.GuiComponent;
const GuiWindow = gui.GuiWindow;
const Button = @import("../components/Button.zig");
const Label = @import("../components/Label.zig");
const TextInput = @import("../components/TextInput.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var window = GuiWindow {
	.contentSize = Vec2f{128, 256},
	.id = "multiplayer",
};

var ipAddressLabel: *Label = undefined;

const padding: f32 = 8;

var connection: ?*ConnectionManager = null;
var ipAddress: []const u8 = "";
var gotIpAddress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thread: ?std.Thread = null;
const width: f32 = 420;

fn flawedDiscoverIpAddress() !void {
	connection = try ConnectionManager.init(12347, true); // TODO: default port
	ipAddress = try std.fmt.allocPrint(main.globalAllocator, "{}", .{connection.?.externalAddress});
	gotIpAddress.store(true, .Release);
}

fn discoverIpAddress() void {
	flawedDiscoverIpAddress() catch |err| {
		std.log.err("Encountered error {s} while discovering the ip address for multiplayer.", .{@errorName(err)});
	};
}

fn discoverIpAddressFromNewThread() void {
	var sta = main.utils.StackAllocator.init(main.globalAllocator, 1 << 23) catch unreachable;
	defer sta.deinit();
	main.stackAllocator = sta.allocator();

	discoverIpAddress();
}

fn join(_: usize) void {
	if(thread) |_thread| {
		_thread.join();
		thread = null;
	}
	if(ipAddress.len != 0) {
		main.globalAllocator.free(ipAddress);
		ipAddress = "";
	}
	if(connection) |_connection| {
		_connection.world = &main.game.testWorld;
		main.game.testWorld.init(settings.lastUsedIPAddress, _connection) catch |err| {
			std.log.err("Encountered error while opening world: {s}", .{@errorName(err)});
		};
		main.game.world = &main.game.testWorld;
		connection = null;
	} else {
		std.log.err("No connection found. Cannot connect.", .{});
	}
	for(gui.openWindows.items) |openWindow| {
		gui.closeWindow(openWindow) catch |err| {
			std.log.err("Encountered error while opening world: {s}", .{@errorName(err)});
		};
	}
	gui.openHud() catch |err| {
		std.log.err("Encountered error while opening world: {s}", .{@errorName(err)});
	};
}

fn copyIp(_: usize) void {
	main.Window.setClipboardString(ipAddress);
}

pub fn onOpen() Allocator.Error!void {
	const list = try VerticalList.init(.{padding, 16 + padding}, 300, 16);
	try list.add(try Label.init(.{0, 0}, width, "Please send your IP to the host of the game and enter the host's IP below.", .center));
	//                                               255.255.255.255:?65536 (longest possible ip address)
	ipAddressLabel = try Label.init(.{0, 0}, width, "                      ", .center);
	try list.add(ipAddressLabel);
	try list.add(try Button.initText(.{0, 0}, 100, "Copy IP", .{.callback = &copyIp}));
	try list.add(try TextInput.init(.{0, 0}, width, 32, settings.lastUsedIPAddress, .{.callback = &join}));
	try list.add(try Button.initText(.{0, 0}, 100, "Join", .{.callback = &join}));
	list.finish(.center);
	window.rootComponent = list.toComponent();
	window.contentSize = window.rootComponent.?.pos() + window.rootComponent.?.size() + @as(Vec2f, @splat(padding));
	gui.updateWindowPositions();

	thread = std.Thread.spawn(.{}, discoverIpAddressFromNewThread, .{}) catch |err| blk: {
		std.log.err("Error spawning thread: {s}. Doing it in the current thread instead.", .{@errorName(err)});
		discoverIpAddress();
		break :blk null;
	};
}

pub fn onClose() void {
	if(thread) |_thread| {
		_thread.join();
		thread = null;
	}
	if(connection) |_connection| {
		_connection.deinit();
		connection = null;
	}
	if(ipAddress.len != 0) {
		main.globalAllocator.free(ipAddress);
		ipAddress = "";
	}

	if(window.rootComponent) |*comp| {
		comp.deinit();
	}
}

pub fn update() Allocator.Error!void {
	if(gotIpAddress.load(.Acquire)) {
		gotIpAddress.store(false, .Monotonic);
		try ipAddressLabel.updateText(ipAddress);
	}
}