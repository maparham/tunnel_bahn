//! Thin C ABI around Cloudflare BoringTun’s FFI so Swift sees a stable `#[repr(C)]` result layout.

use boringtun::ffi;
use std::ffi::{c_char, c_void};

#[repr(C)]
pub struct AppsplitWgResult {
    pub op: u32,
    pub size: usize,
}

impl From<ffi::wireguard_result> for AppsplitWgResult {
    fn from(value: ffi::wireguard_result) -> Self {
        Self {
            op: value.op as u32,
            size: value.size,
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn appsplit_wg_tunnel_new(
    static_private: *const c_char,
    server_static_public: *const c_char,
    preshared_key: *const c_char,
    keep_alive: u16,
    index: u32,
) -> *mut c_void {
    ffi::new_tunnel(static_private, server_static_public, preshared_key, keep_alive, index) as *mut c_void
}

#[no_mangle]
pub unsafe extern "C" fn appsplit_wg_tunnel_free(tunnel: *mut c_void) {
    ffi::tunnel_free(tunnel as _);
}

#[no_mangle]
pub unsafe extern "C" fn appsplit_wg_write(
    tunnel: *const c_void,
    src: *const u8,
    src_len: u32,
    dst: *mut u8,
    dst_len: u32,
) -> AppsplitWgResult {
    ffi::wireguard_write(tunnel as _, src, src_len, dst, dst_len).into()
}

#[no_mangle]
pub unsafe extern "C" fn appsplit_wg_read(
    tunnel: *const c_void,
    src: *const u8,
    src_len: u32,
    dst: *mut u8,
    dst_len: u32,
) -> AppsplitWgResult {
    ffi::wireguard_read(tunnel as _, src, src_len, dst, dst_len).into()
}

#[no_mangle]
pub unsafe extern "C" fn appsplit_wg_tick(
    tunnel: *const c_void,
    dst: *mut u8,
    dst_len: u32,
) -> AppsplitWgResult {
    ffi::wireguard_tick(tunnel as _, dst, dst_len).into()
}

#[no_mangle]
pub unsafe extern "C" fn appsplit_wg_force_handshake(
    tunnel: *const c_void,
    dst: *mut u8,
    dst_len: u32,
) -> AppsplitWgResult {
    ffi::wireguard_force_handshake(tunnel as _, dst, dst_len).into()
}
