const std = @import("std");
const zig_builtin = @import("builtin");

const tres = @import("tres");

const ConfigOption = struct {
    /// Name of config option
    name: []const u8,
    /// (used in doc comments & schema.json)
    description: []const u8,
    /// zig type in string form. e.g "u32", "[]const u8", "?usize"
    type: []const u8,
    /// used in Config.zig as the default initializer
    default: []const u8,
};

const Config = struct {
    options: []ConfigOption,
};

const Schema = struct {
    @"$schema": []const u8 = "http://json-schema.org/schema",
    title: []const u8 = "ZLS Config",
    description: []const u8 = "Configuration file for the zig language server (ZLS)",
    type: []const u8 = "object",
    properties: std.StringArrayHashMap(SchemaEntry),
};

const SchemaEntry = struct {
    description: []const u8,
    type: []const u8,
    default: []const u8,
};

fn zigTypeToTypescript(ty: []const u8) ![]const u8 {
    return if (std.mem.eql(u8, ty, "?[]const u8"))
        "string"
    else if (std.mem.eql(u8, ty, "bool"))
        "boolean"
    else if (std.mem.eql(u8, ty, "usize"))
        "integer"
    else
        error.UnsupportedType;
}

fn generateConfigFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    _ = allocator;

    const config_file = try std.fs.createFileAbsolute(path, .{});
    defer config_file.close();

    var buff_out = std.io.bufferedWriter(config_file.writer());

    _ = try buff_out.write(
        \\//! DO NOT EDIT
        \\//! Configuration options for zls.
        \\//! If you want to add a config option edit
        \\//! src/config_gen/config.json and run `zig build gen`
        \\//! GENERATED BY src/config_gen/config_gen.zig
        \\
    );

    for (config.options) |option| {
        try buff_out.writer().print(
            \\
            \\/// {s}
            \\{s}: {s} = {s},
            \\
        , .{
            std.mem.trim(u8, option.description, &std.ascii.whitespace),
            std.mem.trim(u8, option.name, &std.ascii.whitespace),
            std.mem.trim(u8, option.type, &std.ascii.whitespace),
            std.mem.trim(u8, option.default, &std.ascii.whitespace),
        });
    }

    _ = try buff_out.write(
        \\
        \\// DO NOT EDIT
        \\
    );

    try buff_out.flush();
}

fn generateSchemaFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    const schema_file = try std.fs.openFileAbsolute(path, .{
        .mode = .write_only,
    });
    defer schema_file.close();

    var buff_out = std.io.bufferedWriter(schema_file.writer());

    var properties = std.StringArrayHashMapUnmanaged(SchemaEntry){};
    defer properties.deinit(allocator);
    try properties.ensureTotalCapacity(allocator, config.options.len);

    for (config.options) |option| {
        properties.putAssumeCapacityNoClobber(option.name, .{
            .description = option.description,
            .type = try zigTypeToTypescript(option.type),
            .default = option.default,
        });
    }

    _ = try buff_out.write(
        \\{
        \\    "$schema": "http://json-schema.org/schema",
        \\    "title": "ZLS Config",
        \\    "description": "Configuration file for the zig language server (ZLS)",
        \\    "type": "object",
        \\    "properties": 
    );

    try tres.stringify(properties, .{
        .whitespace = .{
            .indent_level = 1,
        },
    }, buff_out.writer());

    _ = try buff_out.write("\n}\n");
    try buff_out.flush();
    try schema_file.setEndPos(try schema_file.getPos());
}

fn updateREADMEFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    var readme_file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer readme_file.close();

    var readme = try readme_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(readme);

    const start_indicator = "<!-- DO NOT EDIT | THIS SECTION IS AUTO-GENERATED | DO NOT EDIT -->";
    const end_indicator = "<!-- DO NOT EDIT -->";

    const start = start_indicator.len + (std.mem.indexOf(u8, readme, start_indicator) orelse return error.SectionNotFound);
    const end = std.mem.indexOfPos(u8, readme, start, end_indicator) orelse return error.SectionNotFound;

    try readme_file.seekTo(0);
    var writer = readme_file.writer();

    try writer.writeAll(readme[0..start]);

    try writer.writeAll(
        \\
        \\| Option | Type | Default value | What it Does |
        \\| --- | --- | --- | --- |
        \\
    );

    for (config.options) |option| {
        try writer.print(
            \\| `{s}` | `{s}` | `{s}` | {s} |
            \\
        , .{
            std.mem.trim(u8, option.name, &std.ascii.whitespace),
            std.mem.trim(u8, option.type, &std.ascii.whitespace),
            std.mem.trim(u8, option.default, &std.ascii.whitespace),
            std.mem.trim(u8, option.description, &std.ascii.whitespace),
        });
    }

    try writer.writeAll(readme[end..]);

    try readme_file.setEndPos(try readme_file.getPos());
}

