const std = @import("std");
const Allocator = std.mem.Allocator;

const main = @import("root");
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiComponent = gui.GuiComponent;
const GuiWindow = gui.GuiWindow;
const Button = @import("../components/Button.zig");
const HorizontalList = @import("../components/HorizontalList.zig");
const Label = @import("../components/Label.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var window = GuiWindow {
	.contentSize = Vec2f{128, 256},
	.id = "controls",
};

const padding: f32 = 8;
var selectedKey: ?*main.Key = null;
var needsUpdate: bool = false;

fn function(keyPtr: usize) void {
	main.setNextKeypressListener(&keypressListener) catch return;
	selectedKey = @ptrFromInt(keyPtr);
	needsUpdate = true;
}

fn keypressListener(key: c_int, mouseButton: c_int, scancode: c_int) void {
	selectedKey.?.key = key;
	selectedKey.?.mouseButton = mouseButton;
	selectedKey.?.scancode = scancode;
	selectedKey = null;
	needsUpdate = true;
}

pub fn onOpen() Allocator.Error!void {
	const list = try VerticalList.init(.{padding, 16 + padding}, 300, 8);
	for(&main.KeyBoard.keys) |*key| {
		const label = try Label.init(.{0, 0}, 128, key.name, .left);
		const button = if(key == selectedKey) (
			try Button.initText(.{16, 0}, 128, "...", .{})
		) else (
			try Button.initText(.{16, 0}, 128, key.getName(), .{.callback = &function, .arg = @intFromPtr(key)})
		);
		const row = try HorizontalList.init();
		try row.add(label);
		try row.add(button);
		row.finish(.{0, 0}, .center);
		try list.add(row);
	}
	list.finish(.center);
	window.rootComponent = list.toComponent();
	window.contentSize = window.rootComponent.?.pos() + window.rootComponent.?.size() + @as(Vec2f, @splat(padding));
	gui.updateWindowPositions();
}

pub fn onClose() void {
	if(window.rootComponent) |*comp| {
		comp.deinit();
	}
}

pub fn render() Allocator.Error!void {
	if(needsUpdate) {
		needsUpdate = false;
		const oldScroll = window.rootComponent.?.verticalList.scrollBar.currentState;
		onClose();
		onOpen() catch {
			std.log.err("Received out of memory error while rebuilding the controls GUI. This behavior is not handled.", .{});
		};
		window.rootComponent.?.verticalList.scrollBar.currentState = oldScroll;
	}
}