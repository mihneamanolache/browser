const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const reflection = @import("../reflection.zig");
const DOMException = @import("../../DOMException.zig");

const log = lp.log;
const String = lp.String;

const Image = @This();

pub const Proto = HtmlElement;

_generation: u32 = 0,
// Per spec, false only while a fetch is in flight.
_complete: bool = true,
// A failed current request renders Chrome's broken-image replacement box.
// Keep this separate from `complete`: both successful and failed requests are
// complete once their fetch settles.
_broken: bool = false,
_loaded: bool = false,
_natural_width: u32 = 0,
_natural_height: u32 = 0,
_decode_resolvers: std.ArrayList(js.PromiseResolver.Global) = .empty,

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn constructor(w_: ?u32, h_: ?u32, frame: *Frame) !*Image {
    const node = try Frame.node_factory.createElementNS(frame.document, .html, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&frame.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("width"), .wrap(w_string), frame);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&frame.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("height"), .wrap(h_string), frame);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Image) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeInterned("src") orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

fn setSrc(self: *Image, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeInterned("loading") orelse "eager";
}

fn setLoading(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), frame);
}

fn getNaturalWidth(self: *const Image) u32 {
    return self._natural_width;
}

fn getNaturalHeight(self: *const Image) u32 {
    return self._natural_height;
}

fn getDimension(self: *const Image, comptime name: []const u8) u32 {
    if (self.asConstElement().getAttributeSafe(.wrap(name))) |value| {
        const parsed = reflection.parseInteger(value) orelse return 0;
        if (parsed < 0 or parsed > std.math.maxInt(i32)) return 0;
        return @intCast(parsed);
    }

    // Blink paints a 16x16 replacement icon for a broken image without an
    // author-supplied dimension. This is the rendered CSS-pixel size exposed
    // by HTMLImageElement.width/height; naturalWidth/naturalHeight remain 0.
    return if (self._broken and self.asConstElement().asConstNode().isConnected()) 16 else if (comptime std.mem.eql(u8, name, "width")) self._natural_width else self._natural_height;
}

fn setDimension(self: *Image, value: u32, comptime name: []const u8, frame: *Frame) !void {
    const normalized = if (value <= std.math.maxInt(i32)) value else 0;
    const str = try std.fmt.bufPrint(&frame.buf, "{d}", .{normalized});
    try self.asElement().setAttributeSafe(.wrap(name), .wrap(str), frame);
}

fn getWidth(self: *const Image) u32 {
    return self.getDimension("width");
}

fn setWidth(self: *Image, value: u32, frame: *Frame) !void {
    return self.setDimension(value, "width", frame);
}

fn getHeight(self: *const Image) u32 {
    return self.getDimension("height");
}

fn setHeight(self: *Image, value: u32, frame: *Frame) !void {
    return self.setDimension(value, "height", frame);
}

fn getComplete(self: *const Image) bool {
    return self._complete;
}

pub fn decode(self: *Image, frame: *Frame) !js.Promise {
    const local = frame.js.local.?;
    if (self._loaded) return local.resolvePromise(js.Undefined{});
    if (self._complete) return local.rejectPromise(.{ .dom_exception = .{ .err = error.EncodingError } });

    const resolver = local.createPromiseResolver();
    const global = try resolver.persist();
    errdefer global.deinit();
    try self._decode_resolvers.append(frame._factory.storageAllocator(), global);
    return resolver.promise();
}

pub fn finishDecodes(self: *Image, frame: *Frame, success: bool) void {
    var pending = self._decode_resolvers;
    self._decode_resolvers = .empty;
    defer pending.deinit(frame._factory.storageAllocator());
    if (pending.items.len == 0) return;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    for (pending.items) |resolver| {
        defer resolver.deinit();
        const local = ls.toLocal(resolver);
        if (success) {
            local.resolve("Image.decode", js.Undefined{});
        } else {
            local.reject("Image.decode", DOMException.init("The source image cannot be decoded.", "EncodingError"));
        }
    }
}

pub fn releaseDecodes(self: *Image, frame: *Frame) void {
    for (self._decode_resolvers.items) |resolver| resolver.deinit();
    self._decode_resolvers.deinit(frame._factory.storageAllocator());
    self._decode_resolvers = .empty;
}

/// The one funnel for "this element's src became current": parser-created
/// images, `img.src = ...` and `setAttribute`/`removeAttribute("src")` all
/// land here.
fn imageAddedCallback(self: *Image, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger a load event
    // or start fetching a resource.
    if (frame.isGoingAway()) {
        return;
    }

    // A document without a browsing context (DOMParser et al.) loads nothing.
    if (self.asElement().getDocument(frame)._frame == null) {
        return;
    }

    self._generation +%= 1;
    const generation = self._generation;
    self._complete = true;
    self._broken = false;
    self._loaded = false;
    self._natural_width = 0;
    self._natural_height = 0;
    self.finishDecodes(frame, false);
    if (self._generation != generation) return;

    const element = self.asElement();
    // Exit if src not set.
    const src = element.getAttributeInterned("src") orelse return;
    if (src.len == 0) return;

    // If image loading not desired, we just do fake "load" event.
    if (frame._session.load_resources.image == false) {
        return frame.queueLoad(Factory.protoOf(self));
    }

    Frame.resource_load.image(frame, self, src) catch |err| {
        log.warn(.http, "image fetch", .{ .err = err, .src = src });
        self._broken = true;
        return frame.queueElementEvent(Factory.protoOf(self), .@"error");
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "HTMLImageElement";
        pub const constructor_alias = "Image";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Image.constructor, .{});
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{ .ce_reactions = true });
    pub const currentSrc = bridge.accessor(Image.getSrc, null, .{});
    pub const alt = reflect.string("alt");
    pub const width = bridge.accessor(Image.getWidth, Image.setWidth, .{ .ce_reactions = true });
    pub const height = bridge.accessor(Image.getHeight, Image.setHeight, .{ .ce_reactions = true });
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{ .ce_reactions = true });
    const reflect = Element.Reflect(Image);
    pub const srcset = reflect.string("srcset");
    pub const useMap = reflect.string("usemap");
    pub const isMap = reflect.boolean("ismap");
    pub const referrerPolicy = reflect.referrerPolicy();
    pub const decoding = reflect.enumerated("decoding", &.{ "async", "sync", "auto" }, .{ .missing = "auto" });
    // Obsolete
    pub const name = reflect.string("name");
    pub const lowsrc = reflect.url("lowsrc");
    pub const @"align" = reflect.string("align");
    pub const hspace = reflect.unsignedLong("hspace", .{});
    pub const vspace = reflect.unsignedLong("vspace", .{});
    pub const longDesc = reflect.url("longdesc");
    pub const border = reflect.stringNullToEmpty("border");

    pub const naturalWidth = bridge.accessor(Image.getNaturalWidth, null, .{});
    pub const naturalHeight = bridge.accessor(Image.getNaturalHeight, null, .{});
    pub const complete = bridge.accessor(Image.getComplete, null, .{});
    pub const decode = bridge.function(Image.decode, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Image);
        return self.imageAddedCallback(frame);
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }
        return element.as(Image).imageAddedCallback(frame);
    }

    // Removing the src leaves no request to make, but any in-flight one still
    // has to be invalidated.
    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }
        return element.as(Image).imageAddedCallback(frame);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}

test "WebApi: HTML.Image fetch" {
    try testing.htmlRunner("element/html/image_fetch.html", .{ .load_resources = .{ .image = true } });
}
