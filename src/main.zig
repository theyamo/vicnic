const clap = @import("clap");
const zigimg = @import("zigimg");
const std = @import("std");

const debug = std.debug;
const io = std.io;

const default_conversion = "0:0%0 1:1%6 2:2%7 3:3%5";

const ColorConversion = struct {
    index: u8,
    color: u8,
    bitpair: u8,

    pub fn print(self: ColorConversion) !void {
        std.debug.print("ColorConversion {{ index: {}, color: {}, bitpair: {} }}\n", .{ self.index, self.color, self.bitpair });
    }
};

const ConversionResult = struct {
    bitmap: []u8,
    color_ram: []u8,
    screen_ram: []u8,
    color_conversion: []ColorConversion,

    pub fn init(allocator: std.mem.Allocator, conversion_string: []const u8) !ConversionResult {
        return ConversionResult{
            .bitmap = try allocator.alloc(u8, 40 * 200),
            .color_ram = try allocator.alloc(u8, 40 * 25),
            .screen_ram = try allocator.alloc(u8, 40 * 25),
            .color_conversion = parseConversionString(allocator, conversion_string) catch |err| switch (err) {
                error.InvalidFormat => {
                    std.debug.print("Invalid conversion string: {s}\n", .{conversion_string});
                    std.process.exit(1);
                },
                else => @panic("Unexpected error"),
            },
        };
    }

    pub fn deinit(self: *ConversionResult, allocator: std.mem.Allocator) void {
        // Free allocated memory
        allocator.free(self.bitmap);
        allocator.free(self.color_ram);
        allocator.free(self.screen_ram);
        allocator.free(self.color_conversion);
    }
};

fn parseConversionString(allocator: std.mem.Allocator, s: []const u8) ![]ColorConversion {
    var pairs = try allocator.alloc(ColorConversion, 256); // Initialize an empty dynamic array
    var parts = std.mem.split(u8, s, " ");

    while (parts.next()) |part| {
        var split_colon_iter = std.mem.split(u8, part, ":");
        if (split_colon_iter.next()) |first_part| {
            if (split_colon_iter.next()) |second_with_optional_percent| {
                const first = try std.fmt.parseInt(u8, first_part, 10);

                var split_percent_iter = std.mem.split(u8, second_with_optional_percent, "%");
                if (split_percent_iter.next()) |second_part| {
                    const second = try std.fmt.parseInt(u8, second_part, 10);

                    var percent_val: u8 = 0;
                    if (split_percent_iter.next()) |percent_part| {
                        percent_val = try std.fmt.parseInt(u8, percent_part, 10);
                        //if (percent_val > 3) return error.OutOfRange;
                    }

                    if (first > 255 or percent_val > 15 or second > 3) return error.OutOfRange;

                    pairs[first] = ColorConversion{ .index = first, .color = percent_val, .bitpair = second };
                    //try pairs[first].print();
                } else return error.InvalidFormat;
            } else return error.InvalidFormat;
        } else return error.InvalidFormat;
    }

    return pairs;
}

fn get_multicolor_char(output: []u8, image: zigimg.Image, c: []ColorConversion, x: u64, y: u64) void {
    for (0..8) |cy| {
        var vic_pixel: u8 = 0;
        for (0..4) |count| {
            const horizontal_count = @as(u8, @intCast(count));
            const image_x = horizontal_count * 2;

            const shift = 6 - horizontal_count * 2;
            std.debug.assert(shift >= 0 and shift < 8);

            const image_offset = x + image_x + (y + cy) * 320;
            std.debug.assert(image_offset < image.pixels.indexed8.indices.len);

            const pixel: u8 = image.pixels.indexed8.indices[image_offset];
            //std.debug.assert(pixel >= 0 and pixel < 4);

            const bitpair = c[pixel].bitpair;

            vic_pixel |= bitpair << @as(u3, @intCast(shift));
        }
        output[cy] = vic_pixel;
    }
}

fn alloc_colors(o: []u8, c: ConversionResult, image: zigimg.Image, x: u64, y: u64) void {
    for (0..8) |cy| {
        for (0..4) |count| {
            const horizontal_count = @as(u8, @intCast(count));
            const image_x = horizontal_count * 2;

            const image_offset = x + image_x + (y + cy) * 320;
            std.debug.assert(image_offset < image.pixels.indexed8.indices.len);

            const pixel: u8 = image.pixels.indexed8.indices[image_offset];

            //std.debug.assert(pixel < 4);
            const conv = c.color_conversion[pixel];
            o[conv.bitpair] = conv.color;
            //debug.print("{}:{} -> {}\n", .{ pixel, conv.bitpair, conv.color });
        }
    }
}

