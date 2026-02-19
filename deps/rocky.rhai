// Rocky Linux DVD ISO - dependency recipe
//
// Provides: extracted Rocky rootfs for RalphOS to build upon
// Output: BUILD_DIR/rootfs, BUILD_DIR/packages
//
// === Globals (provided by executor) ===
//
// BUILD_DIR  - Temporary build directory for intermediate files
// BUILD_DIR     - Installation prefix (where final artifacts go)
//
// === Helper functions (provided by executor) ===
//
// Filesystem:
//   exists(path)              - Check if path exists
//   is_file(path)             - Check if path is a file
//   is_dir(path)              - Check if path is a directory
//   mkdir(path)               - Create directory (recursive)
//   rm(path)                  - Remove file or directory
//   mv(src, dst)              - Move/rename file or directory
//   cp(src, dst)              - Copy file or directory
//   ln(target, link)          - Create symlink
//   chmod(path, mode)         - Change permissions (mode as octal int, e.g. 0o755)
//   file_size(path)           - Get file size in bytes
//   list_dir(path)            - List directory contents as array of strings
//
// Paths:
//   join_path(a, b)           - Join path components safely
//   basename(path)            - Get filename from path
//   dirname(path)             - Get directory from path
//   extension(path)           - Get file extension (without dot)
//
// Commands:
//   shell(cmd)                - Run shell command, throw on failure
//   shell_output(cmd)         - Run command, return stdout as string
//   shell_status(cmd)         - Run command, return exit code (don't throw)
//
// Network:
//   download(url, dest)       - HTTP download (throws on failure)
//   torrent(url, dest)        - BitTorrent download (throws on failure)
//   http_get(url)             - Fetch URL content as string
//
// Verification:
//   verify_sha256(path, hash) - Verify file checksum, throw on mismatch
//   fetch_sha256(url, name)   - Fetch CHECKSUM file, extract hash for filename
//   check_disk_space(path, n) - Verify n bytes free at path, throw if not
//
// Archive:
//   extract(archive, dest)    - Auto-detect format and extract (tar, zip, 7z, squashfs)
//
// Parsing:
//   parse_int(str)            - Parse string to integer
//
// Version:
//   version_compare(a, b)     - Compare semver: -1 (a<b), 0 (a==b), 1 (a>b)
//   version_newer(a, b)       - Returns true if a > b
//
// Environment:
//   env(name)                 - Get environment variable, "" if not set
//
// File I/O:
//   read_file(path)           - Read file content as string, "" if not exists
//   write_file(path, content) - Write string to file
//
// String:
//   trim(str)                 - Remove leading/trailing whitespace
//
// Logging:
//   log(msg)                  - Print info message
//   warn(msg)                 - Print warning message

let deps = ["rocky-deps"];

let ctx = #{
    description: "Rocky Linux rootfs (extracted from DVD ISO)",
    iso_contents_path: "/tmp/levitate-legacy-stubs/ralph/deps/iso-contents",
    iso_name: "Rocky-10.1-x86_64-dvd1.iso",
    iso_path: "/tmp/levitate-legacy-stubs/ralph/deps/Rocky-10.1-x86_64-dvd1.iso",
    name: "rocky",
    packages_path: "",
    rootfs_path: "/tmp/levitate-legacy-stubs/ralph/rootfs",
    sha256: "55f96d45a052c0ed4f06309480155cb66281a008691eb7f3f359957205b1849a",
    sha256_url: "https://download.rockylinux.org/pub/rocky/10/isos/x86_64/CHECKSUM",
    torrent_url: "https://download.rockylinux.org/pub/rocky/10/isos/x86_64/Rocky-10.1-x86_64-dvd1.torrent",
    version: "10.1",
};

// Recipe ctx is persisted between runs. Always clear run-specific paths so
// the recipe doesn't accidentally reuse another distro's downloads directory.
ctx.iso_path = "";
ctx.rootfs_path = "";
ctx.iso_contents_path = "";

// === ACQUIRE ===

fn is_acquired(ctx) {
    // Check if iso_path is set, or if ISO exists at expected location
    if ctx.iso_path == "" {
        let expected = join_path(BUILD_DIR, ctx.iso_name);
        if is_file(expected) {
            ctx.iso_path = expected;
        } else {
            throw "not acquired";
        }
    }
    if !is_file(ctx.iso_path) {
        throw "ISO missing at " + ctx.iso_path;
    }

    // Version check: filename must match expected
    let actual_name = basename(ctx.iso_path);
    if actual_name != ctx.iso_name {
        throw "version mismatch: have " + actual_name + ", want " + ctx.iso_name;
    }

    // Integrity check (skip if sha256 not yet fetched)
    if ctx.sha256 != "" {
        verify_sha256(ctx.iso_path, ctx.sha256);
    }

    ctx
}

