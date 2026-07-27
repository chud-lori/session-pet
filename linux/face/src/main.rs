//! session-pet Linux face — native GTK renderer. The Python core
//! (linux/core.py) does all session scanning and pet-state logic; this
//! binary only draws, plays sounds, and forwards clicks.
//!
//! Runs from a repo clone (finds linux/core.py + native/assets.json by
//! walking up from the executable) or standalone (no clone): core.py and
//! assets.json are embedded at build time and extracted under
//! ~/.local/share/session-pet.

mod panel;
mod proto;
mod sound;
mod sprites;

use gtk::gdk;
use gtk::glib;
use gtk::prelude::*;
use proto::{Msg, Snapshot};
use sprites::Assets;
use std::cell::RefCell;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::rc::Rc;
use std::time::Duration;

const EMBEDDED_CORE: &str = include_str!("../../core.py");
const EMBEDDED_ASSETS: &str = include_str!("../../../native/assets.json");

fn now_epoch() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// --- roots: repo clone vs standalone install ------------------------------

struct Layout {
    core_py: PathBuf,
    assets_json: Option<PathBuf>, // None → use EMBEDDED_ASSETS
    sprites_dir: PathBuf,
    root: PathBuf, // SESSION_PET_ROOT for the core (.state/, sounds/ live here)
}

fn is_repo_root(p: &Path) -> bool {
    p.join("linux/core.py").is_file() && p.join("native/assets.json").is_file()
}

fn find_layout() -> Layout {
    let mut candidates: Vec<PathBuf> = vec![];
    if let Ok(root) = std::env::var("SESSION_PET_ROOT") {
        candidates.push(PathBuf::from(root));
    }
    if let Ok(exe) = std::env::current_exe() {
        candidates.extend(exe.ancestors().skip(1).map(Path::to_path_buf));
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.extend(cwd.ancestors().map(Path::to_path_buf));
    }
    for c in candidates {
        if is_repo_root(&c) {
            return Layout {
                core_py: c.join("linux/core.py"),
                assets_json: Some(c.join("native/assets.json")),
                sprites_dir: c.join("sprites"),
                root: c,
            };
        }
    }
    // standalone: extract the embedded core under XDG data
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").expect("HOME unset"))
                .join(".local/share")
        })
        .join("session-pet");
    let _ = std::fs::create_dir_all(data.join(".state"));
    let _ = std::fs::create_dir_all(data.join("sprites"));
    let _ = std::fs::create_dir_all(data.join("sounds"));
    let core_py = data.join("core.py");
    if std::fs::read_to_string(&core_py).ok().as_deref() != Some(EMBEDDED_CORE) {
        std::fs::write(&core_py, EMBEDDED_CORE).expect("cannot write core.py");
    }
    Layout {
        core_py,
        assets_json: None,
        sprites_dir: data.join("sprites"),
        root: data,
    }
}

// --- pet window state ------------------------------------------------------

struct St {
    snap: Snapshot,
    frame: i64,
    facing: f64,
    hidden_until: f64,
    // drag bookkeeping
    press_root: Option<(f64, f64)>,
    press_origin: (i32, i32),
    dragged: bool,
    layer_shell: bool,
}