const ConfigurationProperty = struct {
    scope: []const u8 = "resource",
    type: []const u8,
    description: []const u8,
    @"enum": ?[]const []const u8 = null,
    format: ?[]const u8 = null,
    default: ?std.json.Value = null,
};

fn generateVSCodeConfigFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    var config_file = try std.fs.createFileAbsolute(path, .{});
    defer config_file.close();

    const predefined_configurations: usize = 3;
    var configuration: std.StringArrayHashMapUnmanaged(ConfigurationProperty) = .{};
    try configuration.ensureTotalCapacity(allocator, predefined_configurations + @intCast(u32, config.options.len));
    defer {
        for (configuration.keys()[predefined_configurations..]) |name| allocator.free(name);
        configuration.deinit(allocator);
    }

    configuration.putAssumeCapacityNoClobber("trace.server", .{
        .scope = "window",
        .type = "string",
        .@"enum" = &.{ "off", "message", "verbose" },
        .description = "Traces the communication between VS Code and the language server.",
        .default = .{ .String = "off" },
    });
    configuration.putAssumeCapacityNoClobber("check_for_update", .{
        .type = "boolean",
        .description = "Whether to automatically check for new updates",
        .default = .{ .Bool = true },
    });
    configuration.putAssumeCapacityNoClobber("path", .{
        .type = "string",
        .description = "Path to `zls` executable. Example: `C:/zls/zig-cache/bin/zls.exe`.",
        .format = "path",
        .default = null,
    });

    for (config.options) |option| {
        const name = try std.fmt.allocPrint(allocator, "zls.{s}", .{option.name});

        var parser = std.json.Parser.init(allocator, false);
        const default = (try parser.parse(option.default)).root;

        configuration.putAssumeCapacityNoClobber(name, .{
            .type = try zigTypeToTypescript(option.type),
            .description = option.description,
            .format = if (std.mem.indexOf(u8, option.name, "path") != null) "path" else null,
            .default = if (default == .Null) null else default,
        });
    }

    var buffered_writer = std.io.bufferedWriter(config_file.writer());
    var writer = buffered_writer.writer();

    try tres.stringify(configuration, .{
        .whitespace = .{},
        .emit_null_optional_fields = false,
    }, writer);

    try buffered_writer.flush();
}

/// Tokenizer for a langref.html.in file
/// example file: https://raw.githubusercontent.com/ziglang/zig/master/doc/langref.html.in
/// this is a modified version from https://github.com/ziglang/zig/blob/master/doc/docgen.zig
const Tokenizer = struct {
    buffer: []const u8,
    index: usize = 0,
    state: State = .Start,

    const State = enum {
        Start,
        LBracket,
        Hash,
        TagName,
        Eof,
    };

    const Token = struct {
        id: Id,
        start: usize,
        end: usize,

        const Id = enum {
            Invalid,
            Content,
            BracketOpen,
            TagContent,
            Separator,
            BracketClose,
            Eof,
        };
    };

    fn next(self: *Tokenizer) Token {
        var result = Token{
            .id = .Eof,
            .start = self.index,
            .end = undefined,
        };
        while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (self.state) {
                .Start => switch (c) {
                    '{' => {
                        self.state = .LBracket;
                    },
                    else => {
                        result.id = .Content;
                    },
                },
                .LBracket => switch (c) {
                    '#' => {
                        if (result.id != .Eof) {
                            self.index -= 1;
                            self.state = .Start;
                            break;
                        } else {
                            result.id = .BracketOpen;
                            self.index += 1;
                            self.state = .TagName;
                            break;
                        }
                    },
                    else => {
                        result.id = .Content;
                        self.state = .Start;
                    },
                },
                .TagName => switch (c) {
                    '|' => {
                        if (result.id != .Eof) {
                            break;
                        } else {
                            result.id = .Separator;
                            self.index += 1;
                            break;
                        }
                    },
                    '#' => {
                        self.state = .Hash;
                    },
                    else => {
                        result.id = .TagContent;
                    },
                },
                .Hash => switch (c) {
                    '}' => {
                        if (result.id != .Eof) {
                            self.index -= 1;
                            self.state = .TagName;
                            break;
                        } else {
                            result.id = .BracketClose;
                            self.index += 1;
                            self.state = .Start;
                            break;
                        }
                    },
                    else => {
                        result.id = .TagContent;
                        self.state = .TagName;
                    },
                },
                .Eof => unreachable,
            }
        } else {
            switch (self.state) {
                .Start,
                .LBracket,
                .Eof,
                => {},
                else => {
                    result.id = .Invalid;
                },
            }
            self.state = .Eof;
        }
        result.end = self.index;
        return result;
    }
};

