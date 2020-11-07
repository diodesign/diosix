/* build system servives' assembly language files and glue them to rust code
 * 
 * see diosix/hypervisor/build.rs for more info
 *
 * (c) Chris Williams, 2020.
 *
 * See LICENSE for usage and copying.
 */

use std::env;
use std::fs;
use std::process::Command;
use std::collections::HashSet;

extern crate regex;
use regex::Regex;

/* describe a build target from its user-supplied triple */
struct Target
{
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
pub struct Context<'a>
{
    output_dir: String,       /* where we're outputting object code on the host */
    objects: HashSet<String>, /* set of objects to link, referenced by their full path */
    as_exec: String,          /* path to target's GNU assembler executable */
    ar_exec: String,          /* path to target's GNU archiver executable */
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
        target: &target
    };

    /* tell cargo to rebuild if linker file changes */
    println!("cargo:rerun-if-changed=src/supervisor-{}/link.ld", &target.platform);

    /* assemble the platform-specific assembly code */
    assemble_directory(format!("src/supervisor-{}/asm", &target.platform), &mut context);

    /* package up all the generated object files into an archive and link against it */
    link_archive(&mut context);
}

/* Run through a directory of .s assembly source code,
   add each .s file to the project, and assemble each file using the appropriate tools
   => slurp_from = path of directory to scan for .s files to assemble
      context = build context
*/
fn assemble_directory(slurp_from: String, context: &mut Context)
{
    /* we'll just ignore empty/inaccessible directories */
    if let Ok(directory) = fs::read_dir(slurp_from)
    {
        for file in directory
        {
            if let Ok(file) = file
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
        }
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

/* Add an object file, by its full path, to the list of objects to link with a system service application
   To avoid object collisions and overwrites, bail out if the given object path was already taken */
fn register_object(path: &String, context: &mut Context)
{
    if context.objects.insert(path.to_string()) == false
    {
        panic!("Cannot register object {} - an object already exists in that location", &path);
    }
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
