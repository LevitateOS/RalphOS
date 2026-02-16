// Supplementary RPM Extraction - dependency recipe
//
// Provides: core utilities missing from Rocky's install.img
// Depends on: rocky.rhai (must run first)
// Output: Merged RPMs in BUILD_DIR/rootfs
//
// === Globals (provided by executor) ===
//
// BUILD_DIR  - Build directory (where rocky.rhai outputs are)
//
// === Helper functions (see rocky.rhai header for full list) ===
//
// === Package List ===
// The authoritative package list is in build() function below.
// When adding/removing packages:
//   1. Update the inline array in build()
//   2. Add verification in install() if it provides a key binary
//   3. Bump ctx.version to invalidate cache
//
// Packages NOT in Rocky 10 DVD ISO (users install later):
//   - iwd (iwctl) - WiFi via NetworkManager-wifi instead
//   - btrfs-progs - Btrfs filesystem tools
//   - htop - System monitor

// Bump version when package list changes to invalidate cache
let ctx = #{
    description: "Supplementary RPMs for Rocky rootfs",
    iso_contents_path: "",
    name: "packages",
    packages_extracted: 86,
    rootfs_path: "",
    version: "1.0.10",
};

// Recipe ctx is persisted between runs. Clear run-specific paths so stale values
// from another machine/workspace cannot leak into this execution.
ctx.rootfs_path = "";
ctx.iso_contents_path = "";

// === ACQUIRE ===
// Verify rocky.rhai outputs exist

fn is_acquired(ctx) {
    let rootfs = join_path(BUILD_DIR, "rootfs");
    let iso_contents = join_path(BUILD_DIR, "iso-contents");

    if !is_dir(join_path(rootfs, "usr")) {
        throw "rootfs not found - run rocky.rhai first";
    }
    if !is_dir(join_path(iso_contents, "BaseOS/Packages")) {
        throw "iso-contents not found - run rocky.rhai first";
    }

    ctx.rootfs_path = rootfs;
    ctx.iso_contents_path = iso_contents;
    ctx
}

fn acquire(ctx) {
    // Nothing to acquire - we depend on rocky.rhai outputs
    // Just verify they exist
    is_acquired(ctx)
}

// === BUILD ===
// Find and extract each RPM using rpm2cpio | cpio

fn load_manifest(manifest_path) {
    // Load list of already-extracted packages
    let content = read_file_or_empty(manifest_path);
    if content == "" {
        return [];
    }
    split(trim(content), "\n")
}

fn save_manifest(manifest_path, extracted) {
    let content = "";
    for pkg in extracted {
        content += pkg + "\n";
    }
    write_file(manifest_path, content);
}

fn find_rpm(iso_contents, pkg_name) {
    // Use shell to find the RPM - more reliable than Rhai string manipulation
    // Search both BaseOS and AppStream, filter for x86_64/noarch, exclude -devel/-i18n
    let baseos = iso_contents + "/BaseOS/Packages";
    let appstream = iso_contents + "/AppStream/Packages";

    let cmd = "find '" + baseos + "' '" + appstream + "' " +
              "-name '" + pkg_name + "-[0-9]*.rpm' 2>/dev/null | " +
              "grep -E '(x86_64|noarch)\\.rpm$' | " +
              "grep -v -E '(-devel-|-i18n-)' | " +
              "head -1";

    let result = trim(shell_output(cmd));
    result
}

fn is_built(ctx) {
    let version_file = join_path(BUILD_DIR, ".packages-version");
    let manifest_file = join_path(BUILD_DIR, ".packages-manifest");

    // Check if version matches
    let actual_version = trim(read_file_or_empty(version_file));
    if actual_version != ctx.version {
        throw "package list version changed (" + actual_version + " -> " + ctx.version + ") - rebuild required";
    }

    // Check manifest exists and has content
    let manifest = load_manifest(manifest_file);
    if manifest.len() == 0 {
        throw "manifest is empty - rebuild required";
    }

    // Verify expected package count (catch partial extractions)
    // 43 packages as of version 1.0.2 (dracut removed)
    if manifest.len() < 38 {
        throw "manifest has only " + manifest.len() + " packages (expected 43+) - rebuild required";
    }

    ctx.packages_extracted = manifest.len();
    ctx
}