const Builtin = struct {
    name: []const u8,
    signature: []const u8,
    documentation: std.ArrayListUnmanaged(u8),
};

/// parses a `langref.html.in` file and extracts builtins from this section: `https://ziglang.org/documentation/master/#Builtin-Functions`
/// the documentation field contains poorly formated html
fn collectBuiltinData(allocator: std.mem.Allocator, version: []const u8, langref_file: []const u8) error{OutOfMemory}![]Builtin {
    var tokenizer = Tokenizer{ .buffer = langref_file };

    const State = enum {
        /// searching for this line:
        /// {#header_open|Builtin Functions|2col#}
        searching,
        /// skippig builtin functions description:
        /// Builtin functions are provided by the compiler and are prefixed ...
        prefix,
        /// every entry begins with this:
        /// {#syntax#}@addrSpaceCast(comptime addrspace: std.builtin.AddressSpace, ptr: anytype) anytype{#endsyntax#}
        builtin_begin,
        /// iterate over documentation
        builtin_content,
    };
    var state: State = .searching;

    var builtins = std.ArrayListUnmanaged(Builtin){};
    errdefer {
        for (builtins.items) |*builtin| {
            builtin.documentation.deinit(allocator);
        }
        builtins.deinit(allocator);
    }

    var depth: u32 = undefined;
    while (true) {
        const token = tokenizer.next();
        switch (token.id) {
            .Content => {
                switch (state) {
                    .builtin_content => {
                        try builtins.items[builtins.items.len - 1].documentation.appendSlice(allocator, tokenizer.buffer[token.start..token.end]);
                    },
                    else => continue,
                }
            },
            .BracketOpen => {
                const tag_token = tokenizer.next();
                std.debug.assert(tag_token.id == .TagContent);
                const tag_name = tokenizer.buffer[tag_token.start..tag_token.end];

                if (std.mem.eql(u8, tag_name, "header_open")) {
                    std.debug.assert(tokenizer.next().id == .Separator);
                    const content_token = tokenizer.next();
                    std.debug.assert(tag_token.id == .TagContent);
                    const content_name = tokenizer.buffer[content_token.start..content_token.end];

                    switch (state) {
                        .searching => {
                            if (std.mem.eql(u8, content_name, "Builtin Functions")) {
                                state = .prefix;
                                depth = 0;
                            }
                        },
                        .prefix, .builtin_begin => {
                            state = .builtin_begin;
                            try builtins.append(allocator, .{
                                .name = content_name,
                                .signature = "",
                                .documentation = .{},
                            });
                        },
                        .builtin_content => unreachable,
                    }
                    if (state != .searching) {
                        depth += 1;
                    }

                    while (true) {
                        const bracket_tok = tokenizer.next();
                        switch (bracket_tok.id) {
                            .BracketClose => break,
                            .Separator, .TagContent => continue,
                            else => unreachable,
                        }
                    }
                } else if (std.mem.eql(u8, tag_name, "header_close")) {
                    std.debug.assert(tokenizer.next().id == .BracketClose);

                    if (state == .builtin_content) {
                        state = .builtin_begin;
                    }
                    if (state != .searching) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                } else if (state != .searching and std.mem.eql(u8, tag_name, "syntax")) {
                    std.debug.assert(tokenizer.next().id == .BracketClose);
                    const content_tag = tokenizer.next();
                    std.debug.assert(content_tag.id == .Content);
                    const content_name = tokenizer.buffer[content_tag.start..content_tag.end];
                    std.debug.assert(tokenizer.next().id == .BracketOpen);
                    const end_syntax_tag = tokenizer.next();
                    std.debug.assert(end_syntax_tag.id == .TagContent);
                    const end_tag_name = tokenizer.buffer[end_syntax_tag.start..end_syntax_tag.end];
                    std.debug.assert(std.mem.eql(u8, end_tag_name, "endsyntax"));
                    std.debug.assert(tokenizer.next().id == .BracketClose);

                    switch (state) {
                        .builtin_begin => {
                            builtins.items[builtins.items.len - 1].signature = content_name;
                            state = .builtin_content;
                        },
                        .builtin_content => {
                            const writer = builtins.items[builtins.items.len - 1].documentation.writer(allocator);

                            try writeMarkdownCode(content_name, "zig", writer);
                        },
                        else => {},
                    }
                } else if (state != .searching and std.mem.eql(u8, tag_name, "syntax_block")) {
                    std.debug.assert(tokenizer.next().id == .Separator);

                    const source_type_tag = tokenizer.next();
                    std.debug.assert(tag_token.id == .TagContent);
                    const source_type = tokenizer.buffer[source_type_tag.start..source_type_tag.end];
                    switch (tokenizer.next().id) {
                        .Separator => {
                            std.debug.assert(tokenizer.next().id == .TagContent);
                            std.debug.assert(tokenizer.next().id == .BracketClose);
                        },
                        .BracketClose => {},
                        else => unreachable,
                    }

                    var content_token = tokenizer.next();
                    std.debug.assert(content_token.id == .Content);
                    const content = tokenizer.buffer[content_token.start..content_token.end];
                    const writer = builtins.items[builtins.items.len - 1].documentation.writer(allocator);
                    try writeMarkdownCode(content, source_type, writer);

                    std.debug.assert(tokenizer.next().id == .BracketOpen);
                    const end_code_token = tokenizer.next();
                    std.debug.assert(tag_token.id == .TagContent);
                    const end_code_name = tokenizer.buffer[end_code_token.start..end_code_token.end];
                    std.debug.assert(std.mem.eql(u8, end_code_name, "end_syntax_block"));
                    std.debug.assert(tokenizer.next().id == .BracketClose);
                } else if (state != .searching and std.mem.eql(u8, tag_name, "link")) {
                    std.debug.assert(tokenizer.next().id == .Separator);
                    const name_token = tokenizer.next();
                    std.debug.assert(name_token.id == .TagContent);
                    const name = tokenizer.buffer[name_token.start..name_token.end];

                    const url_name = switch (tokenizer.next().id) {
                        .Separator => blk: {
                            const url_name_token = tokenizer.next();
                            std.debug.assert(url_name_token.id == .TagContent);
                            const url_name = tokenizer.buffer[url_name_token.start..url_name_token.end];
                            std.debug.assert(tokenizer.next().id == .BracketClose);
                            break :blk url_name;
                        },
                        .BracketClose => name,
                        else => unreachable,
                    };

                    const spaceless_url_name = try std.mem.replaceOwned(u8, allocator, url_name, " ", "-");
                    defer allocator.free(spaceless_url_name);

                    const writer = builtins.items[builtins.items.len - 1].documentation.writer(allocator);
                    try writer.print("[{s}](https://ziglang.org/documentation/{s}/#{s})", .{
                        name,
                        version,
                        std.mem.trimLeft(u8, spaceless_url_name, "@"),
                    });
                } else if (state != .searching and std.mem.eql(u8, tag_name, "code_begin")) {
                    std.debug.assert(tokenizer.next().id == .Separator);
                    std.debug.assert(tokenizer.next().id == .TagContent);
                    switch (tokenizer.next().id) {
                        .Separator => {
                            std.debug.assert(tokenizer.next().id == .TagContent);
                            std.debug.assert(tokenizer.next().id == .BracketClose);
                        },
                        .BracketClose => {},
                        else => unreachable,
                    }

                    while (true) {
                        const content_token = tokenizer.next();
                        std.debug.assert(content_token.id == .Content);
                        const content = tokenizer.buffer[content_token.start..content_token.end];
                        std.debug.assert(tokenizer.next().id == .BracketOpen);
                        const end_code_token = tokenizer.next();
                        std.debug.assert(end_code_token.id == .TagContent);
                        const end_tag_name = tokenizer.buffer[end_code_token.start..end_code_token.end];

                        if (std.mem.eql(u8, end_tag_name, "code_end")) {
                            std.debug.assert(tokenizer.next().id == .BracketClose);

                            const writer = builtins.items[builtins.items.len - 1].documentation.writer(allocator);
                            try writeMarkdownCode(content, "zig", writer);
                            break;
                        }
                        std.debug.assert(tokenizer.next().id == .BracketClose);
                    }
                } else {
                    while (true) {
                        switch (tokenizer.next().id) {
                            .Eof => unreachable,
                            .BracketClose => break,
                            else => continue,
                        }
                    }
                }
            },
            else => unreachable,
        }
    }

    return try builtins.toOwnedSlice(allocator);
}

