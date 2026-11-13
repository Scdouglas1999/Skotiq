#![allow(non_snake_case)]
use std::ffi::{c_char,c_int};
use std::sync::atomic::{AtomicI32,Ordering};
static POSITION:AtomicI32=AtomicI32::new(0);
static BUSY_POLLS:AtomicI32=AtomicI32::new(0);
static mut ALIASES:[[c_char;24];7]=[[0;24];7];
#[repr(C)] struct PWProperties{name:[c_char;64],handle:c_int,position_count:c_int,sn:[c_char;32],reserved:[c_char;32]}
fn write_cstr(buf:&mut [c_char],text:&[u8]){for b in buf.iter_mut(){*b=0;} for i in 0..text.len().min(buf.len().saturating_sub(1)){buf[i]=text[i] as c_char;}}
unsafe fn put(buf:*mut c_char,len:usize,text:&[u8]){if buf.is_null(){return;} for i in 0..len{*buf.add(i)=0;} for i in 0..text.len().min(len.saturating_sub(1)){*buf.add(i)=text[i] as c_char;}}
fn busy()->bool{BUSY_POLLS.fetch_update(Ordering::SeqCst,Ordering::SeqCst,|n|(n>0).then(||n-1)).is_ok()}
#[no_mangle] pub extern "C" fn POAGetPWCount()->c_int{1}
#[no_mangle] pub extern "C" fn POAGetPWSDKVer()->*const c_char{b"fake-playerone-pw-1.0\0".as_ptr() as *const c_char}
#[no_mangle] pub unsafe extern "C" fn POAGetPWProperties(index:c_int,prop:*mut PWProperties)->c_int{if index!=0{return 1;} fill_prop(prop)}
#[no_mangle] pub unsafe extern "C" fn POAGetPWPropertiesByHandle(handle:c_int,prop:*mut PWProperties)->c_int{if handle!=77{return 2;} fill_prop(prop)}
unsafe fn fill_prop(prop:*mut PWProperties)->c_int{if prop.is_null(){return 7;} let mut p:PWProperties=std::mem::zeroed(); write_cstr(&mut p.name,b"Skotiq Fake Phoenix Wheel"); p.handle=77; p.position_count=7; write_cstr(&mut p.sn,b"PW-FAKE-0001"); *prop=p; 0}
#[no_mangle] pub extern "C" fn POAOpenPW(handle:c_int)->c_int{if handle!=77{return 2;} BUSY_POLLS.store(2,Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn POAClosePW(handle:c_int)->c_int{if handle==77{0}else{2}}
#[no_mangle] pub unsafe extern "C" fn POAGetCurrentPosition(handle:c_int,pos:*mut c_int)->c_int{if handle!=77{return 2;} if pos.is_null(){return 7;} if busy(){return 6;} *pos=POSITION.load(Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn POAGotoPosition(handle:c_int,pos:c_int)->c_int{if handle!=77{return 2;} if pos<0||pos>=7{return 3;} if BUSY_POLLS.load(Ordering::SeqCst)>0{return 6;} POSITION.store(pos,Ordering::SeqCst); BUSY_POLLS.store(3,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn POAGetPWState(handle:c_int,state:*mut c_int)->c_int{if handle!=77{return 2;} if state.is_null(){return 7;} *state=if busy(){2}else{1}; 0}
#[no_mangle] pub unsafe extern "C" fn POAGetPWFilterAlias(handle:c_int,pos:c_int,buf:*mut c_char,len:c_int)->c_int{if handle!=77{return 2;} if pos<0||pos>=7{return 3;} if buf.is_null(){return 7;} if len<24{return 3;} let alias=ALIASES[pos as usize]; if alias[0]==0{let text=format!("Filter {}",pos+1); put(buf,len as usize,text.as_bytes());}else{for i in 0..24{*buf.add(i)=alias[i];}} 0}
#[no_mangle] pub unsafe extern "C" fn POASetPWFilterAlias(handle:c_int,pos:c_int,name:*const c_char,len:c_int)->c_int{if handle!=77{return 2;} if pos<0||pos>=7{return 3;} if len<0||len>=24{return 3;} for i in 0..24{ALIASES[pos as usize][i]=0;} if name.is_null()||len==0{return 0;} for i in 0..(len as usize){ALIASES[pos as usize][i]=*name.add(i);} 0}
