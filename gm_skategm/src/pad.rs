const XINPUT_BUTTONS: [u16; 15] = [
    0x1000, 0x2000, 0x4000, 0x8000, 0x0020, 0x0000, 0x0010, 0x0040, 0x0080, 0x0100, 0x0200, 0x0001, 0x0002, 0x0004,
    0x0008,
];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct State {
    pub buttons: u16,
    pub triggers: [u8; 2],
    pub left: [i16; 2],
    pub right: [i16; 2],
}

pub fn from_sdl(buttons: &[bool; 15], axes: &[i16; 6]) -> State {
    let mut bits = 0;
    for (i, &down) in buttons.iter().enumerate() {
        if down {
            bits |= XINPUT_BUTTONS[i];
        }
    }
    let up = |v: i16| (-(v as i32)).clamp(-32768, 32767) as i16;
    let trigger = |v: i16| ((v.max(0) as i32 * 255 + 16383) / 32767) as u8;
    State {
        buttons: bits,
        triggers: [trigger(axes[4]), trigger(axes[5])],
        left: [axes[0], up(axes[1])],
        right: [axes[2], up(axes[3])],
    }
}

pub fn kind(sdl_type: i32) -> &'static str {
    match sdl_type {
        3 | 4 | 7 => "playstation",
        5 | 11 | 12 | 13 => "nintendo",
        _ => "xbox",
    }
}

#[derive(Default)]
pub struct Chooser {
    numbers: [Option<u32>; 4],
    touched: [u64; 4],
    clock: u64,
}

impl Chooser {
    pub fn choose(&mut self, numbers: [Option<u32>; 4]) -> Option<usize> {
        self.clock += 1;
        for i in 0..4 {
            match (self.numbers[i], numbers[i]) {
                (_, None) => self.touched[i] = 0,
                (Some(a), Some(b)) if a == b => {}
                (None, Some(_)) => self.touched[i] = self.touched[i].max(1),
                (Some(_), Some(_)) => self.touched[i] = self.clock + 1,
            }
        }
        self.numbers = numbers;
        (0..4).filter(|&i| numbers[i].is_some()).max_by_key(|&i| (self.touched[i], std::cmp::Reverse(i)))
    }
}

#[cfg(windows)]
pub fn module_dir() -> Option<std::path::PathBuf> {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStringExt;
    extern "system" {
        fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut *mut c_void) -> i32;
        fn GetModuleFileNameW(module: *mut c_void, name: *mut u16, size: u32) -> u32;
    }
    const FROM_ADDRESS: u32 = 0x4;
    const UNCHANGED_REFCOUNT: u32 = 0x2;
    let mut handle = std::ptr::null_mut();
    let mut buf = vec![0u16; 1024];
    unsafe {
        if GetModuleHandleExW(FROM_ADDRESS | UNCHANGED_REFCOUNT, module_dir as *const () as *const u16, &mut handle) == 0 {
            return None;
        }
        let n = GetModuleFileNameW(handle, buf.as_mut_ptr(), buf.len() as u32) as usize;
        if n == 0 {
            return None;
        }
        buf.truncate(n);
    }
    std::path::PathBuf::from(std::ffi::OsString::from_wide(&buf)).parent().map(|p| p.to_path_buf())
}

#[cfg(not(windows))]
pub fn module_dir() -> Option<std::path::PathBuf> {
    None
}

#[cfg(windows)]
mod sdl {
    use super::State;
    use std::ffi::{c_char, c_int, c_void, CStr};

    type Ctrl = *mut c_void;
    struct Api {
        update: unsafe extern "C" fn(),
        num_joysticks: unsafe extern "C" fn() -> c_int,
        is_controller: unsafe extern "C" fn(c_int) -> c_int,
        open: unsafe extern "C" fn(c_int) -> Ctrl,
        close: unsafe extern "C" fn(Ctrl),
        attached: unsafe extern "C" fn(Ctrl) -> c_int,
        button: unsafe extern "C" fn(Ctrl, c_int) -> u8,
        axis: unsafe extern "C" fn(Ctrl, c_int) -> i16,
        name: unsafe extern "C" fn(Ctrl) -> *const c_char,
        kind: Option<unsafe extern "C" fn(Ctrl) -> c_int>,
        rumble: Option<unsafe extern "C" fn(Ctrl, u16, u16, u32) -> c_int>,
        joystick_name: unsafe extern "C" fn(c_int) -> *const c_char,
    }