/// single line: \`{content}\`
/// multi line:
/// \`\`\`{source_type}
/// {content}
/// \`\`\`
fn writeMarkdownCode(content: []const u8, source_type: []const u8, writer: anytype) @TypeOf(writer).Error!void {
    const trimmed_content = std.mem.trim(u8, content, " \n");
    const is_multiline = std.mem.indexOfScalar(u8, trimmed_content, '\n') != null;
    if (is_multiline) {
        var line_it = std.mem.tokenize(u8, trimmed_content, "\n");
        try writer.print("\n```{s}", .{source_type});
        while (line_it.next()) |line| {
            try writer.print("\n{s}", .{line});
        }
        try writer.writeAll("\n```");
    } else {
        try writer.print("`{s}`", .{trimmed_content});
    }
}

fn writeLine(str: []const u8, single_line: bool, writer: anytype) @TypeOf(writer).Error!void {
    const trimmed_content = std.mem.trim(u8, str, &std.ascii.whitespace);
    if (trimmed_content.len == 0) return;

    if (single_line) {
        var line_it = std.mem.split(u8, trimmed_content, "\n");
        while (line_it.next()) |line| {
            try writer.print("{s} ", .{std.mem.trim(u8, line, &std.ascii.whitespace)});
        }
    } else {
        try writer.writeAll(trimmed_content);
    }

    try writer.writeByte('\n');
}

