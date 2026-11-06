// SPDX-License-Identifier: MPL-2.0

#[cfg(unix)]
use std::fs;

use roammand_host_platform::{
    RestrictedFsError, RuntimePaths, atomic_write_private, ensure_private_directory,
    read_private_file, remove_private_file,
};
use tempfile::tempdir;

#[test]
fn private_directory_and_atomic_file_have_restrictive_permissions() {
    let temporary = tempdir().expect("temporary directory must be created");
    let directory = temporary.path().join("private");
    ensure_private_directory(&directory).expect("private directory must be created");

    let path = directory.join("state.bin");
    atomic_write_private(&path, b"first").expect("first write must succeed");
    assert_eq!(
        read_private_file(&path, 64).expect("first read must succeed"),
        b"first"
    );

    atomic_write_private(&path, b"second").expect("replacement must succeed");
    assert_eq!(
        read_private_file(&path, 64).expect("replacement read must succeed"),
        b"second"
    );

    #[cfg(unix)]
    assert_unix_mode(&directory, 0o700);
    #[cfg(unix)]
    assert_unix_mode(&path, 0o600);
}

#[test]
fn private_files_enforce_size_limits_and_idempotent_removal() {
    let temporary = tempdir().expect("temporary directory must be created");
    let directory = temporary.path().join("private");
    let path = directory.join("state.bin");
    ensure_private_directory(&directory).expect("private directory must be created");
    atomic_write_private(&path, &[0x11; 65]).expect("write must succeed");

    assert!(matches!(
        read_private_file(&path, 64),
        Err(RestrictedFsError::FileTooLarge)
    ));
    remove_private_file(&path).expect("first remove must succeed");
    remove_private_file(&path).expect("repeated remove must succeed");
}

#[test]
fn private_file_reads_support_the_largest_limit() {
    let temporary = tempdir().expect("temporary directory must be created");
    let path = temporary.path().join("state.bin");
    atomic_write_private(&path, b"value").expect("write must succeed");

    assert_eq!(
        read_private_file(&path, usize::MAX).expect("large limit must not overflow"),
        b"value"
    );
}

#[test]
fn private_file_reads_refuse_directories() {
    let temporary = tempdir().expect("temporary directory must be created");

    assert!(matches!(
        read_private_file(temporary.path(), usize::MAX),
        Err(RestrictedFsError::NotRegularFile)
    ));
}

#[cfg(unix)]
#[test]
fn private_file_reads_refuse_fifos_without_waiting_for_a_writer() {
    use nix::{sys::stat::Mode, unistd::mkfifo};

    let temporary = tempdir().expect("temporary directory must be created");
    let path = temporary.path().join("state.bin");
    mkfifo(&path, Mode::S_IRUSR | Mode::S_IWUSR).expect("FIFO must be created");

    assert!(matches!(
        read_private_file(&path, 64),
        Err(RestrictedFsError::NotRegularFile)
    ));
}

#[cfg(unix)]
#[test]
fn private_paths_refuse_symbolic_links() {
    use std::os::unix::fs::symlink;

    let temporary = tempdir().expect("temporary directory must be created");
    let real_directory = temporary.path().join("real");
    fs::create_dir(&real_directory).expect("real directory must be created");
    let linked_directory = temporary.path().join("linked");
    symlink(&real_directory, &linked_directory).expect("directory symlink must be created");

    assert!(matches!(
        ensure_private_directory(&linked_directory),
        Err(RestrictedFsError::SymbolicLink)
    ));

    let real_file = real_directory.join("real.bin");
    fs::write(&real_file, b"value").expect("real file must be written");
    let linked_file = real_directory.join("linked.bin");
    symlink(&real_file, &linked_file).expect("file symlink must be created");
    assert!(matches!(
        atomic_write_private(&linked_file, b"replacement"),
        Err(RestrictedFsError::SymbolicLink)
    ));
    assert!(matches!(
        read_private_file(&linked_file, 64),
        Err(RestrictedFsError::SymbolicLink)
    ));
}

#[test]
fn runtime_paths_prepare_independent_private_roots() {
    let temporary = tempdir().expect("temporary directory must be created");
    let paths = RuntimePaths::from_roots(
        temporary.path().join("data"),
        temporary.path().join("runtime"),
    );

    paths.prepare().expect("runtime paths must be prepared");
    assert!(paths.data_dir().is_dir());
    assert!(paths.runtime_dir().is_dir());
    assert_ne!(paths.data_dir(), paths.runtime_dir());
}

#[cfg(unix)]
fn assert_unix_mode(path: &std::path::Path, expected: u32) {
    use std::os::unix::fs::PermissionsExt;

    let mode = fs::metadata(path)
        .expect("metadata must be readable")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, expected, "mode for {}", path.display());
}
