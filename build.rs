/* build assembly language files and glue them to rust code
 *
 * Reminder: this runs on the host build system using the host's architecture.
 * Thus, a Rust toolchain that can build executables for the host arch must be installed, and
 * the host architecture must be the default toolchain target - or this script will fail.
 * For example: building a RISC-V kernel on an X86-64 server requires a toolchain that
 * can output code for both architectures, and outputs X86-64 by default.
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

/* To build diosix for a particular target, call cargo build with --target <target>

   Acceptable targets:
   * riscv32imac-unknown-none-elf
   * riscv64imac-unknown-none-elf
   * riscv64gc-unknown-none-elf

   eg: cargo build --target riscv32imac-unknown-none-elf

   The boot code should detect and use whatever hardware is present.
*/

use std::env;
use std::fs;
use std::process::Command;
use std::fs::metadata;

extern crate regex;
use regex::Regex;

/* describe a build target from its user-supplied triple */
#[derive(Clone)]
struct Target
{
    pub cpu_arch: String,    /* define the CPU architecture to generate code for */
    pub gnu_prefix: String,  /* locate the GNU as and ar tools */ 
    pub platform: String,    /* locate the platform directory */
    pub width: usize,        /* pointer width in bits */
    pub abi: String          /* define the ABI for this target */
}

impl Target
{
    /* create a target object from a full build triple string, taking the CPU arch from the first part of the triple  */
    pub fn new(triple: String) -> Target
    {
        match triple.split('-').next().expect("Badly formatted target triple").as_ref()
        {
            "riscv32imac" => Target
            {
                cpu_arch: String::from("rv32imac"),
                gnu_prefix: String::from("riscv32"),
                platform: String::from("riscv"),
                width: 32,
                abi: String::from("ilp32")
            },
            "riscv64imac" => Target
            {
                cpu_arch: String::from("rv64imac"),
                gnu_prefix: String::from("riscv64"),
                platform: String::from("riscv"),
                width: 64,
                abi: String::from("lp64")
            },
            "riscv64gc" => Target
            {
                cpu_arch: String::from("rv64gc"),
                gnu_prefix: String::from("riscv64"),
                platform: String::from("riscv"),
                width: 64,
                abi: String::from("lp64")
            },
            unknown_target => panic!("Unknown target '{}'", &unknown_target)
        }
    }
}

/* shared context of this build run */
struct Context
{
    output_dir: String, /* where we're outputting object code on the host */
    as_exec: String,    /* path to host's GNU assembler executable */
    ar_exec: String,    /* path to host's GNU archiver executable */
    target: Target      /* describe the build target */
}

fn main()
{
    /* determine which CPU and platform we're building for from target triple */
    let target = Target::new(env::var("TARGET").expect("Missing target triple, use --target with cargo"));
    let platform = target.platform.clone();

    /* create a shared context describing this build */
    let context = Context
    {
        output_dir: env::var("OUT_DIR").expect("No output directory specified"),
        as_exec: String::from(format!("{}-elf-as", target.gnu_prefix)),
        ar_exec: String::from(format!("{}-elf-ar", target.gnu_prefix)),
        target: target.clone()
    };

    let boot_supervisor_location = String::from(format!("boot/{}/vmlinux", target.gnu_prefix));
    let initrd_location = String::from(format!("boot/{}/rootfs.cpio.gz", target.gnu_prefix));

    /* check we have a supervisor and initrd to boot */
    match metadata(&boot_supervisor_location)
    {
        Err(e) => panic!("Expected boot supervisor at {}, can't find it (error: {:?})", boot_supervisor_location, e),
        _ => ()
    }
    match metadata(&initrd_location)
    {
        Err(e) => panic!("Expected initrd at {}, can't find it (error: {:?})", initrd_location, e),
        _ => ()
    }

    /* tell cargo to rebuild just these files change:
    linker scripts and any files in the platform's assembly code directories.
    also: assemble and link them */
    println!("cargo:rerun-if-changed=src/platform/{}/link.ld", platform);
    slurp_directory(format!("src/platform/{}/asm", platform), &context);
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
    let arch = &context.target.cpu_arch;
    let abi = &context.target.abi;
    let width = &context.target.width;

    /* now let's try to assemble the thing - this is where errors become fatal */
    if Command::new(as_exec)
        .arg("-march")
        .arg(arch)
        .arg("-mabi")
        .arg(abi)
        .arg("--defsym")
        .arg(format!("ptrwidth={}", width))
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