pub fn convert(_: std.mem.Allocator, result: ConversionResult, image: zigimg.Image) !void {
    // TODO: verify that image is 8 bit indexed
    for (0..25) |y| {
        for (0..40) |x| {
            const output_offset = x * 8 + y * 320;
            // alloc colors
            var colors: [4]u8 = undefined;

            colors[0] = 0; // 0 = undefined state
            colors[1] = 0;
            colors[2] = 0;
            colors[3] = 0;

            alloc_colors(&colors, result, image, x * 8, y * 8);

            // get block
            var block: [8]u8 = undefined;
            get_multicolor_char(&block, image, result.color_conversion, x * 8, y * 8);
            const slice = result.bitmap[output_offset .. output_offset + 8];
            @memcpy(slice, &block);

            //debug.print("{} {} {} {}\n", .{ colors[0], colors[1], colors[2], colors[3] });

            result.color_ram[x + y * 40] = colors[3];
            result.screen_ram[x + y * 40] = ((colors[1] & 15) << 4) | (colors[2] & 15);
        }
    }
}

// fn printColorPalette(palette: []zigimg.Color) void {
//     var index: i32 = 0;
//     for (palette) |color| {
//         std.debug.print("Palette[{d}] - R: {d}, G: {d}, B: {d}, A: {d}\n", .{ index, color.r, color.g, color.b, color.a });

//         index += 1;
//     }
// }

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // First we specify what parameters our program can take.
    // We can use `parseParamsComptime` to parse a string into an array of `Param(Help)`
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-n, --number <usize>   An option parameter, which takes a value.
        \\-c, --conversion <str> Color conversion string (see docs)
        \\<str>...               Input filename and output filename (optional).
        \\
    );

    // Initialize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also pass `.{}` to `clap.parse` if you don't
    // care about the extra information `Diagnostics` provides.
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| {
        // Report useful error and exit
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    const allocator = gpa.allocator();

    var conversion_string: ?[]const u8 = null;

    if (res.args.help != 0) {
        debug.print("--help\n", .{});
        std.process.exit(0);
    }
    if (res.args.conversion) |s| {
        conversion_string = s;
    }
    if (res.positionals.len == 0) {
        debug.print("No input file.\n", .{});
        std.process.exit(1);
    }

    var output_file: []const u8 = undefined;

    if (res.positionals.len > 2) {
        debug.print("Too many args\n", .{});
        std.process.exit(1);
    }

    if (res.positionals.len == 2) {
        output_file = res.positionals[1];
    } else output_file = "output";

    const input_file = res.positionals[0];

    debug.print("Input file: {s}\n", .{input_file});
    debug.print("Output file: {s}\n", .{output_file});

    const foo = if (conversion_string) |s| s else default_conversion;

    debug.print("Conversion: {s}\n", .{foo});
    // init conversion
    var result = ConversionResult.init(allocator, foo) catch {
        std.debug.print("Allocation of ConversionResult failed\n", .{});
        std.process.exit(1); // Exit the program with a non-zero status
    };

    for (0..16) |col| {
        try result.color_conversion[col].print();
    }

    // testing zimg --------------------------------------------------------------------------------

    var image = try zigimg.Image.fromFilePath(allocator, input_file);
    debug.print("pixel format {}\n", .{image.pixelFormat()});
    defer image.deinit();
    // this be stupid: test bg.png is already indexed8
    try image.convert(.indexed8);

    const first_color_palette = image.pixels.indexed8.palette[0];
    const second_color_palette = image.pixels.indexed8.palette[1];
    const third_color_palette = image.pixels.indexed8.palette[2];
    debug.print("first_color_palette {}\n", .{first_color_palette.r});
    debug.print("second_color_palette {}\n", .{second_color_palette.r});
    debug.print("third_color_palette {}\n", .{third_color_palette.r});

    // TODO: can below be const?
    try convert(allocator, result, image);
    defer result.deinit(allocator);

    // write out --------------------------------------------------------------------------------
    const chrfn = try std.fmt.allocPrint(allocator, "{s}.chr", .{output_file});
    const d800fn = try std.fmt.allocPrint(allocator, "{s}.d800", .{output_file});
    const scrfn = try std.fmt.allocPrint(allocator, "{s}.scr", .{output_file});
    defer allocator.free(chrfn);
    defer allocator.free(d800fn);
    defer allocator.free(scrfn);

    var file = try std.fs.cwd().createFile(chrfn, .{});
    try file.writeAll(result.bitmap);
    file.close();
    file = try std.fs.cwd().createFile(scrfn, .{});
    try file.writeAll(result.screen_ram);
    file.close();
    file = try std.fs.cwd().createFile(d800fn, .{});
    try file.writeAll(result.color_ram);
    file.close();
}
