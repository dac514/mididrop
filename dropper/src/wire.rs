//! Wire format shared with the Renoise tool (`src/wire.lua`):
//!
//! ```text
//! frame := <body_len>\n<body>
//! body  := (<name> <len>\n<bytes>)*
//! ```

use std::collections::BTreeMap;

pub type Records = BTreeMap<String, Vec<u8>>;

/// Encode records as one frame. `kind` goes first, like the Lua side.
pub fn encode(records: &[(&str, &[u8])]) -> Vec<u8> {
    let mut body = Vec::new();
    for (name, value) in records {
        body.extend_from_slice(format!("{} {}\n", name, value.len()).as_bytes());
        body.extend_from_slice(value);
    }
    let mut frame = format!("{}\n", body.len()).into_bytes();
    frame.extend_from_slice(&body);
    frame
}

/// Outcome of trying to decode the bytes received so far.
#[derive(Debug, PartialEq)]
pub enum Decoded {
    /// Need more bytes.
    Incomplete,
    Frame(Records),
    Error(&'static str),
}

pub fn decode(buf: &[u8]) -> Decoded {
    let Some(nl) = buf.iter().position(|&b| b == b'\n') else {
        return if buf.len() > 20 {
            Decoded::Error("bad frame header")
        } else {
            Decoded::Incomplete
        };
    };
    let Some(total) = std::str::from_utf8(&buf[..nl])
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
    else {
        return Decoded::Error("bad frame header");
    };
    if buf.len() < nl + 1 + total {
        return Decoded::Incomplete;
    }
    let body = &buf[nl + 1..nl + 1 + total];
    let mut records = Records::new();
    let mut pos = 0;
    while pos < body.len() {
        let Some(rel) = body[pos..].iter().position(|&b| b == b'\n') else {
            return Decoded::Error("bad record header");
        };
        let header = &body[pos..pos + rel];
        let Some((name, len)) = std::str::from_utf8(header)
            .ok()
            .and_then(|h| h.split_once(' '))
            .and_then(|(n, l)| l.parse::<usize>().ok().map(|l| (n.to_string(), l)))
        else {
            return Decoded::Error("bad record header");
        };
        let start = pos + rel + 1;
        if start + len > body.len() {
            return Decoded::Error("record overruns frame");
        }
        records.insert(name, body[start..start + len].to_vec());
        pos = start + len;
    }
    Decoded::Frame(records)
}

/// A record as text (lossy), or "" when missing.
pub fn text(records: &Records, name: &str) -> String {
    records
        .get(name)
        .map(|v| String::from_utf8_lossy(v).into_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_binary() {
        let data = b"MThd\0\n\xff";
        let frame = encode(&[("kind", b"drop"), ("name", b"a.mid"), ("data", data)]);
        match decode(&frame) {
            Decoded::Frame(r) => {
                assert_eq!(text(&r, "kind"), "drop");
                assert_eq!(r["data"], data);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn matches_lua_encoding() {
        // Same bytes as `wire.encode { status = "ok", a = "1" }` in tests/wire_test.lua.
        let frame = encode(&[("status", b"ok"), ("a", b"1")]);
        assert_eq!(frame, b"16\nstatus 2\noka 1\n1");
    }

    #[test]
    fn partial_frames_wait() {
        let frame = encode(&[("kind", b"status")]);
        for cut in 0..frame.len() {
            assert_eq!(decode(&frame[..cut]), Decoded::Incomplete, "cut at {cut}");
        }
    }

    #[test]
    fn errors() {
        assert_eq!(decode(b"x\n"), Decoded::Error("bad frame header"));
        assert_eq!(decode(b"5\nab cd"), Decoded::Error("bad record header"));
        assert_eq!(
            decode(b"8\nab 99\nxx"),
            Decoded::Error("record overruns frame")
        );
    }
}
