use std::ffi::{c_char, c_void};

#[repr(C)]
pub struct PmHost {
    version: u32,
    ctx: *mut c_void,
    callback: extern "C" fn(*mut c_void, u64, i64),
}

#[repr(C)]
pub struct PmModule {
    version: u32,
    name: *const c_char,
    add: extern "C" fn(i64, i64) -> i64,
    reverse: extern "C" fn(*const u8, usize, *mut *mut u8, *mut usize) -> i32,
    free_bytes: extern "C" fn(*mut u8, usize),
    counter_new: extern "C" fn(i64) -> *mut c_void,
    count_to: extern "C" fn(*mut c_void, i64, *const PmHost, u64) -> i64,
    counter_free: extern "C" fn(*mut c_void),
}

// The table only holds a pointer to a static string and function pointers.
unsafe impl Sync for PmModule {}

extern "C" fn add(a: i64, b: i64) -> i64 {
    a.wrapping_add(b)
}

extern "C" fn reverse(s: *const u8, len: usize, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    let input = if len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(s, len) } };
    let Ok(text) = std::str::from_utf8(input) else { return 1 };
    let rev: String = text.chars().rev().collect();
    let boxed = rev.into_bytes().into_boxed_slice();
    unsafe {
        *out_len = boxed.len();
        *out = Box::into_raw(boxed) as *mut u8;
    }
    0
}

extern "C" fn free_bytes(p: *mut u8, len: usize) {
    if !p.is_null() {
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len))) };
    }
}

extern "C" fn counter_new(start: i64) -> *mut c_void {
    Box::into_raw(Box::new(start)) as *mut c_void
}

extern "C" fn count_to(counter: *mut c_void, target: i64, host: *const PmHost, cb_id: u64) -> i64 {
    let c = unsafe { &mut *(counter as *mut i64) };
    let host = unsafe { &*host };
    let mut calls = 0;
    while *c < target {
        *c += 1;
        (host.callback)(host.ctx, cb_id, *c);
        calls += 1;
    }
    calls
}

extern "C" fn counter_free(counter: *mut c_void) {
    if !counter.is_null() {
        unsafe { drop(Box::from_raw(counter as *mut i64)) };
    }
}

static MODULE: PmModule = PmModule {
    version: 1,
    name: b"rust\0".as_ptr() as *const c_char,
    add,
    reverse,
    free_bytes,
    counter_new,
    count_to,
    counter_free,
};

#[no_mangle]
pub extern "C" fn probe_rust_module() -> *const PmModule {
    &MODULE
}
