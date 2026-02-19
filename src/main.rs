//! RalphOS Stage 00 builder (legacy transition entrypoint).
//!
//! # Deprecation Notice
//!
//! This CLI is deprecated as the primary RalphOS entrypoint.
//! New conformance-driven work belongs in `distro-variants/ralph`.

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use distro_builder::process::ensure_exists;
use recinit::{ModulePreset, TinyConfig};
use reciso::IsoConfig;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(name = "ralphos")]
#[command(about = "RalphOS Stage 00 builder")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Build Stage 00 artifacts (Ralph kernel-verified initramfs + bootable ISO)
    Build,
    /// Build only the ISO path (same as `build` for Stage 00 parity)
    Iso,
    /// Show Stage 00 artifact status
    Status,
}

struct KernelArtifacts {
    release: String,
    vmlinuz: PathBuf,
    modules_dir: PathBuf,
}

struct BasePayload {
    rootfs: PathBuf,
    live_overlay: Option<PathBuf>,
}

fn main() {
    if std::env::var_os("RALPHOS_ALLOW_LEGACY_ENTRYPOINT").is_none() {
        eprintln!(
            "Deprecated entrypoint blocked: 'ralphos'.\n\
             Use the new Stage 00 endpoint instead:\n\
               just build ralph\n\
             or:\n\
               cargo run -p distro-builder --bin distro-builder -- iso build ralph"
        );
        std::process::exit(2);
    }

    let cli = Cli::parse();
    let result = match cli.command.unwrap_or(Commands::Build) {
        Commands::Build | Commands::Iso => build_stage_00(),
        Commands::Status => print_status(),
    };

    if let Err(err) = result {
        eprintln!("Error: {:#}", err);
        std::process::exit(1);
    }
}

fn build_stage_00() -> Result<()> {
    let base_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let out_dir = distro_builder::artifact_store::central_output_dir_for_distro(&base_dir);
    fs::create_dir_all(&out_dir).with_context(|| format!("Creating {}", out_dir.display()))?;

    eprintln!("[step] Verify Ralph kernel artifacts");
    let kernel = verify_ralph_kernel(&out_dir)?;

    eprintln!("[step] Ensure RalphOS rootfs/overlay payload");
    let payload = ensure_ralph_payload(&base_dir, &out_dir)?;

    eprintln!("[step] Build Ralph initramfs");
    let initramfs = build_ralph_initramfs(&base_dir, &out_dir, &kernel.modules_dir)?;

    eprintln!("[step] Create RalphOS ISO");
    let iso = build_ralph_iso(&out_dir, &kernel.vmlinuz, &initramfs, &payload)?;

    eprintln!("[ok] RalphOS Stage 00 ready");
    eprintln!("  kernel.release: {}", kernel.release);
    eprintln!("  initramfs: {}", initramfs.display());
    eprintln!("  iso: {}", iso.display());
    if payload.live_overlay.is_none() {
        eprintln!("[warn] RalphOS live overlay not found; ISO was built without overlay.");
    }

    Ok(())
}

fn print_status() -> Result<()> {
    let base_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let out_dir = distro_builder::artifact_store::central_output_dir_for_distro(&base_dir);
    let iso = out_dir.join(distro_spec::ralph::ISO_FILENAME);
    let initramfs = out_dir.join(distro_spec::ralph::INITRAMFS_LIVE_OUTPUT);

    println!("RalphOS Stage 00 status");
    match verify_ralph_kernel(&out_dir) {
        Ok(kernel) => {
            println!("  kernel:     OK ({})", kernel.release);
            println!("  vmlinuz:    {}", kernel.vmlinuz.display());
            println!("  modules:    {}", kernel.modules_dir.display());
        }
        Err(e) => {
            println!("  kernel:     MISSING/INVALID ({:#})", e);
        }
    }

    let payload = inspect_ralph_payload(&out_dir);
    match payload {
        Ok(p) => {
            println!("  rootfs:     {}", p.rootfs.display());
            match p.live_overlay {
                Some(path) => println!("  overlay:    {}", path.display()),
                None => println!("  overlay:    (not found; optional for Stage 00)"),
            }
        }
        Err(e) => println!("  payload:    MISSING ({:#})", e),
    }

    if initramfs.is_file() {
        println!("  initramfs:  {}", initramfs.display());
    } else {
        println!("  initramfs:  MISSING ({})", initramfs.display());
    }

    if iso.is_file() {
        println!("  iso:        {}", iso.display());
    } else {
        println!("  iso:        MISSING ({})", iso.display());
    }

    Ok(())
}

