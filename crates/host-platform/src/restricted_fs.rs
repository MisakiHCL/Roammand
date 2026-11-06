// SPDX-License-Identifier: MPL-2.0

use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use thiserror::Error;

#[cfg(unix)]
const PRIVATE_DIRECTORY_MODE: u32 = 0o700;
#[cfg(unix)]
const PRIVATE_FILE_MODE: u32 = 0o600;
const TEMPORARY_FILE_ATTEMPTS: usize = 16;
static TEMPORARY_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Error)]
pub enum RestrictedFsError {
    #[error("private path must not be a symbolic link")]
    SymbolicLink,
    #[error("private directory path is not a directory")]
    NotDirectory,
    #[error("private file path is not a regular file")]
    NotRegularFile,
    #[error("private file is larger than its configured limit")]
    FileTooLarge,
    #[error("private file path has no parent or file name")]
    InvalidPath,
    #[error("private filesystem operation failed")]
    Io(#[source] io::Error),
}

impl From<io::Error> for RestrictedFsError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Creates a private directory or restricts an existing directory.
///
/// # Errors
///
/// Returns an error for symbolic links, non-directory paths, or filesystem
/// failures.
pub fn ensure_private_directory(path: &Path) -> Result<(), RestrictedFsError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => validate_directory_metadata(&metadata)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(path)?;
            validate_directory_metadata(&fs::symlink_metadata(path)?)?;
        }
        Err(error) => return Err(error.into()),
    }

    restrict_directory_permissions(path)?;
    Ok(())
}

/// Atomically creates or replaces a private file in a private directory.
///
/// # Errors
///
/// Returns an error for symbolic links, invalid paths, or filesystem failures.
pub fn atomic_write_private(path: &Path, contents: &[u8]) -> Result<(), RestrictedFsError> {
    let parent = path.parent().ok_or(RestrictedFsError::InvalidPath)?;
    let file_name = path.file_name().ok_or(RestrictedFsError::InvalidPath)?;
    ensure_private_directory(parent)?;
    reject_symbolic_link(path)?;

    let (temporary_path, mut temporary_file) = create_temporary_file(parent, file_name)?;
    let write_result = (|| -> Result<(), RestrictedFsError> {
        temporary_file.write_all(contents)?;
        temporary_file.flush()?;
        temporary_file.sync_all()?;
        drop(temporary_file);
        fs::rename(&temporary_path, path)?;
        restrict_file_permissions(path)?;
        #[cfg(unix)]
        sync_directory(parent)?;
        Ok(())
    })();

    if write_result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    write_result
}

/// Reads a private regular file up to `maximum_bytes`.
///
/// # Errors
///
/// Returns an error for symbolic links, non-regular files, oversized files, or
/// filesystem failures.
pub fn read_private_file(path: &Path, maximum_bytes: usize) -> Result<Vec<u8>, RestrictedFsError> {
    validate_file_metadata(&fs::symlink_metadata(path)?, maximum_bytes)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;

        // A replaced path must not redirect the read or block on a FIFO.
        options.custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    validate_file_metadata(&metadata, maximum_bytes)?;

    let capacity = usize::try_from(metadata.len()).map_err(|_| RestrictedFsError::FileTooLarge)?;
    let mut contents = Vec::with_capacity(capacity);
    file.take((maximum_bytes as u64).saturating_add(1))
        .read_to_end(&mut contents)?;
    if contents.len() > maximum_bytes {
        return Err(RestrictedFsError::FileTooLarge);
    }
    Ok(contents)
}

fn validate_file_metadata(
    metadata: &fs::Metadata,
    maximum_bytes: usize,
) -> Result<(), RestrictedFsError> {
    if metadata.file_type().is_symlink() {
        return Err(RestrictedFsError::SymbolicLink);
    }
    if !metadata.is_file() {
        return Err(RestrictedFsError::NotRegularFile);
    }
    if metadata.len() > maximum_bytes as u64 {
        return Err(RestrictedFsError::FileTooLarge);
    }
    Ok(())
}

/// Removes a private file if it exists.
///
/// # Errors
///
/// Returns an error for symbolic links or filesystem failures other than a
/// missing path.
pub fn remove_private_file(path: &Path) -> Result<(), RestrictedFsError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(RestrictedFsError::SymbolicLink),
        Ok(_) => {
            fs::remove_file(path)?;
            Ok(())
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn validate_directory_metadata(metadata: &fs::Metadata) -> Result<(), RestrictedFsError> {
    if metadata.file_type().is_symlink() {
        return Err(RestrictedFsError::SymbolicLink);
    }
    if !metadata.is_dir() {
        return Err(RestrictedFsError::NotDirectory);
    }
    Ok(())
}

fn reject_symbolic_link(path: &Path) -> Result<(), RestrictedFsError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(RestrictedFsError::SymbolicLink),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn create_temporary_file(
    parent: &Path,
    file_name: &std::ffi::OsStr,
) -> Result<(PathBuf, File), RestrictedFsError> {
    for _ in 0..TEMPORARY_FILE_ATTEMPTS {
        let sequence = TEMPORARY_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temporary_name = format!(
            ".{}.tmp-{}-{sequence}",
            file_name.to_string_lossy(),
            std::process::id()
        );
        let path = parent.join(temporary_name);
        match private_file_options()
            .create_new(true)
            .write(true)
            .open(&path)
        {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate a private temporary file",
    )
    .into())
}

#[cfg(unix)]
fn private_file_options() -> OpenOptions {
    use std::os::unix::fs::OpenOptionsExt;

    let mut options = OpenOptions::new();
    options.mode(PRIVATE_FILE_MODE);
    options
}

#[cfg(not(unix))]
fn private_file_options() -> OpenOptions {
    OpenOptions::new()
}

#[cfg(unix)]
fn restrict_directory_permissions(path: &Path) -> Result<(), RestrictedFsError> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(PRIVATE_DIRECTORY_MODE))?;
    Ok(())
}

#[cfg(not(unix))]
fn restrict_directory_permissions(path: &Path) -> Result<(), RestrictedFsError> {
    #[cfg(windows)]
    crate::windows_security::restrict_path_to_current_user_and_system(path)
        .map_err(RestrictedFsError::Io)?;
    Ok(())
}

#[cfg(unix)]
fn restrict_file_permissions(path: &Path) -> Result<(), RestrictedFsError> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(PRIVATE_FILE_MODE))?;
    Ok(())
}

#[cfg(not(unix))]
fn restrict_file_permissions(path: &Path) -> Result<(), RestrictedFsError> {
    #[cfg(windows)]
    crate::windows_security::restrict_path_to_current_user_and_system(path)
        .map_err(RestrictedFsError::Io)?;
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), RestrictedFsError> {
    File::open(path)?.sync_all()?;
    Ok(())
}
