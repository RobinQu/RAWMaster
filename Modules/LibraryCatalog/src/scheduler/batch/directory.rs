//! Resolve the host-authorized directory once and perform every file operation relative to
//! pinned directory descriptors. The host retains its security-scoped grant for the request.
mod identity;
use self::identity::{volume_uuid, Identity, Local};
use crate::{resources, Result};
use serde::{Deserialize, Serialize};
use std::ffi::{CString, OsStr};
use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::{
    ffi::OsStrExt,
    fs::{MetadataExt, OpenOptionsExt},
};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Binding {
    path: PathBuf,
    identity: Identity,
}
impl Binding {
    pub fn legacy_name_digest(&self, writer: &str, name: &str) -> Result<String> {
        if self.identity.stable() {
            return Err("v9 name reservation has a newer directory identity".into());
        }
        self.scope()?;
        Ok(super::digest(&serde_json::to_vec(&(
            writer,
            &self.identity,
            name,
        ))?))
    }
    pub fn scope(&self) -> Result<String> {
        let (inode, birth) = self.identity.inode_birth();
        let birth = birth
            .filter(|(s, n)| *s > 0 && (1..1_000_000_000).contains(n))
            .ok_or("workbench directory lacks reliable birth time")?;
        if !self.path.is_absolute() || inode == 0 {
            return Err("invalid workbench directory identity".into());
        }
        Ok(super::digest(&serde_json::to_vec(&(inode, birth))?))
    }
}

pub(super) struct Root {
    pub binding: Binding,
    path: PathBuf,
    authorized_path: PathBuf,
    file: File,
    local: Local,
    volume: Option<String>,
}

pub(crate) fn catalog_file_identity(path: &Path) -> Result<serde_json::Value> {
    if !path.is_absolute() {
        return Err("expected absolute catalog file".into());
    }
    // Closing an ordinary Linux fd for this inode also releases process-owned SQLite locks.
    // O_PATH pins the named object for metadata checks without opening it for data access.
    #[cfg(target_os = "linux")]
    let access = libc::O_PATH;
    #[cfg(not(target_os = "linux"))]
    let access = 0;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(access | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Err("expected regular catalog file".into());
    }
    #[cfg(target_os = "linux")]
    require_catalog_read_access(&file)?;
    let local = Local::of(&meta)?;
    let mut result = serde_json::json!({"device":local.device, "inode":local.inode});
    if let (Some(uuid), Some((seconds, nanos))) = (volume_uuid(&file), local.birth) {
        result["apfs"] =
            serde_json::json!({"volumeUUID":uuid,"birthSeconds":seconds,"birthNanoseconds":nanos});
    }
    Ok(result)
}