fn acquire(ctx) {
    let dest = join_path(BUILD_DIR, ctx.iso_name);

    // Ensure BUILD_DIR exists
    mkdir(BUILD_DIR);

    log("Fetching checksum for " + ctx.iso_name);
    ctx.sha256 = fetch_sha256(ctx.sha256_url, ctx.iso_name);
    log("Found checksum: " + ctx.sha256);

    // Check if ISO already exists and is valid
    if is_file(dest) {
        log("Found existing ISO, verifying checksum...");
        verify_sha256(dest, ctx.sha256);
        log("Existing ISO is valid, skipping download");
        ctx.iso_path = dest;
        return ctx;
    }

    // Download via torrent (faster, distributed)
    log("Downloading " + ctx.iso_name + " via torrent (~9GB)...");
    let path = torrent(ctx.torrent_url, BUILD_DIR);
    let iso_path = path;

    if is_dir(path) {
        let expected = join_path(path, ctx.iso_name);
        if is_file(expected) {
            log("Torrent returned directory; using expected ISO: " + expected);
            iso_path = expected;
        } else {
            throw "torrent produced a directory without expected ISO file: " + path;
        }
    }
    if basename(iso_path) != ctx.iso_name {
        throw "torrent produced unexpected filename: " + basename(iso_path) + " (expected " + ctx.iso_name + ")";
    }

    log("Verifying checksum...");
    verify_sha256(iso_path, ctx.sha256);

    ctx.iso_path = iso_path;
    ctx
}

// === BUILD ===

fn is_built(ctx) {
    let rootfs_temp = join_path(BUILD_DIR, "rootfs");
    let iso_contents = join_path(BUILD_DIR, "iso-contents");
    let version_file = join_path(BUILD_DIR, ".rocky-built-version");

    // Check artifacts exist
    if !is_dir(join_path(rootfs_temp, "usr")) {
        throw "rootfs not extracted";
    }
    if !is_dir(join_path(iso_contents, "BaseOS/Packages")) {
        throw "packages not extracted";
    }

    // Version check
    let built_version = trim(read_file_or_empty(version_file));
    if built_version == "" {
        throw "version marker missing - rebuild required";
    }
    if built_version != ctx.version {
        throw "version mismatch: built " + built_version + ", want " + ctx.version;
    }

    ctx
}

fn build(ctx) {
    let iso_contents = join_path(BUILD_DIR, "iso-contents");
    let rootfs_temp = join_path(BUILD_DIR, "rootfs");
    let version_file = join_path(BUILD_DIR, ".rocky-built-version");

    // Check for stale artifacts from a different version
    let existing_version = trim(read_file_or_empty(version_file));
    if existing_version != "" && existing_version != ctx.version {
        log("Cleaning stale build artifacts from version " + existing_version);
        if is_dir(iso_contents) { rm(iso_contents); }
        if is_dir(rootfs_temp) { rm(rootfs_temp); }
        rm(version_file);
    }

    // Extract ISO using 7z (recipe extract() doesn't support ISO format)
    if !is_dir(join_path(iso_contents, "BaseOS")) {
        log("Extracting ISO to " + iso_contents);
        mkdir(iso_contents);
        shell("7z x -o" + iso_contents + " " + ctx.iso_path + " -y");
    }

    // Extract squashfs (install.img contains the rootfs)
    let squashfs = join_path(iso_contents, "images/install.img");
    if !is_file(squashfs) {
        throw "squashfs not found at: " + squashfs;
    }

    if !is_dir(join_path(rootfs_temp, "usr")) {
        log("Extracting squashfs to " + rootfs_temp);
        // -no-xattrs: avoid exit code 2 when not root (can't write SELinux xattrs)
        shell("unsquashfs -no-xattrs -d " + rootfs_temp + " " + squashfs);
        // Fix permissions: unsquashfs preserves root ownership, we need write access
        // for packages.rhai to merge supplementary RPMs later
        // Fix permissions: unsquashfs preserves root ownership and setuid bits
        // Use u+rw (not u+rwX) to ensure ALL files are readable (setuid binaries like sudo have ---s--x--x)
        log("Fixing permissions on extracted rootfs...");
        shell("chmod -R u+rw " + rootfs_temp);
    }

    // Write version marker
    write_file(version_file, ctx.version);
    log("Build complete for Rocky " + ctx.version);

    ctx
}

// === INSTALL ===
//
// For leviso's use case, artifacts stay in BUILD_DIR after build().
// install() records paths and removes bloat that leviso doesn't need.

fn is_installed(ctx) {
    // Check if paths are recorded and artifacts exist
    if ctx.rootfs_path == "" {
        throw "not installed - rootfs_path not set";
    }

    if !is_dir(join_path(ctx.rootfs_path, "usr")) {
        throw "rootfs missing at " + ctx.rootfs_path;
    }

    // iso-contents has the packages (no separate packages dir for leviso)
    let iso_contents = join_path(BUILD_DIR, "iso-contents");
    if !is_dir(join_path(iso_contents, "BaseOS/Packages")) {
        throw "packages missing at " + iso_contents;
    }

    // Check if install marker exists (bloat was removed)
    let install_marker = join_path(BUILD_DIR, ".rocky-installed");
    if !is_file(install_marker) {
        throw "install marker missing - bloat not yet removed";
    }

    ctx
}

