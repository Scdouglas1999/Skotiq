#![allow(non_snake_case)]
// EFWOpen knows an id only after EFWGetNum has listed it. The first wheel opened
// in the process is still counting its slots and answers EFWGetProperty with
// EFW_ERROR_MOVING three times (EFW_filter.h). FAKE_EFW_REMOVED=1 unplugs the
// wheel; FAKE_EFW_SLOTS gives the slot count of a wheel plugged in its place.
// FAKE_EFW_GONE=1 unplugs it after the SDK has re-listed the bus: a call on
// its id answers EFW_ERROR_INVALID_ID.
use std::ffi::{c_char,c_int,c_uchar};
use std::sync::atomic::{AtomicBool,AtomicI32,Ordering};
static POSITION:AtomicI32=AtomicI32::new(0); static DIRECTION:AtomicBool=AtomicBool::new(false); static ENUMERATED:AtomicBool=AtomicBool::new(false); static OPENED:AtomicBool=AtomicBool::new(false); static DETECTING:AtomicI32=AtomicI32::new(0);
#[repr(C)] struct EFWInfo{ id:c_int, name:[c_char;64], slot_num:c_int }
#[repr(C)] struct EFWSerialNumber{ id:[c_uchar;8] }
fn write_cstr(buf:&mut [c_char], text:&[u8]){ for slot in buf.iter_mut(){*slot=0;} for i in 0..text.len().min(buf.len().saturating_sub(1)){buf[i]=text[i] as c_char;} }
fn removed()->bool{ std::env::var("FAKE_EFW_REMOVED").is_ok() }
fn gone()->bool{ std::env::var("FAKE_EFW_GONE").is_ok() }
#[no_mangle] pub extern "C" fn EFWGetNum()->c_int{ENUMERATED.store(true,Ordering::SeqCst); if removed(){0}else{1}}
#[no_mangle] pub unsafe extern "C" fn EFWGetID(index:c_int,id:*mut c_int)->c_int{ if id.is_null()||index!=0||removed(){return 1;} *id=0; 0}
#[no_mangle] pub extern "C" fn EFWOpen(id:c_int)->c_int{ if removed(){return 4;} if id!=0||!ENUMERATED.load(Ordering::SeqCst){return 2;} if !OPENED.swap(true,Ordering::SeqCst){DETECTING.store(3,Ordering::SeqCst);} 0}
#[no_mangle] pub extern "C" fn EFWClose(_id:c_int)->c_int{ if removed(){2}else{0} }
#[no_mangle] pub unsafe extern "C" fn EFWGetProperty(id:c_int,info:*mut EFWInfo)->c_int{ if removed(){return 4;} if info.is_null()||id!=0{return 2;} if DETECTING.load(Ordering::SeqCst)>0 { DETECTING.fetch_sub(1,Ordering::SeqCst); return 5; } let mut value:EFWInfo=std::mem::zeroed(); value.id=id; value.slot_num=std::env::var("FAKE_EFW_SLOTS").ok().and_then(|v| v.parse().ok()).unwrap_or(7); write_cstr(&mut value.name,b"Skotiq Fake EFW 7x36"); *info=value; 0}
#[no_mangle] pub unsafe extern "C" fn EFWGetPosition(_id:c_int,position:*mut c_int)->c_int{ if removed(){return 4;} if gone(){return 2;} if position.is_null(){return 7;} *position=POSITION.load(Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn EFWSetPosition(_id:c_int,position:c_int)->c_int{ if removed(){return 4;} if gone(){return 2;} POSITION.store(position,Ordering::SeqCst);0}
#[no_mangle] pub extern "C" fn EFWSetDirection(_id:c_int,direction:bool)->c_int{DIRECTION.store(direction,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn EFWGetDirection(_id:c_int,direction:*mut bool)->c_int{ if direction.is_null(){return 7;} *direction=DIRECTION.load(Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn EFWCalibrate(_id:c_int)->c_int{0}
#[no_mangle] pub extern "C" fn EFWGetSDKVersion()->*const c_char{b"fake-efw-1.0\0".as_ptr() as *const c_char}
#[no_mangle] pub unsafe extern "C" fn EFWGetHWErrorCode(_id:c_int,code:*mut c_int)->c_int{ if !code.is_null(){*code=0;} 0}
#[no_mangle] pub unsafe extern "C" fn EFWGetFirmwareVersion(_id:c_int,major:*mut c_uchar,minor:*mut c_uchar,build:*mut c_uchar)->c_int{ if !major.is_null(){*major=4;} if !minor.is_null(){*minor=5;} if !build.is_null(){*build=6;} 0}
#[no_mangle] pub unsafe extern "C" fn EFWGetSerialNumber(_id:c_int,serial:*mut EFWSerialNumber)->c_int{ if serial.is_null(){return 7;} (*serial).id=[0xEF,0xF0,1,2,0,0,0,0]; 0}