fn build(ctx) {
    // Always compute paths from BUILD_DIR (don't rely on ctx which may not be updated)
    let rootfs = join_path(BUILD_DIR, "rootfs");
    let iso_contents = join_path(BUILD_DIR, "iso-contents");
    let version_file = join_path(BUILD_DIR, ".packages-version");
    let manifest_file = join_path(BUILD_DIR, ".packages-manifest");

    // === AUTHORITATIVE PACKAGE LIST ===
    // This is the single source of truth for packages to extract.
    // Rhai doesn't allow accessing module-level arrays in functions, so it's inline here.
    let packages = [
        // COREUTILS - many binaries missing from installer
        "coreutils", "coreutils-common",
        // PROCPS-NG - process utilities
        "procps-ng",
        // HWLOC - hardware locality (needed by htop from EPEL)
        "hwloc-libs",
        // OPENCL - OpenCL ICD loader (needed by htop from EPEL)
        "ocl-icd",
        // UTILITIES
        "which", "file", "file-libs", "diffutils", "ncurses", "ncurses-libs",
        // MISSING CORE UTILITIES
        "grep", "findutils", "tar",
        // AUTH
        "sudo", "util-linux", "util-linux-core", "shadow-utils",
        // NETWORK
        "iproute", "iproute-tc",
        // DISK
        "parted",
        // KEYBOARD/LOCALE
        "kbd", "kbd-misc",
        // GLIBC EXTRAS
        "glibc-common",
        // KMOD (module tools)
        "kmod",
        // SQUASHFS-TOOLS (for installation)
        "squashfs-tools",
        // FIRMWARE
        "microcode_ctl",
        // SSH (server and client)
        "openssh-server", "openssh-clients",
        // NETWORK TOOLS
        "NetworkManager-tui", "NetworkManager-wifi", "newt", "slang", "ethtool", "wireless-regdb",
        // HARDWARE SUPPORT
        "bluez", "bluez-libs", "pciutils", "usbutils", "alsa-utils",
        // SOUND/GPU FIRMWARE
        "alsa-sof-firmware", "libdrm", "mesa-dri-drivers",
        // TERMINAL TOOLS
        "tmux", "vim-minimal", "vim-enhanced", "vim-common", "vim-filesystem",
        // DOCUMENTATION
        "man-db", "man-pages", "libpipeline",
        // FILE MANAGERS
        "mc",
        // TEXT BROWSER
        "lynx",
        // NETWORK TOOLS (additional)
        "nmap", "bind-utils", "wget", "iputils",
        // FILE SYNC
        "rsync",
        // DISK TOOLS
        "lvm2", "mdadm", "smartmontools", "hdparm", "nvme-cli", "dmidecode",
        // BINARY INSPECTION
        "binutils",
        // CRYPTO
        "gnupg2",
        // OPENSSL - needed for password hashing (openssl passwd -6)
        // Used by install-tests and manual password setting
        "openssl",
        // GIT - version control (used everywhere)
        "git-core",
        // PYTHON - scripting language (many tools depend on it)
        "python3", "python3-libs",
        // ZIP/UNZIP - archive tools
        "zip", "unzip",
        // TREE - directory listing
        "tree",
        // PIPEWIRE - audio system
        "pipewire", "pipewire-libs", "pipewire-pulseaudio", "pipewire-alsa",
        "pipewire-utils",  // pw-cli, pw-dump, etc.
        "wireplumber", "wireplumber-libs",
        // PULSEAUDIO - compatibility tools
        "pulseaudio-utils", "pulseaudio-libs",  // pactl, paplay, parecord
        // POLKIT - authorization framework
        "polkit", "polkit-libs",
        // UPOWER - power management
        "upower", "upower-libs",
    ];

    // Load existing manifest for incremental extraction
    let extracted = load_manifest(manifest_file);
    let new_count = 0;

    log("Extracting supplementary RPMs to rootfs...");

    for pkg in packages {
        // Skip if already extracted
        let already_done = false;
        for m in extracted {
            if m == pkg {
                already_done = true;
                break;
            }
        }
        if already_done {
            continue;
        }

        // Find the RPM
        let rpm_path = find_rpm(iso_contents, pkg);
        if rpm_path == "" {
            // FAIL FAST - required package not found
            throw "Required RPM not found: " + pkg + "\n" +
                  "This package is in the list because it provides essential utilities.\n" +
                  "Without it, users will get 'command not found' errors.\n" +
                  "Check that the ISO has both BaseOS/Packages and AppStream/Packages.";
        }

        log("  Extracting: " + basename(rpm_path));

        // Extract RPM contents directly into rootfs
        // Note: cpio may return non-zero for permission warnings on existing files,
        // but extraction typically succeeds. We verify key binaries in install phase.
        let cmd = "rpm2cpio '" + rpm_path + "' | cpio -idmu --quiet 2>/dev/null";
        shell_status_in(rootfs, cmd);

        // Register package in RPM database so rpm -qf works for license tracking.
        // --justdb only writes metadata (no file extraction), --nodeps/--noscripts
        // skip dependency checks and scriptlets since files are already in place.
        let db_cmd = "rpm --root '" + rootfs + "' -ivh --justdb --nodeps --noscripts --force '" + rpm_path + "' 2>/dev/null";
        shell_status(db_cmd);

        extracted.push(pkg);
        new_count += 1;
    }

    // Save manifest and version
    save_manifest(manifest_file, extracted);
    write_file(version_file, ctx.version);

    ctx.packages_extracted = extracted.len();

    if new_count > 0 {
        log("Extracted " + new_count + " new packages (" + extracted.len() + " total)");
    } else {
        log("All " + extracted.len() + " packages already extracted");
    }

    ctx
}

