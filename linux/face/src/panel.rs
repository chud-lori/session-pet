//! Session panel — port of native/src/Panel.swift's design: header with XP
//! progress + mode chip, rounded per-session cards (tinted project pill,
//! title, status; click = acknowledge), and settings.

use crate::proto::{fmt_age, fmt_tokens, Snapshot};
use crate::sprites::Assets;
use gtk::gdk;
use gtk::glib;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

pub type CmdSender = Rc<dyn Fn(serde_json::Value)>;

pub struct Panel {
    pub window: gtk::Window,
    /// where to place the panel once the WM has mapped it — moving before
    /// the map races Mutter and the move is silently dropped
    pub place_at: Rc<std::cell::Cell<(i32, i32)>>,
    header: gtk::Label,
    sub: gtk::Label,
    xp_bar: gtk::ProgressBar,
    chip: gtk::Label,
    cards: gtk::ListBox,
    send: CmdSender,
    species_btns: Vec<(String, gtk::Button)>,
    sound: gtk::CheckButton,
    walk: gtk::CheckButton,
    card_paths: Rc<RefCell<Vec<String>>>,
    refreshing: Rc<RefCell<bool>>,
}

fn phase_color(phase: &str) -> &'static str {
    match phase {
        "ready" => "#ffd166",
        "input" => "#f28ca8",
        "stalled" => "#d4a373",
        "working" | "busy" => "#a6e3a1",
        _ => "#7f849c",
    }
}

// stable per-project badge color, hashed from the project name — same djb2 +
// HSB(hue, 0.55, 0.88) formula as the mac panel (Config.swift projectColor)
fn project_color(name: &str) -> String {
    let mut h: u32 = 5381;
    for b in name.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u32);
    }
    let hue = (h % 360) as f64 / 60.0;
    let (s, v) = (0.55, 0.88);
    let c = v * s;
    let x = c * (1.0 - (hue % 2.0 - 1.0).abs());
    let (r, g, b) = match hue as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = v - c;
    format!(
        "#{:02x}{:02x}{:02x}",
        ((r + m) * 255.0) as u8,
        ((g + m) * 255.0) as u8,
        ((b + m) * 255.0) as u8
    )
}

// project pill: colored text on a translucent tint of the same color —
// per-widget CSS provider, since the tint is per-project
fn badge_label(project: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(project));
    l.set_ellipsize(gtk::pango::EllipsizeMode::End);
    l.set_max_width_chars(18);
    let ctx = l.style_context();
    ctx.add_class("badge");
    let color = project_color(project);
    let css = gtk::CssProvider::new();
    let _ = css.load_from_data(
        format!(".badge {{ color: {color}; background-color: alpha({color}, 0.16); }}")
            .as_bytes(),
    );
    ctx.add_provider(&css, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    l
}

