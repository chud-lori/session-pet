//! Sound playback — the Linux stand-in for afplay. First available player
//! wins: paplay (PulseAudio/PipeWire-pulse), pw-play (raw PipeWire), then
//! ffplay. No player / no file = silent, never fatal.

use std::path::Path;
use std::process::{Command, Stdio};

fn which(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths).any(|d| d.join(bin).is_file())
        })
        .unwrap_or(false)
}

pub fn play(path: &str, volume: f64) {
    if !Path::new(path).is_file() {
        return;
    }
    let vol = volume.clamp(0.1, 3.0);
    let spawn = |cmd: &mut Command| {
        let _ = cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
    };
    if which("paplay") {
        // paplay volume is linear, 65536 = 100%
        spawn(Command::new("paplay")
            .arg(format!("--volume={}", (vol * 65536.0) as u32))
            .arg(path));
    } else if which("pw-play") {
        spawn(Command::new("pw-play")
            .arg("--volume")
            .arg(format!("{vol:.2}"))
            .arg(path));
    } else if which("ffplay") {
        spawn(Command::new("ffplay")
            .args(["-nodisp", "-autoexit", "-loglevel", "quiet", "-volume"])
            .arg(format!("{}", (vol * 100.0).min(100.0) as u32))
            .arg(path));
    }
}

pub fn play_event(ev: &crate::proto::SoundEvent) {
    play(&ev.path, ev.volume);
    if ev.double {
        // double-ping: repetition beats loudness through masking
        let (path, vol) = (ev.path.clone(), ev.volume);
        gtk::glib::timeout_add_local_once(std::time::Duration::from_millis(700), move || {
            play(&path, vol);
        });
    }
}
