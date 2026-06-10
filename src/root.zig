//! metalbrew library root.
const std = @import("std");

pub const domain = struct {
    pub const version = @import("domain/version.zig");
    pub const formula = @import("domain/formula.zig");
    pub const resolver = @import("domain/resolver.zig");
    pub const platform = @import("domain/platform.zig");
};

pub const ports = struct {
    pub const catalog = @import("ports/catalog.zig");
    pub const index_cache = @import("ports/index_cache.zig");
    pub const bottle_fetcher = @import("ports/bottle_fetcher.zig");
    pub const receipt_store = @import("ports/receipt_store.zig");
};

pub const adapters = struct {
    pub const http_client = @import("adapters/http_client.zig");
    pub const ghcr_fetcher = @import("adapters/ghcr_fetcher.zig");
    pub const json_api_catalog = @import("adapters/json_api_catalog.zig");
    pub const fs_index_cache = @import("adapters/fs_index_cache.zig");
    pub const cached_catalog = @import("adapters/cached_catalog.zig");
    pub const cli = @import("adapters/cli.zig");
    pub const os_tag = @import("adapters/os_tag.zig");
};

pub const app = struct {
    pub const update_index = @import("app/update_index.zig");
    pub const get_info = @import("app/get_info.zig");
    pub const search = @import("app/search.zig");
    pub const resolve_deps = @import("app/resolve_deps.zig");
};

pub const config = @import("config.zig");

test {
    _ = @import("domain/version.zig");
    _ = @import("domain/formula.zig");
    _ = @import("domain/resolver.zig");
    _ = @import("domain/platform.zig");
    _ = @import("ports/catalog.zig");
    _ = @import("ports/index_cache.zig");
    _ = @import("ports/bottle_fetcher.zig");
    _ = @import("ports/receipt_store.zig");
    _ = @import("adapters/http_client.zig");
    _ = @import("adapters/ghcr_fetcher.zig");
    _ = @import("adapters/json_api_catalog.zig");
    _ = @import("adapters/fs_index_cache.zig");
    _ = @import("adapters/cached_catalog.zig");
    _ = @import("adapters/cli.zig");
    _ = @import("adapters/os_tag.zig");
    _ = @import("app/update_index.zig");
    _ = @import("app/get_info.zig");
    _ = @import("app/search.zig");
    _ = @import("app/resolve_deps.zig");
    _ = @import("config.zig");
}
