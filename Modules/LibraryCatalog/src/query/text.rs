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

// East Asian search needs tokenization that does not depend on spaces. Han, kana, Hangul and
// Bopomofo characters become single-character tokens; a private-use marker keeps runs separated
// by Latin text or punctuation from producing a false phrase match.
const CJK_GAP: char = '\u{E000}';

pub(super) fn is_cjk(c: char) -> bool {
    let c = c as u32;
    matches!(
        c,
        0x1100..=0x11FF
            | 0x2E80..=0x2EFF
            | 0x3005
            | 0x3007
            | 0x3021..=0x3029
            | 0x3038..=0x303B
            | 0x3040..=0x309F
            | 0x30A0..=0x30FF
            | 0x3100..=0x312F
            | 0x3130..=0x318F
            | 0x31A0..=0x31BF
            | 0x31F0..=0x31FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xA960..=0xA97F
            | 0xAC00..=0xD7AF
            | 0xD7B0..=0xD7FF
            | 0xF900..=0xFAFF
            | 0xFF66..=0xFF9F
            | 0x1B000..=0x1B16F
            | 0x20000..=0x2FA1F
            | 0x30000..=0x3FFFF
    )
}

/// A space-separated unigram index for CJK runs. Non-CJK text is a gap, not a token, so a phrase
/// query cannot span "富士Nikon山" while still matching "富士山".
pub(super) fn cjk_index(s: &str) -> String {
    let folded = searchable(s);
    let mut tokens: Vec<String> = Vec::new();
    let mut gap = false;
    for c in folded.chars() {
        if is_cjk(c) {
            if gap && !tokens.is_empty() {
                tokens.push(CJK_GAP.to_string());
            }
            gap = false;
            tokens.push(c.to_string());
        } else {
            gap = true;
        }
    }
    tokens.join(" ")
}

/// Build an FTS5 query for a one or two character CJK needle. Longer needles use the trigram
/// index; mixed or Latin short needles stay on `instr`.
pub(super) fn cjk_query(s: &str) -> Option<String> {
    let folded = searchable(s);
    let mut chars = folded.chars().filter(|c| !c.is_whitespace());
    let first = chars.next()?;
    if !is_cjk(first) {
        return None;
    }
    let mut tokens = vec![first.to_string()];
    for c in chars {
        if !is_cjk(c) || tokens.len() == 2 {
            return None;
        }
        tokens.push(c.to_string());
    }
    Some(if tokens.len() == 1 {
        format!("\"{}\"", tokens[0])
    } else {
        format!("\"{} {}\"", tokens[0], tokens[1])
    })
}

#[cfg(test)]
mod tests {
    use super::{cjk_index, cjk_query, is_cjk};

    #[test]
    fn cjk_tokens_cover_east_asian_scripts() {
        assert!(is_cjk('富'));
        assert!(is_cjk('ふ'));
        assert!(is_cjk('カ'));
        assert!(is_cjk('한'));
        assert!(is_cjk('ㄅ'));
        assert!(!is_cjk('a'));
        assert!(!is_cjk('、'));
    }

    #[test]
    fn cjk_index_marks_gaps_between_runs() {
        assert_eq!(cjk_index("富士山"), "富 士 山");
        assert_eq!(cjk_index("富士Nikon山"), "富 士 \u{E000} 山");
        assert_eq!(cjk_index("写真、山"), "写 真 \u{E000} 山");
        assert_eq!(cjk_index("plain latin"), "");
    }

    #[test]
    fn cjk_query_accepts_one_or_two_characters_only() {
        assert_eq!(cjk_query("富").as_deref(), Some("\"富\""));
        assert_eq!(cjk_query("富士").as_deref(), Some("\"富 士\""));
        assert_eq!(cjk_query("富 士").as_deref(), Some("\"富 士\""));
        assert_eq!(cjk_query("富士山"), None);
        assert_eq!(cjk_query("富士a"), None);
        assert_eq!(cjk_query("ab"), None);
    }
}