/// converts text with various html tags into markdown
/// supported tags:
/// - `<p>`
/// - `<pre>`
/// - `<em>`
/// - `<ul>` and `<li>`
/// - `<a>`
/// - `<code>`
fn writeMarkdownFromHtml(html: []const u8, writer: anytype) !void {
    return writeMarkdownFromHtmlInternal(html, false, 0, writer);
}

/// this is kind of a hacky solution. A cleaner solution would be to implement using a xml/html parser.
fn writeMarkdownFromHtmlInternal(html: []const u8, single_line: bool, depth: u32, writer: anytype) !void {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, index, '<')) |tag_start_index| {
        const tags: []const []const u8 = &.{ "pre", "p", "em", "ul", "li", "a", "code" };
        const opening_tags: []const []const u8 = &.{ "<pre>", "<p>", "<em>", "<ul>", "<li>", "<a>", "<code>" };
        const closing_tags: []const []const u8 = &.{ "</pre>", "</p>", "</em>", "</ul>", "</li>", "</a>", "</code>" };
        const tag_index = for (tags) |tag_name, i| {
            if (std.mem.startsWith(u8, html[tag_start_index + 1 ..], tag_name)) break i;
        } else {
            index += 1;
            continue;
        };

        try writeLine(html[index..tag_start_index], single_line, writer);

        const tag_name = tags[tag_index];
        const opening_tag_name = opening_tags[tag_index];
        const closing_tag_name = closing_tags[tag_index];

        // std.debug.print("tag: '{s}'\n", .{tag_name});

        const content_start = 1 + (std.mem.indexOfScalarPos(u8, html, tag_start_index + 1 + tag_name.len, '>') orelse return error.InvalidTag);

        index = content_start;
        const content_end = while (std.mem.indexOfScalarPos(u8, html, index, '<')) |end| {
            if (std.mem.startsWith(u8, html[end..], closing_tag_name)) break end;
            if (std.mem.startsWith(u8, html[end..], opening_tag_name)) {
                index = std.mem.indexOfPos(u8, html, end + opening_tag_name.len, closing_tag_name) orelse return error.MissingEndTag;
                index += closing_tag_name.len;
                continue;
            }
            index += 1;
        } else html.len;

        const content = html[content_start..content_end];
        index = @min(html.len, content_end + closing_tag_name.len);
        // std.debug.print("content: {s}\n", .{content});

        if (std.mem.eql(u8, tag_name, "p")) {
            try writeMarkdownFromHtmlInternal(content, true, depth, writer);
            try writer.writeByte('\n');
        } else if (std.mem.eql(u8, tag_name, "pre")) {
            try writeMarkdownFromHtmlInternal(content, false, depth, writer);
        } else if (std.mem.eql(u8, tag_name, "em")) {
            try writer.print("**{s}** ", .{content});
        } else if (std.mem.eql(u8, tag_name, "ul")) {
            try writeMarkdownFromHtmlInternal(content, false, depth + 1, writer);
        } else if (std.mem.eql(u8, tag_name, "li")) {
            try writer.writeByteNTimes(' ', 1 + (depth -| 1) * 2);
            try writer.writeAll("- ");
            try writeMarkdownFromHtmlInternal(content, true, depth, writer);
        } else if (std.mem.eql(u8, tag_name, "a")) {
            const href_part = std.mem.trimLeft(u8, html[tag_start_index + 2 .. content_start - 1], " ");
            std.debug.assert(std.mem.startsWith(u8, href_part, "href=\""));
            std.debug.assert(href_part[href_part.len - 1] == '\"');
            const url = href_part["href=\"".len .. href_part.len - 1];
            try writer.print("[{s}]({s})", .{ content, std.mem.trimLeft(u8, url, "@") });
        } else if (std.mem.eql(u8, tag_name, "code")) {
            try writeMarkdownCode(content, "zig", writer);
        } else return error.UnsupportedTag;
    }

    try writeLine(html[index..], single_line, writer);
}

