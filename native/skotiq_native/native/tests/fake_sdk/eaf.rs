#![allow(non_snake_case)]
// EAFOpen knows an id only after EAFGetNum has listed it (EAF_focuser.h: GetNum
// "should be the first API to be called"). FAKE_EAF_GONE=1 unplugs the focuser:
// the SDK lists none and answers a call on its id with EAF_ERROR_INVALID_ID.
use std::ffi::{c_char,c_int,c_uchar};
use std::sync::atomic::{AtomicBool,AtomicI32,Ordering};
static POSITION:AtomicI32=AtomicI32::new(1_000); static MAX_STEP:AtomicI32=AtomicI32::new(60_000); static REVERSE:AtomicBool=AtomicBool::new(false); static BEEP:AtomicBool=AtomicBool::new(false); static BACKLASH:AtomicI32=AtomicI32::new(0); static ENUMERATED:AtomicBool=AtomicBool::new(false);
#[repr(C)] struct EAFInfo{ id:c_int, name:[c_char;64], max_step:c_int }
#[repr(C)] struct EAFSerialNumber{ id:[c_uchar;8] }
fn write_cstr(buf:&mut [c_char], text:&[u8]){ for slot in buf.iter_mut(){*slot=0;} for i in 0..text.len().min(buf.len().saturating_sub(1)){buf[i]=text[i] as c_char;} }
fn gone()->bool{ std::env::var("FAKE_EAF_GONE").is_ok() }
#[no_mangle] pub extern "C" fn EAFGetNum()->c_int{ENUMERATED.store(true,Ordering::SeqCst); if gone(){0}else{1}}
#[no_mangle] pub unsafe extern "C" fn EAFGetID(index:c_int,id:*mut c_int)->c_int{ if id.is_null()||index!=0{return 1;} *id=0; 0}
#[no_mangle] pub extern "C" fn EAFOpen(id:c_int)->c_int{if id==0&&ENUMERATED.load(Ordering::SeqCst){0}else{2}}
#[no_mangle] pub extern "C" fn EAFClose(_id:c_int)->c_int{0}
#[no_mangle] pub unsafe extern "C" fn EAFGetProperty(id:c_int,info:*mut EAFInfo)->c_int{ if info.is_null()||id!=0{return 2;} let mut value:EAFInfo=std::mem::zeroed(); value.id=id; value.max_step=MAX_STEP.load(Ordering::SeqCst); write_cstr(&mut value.name,b"ZWO EAF"); *info=value; 0}
#[no_mangle] pub extern "C" fn EAFMove(_id:c_int,position:c_int)->c_int{if gone(){return 2;} POSITION.store(position,Ordering::SeqCst);0}
#[no_mangle] pub extern "C" fn EAFStop(_id:c_int)->c_int{if gone(){2}else{0}}
#[no_mangle] pub unsafe extern "C" fn EAFIsMoving(_id:c_int,moving:*mut bool,hand_control:*mut bool)->c_int{ if gone(){return 2;} if moving.is_null()||hand_control.is_null(){return 7;} *moving=false; *hand_control=false; 0}
#[no_mangle] pub unsafe extern "C" fn EAFGetPosition(_id:c_int,position:*mut c_int)->c_int{ if gone(){return 2;} if position.is_null(){return 7;} *position=POSITION.load(Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn EAFGetTemp(_id:c_int,temp:*mut f32)->c_int{ if temp.is_null(){return 7;} *temp=21.5; 0}
#[no_mangle] pub extern "C" fn EAFSetMaxStep(_id:c_int,max_step:c_int)->c_int{MAX_STEP.store(max_step,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn EAFGetMaxStep(_id:c_int,max_step:*mut c_int)->c_int{ if max_step.is_null(){return 7;} *max_step=MAX_STEP.load(Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn EAFSetBacklash(_id:c_int,backlash:c_int)->c_int{BACKLASH.store(backlash,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn EAFGetBacklash(_id:c_int,backlash:*mut c_int)->c_int{ if backlash.is_null(){return 7;} *backlash=BACKLASH.load(Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn EAFSetReverse(_id:c_int,reverse:bool)->c_int{REVERSE.store(reverse,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn EAFGetReverse(_id:c_int,reverse:*mut bool)->c_int{ if reverse.is_null(){return 7;} *reverse=REVERSE.load(Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn EAFSetBeep(_id:c_int,beep:bool)->c_int{BEEP.store(beep,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn EAFGetBeep(_id:c_int,beep:*mut bool)->c_int{ if beep.is_null(){return 7;} *beep=BEEP.load(Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn EAFGetSDKVersion()->*const c_char{b"fake-eaf-1.0\0".as_ptr() as *const c_char}
#[no_mangle] pub unsafe extern "C" fn EAFGetFirmwareVersion(_id:c_int,major:*mut c_uchar,minor:*mut c_uchar,build:*mut c_uchar)->c_int{ if !major.is_null(){*major=1;} if !minor.is_null(){*minor=2;} if !build.is_null(){*build=3;} 0}
#[no_mangle] pub unsafe extern "C" fn EAFGetSerialNumber(_id:c_int,serial:*mut EAFSerialNumber)->c_int{ if serial.is_null(){return 7;} (*serial).id=[0xEA,0xF0,1,2,0,0,0,0]; 0}
#[no_mangle] pub extern "C" fn EAFResetPostion(_id:c_int,position:c_int)->c_int{POSITION.store(position,Ordering::SeqCst);0}
