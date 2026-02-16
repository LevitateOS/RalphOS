// EPEL packages - dependency recipe
//
// Provides: packages not in Rocky 10 DVD but available in EPEL/Fedora
// Depends on: rocky.rhai (must run first for rootfs)
// Output: Merged RPMs in BUILD_DIR/rootfs
//
// These packages are REQUIRED for a daily-driver desktop OS but are
// not included in the Rocky 10 DVD ISO. We download them from EPEL.

let ctx = #{
    description: "EPEL packages for Rocky rootfs",
    name: "epel",
    packages_extracted: 11,
    rootfs_path: "",
    version: "1.0.3",
};

// Recipe ctx is persisted between runs. Clear run-specific paths so stale values
// from another machine/workspace cannot leak into this execution.
ctx.rootfs_path = "";

// EPEL 10 base URL
const EPEL_BASE = "https://dl.fedoraproject.org/pub/epel/10/Everything/x86_64/Packages";
const FEDORA_BASE = "https://dl.fedoraproject.org/pub/fedora/linux/releases/42/Everything/x86_64/os/Packages";

// === ACQUIRE ===

fn is_acquired(ctx) {
    let rootfs = join_path(BUILD_DIR, "rootfs");
    if !is_dir(join_path(rootfs, "usr")) {
        throw "rootfs not found - run rocky.rhai first";
    }
    ctx.rootfs_path = rootfs;
    ctx
}

fn acquire(ctx) {
    is_acquired(ctx)
}

// === BUILD ===

fn is_built(ctx) {
    let version_file = join_path(BUILD_DIR, ".epel-version");
    let actual_version = trim(read_file_or_empty(version_file));
    if actual_version != ctx.version {
        throw "version changed";
    }
    ctx
}

fn download_and_extract(cache_dir, rootfs, name, url) {
    let rpm_name = basename(url);
    let rpm_path = join_path(cache_dir, rpm_name);

    // Download if not cached
    if !is_file(rpm_path) {
        log("  Downloading: " + name);
        download(url, rpm_path);
    }

    // Extract to rootfs
    log("  Extracting: " + name);
    let cmd = "rpm2cpio '" + rpm_path + "' | cpio -idmu --quiet 2>/dev/null";
    shell_status_in(rootfs, cmd);

    // Register package in RPM database so rpm -qf works for license tracking.
    let db_cmd = "rpm --root '" + rootfs + "' -ivh --justdb --nodeps --noscripts --force '" + rpm_path + "' 2>/dev/null";
    shell_status(db_cmd);
}

fn build(ctx) {
    let rootfs = join_path(BUILD_DIR, "rootfs");
    let cache_dir = join_path(BUILD_DIR, "epel-cache");
    let version_file = join_path(BUILD_DIR, ".epel-version");

    mkdir(cache_dir);

    log("Downloading and extracting EPEL packages...");

    // BTRFS filesystem tools
    download_and_extract(cache_dir, rootfs, "btrfs-progs",
        EPEL_BASE + "/b/btrfs-progs-6.12-3.el10_0.x86_64.rpm");

    // NTFS filesystem tools
    download_and_extract(cache_dir, rootfs, "ntfs-3g-libs",
        EPEL_BASE + "/n/ntfs-3g-libs-2022.10.3-9.el10_1.x86_64.rpm");
    download_and_extract(cache_dir, rootfs, "ntfs-3g",
        EPEL_BASE + "/n/ntfs-3g-2022.10.3-9.el10_1.x86_64.rpm");
    download_and_extract(cache_dir, rootfs, "ntfsprogs",
        EPEL_BASE + "/n/ntfsprogs-2022.10.3-9.el10_1.x86_64.rpm");

    // Terminal multiplexer
    download_and_extract(cache_dir, rootfs, "screen",
        EPEL_BASE + "/s/screen-5.0.1-6.el10_2.x86_64.rpm");

    // Pipe viewer
    download_and_extract(cache_dir, rootfs, "pv",
        EPEL_BASE + "/p/pv-1.8.14-2.el10_0.x86_64.rpm");

    // Data recovery
    download_and_extract(cache_dir, rootfs, "ddrescue",
        EPEL_BASE + "/d/ddrescue-1.30-1.el10_2.x86_64.rpm");

    // libewf - Expert Witness Format library (dependency of testdisk)
    download_and_extract(cache_dir, rootfs, "libewf",
        EPEL_BASE + "/l/libewf-20140608-30.el10_0.x86_64.rpm");

    // Partition recovery (from Fedora - not in EPEL 10)
    download_and_extract(cache_dir, rootfs, "testdisk",
        FEDORA_BASE + "/t/testdisk-7.2-4.fc42.x86_64.rpm");

    // System monitor
    download_and_extract(cache_dir, rootfs, "htop",
        EPEL_BASE + "/h/htop-3.3.0-5.el10_0.x86_64.rpm");

    // 7-zip archive tools (from Fedora - not in EPEL 10)
    download_and_extract(cache_dir, rootfs, "p7zip",
        FEDORA_BASE + "/p/p7zip-16.02-32.fc42.x86_64.rpm");

    write_file(version_file, ctx.version);
    ctx.packages_extracted = 11;

    log("Extracted 11 EPEL packages");
    ctx
}

// === INSTALL ===

fn is_installed(ctx) {
    let rootfs = join_path(BUILD_DIR, "rootfs");
    let install_marker = join_path(BUILD_DIR, ".epel-installed");

    if !is_file(install_marker) {
        throw "install marker missing";
    }

    let marker_version = trim(read_file_or_empty(install_marker));
    if marker_version != ctx.version {
        throw "version mismatch";
    }

    ctx
}

fn check_binary(rootfs, path) {
    let full = join_path(rootfs, path);
    // Use exists() instead of is_file() to handle symlinks (e.g., mkfs.ntfs -> mkntfs)
    if !exists(full) {
        throw "Missing: " + path;
    }
}

fn install(ctx) {
    let rootfs = join_path(BUILD_DIR, "rootfs");
    let install_marker = join_path(BUILD_DIR, ".epel-installed");

    log("Verifying EPEL package binaries...");

    // Verify key binaries from each package
    check_binary(rootfs, "usr/sbin/btrfs");
    check_binary(rootfs, "usr/sbin/mkfs.btrfs");
    check_binary(rootfs, "usr/sbin/mkfs.ntfs");
    check_binary(rootfs, "usr/bin/ntfsfix");
    check_binary(rootfs, "usr/bin/screen");
    check_binary(rootfs, "usr/bin/pv");
    check_binary(rootfs, "usr/bin/ddrescue");
    check_binary(rootfs, "usr/bin/testdisk");
    check_binary(rootfs, "usr/bin/photorec");
    check_binary(rootfs, "usr/bin/htop");
    check_binary(rootfs, "usr/bin/7za");

    log("All EPEL binaries verified");
    write_file(install_marker, ctx.version);
    ctx
}

// === CLEANUP ===

fn cleanup(ctx, reason) {
    // Only clean up after a full run (or when manually requested).
    if reason != "manual" && reason != "auto.install.success" && reason != "auto.install.failure" {
        return ctx;
    }

    let version_file = join_path(BUILD_DIR, ".epel-version");
    let install_marker = join_path(BUILD_DIR, ".epel-installed");

    log("Cleaning EPEL state...");

    if is_file(version_file) { rm(version_file); }
    if is_file(install_marker) { rm(install_marker); }

    ctx
}
