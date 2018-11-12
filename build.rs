/* build assembly language files and glue them to rust code
 *
 * Reminder: this runs on the host build system using the host's architecture.
 * Thus, a Rust toolchain that can build executables for the host arch must be installed, and
 * the host architecture must be the default toolchain target - or this script will fail.
 * For example: building a RISC-V kernel on an X86-64 server requires a toolchain that
 * can output code for both architectures, and outputs X86-64 by default.
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* acceptable targets (selected using --target to cargo):
   riscv32imac-unknown-none-elf

   acceptable machines (selected as --features to cargo):
   sifive_u34 (SiFive E-series boards)
   qemu32_virt (32-bit Qemu Virt hardware environment)

   eg: cargo build --target riscv32imac-unknown-none-elf --features sifive_u34
*/

use std::env;
use std::fs;
use std::process::exit;
use std::process::Command;

extern crate regex;
use regex::Regex;

/* shared context of this build run */
struct Context
{
    output_dir: String, /* where we're outputting object code on the host */
    as_exec: String,    /* path to host's GNU assembler executable */
    ar_exec: String,    /* path to host's GNU archiver executable */
    arch: String,       /* target CPU architecture */
    abi: String,        /* target CPU ABI for this kernel */
}

fn main()
{
    /* first, determine which CPU we're building for from target triple */
    let target_triple = env::var("TARGET").unwrap();
    let mut target_cpu = String::new();
    let mut target_arch = String::new();
    let mut target_abi = String::new();

    if target_triple.starts_with("riscv32") == true
    {
        target_cpu.push_str("riscv32");
        target_arch.push_str("rv32imac");
        target_abi.push_str("ilp32");
    }
    else
    {
        println!(
            "Unknown target {}. Use --target to select a CPU type",
            target_triple
        );
        exit(1);
    }

    /* generate filenames for as and ar from CPU target */
    let gnu_as = String::from(format!("{}-elf-as", target_cpu));
    let gnu_ar = String::from(format!("{}-elf-ar", target_cpu));

    /* determine machine target from build system's environment variables */
    let mut target_machine = String::new();
    if env::var("CARGO_FEATURE_SIFIVE_U34").is_ok() == true
    {
        target_machine.push_str("sifive_u34");
    }
    else if env::var("CARGO_FEATURE_QEMU32_VIRT").is_ok() == true
    {
        target_machine.push_str("qemu32_virt");
    }
    else
    {
        println!("Cannot determine target machine. Use --features to select a device");
        exit(1);
    }

    let output_dir = env::var("OUT_DIR").unwrap();

    /* create a shared context describing this build */
    let context = Context {
        output_dir: output_dir,
        as_exec: gnu_as,
        ar_exec: gnu_ar,
        arch: target_arch,
        abi: target_abi,
    };

    /* tell cargo to rebuild just these files change:
    linker scripts and any files in the platform's assembly code directories.
    also: assemble and link them */
    println!(
        "cargo:rerun-if-changed=src/platform/{}/{}/link.ld",
        target_cpu, target_machine
    );
    slurp_directory(
        format!("src/platform/{}/{}/asm", target_cpu, target_machine),
        &context,
    );
    slurp_directory(format!("src/platform/{}/common/asm", target_cpu), &context);
}

/* slurp_directory
   Run through a directory of assembly source code, add each .s file to the project
   and assemble it using the given tools
   => slurp_from = path of directory to absorb
      context = build context
*/
fn slurp_directory(slurp_from: String, context: &Context)
{
    match fs::read_dir(slurp_from)
    {
        Ok(directory) =>
        {
            for file in directory
            {
                match file
                {
                    Ok(file) =>
                    {
                        /* assume everything in the asm directory can be assembled if it is a file */
                        if let Ok(metadata) = file.metadata()
                        {
                            if metadata.is_file() == true
                            {
                                println!(
                                    "cargo:rerun-if-changed={}",
                                    file.path().to_str().unwrap()
                                );
                                assemble(file.path().to_str().unwrap(), context);
                            }
                        }
                    }
                    _ =>
                    {} /* ignore empty/inaccessible directories */
                }
            }
        }
        _ =>
        {} /* ignore empty/inaccessible directories */
    }
}

/* assemble
   Attempt to assemble a given source file, which must be a .s file
   => path = path to .s file to assemble
      context = build context
*/
fn assemble(path: &str, context: &Context)
{
    /* create name from .s source file's path - extract just the leafname and drop the
    file extension. so extract 'start' from 'src/platform/blah/asm/start.s' */
    let re = Regex::new(r"(([A-Za-z0-9_]+)(/))+(?P<leaf>[A-Za-z0-9]+)(\.s)").unwrap();
    let matches = re.captures(&path);
    if matches.is_none() == true
    {
        return; /* skip non-conformant files */
    }

    /* extract leafname (sans .s extension) from the path */
    let leafname = &(matches.unwrap())["leaf"];

    /* build pathnames for the assembled .o and .a files */
    let mut object_file = context.output_dir.clone();
    object_file.push_str("/");
    object_file.push_str(leafname);
    object_file.push_str(".o");

    let mut archive_file = context.output_dir.clone();
    archive_file.push_str("/lib");
    archive_file.push_str(leafname);
    archive_file.push_str(".a");

    /* keep rust's borrow checker happy */
    let as_exec = &context.as_exec;
    let ar_exec = &context.ar_exec;
    let abi = &context.abi;
    let arch = &context.arch;

    /* now let's try to assemble the thing - this is where errors become fatal */
    if Command::new(as_exec)
        .arg("-march")
        .arg(arch)
        .arg("-mabi")
        .arg(abi)
        .arg("-o")
        .arg(&object_file)
        .arg(path)
        .status()
        .expect(format!("Failed to assemble {}", path).as_str())
        .code()
        != Some(0)
    {
        panic!("Assembler rejected {}", path);
    }

    if Command::new(ar_exec)
        .arg("crus")
        .arg(archive_file)
        .arg(object_file)
        .status()
        .expect(format!("Failed to archive {}", path).as_str())
        .code()
        != Some(0)
    {
        panic!("Archiver rejected {}", path);
    }

    /* tell cargo where to find the goodies */
    println!("cargo:rustc-link-search=native={}", context.output_dir);
    println!("cargo:rustc-link-lib=static={}", leafname);
}