#[cfg(target_os = "linux")]
fn require_catalog_read_access(file: &File) -> io::Result<()> {
    let fd = file.as_raw_fd();
    let flags = libc::AT_EMPTY_PATH | libc::AT_EACCESS;
    // Check the effective user's read permission on the same inode, including filesystem ACLs.
    if unsafe { libc::faccessat(fd, c"".as_ptr(), libc::R_OK, flags) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if !matches!(
        error.raw_os_error(),
        Some(libc::EINVAL | libc::ENOSYS | libc::ENOENT)
    ) {
        return Err(error);
    }
    // Older kernels/libcs lack AT_EMPTY_PATH. This procfs link still denotes the held file.
    let proc_fd = CString::new(format!("/proc/self/fd/{fd}"))?;
    if unsafe {
        libc::faccessat(
            libc::AT_FDCWD,
            proc_fd.as_ptr(),
            libc::R_OK,
            libc::AT_EACCESS,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn component(name: &OsStr) -> Result<CString> {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes == b"." || bytes == b".." || bytes.contains(&b'/') {
        return Err("invalid workbench directory entry".into());
    }
    Ok(CString::new(bytes)?)
}

fn open_at(directory: &File, name: &str, flags: i32) -> io::Result<File> {
    let name = component(OsStr::new(name))
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e.to_string()))?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK | flags,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // openat returned a new descriptor owned by this File.
    Ok(unsafe { File::from_raw_fd(fd) })
}

impl Root {
    pub fn open(path: &Path) -> Result<Self> {
        if !path.is_absolute()
            || path
                .components()
                .any(|c| c == std::path::Component::ParentDir)
        {
            return Err("expected the original absolute workbench directory".into());
        }
        let authorized_path = path.to_owned();
        let path = match (path.parent(), path.file_name()) {
            (Some(parent), Some(name)) => parent.canonicalize()?.join(name),
            _ if path == Path::new("/") => path.to_owned(),
            _ => return Err("missing workbench directory name".into()),
        };
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)?;
        let local = Local::of(&file.metadata()?)?;
        let volume = volume_uuid(&file);
        let identity = Identity::capture(&local, volume.as_deref());
        // A persisted directory without a creation identity could be replaced at the same inode.
        if !identity.has_birth() {
            return Err("target directory lacks a persistent creation identity".into());
        }
        Ok(Self {
            binding: Binding {
                path: path.clone(),
                identity,
            },
            file,
            path,
            authorized_path,
            local,
            volume,
        })
    }
    pub fn volume_uuid(&self) -> Option<&str> {
        self.volume.as_deref()
    }
    pub fn matches(&self, binding: &Binding) -> bool {
        (binding.identity.stable() || self.path == binding.path)
            && binding
                .identity
                .matches(&self.local, self.volume.as_deref())
    }
    pub fn verify_hint(&self, path: &Path) -> Result<()> {
        let hint = Self::open(path)?;
        if hint.path != self.path || hint.local != self.local || hint.volume != self.volume {
            return Err("workbench path hint differs from the authorized directory".into());
        }
        Ok(())
    }
    pub fn authorize(path: &Path, binding: &Binding) -> Result<Self> {
        let mut root = Self::open(path)?;
        if !root.matches(binding) {
            return Err("workbench target is no longer the original directory".into());
        }
        // Retain the original wire identity: a matching v9 grant stays mount-local.
        root.binding = binding.clone();
        Ok(root)
    }
    pub fn recheck(&self) -> Result<()> {
        let fresh = Self::open(&self.authorized_path)?;
        if fresh.path != self.path
            || fresh.local != self.local
            || fresh.volume != self.volume
            || !fresh.matches(&self.binding)
            || Local::of(&self.file.metadata()?)? != self.local
        {
            return Err("workbench directory changed during the operation".into());
        }
        Ok(())
    }
    fn matches_file(&self, expected: &Identity, file: &File) -> Result<bool> {
        Ok(file.metadata()?.dev() == self.local.device && expected.matches_file(file)?)
    }
    fn stage_identity(&self, file: &File, local: &Local) -> Result<Identity> {
        if local.device != self.local.device {
            return Err("workbench stage is not on the target volume".into());
        }
        if self.binding.identity.stable() {
            let uuid = volume_uuid(file);
            if uuid != self.volume {
                return Err("workbench stage does not prove the registered APFS volume".into());
            }
            Ok(Identity::capture(local, uuid.as_deref()))
        } else {
            Ok(Identity::Legacy(local.clone()))
        }
    }
    pub fn occupied(&self, name: &str) -> Result<bool> {
        let name = component(OsStr::new(name))?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                self.file.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } == 0
        {
            return Ok(true);
        }
        let err = io::Error::last_os_error();
        if err.kind() == io::ErrorKind::NotFound {
            Ok(false)
        } else {
            Err(err.into())
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Ticket {
    folder: String,
    file: String,
    folder_identity: Identity,
    identity: Identity,
    pub filename: String,
    pub sha256: String,
    pub byte_count: i64,
}

#[derive(Clone, Eq, PartialEq)]
struct Stamp {
    identity: Local,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl Stamp {
    fn read(file: &File) -> Result<Self> {
        let m = file.metadata()?;
        if !m.is_file() {
            return Err("workbench stage must be a regular file".into());
        }
        Ok(Self {
            identity: Local::of(&m)?,
            size: m.len(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        })
    }
}

pub(super) struct Verified {
    file: File,
    stamp: Stamp,
}
impl Verified {
    fn hash(file: File) -> Result<(Self, String, i64)> {
        let stamp = Stamp::read(&file)?;
        let (sha, n) = resources::transfer(&file, std::io::sink())?;
        if n <= 0 || stamp.size != n as u64 || Stamp::read(&file)? != stamp {
            return Err("workbench bytes changed while hashing".into());
        }
        file.sync_all()?;
        Ok((Self { file, stamp }, sha, n))
    }
    fn at(&self, dir: &File, name: &str) -> Result<()> {
        let current = open_at(dir, name, 0)?;
        if Stamp::read(&current)? != self.stamp || Stamp::read(&self.file)? != self.stamp {
            return Err("verified workbench file changed".into());
        }
        Ok(())
    }
}

/// Contains a freshly checked, synced stage and its directory descriptor. SQLite code retains
/// this proof while waiting for a write transaction, then rechecks the name before publishing.
pub(super) struct Stage {
    pub ticket: Ticket,
    folder: File,
    folder_local: Local,
    verified: Verified,
}
const WITNESS: &str = ".workbench-ticket-witness";

fn matches_witness(dir: &File, identity: &Identity) -> Result<bool> {
    match open_at(dir, WITNESS, 0) {
        Ok(file) => {
            let meta = file.metadata()?;
            Ok(meta.is_file() && identity.matches_file(&file)? && meta.nlink() >= 2)
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.into()),
    }
}

fn validate_stage_names(folder: &str, file: &str, extension: &str) -> Result<()> {
    let uuid = folder
        .strip_prefix(".rawmaster-export-")
        .ok_or("invalid workbench private stage")?;
    super::manifest::id(uuid)?;
    if file != format!("pixels.{extension}") && file != format!("delivery.{extension}") {
        return Err("invalid workbench stage filename".into());
    }
    Ok(())
}

impl Stage {
    pub fn read(
        root: &Root,
        relative: &str,
        filename: String,
        extension: &str,
        initial: bool,
    ) -> Result<Self> {
        let (folder, file) = relative
            .split_once('/')
            .ok_or("missing workbench private stage directory")?;
        validate_stage_names(folder, file, extension)?;
        let dir = open_at(&root.file, folder, libc::O_DIRECTORY)?;
        let folder_local = Local::of(&dir.metadata()?)?;
        let folder_identity = root.stage_identity(&dir, &folder_local)?;
        let input = open_at(&dir, file, 0)?;
        let original = Stamp::read(&input)?;
        let identity = root.stage_identity(&input, &original.identity)?;
        if !identity.has_birth() {
            if initial {
                let source = component(OsStr::new(file))?;
                let witness = component(OsStr::new(WITNESS))?;
                let status = unsafe {
                    libc::linkat(
                        dir.as_raw_fd(),
                        source.as_ptr(),
                        dir.as_raw_fd(),
                        witness.as_ptr(),
                        0,
                    )
                };
                if status != 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::AlreadyExists {
                        return Err(error.into());
                    }
                }
            }
            if !matches_witness(&dir, &identity)? {
                return Err("workbench stage has no original identity witness".into());
            }
        }
        let (verified, sha256, byte_count) = Verified::hash(input)?;
        if verified.stamp.identity != original.identity {
            return Err("workbench stage identity changed before verification".into());
        }
        dir.sync_all()?;
        root.file.sync_all()?;
        let ticket = Ticket {
            folder: folder.into(),
            file: file.into(),
            folder_identity,
            identity,
            filename,
            sha256,
            byte_count,
        };
        Ok(Self {
            ticket,
            folder: dir,
            folder_local,
            verified,
        })
    }
    pub fn check(&self, root: &Root) -> Result<()> {
        root.recheck()?;
        let fresh = open_at(&root.file, &self.ticket.folder, libc::O_DIRECTORY)?;
        if Local::of(&fresh.metadata()?)? != self.folder_local
            || Local::of(&self.folder.metadata()?)? != self.folder_local
            || !root.matches_file(&self.ticket.folder_identity, &fresh)?
            || !root.matches_file(&self.ticket.identity, &self.verified.file)?
        {
            return Err("workbench stage directory changed".into());
        }
        if !self.ticket.identity.has_birth()
            && !matches_witness(&self.folder, &self.ticket.identity)?
        {
            return Err("workbench identity witness changed".into());
        }
        self.verified.at(&self.folder, &self.ticket.file)
    }
    pub fn from_ticket(root: &Root, ticket: &Ticket, extension: &str) -> Result<Option<Self>> {
        let value = match Self::read(
            root,
            &format!("{}/{}", ticket.folder, ticket.file),
            ticket.filename.clone(),
            extension,
            false,
        ) {
            Ok(stage) => stage,
            Err(error) if missing(&*error) => return Ok(None),
            Err(error) => return Err(error),
        };
        if &value.ticket != ticket {
            return Err("prepared workbench stage no longer matches its receipt".into());
        }
        Ok(Some(value))
    }
    pub fn publish(&self, root: &Root, fence: impl Fn() -> Result<()>) -> Result<bool> {
        self.check(root)?;
        let src = component(OsStr::new(&self.ticket.file))?;
        let dest = component(OsStr::new(&self.ticket.filename))?;
        // Retain the original stage as an identity witness through ACK. Some removable volumes
        // cannot create hard links; there a dependable creation timestamp permits exclusive rename.
        fence()?;
        let linked = unsafe {
            libc::linkat(
                self.folder.as_raw_fd(),
                src.as_ptr(),
                root.file.as_raw_fd(),
                dest.as_ptr(),
                0,
            )
        };
        if linked != 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::AlreadyExists {
                return Ok(false);
            }
            if !matches!(
                error.raw_os_error(),
                Some(libc::ENOTSUP | libc::EPERM | libc::ENOSYS)
            ) || !self.ticket.identity.has_birth()
            {
                return Err(error.into());
            }
            fence()?;
            #[cfg(target_vendor = "apple")]
            let result = unsafe {
                libc::renameatx_np(
                    self.folder.as_raw_fd(),
                    src.as_ptr(),
                    root.file.as_raw_fd(),
                    dest.as_ptr(),
                    libc::RENAME_EXCL,
                )
            };
            #[cfg(target_os = "linux")]
            let result = unsafe {
                libc::renameat2(
                    self.folder.as_raw_fd(),
                    src.as_ptr(),
                    root.file.as_raw_fd(),
                    dest.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            if result != 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::AlreadyExists {
                    return Ok(false);
                }
                return Err(e.into());
            }
        }
        Ok(true)
    }
    pub fn sync_publication(&self, root: &Root) -> Result<()> {
        // Both descriptors still refer to the directories used for the exclusive syscall. The
        // SQLite lock has been released; its separately committed PREPARED receipt spans a crash.
        root.file.sync_all()?;
        self.folder.sync_all()?;
        Ok(())
    }
}

fn missing(error: &(dyn std::error::Error + 'static)) -> bool {
    error
        .downcast_ref::<io::Error>()
        .is_some_and(|e| e.kind() == io::ErrorKind::NotFound)
}
pub(super) enum Final {
    Missing,
    Conflict,
    Verified(Verified),
}
impl Ticket {
    pub fn validate_legacy(&self, binding: &Binding, extension: &str) -> Result<()> {
        validate_stage_names(&self.folder, &self.file, extension)?;
        let Identity::Legacy(root) = &binding.identity else {
            return Err("unexpected volume identity in old workbench target".into());
        };
        for identity in [&self.folder_identity, &self.identity] {
            let Identity::Legacy(local) = identity else {
                return Err("unexpected volume identity in old workbench ticket".into());
            };
            if local.device != root.device
                || local.inode == 0
                || local
                    .birth
                    .is_some_and(|(s, n)| s == 0 || !(1..1_000_000_000).contains(&n))
            {
                return Err("invalid old workbench ticket identity".into());
            }
        }
        if self.byte_count <= 0 || !super::manifest::sha256(&self.sha256) {
            return Err("invalid old workbench ticket byte receipt".into());
        }
        Ok(())
    }
    fn witness(&self, root: &Root) -> Result<bool> {
        if self.identity.has_birth() {
            return Ok(true);
        }
        let Some(folder) = self.current_folder(root)? else {
            return Ok(false);
        };
        matches_witness(&folder, &self.identity)
    }
    fn current_folder(&self, root: &Root) -> Result<Option<File>> {
        match open_at(&root.file, &self.folder, libc::O_DIRECTORY) {
            Ok(dir) if root.matches_file(&self.folder_identity, &dir)? => Ok(Some(dir)),
            Ok(_) => Ok(None),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }
    pub fn verify_final(&self, root: &Root) -> Result<Final> {
        let file = match open_at(&root.file, &self.filename, 0) {
            Ok(f) => f,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Final::Missing),
            Err(e) if matches!(e.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) => {
                return Ok(Final::Conflict)
            }
            Err(e) => return Err(e.into()),
        };
        let meta = file.metadata()?;
        if !meta.is_file()
            || !root.matches_file(&self.identity, &file)?
            || meta.len() != self.byte_count as u64
            || !self.witness(root)?
        {
            return Ok(Final::Conflict);
        }
        let (file, sha, n) = Verified::hash(file)?;
        if sha != self.sha256 || n != self.byte_count {
            return Ok(Final::Conflict);
        }
        root.file.sync_all()?;
        Ok(Final::Verified(file))
    }
    pub fn check_final(&self, root: &Root, file: &Verified) -> Result<()> {
        root.recheck()?;
        file.at(&root.file, &self.filename)?;
        if !root.matches_file(&self.identity, &file.file)? || !self.witness(root)? {
            return Err("workbench publication lost its identity witness".into());
        }
        Ok(())
    }
    pub fn cleanup(&self, root: &Root) -> Result<()> {
        root.recheck()?;
        let Some(dir) = self.current_folder(root)? else {
            return Ok(());
        };
        // Without reliable birth time, future health checks also need the retained hard link.
        if !self.identity.has_birth() && !matches_witness(&dir, &self.identity)? {
            return Ok(());
        }
        match open_at(&dir, &self.file, 0) {
            Ok(file) if root.matches_file(&self.identity, &file)? => {
                let name = component(OsStr::new(&self.file))?;
                if unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                    return Err(io::Error::last_os_error().into());
                }
                dir.sync_all()?;
            }
            Ok(_) => return Ok(()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
        }
        if self.current_folder(root)?.is_some() {
            let name = component(OsStr::new(&self.folder))?;
            if unsafe { libc::unlinkat(root.file.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) }
                == 0
            {
                root.file.sync_all()?;
            }
        }
        Ok(())
    }
}