fn verify_ralph_kernel(out_dir: &Path) -> Result<KernelArtifacts> {
    let rel_file = out_dir.join("kernel-build/include/config/kernel.release");
    let rel = fs::read_to_string(&rel_file)
        .with_context(|| format!("Reading {}", rel_file.display()))?
        .trim_end_matches(['\n', '\r'])
        .to_string();
    if rel.is_empty() {
        bail!("kernel.release at {} is empty", rel_file.display());
    }

    if !rel.starts_with(distro_spec::ralph::KERNEL_SOURCE.version) {
        bail!(
            "kernel.release '{}' does not start with expected version '{}'",
            rel,
            distro_spec::ralph::KERNEL_SOURCE.version
        );
    }
    if !rel.ends_with(distro_spec::ralph::KERNEL_SOURCE.localversion) {
        bail!(
            "kernel.release '{}' does not end with expected localversion '{}'",
            rel,
            distro_spec::ralph::KERNEL_SOURCE.localversion
        );
    }

    let vmlinuz = out_dir.join("staging/boot/vmlinuz");
    if !vmlinuz.is_file() {
        bail!("Missing vmlinuz: {}", vmlinuz.display());
    }

    let usr_modules = out_dir.join(format!("staging/usr/lib/modules/{}", rel));
    let lib_modules = out_dir.join(format!("staging/lib/modules/{}", rel));
    let modules_dir = if usr_modules.is_dir() {
        usr_modules
    } else if lib_modules.is_dir() {
        lib_modules
    } else {
        bail!(
            "Missing modules directory for release '{}' under staging/usr/lib/modules or staging/lib/modules",
            rel
        );
    };

    Ok(KernelArtifacts {
        release: rel,
        vmlinuz,
        modules_dir,
    })
}

fn inspect_ralph_payload(out_dir: &Path) -> Result<BasePayload> {
    let rootfs = out_dir.join(distro_spec::ralph::ROOTFS_NAME);
    if !rootfs.is_file() {
        bail!(
            "Missing RalphOS rootfs payload at {}\n\
             Build/generate a RalphOS rootfs at this path first.",
            rootfs.display()
        );
    }

    let overlay = out_dir.join("live-overlay");
    let live_overlay = if overlay.is_dir() {
        Some(overlay)
    } else {
        None
    };

    Ok(BasePayload {
        rootfs,
        live_overlay,
    })
}

fn ensure_ralph_payload(base_dir: &Path, out_dir: &Path) -> Result<BasePayload> {
    ensure_ralph_source_rootfs(base_dir)?;

    let rootfs = out_dir.join(distro_spec::ralph::ROOTFS_NAME);
    if !rootfs.is_file() {
        build_ralph_rootfs_from_source(base_dir, out_dir)?;
    }

    if !rootfs.is_file() {
        bail!(
            "Ralph rootfs build finished but {} was not produced",
            rootfs.display()
        );
    }

    let overlay_dir = out_dir.join("live-overlay");
    if !overlay_dir.is_dir() {
        distro_builder::create_systemd_live_overlay(
            out_dir,
            &distro_builder::SystemdLiveOverlayConfig {
                os_name: distro_spec::ralph::OS_NAME,
                issue_message: None,
                masked_units: &[],
                write_serial_test_profile: true,
                machine_id: None,
                enforce_utf8_locale_profile: true,
            },
        )?;
    }

    inspect_ralph_payload(out_dir)
}