fn install(ctx) {
    let iso_contents = join_path(BUILD_DIR, "iso-contents");
    let rootfs = join_path(BUILD_DIR, "rootfs");
    let install_marker = join_path(BUILD_DIR, ".rocky-installed");

    // Record the paths
    ctx.rootfs_path = rootfs;
    ctx.iso_contents_path = iso_contents;

    // Skip if already installed
    if is_file(install_marker) {
        log("Already installed (bloat removed)");
        return ctx;
    }

    log("Removing bloat from iso-contents...");

    // Remove installer boot files (leviso builds its own)
    let efi_dir = join_path(iso_contents, "EFI");
    if is_dir(efi_dir) {
        log("  Removing EFI/ (installer boot files)");
        rm(efi_dir);
    }

    let isolinux_dir = join_path(iso_contents, "isolinux");
    if is_dir(isolinux_dir) {
        log("  Removing isolinux/ (legacy BIOS boot)");
        rm(isolinux_dir);
    }

    // Remove images/ (squashfs already extracted to rootfs)
    let images_dir = join_path(iso_contents, "images");
    if is_dir(images_dir) {
        log("  Removing images/ (squashfs already extracted)");
        rm(images_dir);
    }

    // Remove LiveOS (not used by leviso)
    let liveos_dir = join_path(iso_contents, "LiveOS");
    if is_dir(liveos_dir) {
        log("  Removing LiveOS/");
        rm(liveos_dir);
    }

    // Remove Minimal (not used - we use full packages)
    let minimal_dir = join_path(iso_contents, "Minimal");
    if is_dir(minimal_dir) {
        log("  Removing Minimal/");
        rm(minimal_dir);
    }

    // Remove installer metadata files
    let metadata_files = [".discinfo", ".treeinfo", "media.repo", "TRANS.TBL"];
    for f in metadata_files {
        let fpath = join_path(iso_contents, f);
        if is_file(fpath) {
            log("  Removing " + f);
            rm(fpath);
        }
    }

    log("Removing bloat from rootfs...");

    // Remove Anaconda installer (leviso doesn't use it)
    let anaconda_dir = join_path(rootfs, "usr/lib64/python3.12/site-packages/pyanaconda");
    if is_dir(anaconda_dir) {
        log("  Removing pyanaconda/");
        rm(anaconda_dir);
    }

    // Remove Anaconda data
    let anaconda_share = join_path(rootfs, "usr/share/anaconda");
    if is_dir(anaconda_share) {
        log("  Removing anaconda share data");
        rm(anaconda_share);
    }

    // Remove installer-specific GTK themes
    let gtk_themes = join_path(rootfs, "usr/share/themes");
    if is_dir(gtk_themes) {
        log("  Removing GTK themes (installer UI)");
        rm(gtk_themes);
    }

    // Remove locale data (leviso builds its own)
    let locale_dir = join_path(rootfs, "usr/share/locale");
    if is_dir(locale_dir) {
        log("  Removing locale data");
        rm(locale_dir);
    }

    // Remove man pages (not needed for base extraction)
    let man_dir = join_path(rootfs, "usr/share/man");
    if is_dir(man_dir) {
        log("  Removing man pages");
        rm(man_dir);
    }

    // Remove doc (not needed for base extraction)
    let doc_dir = join_path(rootfs, "usr/share/doc");
    if is_dir(doc_dir) {
        log("  Removing documentation");
        rm(doc_dir);
    }

    // Write install marker
    write_file(install_marker, ctx.version);

    log("Install complete - bloat removed from " + BUILD_DIR);
    ctx
}

// === CLEANUP ===

fn cleanup(ctx, reason) {
    // Keep extracted payload after install; later recipes/components consume it.
    // Only perform destructive cleanup on explicit manual request.
    if reason != "manual" {
        return ctx;
    }

    let iso_contents = join_path(BUILD_DIR, "iso-contents");
    let rootfs_temp = join_path(BUILD_DIR, "rootfs");
    let version_file = join_path(BUILD_DIR, ".rocky-built-version");
    let install_marker = join_path(BUILD_DIR, ".rocky-installed");

    log("Cleaning up build artifacts...");

    if is_dir(iso_contents) {
        rm(iso_contents);
    }
    if is_dir(rootfs_temp) {
        rm(rootfs_temp);
    }
    // NOTE: ISO is preserved (expensive to re-download)
    if is_file(version_file) {
        rm(version_file);
    }
    if is_file(install_marker) {
        rm(install_marker);
    }

    log("Cleanup complete");
    ctx
}