fn main() {
    let scale: f64 = std::env::args()
        .skip(1)
        .find_map(|a| a.parse::<i64>().ok())
        .unwrap_or(5)
        .clamp(3, 12) as f64;
    let w = 18.0 * scale;
    let h = 23.0 * scale;

    // GTK3 prefers the native Wayland backend on a Wayland session, where
    // set_keep_above/move_/position are silent no-ops — the pet's whole
    // windowing model. Pin XWayland unless the user overrides; layer-shell
    // builds stay native Wayland (that's their point).
    #[cfg(not(feature = "layer-shell"))]
    if std::env::var_os("GDK_BACKEND").is_none() {
        std::env::set_var("GDK_BACKEND", "x11");
    }

    let layout = find_layout();
    let assets_text = layout
        .assets_json
        .as_ref()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_else(|| EMBEDDED_ASSETS.to_string());
    let assets = Rc::new(sprites::load_assets(&assets_text, Some(&layout.sprites_dir)));

    gtk::init().expect("GTK init failed — is a display available?");
    load_css();

    // --- spawn the core
    let mut child = Command::new("python3")
        .arg(&layout.core_py)
        .arg("--serve")
        .env("SESSION_PET_ROOT", &layout.root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("cannot start python3 core — is python3 installed?");
    let core_in = Rc::new(RefCell::new(child.stdin.take().unwrap()));
    let core_out = child.stdout.take().unwrap();
    let child = Rc::new(RefCell::new(child));

    // deprecated in glib 0.18 but fully functional — the async-channel
    // replacement would add a dependency for zero behavior change
    #[allow(deprecated)]
    let (tx, rx) = glib::MainContext::channel::<Msg>(glib::Priority::DEFAULT);
    std::thread::spawn(move || {
        for line in BufReader::new(core_out).lines() {
            let Ok(line) = line else { break };
            if let Ok(msg) = serde_json::from_str::<Msg>(&line) {
                if tx.send(msg).is_err() {
                    break;
                }
            }
        }
    });

    let send: panel::CmdSender = {
        let core_in = core_in.clone();
        Rc::new(move |v: serde_json::Value| {
            let mut w = core_in.borrow_mut();
            let _ = writeln!(w, "{v}");
            let _ = w.flush();
        })
    };

    // --- pet window
    let window = gtk::Window::new(gtk::WindowType::Toplevel);
    window.set_decorated(false);
    window.set_app_paintable(true);
    window.set_keep_above(true);
    window.set_skip_taskbar_hint(true);
    window.set_skip_pager_hint(true);
    window.set_type_hint(gdk::WindowTypeHint::Utility);
    window.set_default_size(w as i32, h as i32);
    window.set_resizable(false);
    window.stick();
    if let Some(screen) = GtkWindowExt::screen(&window) {
        if let Some(visual) = screen.rgba_visual() {
            window.set_visual(Some(&visual)); // per-pixel transparency
        }
    }

    let st = Rc::new(RefCell::new(St {
        snap: Snapshot::default(),
        frame: 0,
        facing: 1.0,
        hidden_until: 0.0,
        press_root: None,
        press_origin: (0, 0),
        dragged: false,
        layer_shell: false,
    }));

    // pure-Wayland overlay via layer-shell where the compositor supports it
    // (KDE, sway, Hyprland — not GNOME); everywhere else a normal X11/XWayland
    // window with keep-above. Positioning APIs are no-ops under layer-shell.
    #[cfg(feature = "layer-shell")]
    if gtk_layer_shell::is_supported() {
        gtk_layer_shell::init_for_window(&window);
        gtk_layer_shell::set_layer(&window, gtk_layer_shell::Layer::Overlay);
        gtk_layer_shell::set_anchor(&window, gtk_layer_shell::Edge::Bottom, true);
        gtk_layer_shell::set_anchor(&window, gtk_layer_shell::Edge::Right, true);
        gtk_layer_shell::set_margin(&window, gtk_layer_shell::Edge::Bottom, 40);
        gtk_layer_shell::set_margin(&window, gtk_layer_shell::Edge::Right, 30);
        st.borrow_mut().layer_shell = true;
    }

    let area = gtk::DrawingArea::new();
    window.add(&area);
    {
        let st = st.clone();
        let assets = assets.clone();
        area.connect_draw(move |a, ctx| {
            draw_pet(a, ctx, &st.borrow(), &assets, scale);
            glib::Propagation::Proceed
        });
    }

    let pet_panel = Rc::new(panel::Panel::new(&assets, send.clone()));

    // --- input: drag to move, click for panel, right-click for menu
    window.add_events(
        gdk::EventMask::BUTTON_PRESS_MASK
            | gdk::EventMask::BUTTON_RELEASE_MASK
            | gdk::EventMask::POINTER_MOTION_MASK,
    );
    {
        let st = st.clone();
        window.connect_button_press_event(move |win, ev| {
            if ev.button() == 1 {
                let mut s = st.borrow_mut();
                s.press_root = Some(ev.root());
                s.press_origin = win.position();
                s.dragged = false;
            }
            glib::Propagation::Proceed
        });
    }
    {
        let st = st.clone();
        window.connect_motion_notify_event(move |win, ev| {
            let mut s = st.borrow_mut();
            if let Some((rx0, ry0)) = s.press_root {
                let (rx, ry) = ev.root();
                let (dx, dy) = (rx - rx0, ry - ry0);
                if dx.abs() + dy.abs() > 3.0 {
                    s.dragged = true;
                }
                if s.dragged && !s.layer_shell {
                    win.move_(
                        s.press_origin.0 + dx as i32,
                        s.press_origin.1 + dy as i32,
                    );
                }
            }
            glib::Propagation::Proceed
        });
    }
    {
        let st = st.clone();
        let pet_panel = pet_panel.clone();
        let assets = assets.clone();
        let send = send.clone();
        let child_q = child.clone();
        window.connect_button_release_event(move |win, ev| {
            match ev.button() {
                1 => {
                    let dragged = {
                        let mut s = st.borrow_mut();
                        s.press_root = None;
                        s.dragged
                    };
                    if !dragged {
                        toggle_panel(&pet_panel, win, &st.borrow().snap, &assets);
                    }
                }
                3 => {
                    show_menu(win, ev, &st, &pet_panel, &send, &child_q);
                }
                _ => {}
            }
            glib::Propagation::Proceed
        });
    }

    // --- snapshot / sound intake
    {
        let st = st.clone();
        let pet_panel = pet_panel.clone();
        let assets = assets.clone();
        let window = window.clone();
        rx.attach(None, move |msg| {
            match msg {
                Msg::Snapshot(snap) => {
                    let mut s = st.borrow_mut();
                    // needs-input brings the pet back from "hide 30 min" early
                    if s.hidden_until > 0.0
                        && (snap.unhide
                            || snap.sessions.iter().any(|x| x.phase == "input"))
                    {
                        s.hidden_until = 0.0;
                        window.show_all();
                    }
                    s.snap = snap;
                    if pet_panel.window.is_visible() {
                        pet_panel.refresh(&s.snap, &assets);
                    }
                }
                Msg::Sound(ev) => sound::play_event(&ev),
            }
            glib::ControlFlow::Continue
        });
    }

    // --- animation tick (4 fps, like the Mac pet's visible cadence)
    {
        let st = st.clone();
        let area = area.clone();
        let window = window.clone();
        glib::timeout_add_local(Duration::from_millis(250), move || {
            let mut s = st.borrow_mut();
            s.frame += 1;
            if s.hidden_until > 0.0 && now_epoch() > s.hidden_until {
                s.hidden_until = 0.0;
                window.show_all();
            }
            drop(s);
            area.queue_draw();
            glib::ControlFlow::Continue
        });
    }

    {
        let child = child.clone();
        window.connect_delete_event(move |_, _| {
            let _ = child.borrow_mut().kill();
            gtk::main_quit();
            glib::Propagation::Proceed
        });
    }

    window.show_all();
    // bottom-right corner of the primary monitor (no-op under layer-shell)
    if !st.borrow().layer_shell {
        if let Some(display) = gdk::Display::default() {
            if let Some(mon) = display.primary_monitor().or_else(|| display.monitor(0)) {
                let g = mon.geometry();
                window.move_(
                    g.x() + g.width() - w as i32 - 30,
                    g.y() + g.height() - h as i32 - 60,
                );
            }
        }
    }
    gtk::main();
}

fn toggle_panel(p: &panel::Panel, pet_win: &gtk::Window, snap: &Snapshot, assets: &Assets) {
    if p.window.is_visible() {
        p.window.hide();
        return;
    }
    p.refresh(snap, assets);
    p.window.show_all();
    let (px, py) = pet_win.position();
    let pw = p.window.size().0;
    let x = if px - pw - 10 > 0 { px - pw - 10 } else { px + pet_win.size().0 + 10 };
    p.window.move_(x.max(0), (py - 120).max(10));
}

fn show_menu(
    win: &gtk::Window,
    ev: &gdk::EventButton,
    st: &Rc<RefCell<St>>,
    p: &Rc<panel::Panel>,
    send: &panel::CmdSender,
    child: &Rc<RefCell<Child>>,
) {
    let menu = gtk::Menu::new();
    let open = gtk::MenuItem::with_label("Open panel");
    {
        let win = win.clone();
        let st = st.clone();
        let p = p.clone();
        open.connect_activate(move |_| {
            // assets live inside the panel's picker already; refresh happens
            // on the next snapshot — just show it near the pet
            if !p.window.is_visible() {
                p.window.show_all();
                let (px, py) = win.position();
                let pw = p.window.size().0;
                let x = if px - pw - 10 > 0 { px - pw - 10 } else { px + win.size().0 + 10 };
                p.window.move_(x.max(0), (py - 120).max(10));
            }
            let _ = st.borrow(); // keep signature uniform; state read on snapshot
        });
    }
    menu.append(&open);
    let sound_on = st.borrow().snap.pet.sound;
    let sound = gtk::CheckMenuItem::with_label("Sound");
    sound.set_active(sound_on);
    {
        let send = send.clone();
        sound.connect_toggled(move |m| {
            send(serde_json::json!({"cmd": "set", "key": "sound",
                                    "value": m.is_active()}));
        });
    }
    menu.append(&sound);
    let hide = gtk::MenuItem::with_label("Hide 30 min (returns if an agent needs you)");
    {
        let st = st.clone();
        let win = win.clone();
        let p = p.clone();
        hide.connect_activate(move |_| {
            st.borrow_mut().hidden_until = now_epoch() + 1800.0;
            p.window.hide();
            win.hide();
        });
    }
    menu.append(&hide);
    menu.append(&gtk::SeparatorMenuItem::new());
    let quit = gtk::MenuItem::with_label("Quit pet");
    {
        let child = child.clone();
        quit.connect_activate(move |_| {
            let _ = child.borrow_mut().kill();
            gtk::main_quit();
        });
    }
    menu.append(&quit);
    menu.show_all();
    menu.popup_easy(ev.button(), ev.time());
}

fn load_css() {
    let css = gtk::CssProvider::new();
    let _ = css.load_from_data(
        b"
        .pet-panel { background-color: rgba(24, 24, 37, 0.97);
                     color: #cdd6f4; font-family: monospace; }
        .pet-panel label { color: #cdd6f4; }
        .pet-panel .dim { color: #7f849c; font-size: 90%; }
        .pet-panel .card { padding: 4px 2px; }
        .pet-panel row { border-radius: 8px; }
        .pet-panel row:hover { background-color: rgba(60, 60, 80, 0.6); }
        .pet-panel progressbar progress { background-color: #a6e3a1; }
        ",
    );
    if let Some(screen) = gdk::Screen::default() {
        gtk::StyleContext::add_provider_for_screen(
            &screen,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

// --- drawing — port of native/src/PetView.swift (cairo y grows DOWN) -------

fn puts(ctx: &gtk::cairo::Context, text: &str, x: f64, y: f64,
        rgb: (f64, f64, f64), size: f64, bold: bool) {
    ctx.select_font_face(
        "monospace",
        gtk::cairo::FontSlant::Normal,
        if bold { gtk::cairo::FontWeight::Bold } else { gtk::cairo::FontWeight::Normal },
    );
    ctx.set_font_size(size);
    ctx.set_source_rgb(rgb.0, rgb.1, rgb.2);
    ctx.move_to(x, y);
    let _ = ctx.show_text(text);
}

const C_FG: (f64, f64, f64) = (0.80, 0.84, 0.96);
const C_MUTED: (f64, f64, f64) = (0.50, 0.52, 0.61);
const C_ACCENT: (f64, f64, f64) = (0.65, 0.89, 0.63);
const C_WARN: (f64, f64, f64) = (1.00, 0.82, 0.40);
const C_INPUT: (f64, f64, f64) = (0.95, 0.55, 0.66);
const C_STALLED: (f64, f64, f64) = (0.83, 0.64, 0.45);

fn draw_pet(area: &gtk::DrawingArea, ctx: &gtk::cairo::Context, st: &St,
            assets: &Assets, s: f64) {
    let w = area.allocated_width() as f64;
    let h = area.allocated_height() as f64;
    // transparent clear
    ctx.set_operator(gtk::cairo::Operator::Source);
    ctx.set_source_rgba(0.0, 0.0, 0.0, 0.0);
    let _ = ctx.paint();
    ctx.set_operator(gtk::cairo::Operator::Over);

    let snap = &st.snap;
    let pet = &snap.pet;
    let mode = snap.mode.as_str();
    let frame = st.frame;
    let now = now_epoch();

    let sprite_key = if pet.hatched { pet.species.as_str() } else { "egg" };
    let Some(sp) = assets
        .species
        .get(sprite_key)
        .or_else(|| assets.species.get("cat"))
        .or_else(|| assets.species.values().next())
    else {
        return;
    };

    // QUIET BASELINE, LOUD ALERT (see PetView.swift): only working bounces;
    // waiting/sleeping sit still except a subtle breath every ~4s
    let bob = if mode == "working" {
        ((frame / 2) % 2) as f64 * (s / 2.0)
    } else if frame % 16 == 0 {
        s / 4.0
    } else {
        0.0
    };
    // alert = a DIFFERENT motion: hops + rapid left-right wiggle; while
    // unacknowledged, a reminder hop fires every ~12s against stillness
    let mut hop = 0.0;
    let mut wiggle = false;
    if now < snap.excite_until {
        let phase = (now * 2.0).fract();
        hop = (phase * std::f64::consts::PI).sin().abs() * 2.2 * s;
        wiggle = (now * 6.0) as i64 % 2 == 0;
    } else if snap.needs_attention && frame % 48 < 6 {
        let phase = (frame % 48) as f64 / 6.0;
        hop = (phase * std::f64::consts::PI).sin().abs() * 1.2 * s;
    }

    let rows_n = sp.rows.len() as f64;
    let sprite_w = sp.rows.first().map_or(16.0, |r| r.chars().count() as f64) * s;
    let ox = (w - sprite_w) / 2.0;
    let base_y = 3.5 * s; // above caption + dots (distance from BOTTOM)

    // ground shadow
    ctx.set_source_rgba(0.0, 0.0, 0.0, 0.35);
    ctx.save().ok();
    ctx.translate(w / 2.0, h - base_y);
    ctx.scale(7.0 * s, 0.8 * s);
    ctx.arc(0.0, 0.0, 1.0, 0.0, std::f64::consts::TAU);
    let _ = ctx.fill();
    ctx.restore().ok();

    let blink = mode == "sleeping" || frame % 16 == 0;
    let sprite_top = h - base_y - rows_n * s - bob - hop;
    sprites::draw_sprite(
        ctx, sp, s, ox, sprite_top, blink,
        (st.facing < 0.0) != wiggle,
        None,
    );

    // effects above the sprite
    let top_y = h - base_y - rows_n * s; // cairo y of the sprite's crown
    if now < snap.alert_until || snap.needs_attention {
        puts(ctx, "!", w - 3.0 * s, top_y + s, C_WARN, s + 6.0, true);
    } else if mode == "working" {
        let cols = w / s;
        for i in 0..3 {
            let px = ((frame * 3 + i * 41) % ((cols - 1.0) as i64 * s as i64).max(1)) as f64;
            let py = top_y + ((frame * 5 + i * 29) % (3 * s as i64).max(1)) as f64;
            puts(ctx, "*", px, py.max(s), C_WARN, s + 2.0, false);
        }
    } else if mode == "waiting" {
        puts(ctx, "?", w - 3.0 * s, top_y + s, C_WARN, s + 6.0, true);
    } else {
        for i in 0..3i64 {
            let phase = ((frame / 2) + i * 3) % 9;
            puts(
                ctx, "z",
                w / 2.0 + 3.0 * s + phase as f64 * 2.0,
                top_y + 2.0 * s - phase as f64 * s / 2.0,
                C_MUTED, s + 2.0 + i as f64, false,
            );
        }
    }

    // per-session dots (only when juggling several live sessions);
    // shape doubles the color: filled circle = working, square = ready,
    // blinking ring = needs a human
    let live: Vec<_> = snap.sessions.iter().filter(|x| x.phase != "idle").collect();
    if live.len() > 1 {
        let dots = &live[..live.len().min(8)];
        let gap = 2.0 * s;
        let r = s * 0.4;
        let cy = h - 2.4 * s;
        let mut x = w / 2.0 - gap * (dots.len() as f64 - 1.0) / 2.0;
        for sess in dots {
            match sess.phase.as_str() {
                "ready" => {
                    ctx.set_source_rgb(C_WARN.0, C_WARN.1, C_WARN.2);
                    ctx.rectangle(x - r, cy - r, 2.0 * r, 2.0 * r);
                    let _ = ctx.fill();
                }
                "input" | "stalled" => {
                    let c = if sess.phase == "input" { C_INPUT } else { C_STALLED };
                    let a = if frame % 2 == 0 { 1.0 } else { 0.35 };
                    ctx.set_source_rgba(c.0, c.1, c.2, a);
                    ctx.set_line_width((s * 0.25).max(1.0));
                    ctx.arc(x, cy, r, 0.0, std::f64::consts::TAU);
                    let _ = ctx.stroke();
                }
                _ => {
                    ctx.set_source_rgb(C_ACCENT.0, C_ACCENT.1, C_ACCENT.2);
                    ctx.arc(x, cy, r, 0.0, std::f64::consts::TAU);
                    let _ = ctx.fill();
                }
            }
            x += gap;
        }
    }

    // caption on a dark pill; flashes yellow during an alert burst
    let sp_name = &sp.name;
    let name = if pet.hatched {
        pet.name.clone().unwrap_or_else(|| sp_name.clone())
    } else {
        "???".into()
    };
    let crown = if pet.stage == "legendary" { "★" } else { "" };
    let caption = format!("{crown}{name} · Lv.{}", pet.level);
    // shrink-to-fit
    let mut cap_size = s + 6.0;
    let mut ext = None;
    while cap_size >= 8.0 {
        ctx.select_font_face("monospace", gtk::cairo::FontSlant::Normal,
                             gtk::cairo::FontWeight::Bold);
        ctx.set_font_size(cap_size);
        let e = ctx.text_extents(&caption).ok();
        if let Some(e) = &e {
            if e.width() + 16.0 <= w {
                ext = Some((e.width(), e.height()));
                break;
            }
        }
        cap_size -= 1.0;
    }
    let (tw, th) = ext.unwrap_or((w - 16.0, cap_size));
    let flashing = now < snap.excite_until && frame % 2 == 0;
    let pad = 6.0;
    let plate_h = th + 8.0;
    let plate_y = h - 0.2 * s - plate_h;
    let plate_x = (w - tw) / 2.0 - pad;
    if flashing {
        ctx.set_source_rgba(C_WARN.0, C_WARN.1, C_WARN.2, 0.95);
    } else {
        ctx.set_source_rgba(0.09, 0.09, 0.12, 0.82);
    }
    rounded_rect(ctx, plate_x, plate_y, tw + 2.0 * pad, plate_h, 7.0);
    let _ = ctx.fill();
    let text_c = if flashing { (0.09, 0.09, 0.12) } else { C_FG };
    puts(ctx, &caption, (w - tw) / 2.0, plate_y + plate_h - 5.0, text_c,
         cap_size, true);
}

fn rounded_rect(ctx: &gtk::cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    ctx.new_sub_path();
    ctx.arc(x + w - r, y + r, r, -std::f64::consts::FRAC_PI_2, 0.0);
    ctx.arc(x + w - r, y + h - r, r, 0.0, std::f64::consts::FRAC_PI_2);
    ctx.arc(x + r, y + h - r, r, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
    ctx.arc(x + r, y + r, r, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
    ctx.close_path();
}
