use std::cmp::Ordering;
use unicode_normalization::UnicodeNormalization;

pub(super) fn path_tiebreak(value: &str) -> String {
    value.nfc().collect()
}

#[cfg(target_os = "macos")]
mod platform {
    use std::{cmp::Ordering, ffi::c_void, ptr};

    type Ref = *const c_void;
    #[repr(C)]
    struct Range {
        location: isize,
        length: isize,
    }
    const UTF8: u32 = 0x0800_0100;
    const CASE: usize = 1;
    const NUMERIC: usize = 64;
    const DIACRITIC: usize = 128;
    const WIDTH: usize = 256;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            a: Ref,
            s: *const u8,
            n: isize,
            encoding: u32,
            external: u8,
        ) -> Ref;
        fn CFStringCreateMutableCopy(a: Ref, max: isize, s: Ref) -> Ref;
        fn CFLocaleCreate(a: Ref, name: Ref) -> Ref;
        fn CFRelease(object: Ref);
        fn CFStringGetLength(s: Ref) -> isize;
        fn CFStringGetBytes(
            s: Ref,
            r: Range,
            encoding: u32,
            lossy: u8,
            external: u8,
            buffer: *mut u8,
            size: isize,
            used: *mut isize,
        ) -> isize;
        fn CFStringNormalize(s: Ref, form: isize);
        fn CFStringFold(s: Ref, flags: usize, locale: Ref);
        fn CFStringCompareWithOptionsAndLocale(
            a: Ref,
            b: Ref,
            r: Range,
            flags: usize,
            locale: Ref,
        ) -> isize;
    }

    // Every value here is returned by a Core Foundation Create/Copy function.
    // Keep locale and input strings alive through the non-retaining CF calls.
    struct Owned(Ref);
    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe { CFRelease(self.0) }
        }
    }
    fn string(s: &str) -> Owned {
        let raw =
            unsafe { CFStringCreateWithBytes(ptr::null(), s.as_ptr(), s.len() as isize, UTF8, 0) };
        assert!(!raw.is_null(), "CF string allocation failed");
        Owned(raw)
    }
    thread_local! {
        static LOCALE: Owned = {
            let raw = unsafe { CFLocaleCreate(ptr::null(), string("en_US_POSIX").0) };
            assert!(!raw.is_null(), "CF locale allocation failed");
            Owned(raw)
        };
    }
    pub(crate) fn fold(s: &str, accents_and_width: bool) -> String {
        let original = string(s);
        unsafe {
            let raw = CFStringCreateMutableCopy(ptr::null(), 0, original.0);
            assert!(!raw.is_null(), "CF mutable string allocation failed");
            let folded = Owned(raw);
            CFStringNormalize(folded.0, 2); // kCFStringNormalizationFormC
            let flags = if accents_and_width {
                CASE | DIACRITIC | WIDTH
            } else {
                CASE
            };
            LOCALE.with(|locale| CFStringFold(folded.0, flags, locale.0));
            let n = CFStringGetLength(folded.0);
            let mut buffer = vec![0; (n as usize) * 3];
            let mut used = 0;
            let converted = CFStringGetBytes(
                folded.0,
                Range {
                    location: 0,
                    length: n,
                },
                UTF8,
                0,
                0,
                buffer.as_mut_ptr(),
                buffer.len() as isize,
                &mut used,
            );
            assert_eq!(converted, n, "CF UTF-8 conversion failed");
            buffer.truncate(used as usize);
            String::from_utf8(buffer).expect("CF returned malformed UTF-8")
        }
    }

    pub(crate) fn natural(a: &str, b: &str) -> Ordering {
        let left = string(a);
        let right = string(b);
        let result = LOCALE.with(|locale| unsafe {
            CFStringCompareWithOptionsAndLocale(
                left.0,
                right.0,
                Range {
                    location: 0,
                    length: CFStringGetLength(left.0),
                },
                CASE | NUMERIC,
                locale.0,
            )
        });
        result.cmp(&0)
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;
    use unicode_normalization::char::is_combining_mark;

    pub(crate) fn fold(s: &str, accents_and_width: bool) -> String {
        let normalized = if accents_and_width {
            s.nfkd()
                .filter(|c| !is_combining_mark(*c))
                .collect::<String>()
        } else {
            s.nfc().collect()
        };
        normalized
            .to_lowercase()
            .replace('ß', "ss")
            .replace('ς', "σ")
            .nfc()
            .collect()
    }

    // Unbounded digit runs are compared by length and digit sequence. Numeric
    // equivalents are left equal so the same path/asset tie-breakers apply.
    pub(crate) fn natural(a: &str, b: &str) -> Ordering {
        let (a, b) = (fold(a, false), fold(b, false));
        let (mut a, mut b) = (a.as_bytes(), b.as_bytes());
        while let (Some(&x), Some(&y)) = (a.first(), b.first()) {
            if x.is_ascii_digit() && y.is_ascii_digit() {
                let n = a.iter().take_while(|v| v.is_ascii_digit()).count();
                let m = b.iter().take_while(|v| v.is_ascii_digit()).count();
                let left = &a[a[..n].iter().position(|&v| v != b'0').unwrap_or(n)..n];
                let right = &b[b[..m].iter().position(|&v| v != b'0').unwrap_or(m)..m];
                let order = left.len().cmp(&right.len()).then_with(|| left.cmp(right));
                if order != Ordering::Equal {
                    return order;
                }
                (a, b) = (&a[n..], &b[m..]);
            } else {
                if x != y {
                    return x.cmp(&y);
                }
                (a, b) = (&a[1..], &b[1..]);
            }
        }
        a.len().cmp(&b.len())
    }
}

pub(super) fn searchable(s: &str) -> String {
    platform::fold(s, true)
}
pub(super) fn tag_key(s: &str) -> String {
    platform::fold(s, false)
}
pub(super) fn natural(a: &str, b: &str) -> Ordering {
    platform::natural(a, b)
}

// A moved cache must rebuild its B-trees when its collation provider changes.
pub(super) const COLLATION_VERSION: &str = if cfg!(target_os = "macos") {
    "foundation-posix-numeric-v1"
} else {
    "unicode-numeric-v1"
};