    extern "system" {
        fn LoadLibraryW(name: *const u16) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    }

    fn wide(p: &std::path::Path) -> Vec<u16> {
        use std::os::windows::ffi::OsStrExt;
        p.as_os_str().encode_wide().chain(Some(0)).collect()
    }

    fn text(p: *const c_char) -> String {
        if p.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
        }
    }

    pub struct Sdl {
        api: Api,
        ctrl: Ctrl,
        number: u32,
        last: State,
        pub name: String,
        pub kind: &'static str,
        pub others: Vec<String>,
    }

    unsafe impl Send for Sdl {}

    impl Sdl {
        pub fn load() -> Result<Sdl, String> {
            let dir = super::module_dir().ok_or("can't find the module's folder")?;
            let dll = dir.join("skategm_sdl2.dll");
            let lib = unsafe { LoadLibraryW(wide(&dll).as_ptr()) };
            if lib.is_null() {
                return Err(format!("{} not found", dll.display()));
            }
            macro_rules! f {
                ($name:literal) => {{
                    let p = unsafe { GetProcAddress(lib, concat!($name, "\0").as_ptr() as *const c_char) };
                    if p.is_null() {
                        return Err(format!("{} lacks {}", dll.display(), $name));
                    }
                    unsafe { std::mem::transmute::<*mut c_void, _>(p) }
                }};
            }
            let set_hint: unsafe extern "C" fn(*const c_char, *const c_char) -> c_int = f!("SDL_SetHint");
            let init: unsafe extern "C" fn(u32) -> c_int = f!("SDL_Init");
            let rw_from_file: unsafe extern "C" fn(*const c_char, *const c_char) -> *mut c_void = f!("SDL_RWFromFile");
            let add_mappings: unsafe extern "C" fn(*mut c_void, c_int) -> c_int = f!("SDL_GameControllerAddMappingsFromRW");
            let api = Api {
                update: f!("SDL_GameControllerUpdate"),
                num_joysticks: f!("SDL_NumJoysticks"),
                is_controller: f!("SDL_IsGameController"),
                open: f!("SDL_GameControllerOpen"),
                close: f!("SDL_GameControllerClose"),
                attached: f!("SDL_GameControllerGetAttached"),
                button: f!("SDL_GameControllerGetButton"),
                axis: f!("SDL_GameControllerGetAxis"),
                name: f!("SDL_GameControllerName"),
                joystick_name: f!("SDL_JoystickNameForIndex"),
                kind: {
                    let p = unsafe { GetProcAddress(lib, c"SDL_GameControllerGetType".as_ptr()) };
                    (!p.is_null()).then(|| unsafe { std::mem::transmute::<*mut c_void, unsafe extern "C" fn(Ctrl) -> c_int>(p) })
                },
                rumble: {
                    let p = unsafe { GetProcAddress(lib, c"SDL_GameControllerRumble".as_ptr()) };
                    (!p.is_null()).then(|| unsafe { std::mem::transmute::<*mut c_void, unsafe extern "C" fn(Ctrl, u16, u16, u32) -> c_int>(p) })
                },
            };
            for (k, v) in [
                ("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1"),
                ("SDL_XINPUT_ENABLED", "0"),
                ("SDL_JOYSTICK_HIDAPI_XBOX", "0"),
                ("SDL_JOYSTICK_RAWINPUT", "0"),
                ("SDL_JOYSTICK_WGI", "0"),
            ] {
                let (k, v) = (std::ffi::CString::new(k).unwrap(), std::ffi::CString::new(v).unwrap());
                unsafe { set_hint(k.as_ptr(), v.as_ptr()) };
            }
            const JOYSTICK: u32 = 0x200;
            const GAMECONTROLLER: u32 = 0x2000;
            if unsafe { init(JOYSTICK | GAMECONTROLLER) } != 0 {
                return Err("SDL couldn't start its controller support".into());
            }
            let mut files = vec![dir.join("skategm_gamecontrollerdb.txt")];
            if let Some(garrysmod) = dir.parent().and_then(|p| p.parent()) {
                files.push(garrysmod.join("data").join("skategm").join("gamecontrollerdb.txt"));
            }
            for file in files {
                if let Some(path) = file.to_str().and_then(|s| std::ffi::CString::new(s).ok()) {
                    if file.exists() {
                        let rw = unsafe { rw_from_file(path.as_ptr(), c"rb".as_ptr()) };
                        if !rw.is_null() {
                            unsafe { add_mappings(rw, 1) };
                        }
                    }
                }
            }
            Ok(Sdl { api, ctrl: std::ptr::null_mut(), number: 0, last: State::default(), name: String::new(), kind: "xbox", others: Vec::new() })
        }

        pub fn rumble(&mut self, low: u16, high: u16, ms: u32) -> bool {
            match self.api.rumble {
                Some(f) if !self.ctrl.is_null() => {
                    let on = low > 0 || high > 0;
                    super::watch_sdl(on.then_some((f as usize, self.ctrl as usize)));
                    unsafe { f(self.ctrl, low, high, ms) == 0 }
                }
                _ => false,
            }
        }

        pub fn read(&mut self) -> Option<(u32, State)> {
            let a = &self.api;
            unsafe {
                (a.update)();
                if !self.ctrl.is_null() && (a.attached)(self.ctrl) == 0 {
                    super::watch_sdl(None);
                    (a.close)(self.ctrl);
                    self.ctrl = std::ptr::null_mut();
                    self.name.clear();
                }
                if self.ctrl.is_null() {
                    self.others.clear();
                    for i in 0..(a.num_joysticks)() {
                        if (a.is_controller)(i) != 0 {
                            self.ctrl = (a.open)(i);
                            if !self.ctrl.is_null() {
                                self.name = text((a.name)(self.ctrl));
                                self.kind = super::kind(a.kind.map_or(0, |f| f(self.ctrl)));
                                break;
                            }
                        } else {
                            self.others.push(text((a.joystick_name)(i)));
                        }
                    }
                }
                if self.ctrl.is_null() {
                    return None;
                }
                let buttons: [bool; 15] = std::array::from_fn(|i| (a.button)(self.ctrl, i as c_int) != 0);
                let axes: [i16; 6] = std::array::from_fn(|i| (a.axis)(self.ctrl, i as c_int));
                let state = super::from_sdl(&buttons, &axes);
                if state != self.last {
                    self.last = state;
                    self.number = self.number.wrapping_add(1);
                }
                Some((self.number, state))
            }
        }
    }
}

