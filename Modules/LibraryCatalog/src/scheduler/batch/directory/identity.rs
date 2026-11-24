use crate::Result;
use serde::{Deserialize, Serialize};
use std::fs::{File, Metadata};
use std::os::unix::fs::MetadataExt;
use std::time::UNIX_EPOCH;

type Birth = (u64, u32);

// The field order and names of the legacy shape are part of the v9 reservation digest.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Local {
    pub device: u64,
    pub inode: u64,
    #[serde(deserialize_with = "Option::deserialize")]
    pub birth: Option<Birth>,
}

impl Local {
    pub fn of(metadata: &Metadata) -> Result<Self> {
        if metadata.ino() == 0 {
            return Err("filesystem lacks a usable file identity".into());
        }
        let birth = metadata
            .created()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .filter(|time| time.as_secs() > 0 && time.subsec_nanos() != 0)
            .map(|time| (time.as_secs(), time.subsec_nanos()));
        Ok(Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            birth,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(untagged, deny_unknown_fields)]
pub(super) enum Identity {
    Legacy(Local),
    Apfs {
        #[serde(rename = "volumeUUID", deserialize_with = "decode_uuid")]
        volume_uuid: String,
        inode: u64,
        birth: Birth,
    },
}

fn decode_uuid<'de, D: serde::Deserializer<'de>>(
    input: D,
) -> std::result::Result<String, D::Error> {
    let text = String::deserialize(input)?;
    let uuid = uuid::Uuid::parse_str(&text).map_err(serde::de::Error::custom)?;
    if uuid.is_nil() || uuid.is_max() || uuid.hyphenated().to_string() != text {
        return Err(serde::de::Error::custom(
            "invalid workbench APFS volume UUID",
        ));
    }
    Ok(text)
}

impl Identity {
    pub fn capture(local: &Local, volume: Option<&str>) -> Self {
        match (volume, local.birth) {
            (Some(uuid), Some(birth)) => Self::Apfs {
                volume_uuid: uuid.into(),
                inode: local.inode,
                birth,
            },
            _ => Self::Legacy(local.clone()),
        }
    }

    pub fn matches(&self, local: &Local, volume: Option<&str>) -> bool {
        match self {
            Self::Legacy(original) => original == local,
            Self::Apfs {
                volume_uuid,
                inode,
                birth,
            } => {
                volume == Some(volume_uuid.as_str())
                    && *inode == local.inode
                    && Some(*birth) == local.birth
            }
        }
    }

    pub fn matches_file(&self, file: &File) -> Result<bool> {
        let local = Local::of(&file.metadata()?)?;
        let volume = self.stable().then(|| volume_uuid(file)).flatten();
        Ok(self.matches(&local, volume.as_deref()))
    }

    pub fn inode_birth(&self) -> (u64, Option<Birth>) {
        match self {
            Self::Legacy(original) => (original.inode, original.birth),
            Self::Apfs { inode, birth, .. } => (*inode, Some(*birth)),
        }
    }

    pub fn stable(&self) -> bool {
        matches!(self, Self::Apfs { .. })
    }
    pub fn has_birth(&self) -> bool {
        self.inode_birth().1.is_some()
    }
}

#[cfg(not(target_os = "macos"))]
pub(super) fn volume_uuid(_: &File) -> Option<String> {
    None
}

#[cfg(target_os = "macos")]
pub(super) fn volume_uuid(file: &File) -> Option<String> {
    use std::mem::{size_of, MaybeUninit};
    use std::os::fd::AsRawFd;
    #[repr(C)]
    struct Attributes {
        length: u32,
        returned: libc::attribute_set_t,
        uuid: [u8; 16],
    }
    let fd = file.as_raw_fd();
    let mut fs = MaybeUninit::<libc::statfs>::uninit();
    if unsafe { libc::fstatfs(fd, fs.as_mut_ptr()) } != 0 {
        return None;
    }
    // fstatfs initialized this local structure. Inspect the bounded type name without following paths.
    let fs = unsafe { fs.assume_init() };
    if fs.f_flags & libc::MNT_LOCAL as u32 == 0
        || !fs
            .f_fstypename
            .iter()
            .map(|&n| n as u8)
            .take_while(|&n| n != 0)
            .eq(b"apfs".iter().copied())
    {
        return None;
    }
    let mut request = libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: libc::ATTR_CMN_RETURNED_ATTRS,
        volattr: libc::ATTR_VOL_INFO | libc::ATTR_VOL_UUID,
        dirattr: 0,
        fileattr: 0,
        forkattr: 0,
    };
    // Zero initialization also makes short replies safe to inspect before rejecting their length.
    let mut reply: Attributes = unsafe { std::mem::zeroed() };
    let status = unsafe {
        libc::fgetattrlist(
            fd,
            (&raw mut request).cast(),
            (&raw mut reply).cast(),
            size_of::<Attributes>(),
            0,
        )
    };
    if status != 0
        || reply.length as usize != size_of::<Attributes>()
        || reply.returned.commonattr & libc::ATTR_CMN_RETURNED_ATTRS == 0
        || reply.returned.volattr & libc::ATTR_VOL_UUID == 0
    {
        return None;
    }
    let uuid = uuid::Uuid::from_bytes(reply.uuid);
    (!uuid.is_nil() && !uuid.is_max()).then(|| uuid.hyphenated().to_string())
}