fn ensure_ralph_source_rootfs(base_dir: &Path) -> Result<()> {
    ensure_ralph_deps(base_dir)?;

    let downloads = base_dir.join("downloads");
    let rootfs = downloads.join("rootfs");
    let iso_contents = downloads.join("iso-contents/BaseOS/Packages");

    if rootfs.join("usr").is_dir() && iso_contents.is_dir() {
        normalize_executable_permissions(&rootfs)?;
        return Ok(());
    }

    eprintln!("[step] Resolve Rocky base rootfs for RalphOS");
    run_ralph_recipe(base_dir, "rocky.rhai", "Rocky base rootfs")?;

    eprintln!("[step] Extract supplementary packages for RalphOS");
    run_ralph_recipe(base_dir, "packages.rhai", "supplementary packages")?;

    eprintln!("[step] Extract EPEL packages for RalphOS");
    run_ralph_recipe(base_dir, "epel.rhai", "EPEL packages")?;

    if !rootfs.join("usr").is_dir() {
        bail!(
            "Ralph source rootfs missing after recipe resolve: {}",
            rootfs.display()
        );
    }

    normalize_executable_permissions(&rootfs)?;

    Ok(())
}

fn run_ralph_recipe(base_dir: &Path, recipe_file: &str, recipe_desc: &str) -> Result<()> {
    let monorepo_dir = base_dir
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| base_dir.to_path_buf());
    let downloads_dir = base_dir.join("downloads");
    let recipe_path = base_dir.join("deps").join(recipe_file);

    ensure_exists(&recipe_path, recipe_desc).map_err(|_| {
        anyhow::anyhow!(
            "{} recipe not found at: {}",
            recipe_desc,
            recipe_path.display()
        )
    })?;

    let recipe_bin = distro_builder::recipe::find_recipe(&monorepo_dir)?;
    recipe_bin
        .run(&recipe_path, &downloads_dir)
        .with_context(|| {
            format!(
                "Running Ralph recipe '{}' ({})",
                recipe_path.display(),
                recipe_desc
            )
        })?;
    Ok(())
}

fn build_ralph_rootfs_from_source(base_dir: &Path, out_dir: &Path) -> Result<()> {
    let source_rootfs = base_dir.join("downloads/rootfs");
    if !source_rootfs.join("usr").is_dir() {
        bail!(
            "Ralph source rootfs missing at {} (run deps/rocky.rhai first)",
            source_rootfs.display()
        );
    }

    let final_output = out_dir.join(distro_spec::ralph::ROOTFS_NAME);
    let work_output = out_dir.join(format!("{}.work", distro_spec::ralph::ROOTFS_NAME));

    eprintln!("[step] Build Ralph rootfs EROFS from Ralph source rootfs");
    if work_output.exists() {
        fs::remove_file(&work_output)
            .with_context(|| format!("Removing stale {}", work_output.display()))?;
    }
    distro_builder::build_erofs_default(&source_rootfs, &work_output).with_context(|| {
        format!(
            "Building Ralph rootfs from source {}",
            source_rootfs.display()
        )
    })?;

    if final_output.exists() {
        fs::remove_file(&final_output)
            .with_context(|| format!("Removing stale {}", final_output.display()))?;
    }
    fs::rename(&work_output, &final_output).with_context(|| {
        format!(
            "Promoting rootfs {} -> {}",
            work_output.display(),
            final_output.display()
        )
    })?;
    Ok(())
}

fn normalize_executable_permissions(rootfs: &Path) -> Result<()> {
    if !rootfs.is_dir() {
        bail!(
            "rootfs not found for permission normalization: {}",
            rootfs.display()
        );
    }

    eprintln!("[step] Normalize source rootfs executable permissions");
    let status = std::process::Command::new("find")
        .arg(rootfs)
        .arg("-type")
        .arg("f")
        .arg("-perm")
        .arg("/111")
        .arg("-exec")
        .arg("chmod")
        .arg("u+r")
        .arg("{}")
        .arg("+")
        .status()
        .with_context(|| format!("Running find/chmod in {}", rootfs.display()))?;

    if !status.success() {
        bail!(
            "Failed to normalize executable permissions in {} (exit code {})",
            rootfs.display(),
            status.code().unwrap_or(-1)
        );
    }

    Ok(())
}

