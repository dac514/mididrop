//! Talks to the Renoise tool on a background thread so the window never blocks.
//! Every request is one short TCP connection: send a frame, read one frame back,
//! close (the tool never closes sockets from inside its callbacks). Renoise
//! shutdown arrives separately over a one-way localhost UDP control socket.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::sync::mpsc::{Receiver, Sender};
use std::time::Duration;

use crate::wire::{self, Decoded, Records};

const CONNECT_TIMEOUT: Duration = Duration::from_millis(400);
const IO_TIMEOUT: Duration = Duration::from_secs(5);
const CONTROL_POLL: Duration = Duration::from_millis(100);

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
    /// Renoise is unloading; allow time for a tool reload to reconnect.
    Shutdown,
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
    // Where this program is, so the tool's *Launch window* can start it next time.
    let exe = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();

    // Where the tool tells us that Renoise is going away. Without it the window
    // simply stays open after Renoise quits, so a failure is only logged.
    let control = UdpSocket::bind("127.0.0.1:0").and_then(|socket| {
        socket.set_nonblocking(true)?;
        let port = socket.local_addr()?.port();
        Ok((socket, port))
    });
    let (mut shutdown_socket, shutdown_port) = match control {
        Ok((socket, port)) => (Some(socket), Some(port)),
        Err(error) => {
            eprintln!(
                "midi-drop: no control socket, the window will not close with Renoise: {error}"
            );
            (None, None)
        }
    };
    let mut control_buf = [0; 128];

    loop {
        if let Some(socket) = &shutdown_socket {
            match socket.recv_from(&mut control_buf) {
                Ok((len, address)) => {
                    if address.ip().is_loopback()
                        && matches!(
                            wire::decode(&control_buf[..len]),
                            Decoded::Frame(records) if wire::text(&records, "kind") == "shutdown"
                        )
                    {
                        if replies.send(Reply::Shutdown).is_err() {
                            return;
                        }
                        notify();
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => {
                    eprintln!("midi-drop: control socket failed, the window will not close with Renoise: {error}");
                    shutdown_socket = None;
                }
            }
        }

        let request = match requests.recv_timeout(CONTROL_POLL) {
            Ok(request) => request,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        };
        let (frame, is_drop) = match &request {
            Request::Status => {
                let frame = if let Some(port) = shutdown_port {
                    let port = port.to_string();
                    wire::encode(&[
                        ("kind", b"status"),
                        ("exe", exe.as_bytes()),
                        ("control_port", port.as_bytes()),
                    ])
                } else {
                    wire::encode(&[("kind", b"status"), ("exe", exe.as_bytes())])
                };
                (frame, false)
            }
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