impl Panel {
    pub fn new(assets: &Assets, send: CmdSender, on_quit: Rc<dyn Fn()>) -> Self {
        let window = gtk::Window::new(gtk::WindowType::Toplevel);
        window.set_decorated(false);
        window.set_keep_above(true);
        window.set_skip_taskbar_hint(true);
        window.set_skip_pager_hint(true);
        window.set_type_hint(gtk::gdk::WindowTypeHint::Utility);
        window.set_default_size(340, -1);
        window.style_context().add_class("pet-panel");
        // closing via the WM must hide, not destroy — the panel is reused
        window.connect_delete_event(|w, _| {
            w.hide();
            glib::Propagation::Stop
        });
        // Esc closes
        window.connect_key_press_event(|w, ev| {
            if ev.keyval() == gtk::gdk::keys::constants::Escape {
                w.hide();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });

        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        root.set_margin_top(14);
        root.set_margin_bottom(12);
        root.set_margin_start(14);
        root.set_margin_end(14);

        let header = gtk::Label::new(None);
        header.set_xalign(0.0);
        let sub = gtk::Label::new(None);
        sub.set_xalign(0.0);
        sub.style_context().add_class("dim");
        let xp_bar = gtk::ProgressBar::new();
        // mode chip ("all idle" / "2 working" / "1 need you") — pill that
        // must not stretch to full width
        let chip = gtk::Label::new(None);
        chip.style_context().add_class("chip");
        let chip_row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        chip_row.pack_start(&chip, false, false, 0);
        root.pack_start(&header, false, false, 0);
        root.pack_start(&sub, false, false, 0);
        root.pack_start(&xp_bar, false, false, 2);
        root.pack_start(&chip_row, false, false, 4);

        let cards = gtk::ListBox::new();
        cards.set_selection_mode(gtk::SelectionMode::None);
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .propagate_natural_height(true)
            .max_content_height(440)
            .build();
        scroll.add(&cards);
        root.pack_start(&scroll, true, true, 0);

        // NB: clicks are handled per-card by an EventBox in refresh(), not by
        // ListBox row-activated — a ListBox in SelectionMode::None does not
        // reliably activate rows, and an EventBox owns its own GdkWindow so
        // it always gets button events.

        // outside-click closes, mac-style: any focus loss hides the panel.
        // The pet window itself never takes focus (set_accept_focus(false)),
        // so clicking the pet keeps plain toggle semantics.
        window.connect_focus_out_event(move |w, _| {
            w.hide();
            glib::Propagation::Proceed
        });

        // --- settings ▸
        let refreshing = Rc::new(RefCell::new(false));
        let settings = gtk::Expander::new(Some("settings ▾"));
        let sbox = gtk::Box::new(gtk::Orientation::Vertical, 8);
        sbox.set_margin_top(8);

        // visual species picker: sprite thumbnails, click one to adopt it
        // (picking is also what hatches an egg)
        let picker = gtk::FlowBox::new();
        picker.set_selection_mode(gtk::SelectionMode::None);
        picker.set_max_children_per_line(4);
        picker.set_column_spacing(6);
        picker.set_row_spacing(6);
        picker.set_homogeneous(true);
        let mut species_btns: Vec<(String, gtk::Button)> = vec![];
        for key in &assets.order {
            let Some(sp) = assets.species.get(key) else { continue };
            let btn = gtk::Button::new();
            btn.style_context().add_class("sprite-btn");
            btn.set_tooltip_text(Some(&sp.name));
            btn.set_relief(gtk::ReliefStyle::None);
            // add the image as the button's child rather than set_image() —
            // that path is subject to the gtk-button-images theme setting
            if let Some(pb) = crate::sprites::sprite_pixbuf(sp, 2.0) {
                btn.add(&gtk::Image::from_pixbuf(Some(&pb)));
            } else {
                btn.add(&gtk::Label::new(Some(&sp.name)));
            }
            {
                let send = send.clone();
                let key = key.clone();
                btn.connect_clicked(move |_| {
                    send(serde_json::json!({"cmd": "pick_species", "key": key}));
                });
            }
            picker.add(&btn);
            species_btns.push((key.clone(), btn));
        }
        sbox.pack_start(&picker, false, false, 0);

        let sound = gtk::CheckButton::with_label("sound when an agent needs me");
        {
            let send = send.clone();
            let refreshing = refreshing.clone();
            sound.connect_toggled(move |b| {
                if !*refreshing.borrow() {
                    send(serde_json::json!({"cmd": "set", "key": "sound",
                                            "value": b.is_active()}));
                }
            });
        }
        let walk = gtk::CheckButton::with_label("let the pet wander around");
        {
            let send = send.clone();
            let refreshing = refreshing.clone();
            walk.connect_toggled(move |b| {
                if !*refreshing.borrow() {
                    send(serde_json::json!({"cmd": "set", "key": "walk",
                                            "value": b.is_active()}));
                }
            });
        }
        sbox.pack_start(&sound, false, false, 0);
        sbox.pack_start(&walk, false, false, 0);
        let quit = gtk::Button::with_label("quit pet");
        quit.style_context().add_class("quit-btn");
        {
            let on_quit = on_quit.clone();
            quit.connect_clicked(move |_| on_quit());
        }
        let quit_row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        quit_row.set_margin_top(4);
        quit_row.pack_start(&quit, false, false, 0);
        sbox.pack_start(&quit_row, false, false, 0);
        settings.add(&sbox);
        root.pack_start(&settings, false, false, 2);

        window.add(&root);
        let place_at = Rc::new(std::cell::Cell::new((0, 0)));
        {
            let place_at = place_at.clone();
            window.connect_map_event(move |w, _| {
                let (x, y) = place_at.get();
                if (x, y) != (0, 0) {
                    w.move_(x, y);
                }
                glib::Propagation::Proceed
            });
        }
        Panel {
            window,
            place_at,
            header,
            sub,
            xp_bar,
            chip,
            cards,
            send,
            species_btns,
            sound,
            walk,
            card_paths,
            refreshing,
        }
    }

    pub fn refresh(&self, snap: &Snapshot, assets: &Assets) {
        *self.refreshing.borrow_mut() = true;
        let pet = &snap.pet;
        let sp_name = assets
            .species
            .get(&pet.species)
            .map(|s| s.name.clone())
            .unwrap_or_else(|| pet.species.clone());
        let name = if pet.hatched {
            pet.name.clone().unwrap_or(sp_name)
        } else {
            "???".to_string()
        };
        let crown = if pet.stage == "legendary" { "★ " } else { "" };
        self.header.set_markup(&format!(
            "<span size='large'><b>{}{} · Lv.{}</b></span>",
            crown,
            glib::markup_escape_text(&name),
            pet.level
        ));
        match pet.stage_hi {
            Some(hi) if hi > pet.stage_lo => {
                self.sub.set_text(&format!(
                    "{} · {} XP · {} to next stage",
                    pet.stage,
                    pet.xp,
                    hi - pet.xp
                ));
                self.xp_bar.set_visible(true);
                self.xp_bar.set_fraction(
                    ((pet.xp - pet.stage_lo) as f64 / (hi - pet.stage_lo) as f64)
                        .clamp(0.0, 1.0),
                );
            }
            _ => {
                self.sub.set_text(&format!("{} · {} XP · max stage", pet.stage, pet.xp));
                self.xp_bar.set_visible(true);
                self.xp_bar.set_fraction(1.0);
            }
        }

        // mode chip, most urgent first
        let n = |p: &str| snap.sessions.iter().filter(|s| s.phase == p).count();
        let (n_input, n_ready, n_stalled) = (n("input"), n("ready"), n("stalled"));
        let n_active = n("working") + n("busy");
        let (chip_text, chip_color) = if n_input > 0 {
            (format!("{n_input} need you"), "#f28ca8")
        } else if n_stalled > 0 {
            (format!("{n_stalled} stalled"), "#d4a373")
        } else if n_active > 0 {
            (format!("{n_active} working"), "#a6e3a1")
        } else if n_ready > 0 {
            (format!("{n_ready} ready"), "#ffd166")
        } else {
            ("all idle".to_string(), "#7f849c")
        };
        self.chip
            .set_markup(&format!("<span foreground='{chip_color}'>{chip_text}</span>"));

        for child in self.cards.children() {
            self.cards.remove(&child);
        }
        let mut paths = self.card_paths.borrow_mut();
        paths.clear();
        for s in &snap.sessions {
            let row = gtk::ListBoxRow::new();
            row.set_margin_bottom(8);
            let card = gtk::Box::new(gtk::Orientation::Vertical, 3);
            card.style_context().add_class("card");
            if s.phase == "input" {
                card.style_context().add_class("card-input");
            }
            // top: project pill left, age right
            let top = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            top.pack_start(&badge_label(&s.project), false, false, 0);
            let age = gtk::Label::new(Some(&fmt_age(s.age)));
            age.style_context().add_class("dim");
            top.pack_end(&age, false, false, 0);
            // title: the session's name (ai-title / rename), like the mac card
            let title_text = if s.label.is_empty() { &s.project } else { &s.label };
            let title = gtk::Label::new(None);
            title.set_markup(&format!(
                "<b>{}</b>",
                glib::markup_escape_text(title_text)
            ));
            title.set_xalign(0.0);
            title.set_ellipsize(gtk::pango::EllipsizeMode::End);
            // status line, phase-colored for anything needing eyes
            let doing = gtk::Label::new(None);
            match s.phase.as_str() {
                "input" | "ready" | "stalled" => doing.set_markup(&format!(
                    "<span foreground='{}'>{}</span>",
                    phase_color(&s.phase),
                    glib::markup_escape_text(&s.doing)
                )),
                _ => {
                    doing.set_text(&s.doing);
                    doing.style_context().add_class("dim");
                }
            }
            doing.set_xalign(0.0);
            doing.set_ellipsize(gtk::pango::EllipsizeMode::End);
            // meta: provider · ctx, tiny and dim (mac shows on expand;
            // one compact line here keeps the info without the interaction)
            let ctx = s.ctx.map(|c| format!(" · ctx {}", fmt_tokens(c))).unwrap_or_default();
            let meta = gtk::Label::new(Some(&format!("{}{}", s.provider, ctx)));
            meta.set_xalign(0.0);
            meta.style_context().add_class("meta");
            card.pack_start(&top, false, false, 0);
            card.pack_start(&title, false, false, 0);
            card.pack_start(&doing, false, false, 0);
            card.pack_start(&meta, false, false, 0);
            // EventBox: gives the card its own GdkWindow so a plain click is
            // delivered here regardless of ListBox selection/activation rules
            let hit = gtk::EventBox::new();
            hit.set_above_child(false);
            hit.set_visible_window(false);
            hit.add_events(gdk::EventMask::BUTTON_RELEASE_MASK);
            hit.add(&card);
            row.add(&hit);
            {
                // needles, most specific first: Claude Code writes the
                // session title into the terminal title, so it beats the dir
                let mut needles = vec![s.label.clone()];
                if let Some(dir) = s.cwd.as_deref().and_then(|c| c.rsplit('/').next()) {
                    needles.push(dir.to_string());
                }
                needles.push(s.project.clone());
                let pids = s.term_pids.clone();
                let path = s.path.clone();
                let send = self.send.clone();
                hit.connect_button_release_event(move |_, ev| {
                    if ev.button() != 1 {
                        return glib::Propagation::Proceed;
                    }
                    // click = you saw this session, and take me to it
                    send(serde_json::json!({"cmd": "ack", "path": path}));
                    crate::jump_to_terminal(&pids, &needles);
                    glib::Propagation::Stop
                });
            }
            self.cards.add(&row);
            paths.push(s.path.clone());
        }
        self.cards.show_all();

        // ring the adopted species (only once hatched — an egg has none yet)
        for (key, btn) in &self.species_btns {
            let ctx = btn.style_context();
            if pet.hatched && *key == pet.species {
                ctx.add_class("selected");
            } else {
                ctx.remove_class("selected");
            }
        }
        self.sound.set_active(pet.sound);
        self.walk.set_active(pet.walk);
        *self.refreshing.borrow_mut() = false;
    }
}
