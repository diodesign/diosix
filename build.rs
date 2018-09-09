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
   sifive_e (SiFive E-series boards)
   spike (Spike emulator)

   eg: cargo build --target riscv32imac-unknown-none-elf --features spike
*/

use std::process::Command;
use std::process::exit;
use std::env;
use std::fs;

extern crate regex;
use regex::Regex;

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
  else if target_triple.starts_with("riscv64") == true
  {
    target_cpu.push_str("riscv64");
    target_arch.push_str("rv64g");
    target_abi.push_str("lp64q");
  }
  else
  {
    println!("Unknown target {}. Use --target to select a CPU type", target_triple);
    exit(1);
  }

  /* generate filenames for as and ar from CPU target */
  let gnu_as = String::from(format!("{}-elf-as", target_cpu));
  let gnu_ar = String::from(format!("{}-elf-ar", target_cpu));

  /* determine machine target from build system's environment variables */
  let mut target_machine = String::new();
  if env::var("CARGO_FEATURE_SIFIVE_E").is_ok() == true
  {
    target_machine.push_str("sifive_e");
  }
  else if env::var("CARGO_FEATURE_SPIKE").is_ok() == true
  {
    target_machine.push_str("spike");
  }
  else
  {
    println!("Cannot determine target machine. Use --features to select a device");
    exit(1);
  }

  let output_dir = env::var("OUT_DIR").unwrap();

  /* tell cargo to rebuild just these files change:
     linker scripts and any files in the platform's assembly code directory */
  println!("cargo:rerun-if-changed=src/platform/{}/{}/link.ld", target_cpu, target_machine);
  match fs::read_dir(format!("src/platform/{}/{}/asm", target_cpu, target_machine))
  {
    Ok(directory) => for file in directory
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
              println!("cargo:rerun-if-changed={}",file.path().to_str().unwrap());
              assemble(&output_dir, file.path().to_str().unwrap(),
                       &gnu_as, &gnu_ar, &target_arch, &target_abi);
            }
          }
        },
        _ => {} /* ignore empty/inaccessible directories */
      }
    },
    _ => {} /* ignore empty/inaccessible directories */
  }
}

/* assemble
   Attempt to assemble a given source file, which must be a .s file
   => output_dir = where to assemble our code
      path = path to .s file to assemble
      as_exec, ar_exec = assember and archive executable names,
      arch, abi = CPU architecture and ABI strings to pass to assembler
*/
fn assemble(output_dir: &String, path: &str,
            as_exec: &String, ar_exec: &String, arch: &String, abi: &String)
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
  let mut object_file = output_dir.clone();
  object_file.push_str("/");
  object_file.push_str(leafname);
  object_file.push_str(".o");

  let mut archive_file = output_dir.clone();
  archive_file.push_str("/lib");
  archive_file.push_str(leafname);
  archive_file.push_str(".a");

  /* now let's try to assemble the thing - this is where errors become fatal */
  Command::new(as_exec).arg("-fpic").arg("-march").arg(arch).arg("-mabi").arg(abi)
                       .arg("-o").arg(&object_file).arg(path)
                       .status().expect(format!("Failed to assemble {}", path).as_str());
  Command::new(ar_exec).arg("crus").arg(archive_file).arg(object_file)
                       .status().expect(format!("Failed to archive {}", path).as_str());

  /* tell cargo where to find the goodies */
  println!("cargo:rustc-link-search=native={}", output_dir);
  println!("cargo:rustc-link-lib=static={}", leafname);
}