// === INSTALL ===
// Verify key binaries exist from each package category

fn is_installed(ctx) {
    let rootfs = join_path(BUILD_DIR, "rootfs");
    let install_marker = join_path(BUILD_DIR, ".packages-installed");

    // Check marker exists
    if !is_file(install_marker) {
        throw "install marker missing";
    }

    // Check version matches - the marker's first line is the installed version
    let marker_content = read_file_or_empty(install_marker);
    let marker_lines = split(trim(marker_content), "\n");
    if marker_lines.len() == 0 {
        throw "install marker is empty";
    }
    let installed_version = marker_lines[0];
    if installed_version != ctx.version {
        throw "installed version mismatch (" + installed_version + " -> " + ctx.version + ")";
    }

    // Quick verification of a few critical binaries
    let critical = ["usr/bin/sudo", "usr/bin/grep", "usr/sbin/parted"];
    for bin in critical {
        if !exists(join_path(rootfs, bin)) {
            throw "critical binary missing: " + bin;
        }
    }

    ctx
}

fn install(ctx) {
    let rootfs = join_path(BUILD_DIR, "rootfs");
    let install_marker = join_path(BUILD_DIR, ".packages-installed");

    // Create symlinks that RPM alternatives system would normally create
    // man-db provides man.man-db, whatis.man-db, apropos.man-db
    // but the alternatives system creates the user-facing symlinks
    log("Creating alternatives symlinks...");
    let bin_dir = join_path(rootfs, "usr/bin");

    // man -> man.man-db
    let man_link = join_path(bin_dir, "man");
    if !is_file(man_link) {
        shell_status_in(bin_dir, "ln -sf man.man-db man");
    }

    // whatis -> whatis.man-db
    let whatis_link = join_path(bin_dir, "whatis");
    if !is_file(whatis_link) {
        shell_status_in(bin_dir, "ln -sf whatis.man-db whatis");
    }

    // apropos -> whatis (apropos is the same as whatis -a)
    let apropos_link = join_path(bin_dir, "apropos");
    if !is_file(apropos_link) {
        shell_status_in(bin_dir, "ln -sf whatis apropos");
    }

    log("Verifying key binaries from each package category...");

    // Comprehensive verification - at least one binary from each major category
    // Format: [path, package_name, category]
    let key_binaries = [
        // COREUTILS
        ["usr/bin/ls", "coreutils", "coreutils"],
        ["usr/bin/cat", "coreutils", "coreutils"],
        // PROCPS-NG
        ["usr/bin/ps", "procps-ng", "process tools"],
        ["usr/bin/free", "procps-ng", "process tools"],
        // UTILITIES
        ["usr/bin/grep", "grep", "text search"],
        ["usr/bin/find", "findutils", "file search"],
        ["usr/bin/tar", "tar", "archiving"],
        ["usr/bin/diff", "diffutils", "comparison"],
        ["usr/bin/file", "file", "file type detection"],
        ["usr/bin/which", "which", "command location"],
        // AUTH
        ["usr/bin/sudo", "sudo", "privilege escalation"],
        ["usr/bin/passwd", "shadow-utils", "password management"],
        ["usr/bin/su", "util-linux", "user switching"],
        // NETWORK
        ["usr/sbin/ip", "iproute", "network config"],
        ["usr/sbin/ss", "iproute", "socket stats"],
        // DISK
        ["usr/sbin/parted", "parted", "disk partitioning"],
        // KEYBOARD
        ["usr/bin/loadkeys", "kbd", "keyboard layout"],
        // KMOD
        ["usr/sbin/modprobe", "kmod", "module loading"],
        // SQUASHFS
        ["usr/sbin/unsquashfs", "squashfs-tools", "squashfs extraction"],
        // SSH
        ["usr/bin/ssh", "openssh-clients", "SSH client"],
        ["usr/sbin/sshd", "openssh-server", "SSH server"],
        // NETWORK TOOLS
        ["usr/bin/nmtui", "NetworkManager-tui", "network UI"],
        ["usr/sbin/ethtool", "ethtool", "ethernet tools"],
        // HARDWARE
        ["usr/bin/bluetoothctl", "bluez", "bluetooth"],
        ["usr/sbin/lspci", "pciutils", "PCI devices"],
        ["usr/bin/lsusb", "usbutils", "USB devices"],
        ["usr/bin/amixer", "alsa-utils", "audio mixer"],
        // GPU
        ["usr/lib64/dri/radeonsi_dri.so", "mesa-dri-drivers", "GPU drivers"],
        // TERMINAL
        ["usr/bin/tmux", "tmux", "terminal multiplexer"],
        ["usr/bin/vi", "vim-minimal", "text editor"],
        // GLIBC
        ["usr/bin/getent", "glibc-common", "name service lookup"],
        // OPENSSL
        ["usr/bin/openssl", "openssl", "crypto/password hashing"],
        // GIT
        ["usr/bin/git", "git-core", "version control"],
        // PYTHON
        ["usr/bin/python3", "python3", "scripting"],
        // ZIP/UNZIP
        ["usr/bin/zip", "zip", "compression"],
        ["usr/bin/unzip", "unzip", "compression"],
        // TREE
        ["usr/bin/tree", "tree", "directory listing"],
        // PIPEWIRE
        ["usr/bin/pw-cli", "pipewire", "audio"],
        ["usr/bin/wpctl", "wireplumber", "audio session"],
        ["usr/bin/pactl", "pipewire-pulseaudio", "pulseaudio compat"],
        // POLKIT
        ["usr/bin/pkexec", "polkit", "authorization"],
        // UPOWER
        ["usr/bin/upower", "upower", "power management"],
    ];

    let missing = [];
    for entry in key_binaries {
        let bin_path = entry[0];
        let full_path = join_path(rootfs, bin_path);

        if !exists(full_path) {
            missing.push(bin_path);
        }
    }

    if missing.len() > 0 {
        let msg = "Missing binaries: ";
        for m in missing {
            msg += m + ", ";
        }
        throw msg;
    }

    log("All " + key_binaries.len() + " key binaries verified across all categories");

    // Write install marker with metadata
    write_file(install_marker, ctx.version + "\n" + ctx.packages_extracted + "\nverified: " + key_binaries.len());

    ctx
}

// === CLEANUP ===

fn cleanup(ctx, reason) {
    // Only clean up after a full run (or when manually requested).
    if reason != "manual" && reason != "auto.install.success" && reason != "auto.install.failure" {
        return ctx;
    }

    let version_file = join_path(BUILD_DIR, ".packages-version");
    let manifest_file = join_path(BUILD_DIR, ".packages-manifest");
    let install_marker = join_path(BUILD_DIR, ".packages-installed");

    log("Cleaning packages state files...");

    if is_file(version_file) { rm(version_file); }
    if is_file(manifest_file) { rm(manifest_file); }
    if is_file(install_marker) { rm(install_marker); }

    log("Cleanup complete (rootfs not touched - run rocky cleanup for that)");
    ctx
}