#[cfg(windows)]
mod xinput {
    #[repr(C)]
    struct Vibration {
        left: u16,
        right: u16,
    }
    #[link(name = "xinput")]
    extern "system" {
        fn XInputSetState(index: u32, vibration: *mut Vibration) -> u32;
    }
    pub fn set(slot: usize, low: u16, high: u16) {
        let mut v = Vibration { left: low, right: high };
        unsafe { XInputSetState(slot as u32, &mut v) };
    }
}

pub fn motor(v: f32) -> u16 {
    (v.clamp(0.0, 1.0) * 65535.0).round() as u16
}

#[derive(Clone, Copy, Default)]
struct Live {
    xinput: Option<usize>,
    sdl: Option<(usize, usize)>,
}
static LIVE: std::sync::Mutex<Live> = std::sync::Mutex::new(Live { xinput: None, sdl: None });
static WATCHDOG: std::sync::Once = std::sync::Once::new();

#[allow(dead_code)]
fn watch_sdl(sdl: Option<(usize, usize)>) {
    LIVE.lock().unwrap_or_else(|e| e.into_inner()).sdl = sdl;
    if sdl.is_some() {
        start_watchdog();
    }
}

#[allow(dead_code)]
fn watch_xinput(slot: Option<usize>) {
    LIVE.lock().unwrap_or_else(|e| e.into_inner()).xinput = slot;
    if slot.is_some() {
        start_watchdog();
    }
}

fn start_watchdog() {
    WATCHDOG.call_once(|| {
        let _ = std::thread::Builder::new().name("skategm rumble".into()).spawn(|| loop {
            std::thread::sleep(std::time::Duration::from_millis(40));
            let until = crate::engine::RUMBLE.lock().unwrap_or_else(|e| e.into_inner()).until;
            if until.is_some_and(|u| u > std::time::Instant::now()) {
                continue;
            }
            let live = std::mem::take(&mut *LIVE.lock().unwrap_or_else(|e| e.into_inner()));
            stop_live(live);
        });
    });
}

