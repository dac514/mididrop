//! Talks to the Renoise tool on a background thread so the window never blocks.
//! Every request is one short TCP connection: send a frame, read one frame back,
//! close (the tool never closes sockets from inside its callbacks).

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::mpsc::{Receiver, Sender};
use std::time::Duration;

use crate::wire::{self, Decoded, Records};

const CONNECT_TIMEOUT: Duration = Duration::from_millis(400);
const IO_TIMEOUT: Duration = Duration::from_secs(5);

pub enum Request {
    Status,
    Drop { name: String, data: Vec<u8> },
}

pub enum Reply {
    /// Target info from a status request.
    Status(Records),
    /// The tool placed the drop; carries the summary and the new target info.
    Dropped(Records),
    /// The tool refused the drop (bad file, wrong track...).
    Rejected(String),
    /// Renoise or the tool is not reachable.
    Offline,
}

fn exchange(port: u16, frame: &[u8]) -> Result<Records, String> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream =
        TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(IO_TIMEOUT)).ok();
    stream.set_write_timeout(Some(IO_TIMEOUT)).ok();
    stream.set_nodelay(true).ok();
    stream.write_all(frame).map_err(|e| e.to_string())?;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let n = stream.read(&mut chunk).map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("connection closed before a reply".into());
        }
        buf.extend_from_slice(&chunk[..n]);
        match wire::decode(&buf) {
            Decoded::Incomplete => continue,
            Decoded::Frame(records) => return Ok(records),
            Decoded::Error(e) => return Err(e.into()),
        }
    }
}

/// Run requests until the sender is dropped. `notify` wakes the UI.
pub fn worker(port: u16, requests: Receiver<Request>, replies: Sender<Reply>, notify: impl Fn()) {
    for request in requests {
        let (frame, is_drop) = match &request {
            Request::Status => (wire::encode(&[("kind", b"status")]), false),
            Request::Drop { name, data } => (
                wire::encode(&[("kind", b"drop"), ("name", name.as_bytes()), ("data", data)]),
                true,
            ),
        };
        let reply = match exchange(port, &frame) {
            Err(_) => Reply::Offline,
            Ok(records) if wire::text(&records, "status") == "error" => {
                Reply::Rejected(wire::text(&records, "error"))
            }
            Ok(records) if is_drop => Reply::Dropped(records),
            Ok(records) => Reply::Status(records),
        };
        if replies.send(reply).is_err() {
            return;
        }
        notify();
    }
}