/// takes in a signature like this: `@intToEnum(comptime DestType: type, integer: anytype) DestType`
/// and outputs its arguments: `comptime DestType: type`, `integer: anytype`
fn extractArgumentsFromSignature(allocator: std.mem.Allocator, signature: []const u8) error{OutOfMemory}![][]const u8 {
    var arguments = std.ArrayListUnmanaged([]const u8){};
    defer arguments.deinit(allocator);

    var argument_start: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfAnyPos(u8, signature, index, ",()")) |token_index| {
        if (signature[token_index] == '(') {
            argument_start = index;
            index = 1 + std.mem.indexOfScalarPos(u8, signature, token_index + 1, ')').?;
            continue;
        }
        const argument = std.mem.trim(u8, signature[argument_start..token_index], &std.ascii.whitespace);
        if (argument.len != 0) try arguments.append(allocator, argument);
        if (signature[token_index] == ')') break;
        argument_start = token_index + 1;
        index = token_index + 1;
    }

    return arguments.toOwnedSlice(allocator);
}

/// takes in a signature like this: `@intToEnum(comptime DestType: type, integer: anytype) DestType`
/// and outputs a snippet: `@intToEnum(${1:comptime DestType: type}, ${2:integer: anytype})`
fn extractSnippetFromSignature(allocator: std.mem.Allocator, signature: []const u8) error{OutOfMemory}![]const u8 {
    var snippet = std.ArrayListUnmanaged(u8){};
    defer snippet.deinit(allocator);
    var writer = snippet.writer(allocator);

    const start_index = 1 + std.mem.indexOfScalar(u8, signature, '(').?;
    try writer.writeAll(signature[0..start_index]);

    var argument_start: usize = start_index;
    var index: usize = start_index;
    var i: u32 = 1;
    while (std.mem.indexOfAnyPos(u8, signature, index, ",()")) |token_index| {
        if (signature[token_index] == '(') {
            argument_start = index;
            index = 1 + std.mem.indexOfScalarPos(u8, signature, token_index + 1, ')').?;
            continue;
        }
        const argument = std.mem.trim(u8, signature[argument_start..token_index], &std.ascii.whitespace);
        if (argument.len != 0) {
            if (i != 1) try writer.writeAll(", ");
            try writer.print("${{{d}:{s}}}", .{ i, argument });
        }
        if (signature[token_index] == ')') break;
        argument_start = token_index + 1;
        index = token_index + 1;
        i += 1;
    }
    try writer.writeByte(')');

    return snippet.toOwnedSlice(allocator);
}