#[allow(unused_variables)]
fn stop_live(live: Live) {
    #[cfg(windows)]
    {
        if let Some(slot) = live.xinput {
            xinput::set(slot, 0, 0);
        }
        if let Some((f, ctrl)) = live.sdl {
            let f: unsafe extern "C" fn(*mut std::ffi::c_void, u16, u16, u32) -> std::ffi::c_int = unsafe { std::mem::transmute(f) };
            unsafe { f(ctrl as *mut std::ffi::c_void, 0, 0, 0) };
        }
    }
}

pub fn stop_rumble() {
    crate::engine::set_rumble(0.0, 0.0, 0.0);
    #[cfg(windows)]
    for slot in 0..4 {
        xinput::set(slot, 0, 0);
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Device {
    XInput(usize),
    Sdl,
}

#[derive(Default)]
pub struct Pads {
    chooser: Chooser,
    #[cfg(windows)]
    sdl: Option<Result<sdl::Sdl, String>>,
    pub name: String,
    pub kind: &'static str,
    rumbled: Option<(u64, bool, Option<Device>)>,
    rumbling: Option<Device>,
}

impl Pads {
    pub fn pick(&mut self, numbers: [Option<u32>; 4]) -> (Option<usize>, Option<(u32, State)>) {
        let picked = self.pick_pad(numbers);
        let device = match picked {
            (Some(i), _) => Some(Device::XInput(i)),
            (None, Some(_)) => Some(Device::Sdl),
            _ => None,
        };
        self.apply_rumble(device);
        picked
    }

    fn apply_rumble(&mut self, device: Option<Device>) {
        let r = *crate::engine::RUMBLE.lock().unwrap_or_else(|e| e.into_inner());
        let now = std::time::Instant::now();
        let left = r.until.filter(|u| *u > now).map(|u| u - now);
        let key = (r.seq, left.is_some(), device);
        if self.rumbled == Some(key) {
            return;
        }
        self.rumbled = Some(key);
        let (low, high) = if left.is_some() { (motor(r.low), motor(r.high)) } else { (0, 0) };
        if self.rumbling.is_some() && self.rumbling != device {
            self.drive(self.rumbling, 0, 0, 0);
        }
        let ms = left.map_or(0, |d| d.as_millis().min(5000) as u32);
        self.drive(device, low, high, ms);
        self.rumbling = if low > 0 || high > 0 { device } else { None };
    }

    #[allow(unused_variables)]
    fn drive(&mut self, device: Option<Device>, low: u16, high: u16, ms: u32) {
        #[cfg(windows)]
        match device {
            Some(Device::XInput(i)) => {
                watch_xinput((low > 0 || high > 0).then_some(i));
                xinput::set(i, low, high)
            }
            Some(Device::Sdl) => {
                if let Some(Ok(s)) = self.sdl.as_mut() {
                    s.rumble(low, high, ms);
                }
            }
            None => {}
        }
    }

    fn pick_pad(&mut self, numbers: [Option<u32>; 4]) -> (Option<usize>, Option<(u32, State)>) {
        let numbers = if crate::cleanup::on("sdlonly") { [None; 4] } else { numbers };
        let slot = self.chooser.choose(numbers);
        if let Some(i) = slot {
            self.name = format!("Xbox controller (XInput slot {})", i + 1);
            self.kind = "xbox";
            return (slot, None);
        }
        if crate::cleanup::off("sdlpads") {
            self.name = "none (SDL pads off)".into();
            return (None, None);
        }
        #[cfg(windows)]
        {
            let sdl = self.sdl.get_or_insert_with(sdl::Sdl::load);
            match sdl {
                Ok(s) => {
                    let read = s.read();
                    self.kind = if read.is_some() { s.kind } else { "xbox" };
                    self.name = if read.is_some() {
                        s.name.clone()
                    } else if s.others.is_empty() {
                        "none".into()
                    } else {
                        format!("none usable (not recognised as a gamepad: {})", s.others.join(", "))
                    };
                    return (None, read);
                }
                Err(e) => self.name = format!("none (no SDL: {e})"),
            }
        }
        #[cfg(not(windows))]
        {
            self.name = "none".into();
        }
        (None, None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sdl_state_becomes_xinput_state() {
        let mut b = [false; 15];
        b[0] = true;
        b[9] = true;
        b[11] = true;
        let s = from_sdl(&b, &[100, -32768, -5, 32767, 32767, 0]);
        assert_eq!(s.buttons, 0x1000 | 0x0100 | 0x0001);
        assert_eq!(s.left, [100, 32767], "SDL up is negative, XInput up is positive");
        assert_eq!(s.right, [-5, -32767]);
        assert_eq!(s.triggers, [255, 0]);
        assert_eq!(from_sdl(&[false; 15], &[0, 0, 0, 0, 16384, -100]).triggers, [128, 0]);
    }

    #[test]
    fn pad_types() {
        assert_eq!([kind(4), kind(7), kind(3), kind(5), kind(1), kind(0)], ["playstation", "playstation", "playstation", "nintendo", "xbox", "xbox"]);
    }

    #[test]
    fn the_watchdog_lets_go_once_the_rumble_runs_out() {
        crate::engine::set_rumble(0.5, 0.5, 0.05);
        watch_xinput(Some(3));
        std::thread::sleep(std::time::Duration::from_millis(200));
        assert!(LIVE.lock().unwrap().xinput.is_none());
        crate::engine::set_rumble(0.0, 0.0, 0.0);
    }

    #[test]
    fn rumble_follows_the_requests_and_the_pad() {
        assert_eq!(motor(1.0), 65535);
        assert_eq!(motor(-2.0), 0);
        let mut pads = Pads::default();
        crate::engine::set_rumble(0.5, 0.25, 1.0);
        pads.apply_rumble(Some(Device::XInput(1)));
        assert_eq!(pads.rumbling, Some(Device::XInput(1)));
        pads.apply_rumble(Some(Device::Sdl));
        assert_eq!(pads.rumbling, Some(Device::Sdl));
        crate::engine::set_rumble(0.0, 0.0, 0.0);
        pads.apply_rumble(Some(Device::Sdl));
        assert_eq!(pads.rumbling, None);
        crate::engine::set_rumble(1.0, 1.0, 0.0);
        pads.apply_rumble(Some(Device::Sdl));
        assert_eq!(pads.rumbling, None);
        crate::engine::set_rumble(f32::NAN, 2.0, 0.01);
        let r = *crate::engine::RUMBLE.lock().unwrap();
        assert_eq!((r.low, r.high), (0.0, 1.0));
        std::thread::sleep(std::time::Duration::from_millis(20));
        pads.apply_rumble(Some(Device::Sdl));
        assert_eq!(pads.rumbling, None);
    }

    #[test]
    fn lb_keeps_the_right_stick_until_it_comes_back() {
        use crate::engine::{right_stick_held, LB_RIGHT_STICK};
        use std::sync::atomic::Ordering::Relaxed;
        LB_RIGHT_STICK.store(false, Relaxed);
        assert!(!right_stick_held(true, [30000, 0], false, false));
        LB_RIGHT_STICK.store(true, Relaxed);
        assert!(right_stick_held(true, [0, 0], false, false));
        assert!(right_stick_held(false, [30000, 0], false, true));
        assert!(right_stick_held(false, [0, 0], true, true));
        assert!(!right_stick_held(false, [0, 0], false, true));
        assert!(!right_stick_held(false, [30000, 0], false, false));
        LB_RIGHT_STICK.store(false, Relaxed);
    }

    #[test]
    fn the_pad_touched_last_drives_the_skater() {
        let mut c = Chooser::default();
        assert_eq!(c.choose([None; 4]), None);
        assert_eq!(c.choose([Some(5), Some(9), None, None]), Some(0), "nothing touched yet: the first");
        assert_eq!(c.choose([Some(5), Some(10), None, None]), Some(1), "slot 2 moved");
        assert_eq!(c.choose([Some(5), Some(10), None, None]), Some(1), "it stays while nothing changes");
        assert_eq!(c.choose([Some(6), Some(10), None, None]), Some(0), "back to slot 1 when it's used");
        assert_eq!(c.choose([None, Some(10), None, None]), Some(1), "unplugged: the other");
        assert_eq!(c.choose([Some(1), Some(10), None, None]), Some(1), "plugged back in, untouched: not taken over");
    }
}