fn ensure_ralph_deps(base_dir: &Path) -> Result<()> {
    let required = ["deps/rocky.rhai", "deps/packages.rhai", "deps/epel.rhai"];
    for rel in required {
        let p = base_dir.join(rel);
        if !p.is_file() {
            bail!("Missing required recipe file: {}", p.display());
        }
    }
    Ok(())
}

fn ensure_busybox(base_dir: &Path) -> Result<PathBuf> {
    let downloads = base_dir.join("downloads");
    fs::create_dir_all(&downloads).with_context(|| format!("Creating {}", downloads.display()))?;

    let busybox_path = downloads.join("busybox-static");
    if busybox_path.is_file() {
        return Ok(busybox_path);
    }

    let url = std::env::var(recinit::BUSYBOX_URL_ENV)
        .unwrap_or_else(|_| recinit::BUSYBOX_URL.to_string());
    eprintln!("[step] Download busybox: {}", url);
    recinit::download_busybox(&url, &busybox_path)
        .with_context(|| format!("Downloading busybox from {}", url))?;

    Ok(busybox_path)
}

fn build_ralph_initramfs(base_dir: &Path, out_dir: &Path, modules_dir: &Path) -> Result<PathBuf> {
    let template = base_dir.join("profile/init_tiny.template");
    if !template.is_file() {
        bail!("Missing initramfs template: {}", template.display());
    }

    let busybox_path = ensure_busybox(base_dir)?;
    let initramfs = out_dir.join(distro_spec::ralph::INITRAMFS_LIVE_OUTPUT);

    let cfg = TinyConfig {
        modules_dir: modules_dir.to_path_buf(),
        busybox_path,
        template_path: template,
        output: initramfs.clone(),
        iso_label: distro_spec::ralph::ISO_LABEL.to_string(),
        rootfs_path: distro_spec::ralph::ROOTFS_ISO_PATH.to_string(),
        live_overlay_image_path: Some(distro_spec::ralph::LIVE_OVERLAY_ISO_PATH.to_string()),
        live_overlay_path: Some(distro_spec::ralph::LIVE_OVERLAY_ISO_PATH.to_string()),
        boot_devices: distro_spec::ralph::BOOT_DEVICE_PROBE_ORDER
            .iter()
            .map(|s| s.to_string())
            .collect(),
        // RalphOS Stage 00 currently targets QEMU-first boot parity.
        // Its kernel config may intentionally omit NVMe modules; keep the
        // live preset strict, but drop nvme{,-core} for now.
        module_preset: ModulePreset::Custom(ralph_live_module_names()),
        gzip_level: distro_spec::ralph::CPIO_GZIP_LEVEL,
        check_builtin: true,
        extra_template_vars: Vec::new(),
    };

    recinit::build_tiny_initramfs(&cfg, true).context("Building RalphOS initramfs")?;
    Ok(initramfs)
}

fn ralph_live_module_names() -> Vec<String> {
    distro_spec::shared::LIVE_MODULES
        .iter()
        .filter(|m| **m != "nvme-core" && **m != "nvme")
        .map(|m| (*m).to_string())
        .collect()
}

fn build_ralph_iso(
    out_dir: &Path,
    kernel: &Path,
    initramfs: &Path,
    payload: &BasePayload,
) -> Result<PathBuf> {
    let iso = out_dir.join(distro_spec::ralph::ISO_FILENAME);

    let mut cfg = IsoConfig::new(
        kernel,
        initramfs,
        &payload.rootfs,
        distro_spec::ralph::ISO_LABEL,
        &iso,
    )
    .with_os_release(
        distro_spec::ralph::OS_NAME,
        distro_spec::ralph::OS_ID,
        distro_spec::ralph::OS_VERSION,
    );

    if let Some(overlay) = &payload.live_overlay {
        cfg = cfg.with_overlay(overlay);
    }

    reciso::create_iso(&cfg).context("Creating RalphOS ISO")?;
    Ok(iso)
}