/// Generates data files from the Zig language Reference (https://ziglang.org/documentation/master/)
/// An output example would `zls/src/master.zig`
fn generateVersionDataFile(allocator: std.mem.Allocator, version: []const u8, path: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/ziglang/zig/{s}/doc/langref.html.in", .{version});
    defer allocator.free(url);

    const response = try httpGET(allocator, try std.Uri.parse(url));
    switch (response) {
        .ok => {},
        .other => |status| {
            const error_name = status.phrase() orelse @tagName(status.class());
            std.log.err("failed to download {s}: {s}", .{ url, error_name });
            return error.DownloadFailed;
        },
    }
    defer allocator.free(response.ok);

    const response_bytes = response.ok;
    // const response_bytes: []const u8 = @embedFile("langref.html.in");

    var builtins = try collectBuiltinData(allocator, version, response_bytes);
    defer {
        for (builtins) |*builtin| {
            builtin.documentation.deinit(allocator);
        }
        allocator.free(builtins);
    }

    var builtin_file = try std.fs.createFileAbsolute(path, .{});
    defer builtin_file.close();

    var buffered_writer = std.io.bufferedWriter(builtin_file.writer());
    var writer = buffered_writer.writer();

    try writer.print(
        \\//! DO NOT EDIT
        \\//! If you want to update this file run:
        \\//! `zig build gen -- --generate-version-data {s}` (requires an internet connection)
        \\//! GENERATED BY src/config_gen/config_gen.zig
        \\
        \\const Builtin = struct {{
        \\    name: []const u8,
        \\    signature: []const u8,
        \\    snippet: []const u8,
        \\    documentation: []const u8,
        \\    arguments: []const []const u8,
        \\}};
        \\
        \\pub const builtins = [_]Builtin{{
        \\
    , .{version});

    for (builtins) |builtin| {
        const signature = try std.mem.replaceOwned(u8, allocator, builtin.signature, "\n", "");
        defer allocator.free(signature);

        const snippet = try extractSnippetFromSignature(allocator, signature);
        defer allocator.free(snippet);

        var arguments = try extractArgumentsFromSignature(allocator, signature[builtin.name.len + 1 ..]);
        defer allocator.free(arguments);

        try writer.print(
            \\    .{{
            \\        .name = "{}",
            \\        .signature = "{}",
            \\        .snippet = "{}",
            \\
        , .{
            std.zig.fmtEscapes(builtin.name),
            std.zig.fmtEscapes(signature),
            std.zig.fmtEscapes(snippet),
        });

        const html = builtin.documentation.items["</pre>".len..];
        var markdown = std.ArrayListUnmanaged(u8){};
        defer markdown.deinit(allocator);
        try writeMarkdownFromHtml(html, markdown.writer(allocator));

        try writer.writeAll("        .documentation =\n");
        var line_it = std.mem.split(u8, std.mem.trim(u8, markdown.items, "\n"), "\n");
        while (line_it.next()) |line| {
            try writer.print("        \\\\{s}\n", .{std.mem.trimRight(u8, line, " ")});
        }

        try writer.writeAll(
            \\        ,
            \\        .arguments = &.{
        );

        if (arguments.len != 0) {
            try writer.writeByte('\n');
            for (arguments) |arg| {
                try writer.print("            \"{}\",\n", .{std.zig.fmtEscapes(arg)});
            }
            try writer.writeByteNTimes(' ', 8);
        }

        try writer.writeAll(
            \\},
            \\    },
            \\
        );
    }

    try writer.writeAll(
        \\};
        \\
        \\// DO NOT EDIT
        \\
    );
    try buffered_writer.flush();
}

const Response = union(enum) {
    ok: []const u8,
    other: std.http.Status,
};

fn httpGET(allocator: std.mem.Allocator, uri: std.Uri) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit(allocator);
    try client.ca_bundle.rescan(allocator);

    var request = try client.request(uri, .{}, .{});
    defer request.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    while (true) {
        const size = try request.read(&buffer);
        if (size == 0) break;
        try output.appendSlice(allocator, buffer[0..size]);
    }

    if (request.response.headers.status != .ok) {
        return .{
            .other = request.response.headers.status,
        };
    }

    return .{ .ok = try output.toOwnedSlice(allocator) };
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!general_purpose_allocator.deinit());
    var gpa = general_purpose_allocator.allocator();

    var stderr = std.io.getStdErr().writer();

    var args_it = try std.process.argsWithAllocator(gpa);
    defer args_it.deinit();

    _ = args_it.next() orelse @panic("");
    const config_path = args_it.next() orelse @panic("first argument must be path to Config.zig");
    const schema_path = args_it.next() orelse @panic("second argument must be path to schema.json");
    const readme_path = args_it.next() orelse @panic("third argument must be path to README.md");
    const data_path = args_it.next() orelse @panic("fourth argument must be path to data directory");

    var maybe_vscode_config_path: ?[]const u8 = null;
    var maybe_data_file_version: ?[]const u8 = null;
    var maybe_data_file_path: ?[]const u8 = null;

    while (args_it.next()) |argname| {
        if (std.mem.eql(u8, argname, "--help")) {
            try stderr.writeAll(
                \\ Usage: zig build gen -- [command]
                \\
                \\    Commands:
                \\
                \\    --help                               Prints this message
                \\    --vscode-config-path [path]          Output zls-vscode configurations 
                \\    --generate-version-data [version]    Output version data file (see src/data/master.zig)
                \\    --generate-version-data-path [path]  Override default data file path (default: src/data/*.zig)
                \\
            );
        } else if (std.mem.eql(u8, argname, "--vscode-config-path")) {
            maybe_vscode_config_path = args_it.next() orelse {
                try stderr.print("Expected output path after --vscode-config-path argument.\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, argname, "--generate-version-data")) {
            maybe_data_file_version = args_it.next() orelse {
                try stderr.print("Expected version after --generate-version-data argument.\n", .{});
                return;
            };
            const is_valid_version = blk: {
                if (std.mem.eql(u8, maybe_data_file_version.?, "master")) break :blk true;
                _ = std.SemanticVersion.parse(maybe_data_file_version.?) catch break :blk false;
                break :blk true;
            };
            if (!is_valid_version) {
                try stderr.print("'{s}' is not a valid argument after --generate-version-data.\n", .{maybe_data_file_version.?});
                return;
            }
        } else if (std.mem.eql(u8, argname, "--generate-version-data-path")) {
            maybe_data_file_path = args_it.next() orelse {
                try stderr.print("Expected output path after --generate-version-data-path argument.\n", .{});
                return;
            };
        } else {
            try stderr.print("Unrecognized argument '{s}'.\n", .{argname});
            return;
        }
    }

    const parse_options = std.json.ParseOptions{
        .allocator = gpa,
    };
    var token_stream = std.json.TokenStream.init(@embedFile("config.json"));
    const config = try std.json.parse(Config, &token_stream, parse_options);
    defer std.json.parseFree(Config, config, parse_options);

    try generateConfigFile(gpa, config, config_path);
    try generateSchemaFile(gpa, config, schema_path);
    try updateREADMEFile(gpa, config, readme_path);

    if (maybe_vscode_config_path) |vscode_config_path| {
        try generateVSCodeConfigFile(gpa, config, vscode_config_path);
    }

    if (maybe_data_file_version) |data_version| {
        const path = if (maybe_data_file_path) |path| path else blk: {
            const file_name = try std.fmt.allocPrint(gpa, "{s}.zig", .{data_version});
            defer gpa.free(file_name);
            break :blk try std.fs.path.join(gpa, &.{ data_path, file_name });
        };
        defer if (maybe_data_file_path == null) gpa.free(path);

        try generateVersionDataFile(gpa, data_version, path);
    }

    if (zig_builtin.os.tag == .windows) {
        std.log.warn("Running on windows may result in CRLF and LF mismatch", .{});
    }

    try stderr.writeAll(
        \\Changing configuration options may also require editing the `package.json` from zls-vscode at https://github.com/zigtools/zls-vscode/blob/master/package.json
        \\You can use `zig build gen -Dvscode-config-path=/path/to/output/file.json` to generate the new configuration properties which you can then copy into `package.json`
        \\
    );
}