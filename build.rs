/* build assembly language files and glue them to rust code
 *
 * Reminder: this runs on the host build system using the host's architecture.
 * Thus, a Rust toolchain that can build executables for the host arch must be installed, and
 * the host architecture must be the default toolchain target - or this script will fail.
 * For example: building a RISC-V kernel on an X86-64 server requires a toolchain that
 * can output code for both architectures, and outputs X86-64 by default.
 *
 * (c) Chris Williams, 2019-2020.
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
use std::collections::HashSet;
use std::vec::Vec;

extern crate regex;
use regex::Regex;

/* describe a build target from its user-supplied triple */
struct Target
{
    pub target: String,      /* full target name */
    pub cpu_arch: String,    /* define the CPU architecture to generate code for */
    pub gnu_prefix: String,  /* locate the GNU as and ar tools */ 
    pub platform: String,    /* locate the tail of the platform directory in src, eg riscv for src/platform-riscv */
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
                target: String::from("riscv32imac"),
                cpu_arch: String::from("rv32imac"),
                gnu_prefix: String::from("riscv32"),
                platform: String::from("riscv"),
                width: 32,
                abi: String::from("ilp32")
            },
            "riscv64imac" => Target
            {
                target: String::from("riscv64imac"),
                cpu_arch: String::from("rv64imac"),
                gnu_prefix: String::from("riscv64"),
                platform: String::from("riscv"),
                width: 64,
                abi: String::from("lp64")
            },
            "riscv64gc" => Target
            {
                target: String::from("riscv64gc"),
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
pub struct Context<'a>
{
    output_dir: String,       /* where we're outputting object code on the host */
    objects: HashSet<String>, /* set of objects to link, referenced by their full path */
    as_exec: String,          /* path to target's GNU assembler executable */
    ar_exec: String,          /* path to target's GNU archiver executable */
    ld_exec: String,          /* path to target's GNU linker executable */
    oc_exec: String,          /* path to the target's GNU objcopy executable */
    target: &'a Target        /* describe the build target */
}

fn main()
{
    /* determine which CPU and platform we're building for from target triple */
    let target = Target::new(env::var("TARGET").expect("Missing target triple, use --target with cargo"));

    /* create a shared context describing this build */
    let mut context = Context
    {
        output_dir: env::var("OUT_DIR").expect("No output directory specified"),
        objects: HashSet::new(),
        as_exec: String::from(format!("{}-linux-gnu-as", target.gnu_prefix)),
        ar_exec: String::from(format!("{}-linux-gnu-ar", target.gnu_prefix)),
        ld_exec: String::from(format!("{}-linux-gnu-ld", target.gnu_prefix)),
        oc_exec: String::from(format!("{}-linux-gnu-objcopy", target.gnu_prefix)),
        target: &target
    };

    /* provide a supervisor kernel for the first capsule to run. this should contain an executable
    that unpacks a basic filesystem and then loads more files as needed from storage.
    its job is to manage all child capsules, which should also be loaded as needed from storage.

    the boot capsule's supervisor is expected in boot/binaries/cpu/supervisor
    where cpu = target CPU architectures, such as rv32imac, rv64gc, etc */
    
    let boot_files = String::from(format!("boot/binaries/{}", target.target));
    let boot_supervisor_name = String::from("supervisor");
    let boot_supervisor = format!("{}/{}", boot_files, boot_supervisor_name);

    /* check we have a supervisor to boot, and if so, include them in the final linking process */
    match metadata(&boot_supervisor)
    {
        Err(e) => panic!("Expected boot capsule supervisor at {}, can't find it (error: {:?})", boot_supervisor, e),
        _ => package_binary(&boot_files, &boot_supervisor_name, &mut context)
    };

    /* tell cargo to rebuild if linker file changes */
    println!("cargo:rerun-if-changed=src/platform-{}/link.ld", &target.platform);

    /* assemble the platform-specific assembly code */
    assemble_directory(format!("src/platform-{}/asm", &target.platform), &mut context);

    /* package up all the generated object files into an archive and link against it */
    link_archive(&mut context);
}

/* Turn a binary file into a .o object file to link with hypervisor. 
   the following symbols will be defined pointing to the start and end
   of the object when it is located in memory and its size in bytes:

    _binary_component_start
    _binary_component_end
    _binary_component_size
   
   where component = name of component specified below

   This allows the hypervisor code to find the binary file
   in memory after the combined hypervisor executable is loaded into RAM.
   => binary_dir = path to directory containing binary file to convert
      component = leafname of the binary file within binary_dir,
                  also used to reference file as per above
      context => build context
*/
fn package_binary(binary_dir: &String, component: &String, mut context: &mut Context)
{
    /* generate path to output .o object file for this given binary */
    let object_file = format!("{}/{}.o", &context.output_dir, &component);
    let binary_file = format!("{}/{}", &binary_dir, &component);

    /* generate an intemediate .o object file from the given binary file */
    let result = Command::new(&context.ld_exec)
        .arg("-r")
        .arg("--format=binary")
        .arg(&binary_file)
        .arg("-o")
        .arg(&object_file)
        .output()
        .expect(format!("Couldn't run command to convert {} into linkable object file", &binary_file).as_str());

    if result.status.success() != true
    {
        panic!(format!("Conversion of {} to object {} failed:\n{}\n{}",
            &binary_file, &object_file, String::from_utf8(result.stdout).unwrap(), String::from_utf8(result.stderr).unwrap()));
    }

    /* when we use ld, it defines the _start, _end, _size symbols using the full filename
    of the binary file, which pollutes the symbol with the architecture and project layout, eg:
    _binary_boot_riscv64_supervisor_start

    rename the symbols so they can be accessed generically just by their component name.
    we need to convert the '/' and '.' in the path to _ FIXME: this very Unix/Linux-y */
    let symbol_prefix = format!("_binary_{}_{}_", &binary_dir.replace("/", "_").replace(".", "_"), &component);
    let renamed_prefix = format!("_binary_{}_", &component);

    /* select correct executable */
    let rename = Command::new(&context.oc_exec)
        .arg("--redefine-sym")
        .arg(format!("{}start={}start", &symbol_prefix, &renamed_prefix))
        .arg("--redefine-sym")
        .arg(format!("{}end={}end", &symbol_prefix, &renamed_prefix))
        .arg("--redefine-sym")
        .arg(format!("{}size={}size", &symbol_prefix, &renamed_prefix))
        .arg(&object_file)
        .output()
        .expect(format!("Couldn't run command to rename symbols for {}", &binary_file).as_str());

    if rename.status.success() != true
    {
        panic!(format!("Symbol rename for {} in {} failed:\n{}\n{}",
            &binary_file, &object_file, String::from_utf8(result.stdout).unwrap(), String::from_utf8(result.stderr).unwrap()));
    }

    register_object(&object_file, &mut context);
}

/* Add an object file, by its full path, to the list of objects to link with the hypervisor
   To avoid object collisions and overwrites, bail out if the given object path was already taken */
fn register_object(path: &String, context: &mut Context)
{
    if context.objects.insert(path.to_string()) == false
    {
        panic!("Cannot register object {} - an object already exists in that location", &path);
    }
}

/* Run through a directory of .s assembly source code,
   add each .s file to the project, and assemble each file using the appropriate tools
   => slurp_from = path of directory to scan for .s files to assemble
      context = build context
*/
fn assemble_directory(slurp_from: String, context: &mut Context)
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

/* Attempt to assemble a given .s source file into a .o object file
   => path = path to .s file to assemble. non-.s files are silently ignored
      context = build context
*/
fn assemble(path: &str, mut context: &mut Context)
{
    /* create name from .s source file's path - extract just the leafname and drop the
    file extension. so extract 'start' from 'src/platform-blah/asm/start.s' */
    let re = Regex::new(r"(([A-Za-z0-9_]+)(/))+(?P<leaf>[A-Za-z0-9]+)(\.s)").unwrap();
    let matches = re.captures(&path);
    if matches.is_none() == true
    {
        return; /* skip non-conformant files */
    }

    /* extract leafname (sans .s extension) from the path */
    let leafname = &(matches.unwrap())["leaf"];

    /* build pathname for the target .o file */
    let object_file = format!("{}/{}.o", &context.output_dir, &leafname);

    /* now let's try to assemble the .s into an intermediate .o */
    let result = Command::new(&context.as_exec)
        .arg("-march")
        .arg(&context.target.cpu_arch)
        .arg("-mabi")
        .arg(&context.target.abi)
        .arg("--defsym")
        .arg(format!("ptrwidth={}", &context.target.width))
        .arg("-o")
        .arg(&object_file)
        .arg(path)
        .output()
        .expect(format!("Failed to execute command to assemble {}", path).as_str());

    if result.status.success() != true
    {
        panic!(format!("Assembling {} failed:\n{}\n{}",
            &path, String::from_utf8(result.stdout).unwrap(), String::from_utf8(result.stderr).unwrap()));
    }

    register_object(&object_file, &mut context);
}

/* Create an archive containing all registered .o files and link with this archive */
fn link_archive(context: &mut Context)
{
    let archive_name = String::from("hv");
    let archive_path = format!("{}/lib{}.a", &context.output_dir, &archive_name);

    /* create archive from .o files in the output directory */
    let mut cmd = Command::new(&context.ar_exec);
    cmd.arg("crus").arg(&archive_path);

    /* add list of object files generated */
    for obj in context.objects.iter()
    {
        cmd.arg(obj);
    }

    /* run command */
    let result = cmd.output().expect(format!("Failed to execute command to archive {}", &archive_path).as_str());

    if result.status.success() != true
    {
        panic!(format!("Archiving {} failed:\n{}\n{}",
            &archive_path, String::from_utf8(result.stdout).unwrap(), String::from_utf8(result.stderr).unwrap()));
    }

    /* tell the linker where to find our archive */
    println!("cargo:rustc-link-search={}", &context.output_dir);
    println!("cargo:rustc-link-lib=static={}", &archive_name);
}
