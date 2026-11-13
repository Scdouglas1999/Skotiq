#![allow(non_snake_case)]
// Models the ToupTek-family SDK as its header and en.html describe it: option defaults
// (TEC on, BITDEPTH 8-bit, UPSIDE_DOWN 1 on Windows), E_NOTIMPL for what a model lacks,
// ROI in unbinned sensor coordinates (even, >= 16), saturating digital binning, a frame
// queue that a cancelled trigger does not empty, and frame info carrying the exposure the
// sensor ran (a 15 us line time). SK_TOUPTEK_UPSIDE_DOWN=1 gives the Windows default on
// any host; SK_TOUPTEK_PULL_ERROR reports EVENT_ERROR instead of a frame.
use std::ffi::{c_char,c_int,c_uint,c_ushort,c_void};
use std::sync::atomic::{AtomicI32,AtomicU32,AtomicUsize,Ordering};
use std::sync::Mutex;
#[cfg(windows)] type Ch=u16;
#[cfg(not(windows))] type Ch=c_char;
#[repr(C)] struct OgmacamResolution{width:c_uint,height:c_uint}
#[repr(C)] struct OgmacamModelV2{name:*const c_char,flag:u64,maxspeed:c_uint,preview:c_uint,still:c_uint,maxfanspeed:c_uint,ioctrol:c_uint,xpixsz:f32,ypixsz:f32,res:[OgmacamResolution;16]}
#[repr(C)] struct OgmacamDeviceV2{displayname:[Ch;64],id:[Ch;64],model:*const OgmacamModelV2}
#[repr(C)] struct OgmacamFrameInfoV3{width:c_uint,height:c_uint,flag:c_uint,seq:c_uint,timestamp:u64,shutterseq:c_uint,expotime:c_uint,expogain:u16,blacklevel:u16}
type Callback=unsafe extern "C" fn(c_uint,*mut c_void);
const E_NOTIMPL:c_int=0x80004001u32 as c_int; const E_INVALIDARG:c_int=0x80070057u32 as c_int; const E_UNEXPECTED:c_int=0x8000ffffu32 as c_int; const E_PENDING:c_int=0x8000000au32 as c_int;
const IDS:[&str;4]=["OGMA-COOLED-0001","OGMA-GUIDE-0002","OGMA-EIGHTBIT-0003","OGMA-WHEEL-0004"];
const NAMES:[&str;4]=["OGMA AP26CC","OGMA GP2000M","OGMA GP130M8","OGMA EFW"];
// AP26CC: TEC, TEC_ONOFF, ST4, ROI_HARDWARE, BINSKIP, FAN, HEAT, GETTEMPERATURE, BLACKLEVEL, RAW12, TRIGGER_SOFTWARE.
// GP2000M: MONO, BINSKIP, RAW12, TRIGGER_SOFTWARE (no thermometer, no black level).
// GP130M8: MONO, ROI_HARDWARE, TRIGGER_SOFTWARE, 8-bit only. EFW: a filter wheel, which the SDK lists too.
const FLAGS:[u64;4]=[0x80|0x20000|0x200|0x08|0x20|0x10000|0x0000008000000000|0x400|0x400000|0x2000|0x80000,0x10|0x20|0x2000|0x80000,0x10|0x08|0x80000,0x0000100000000000];
const LINE_US:u32=15;
static ACTIVE:AtomicUsize=AtomicUsize::new(0); static BIN:AtomicI32=AtomicI32::new(1);
static GAIN:AtomicI32=AtomicI32::new(100); static TEMP:AtomicI32=AtomicI32::new(-80); static EXPO_US:AtomicU32=AtomicU32::new(0); static SEQ:AtomicU32=AtomicU32::new(0);
static ROI:Mutex<[u32;4]>=Mutex::new([0;4]);
static OPTIONS:Mutex<[c_int;256]>=Mutex::new([0;256]);
// A frame the sensor finished: (seq, roi, bin, expotime, gain, black level, bits, rows reversed).
static QUEUE:Mutex<Vec<(u32,[u32;4],i32,u32,u16,u16,u32,bool)>>=Mutex::new(Vec::new());
// One lock for the callback context and the trigger generation: Stop/Close take it, so no
// callback runs after they return, as the real SDK promises.
static STREAM:Mutex<(usize,u64,bool)>=Mutex::new((0,0,false));
static CALLBACK:AtomicUsize=AtomicUsize::new(0);
fn full(index:usize)->(u32,u32){match index{0=>(80,60),1=>(40,30),2=>(32,24),_=>(0,0)}}
fn flags()->u64{FLAGS[ACTIVE.load(Ordering::SeqCst)]}
fn has(flag:u64)->bool{flags()&flag!=0}
fn bits()->u32{if has(0x2000)&&OPTIONS.lock().unwrap()[0x06]==1{12}else{8}}
fn running()->bool{STREAM.lock().unwrap().2}
fn chars(text:&str)->[Ch;64]{let mut out=[0 as Ch;64]; for (i,ch) in text.bytes().take(63).enumerate(){out[i]=ch as Ch;} out}
// SAFETY: OgmacamResolution is repr(C) POD; an all-zero value is a valid bit pattern.
fn model(index:usize)->*const OgmacamModelV2{let mut res:[OgmacamResolution;16]=unsafe{std::mem::zeroed()}; let (w,h)=full(index); res[0]=OgmacamResolution{width:w,height:h}; let name=match index{0=>b"OGMA AP26CC\0".as_ptr(),1=>b"OGMA GP2000M\0".as_ptr(),2=>b"OGMA GP130M8\0".as_ptr(),_=>b"OGMA EFW\0".as_ptr()}; Box::into_raw(Box::new(OgmacamModelV2{name:name as *const c_char,flag:FLAGS[index],maxspeed:1,preview:1,still:1,maxfanspeed:if index==0{3}else{0},ioctrol:0,xpixsz:3.76,ypixsz:3.76,res}))}
fn final_size(roi:[u32;4],bin:i32)->(u32,u32){let bin=(bin&0x0f).max(1) as u32; ((roi[2]/bin)&!1,(roi[3]/bin)&!1)}
fn sensor_value(x:u32,y:u32,seq:u32)->u32{100+(y*80+x)%800+seq}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_EnumV2(devs:*mut OgmacamDeviceV2)->c_uint{if devs.is_null(){return 0;} for i in 0..4{*devs.add(i)=OgmacamDeviceV2{displayname:chars(NAMES[i]),id:chars(IDS[i]),model:model(i)};} 4}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_Open(id:*const c_void)->*mut c_void{if id.is_null(){return std::ptr::null_mut();} let p=id as *const Ch; let mut text=String::new(); let mut i=0; while *p.add(i)!=0{text.push(*p.add(i) as u8 as char); i+=1;} let Some(index)=IDS.iter().position(|known|*known==text) else {return std::ptr::null_mut()}; ACTIVE.store(index,Ordering::SeqCst); let (w,h)=full(index); *ROI.lock().unwrap()=[0,0,w,h]; BIN.store(1,Ordering::SeqCst); QUEUE.lock().unwrap().clear(); let mut o=[0;256]; o[0x17]=1; o[0x2e]=100; if index==0{o[0x08]=1; o[0x0f]=0; o[0x07]=1; o[0x37]=2; o[0x21]=80;} o[0x23]=if cfg!(windows)||std::env::var("SK_TOUPTEK_UPSIDE_DOWN").is_ok(){1}else{0}; *OPTIONS.lock().unwrap()=o; (index+1) as *mut c_void}
#[no_mangle] pub extern "C" fn Ogmacam_Close(_h:*mut c_void){let mut s=STREAM.lock().unwrap(); s.2=false; s.1+=1;}
#[no_mangle] pub extern "C" fn Ogmacam_Stop(_h:*mut c_void)->c_int{let mut s=STREAM.lock().unwrap(); s.2=false; s.1+=1; 0}
// Version() returns const wchar_t* on Windows (toupcam.h), char* elsewhere.
#[cfg(windows)] static VERSION:[u16;14]=[102,97,107,101,45,111,103,109,97,45,49,46,48,0];
#[cfg(not(windows))] static VERSION:&[u8]=b"fake-ogma-1.0\0";
#[no_mangle] pub extern "C" fn Ogmacam_Version()->*const Ch{VERSION.as_ptr() as *const Ch}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_ExpTimeRange(_h:*mut c_void,min:*mut c_uint,max:*mut c_uint,def:*mut c_uint)->c_int{if !min.is_null(){*min=10;} if !max.is_null(){*max=3_600_000_000;} if !def.is_null(){*def=1000;} 0}
#[no_mangle] pub extern "C" fn Ogmacam_put_ExpoTime(_h:*mut c_void,us:c_uint)->c_int{if !(10..=3_600_000_000).contains(&us){return E_INVALIDARG;} EXPO_US.store(us,Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn Ogmacam_put_Speed(_h:*mut c_void,speed:c_ushort)->c_int{if speed>1{return E_INVALIDARG;} 0}
#[no_mangle] pub extern "C" fn Ogmacam_put_AutoExpoEnable(_h:*mut c_void,mode:c_int)->c_int{if !(0..=2).contains(&mode){return E_INVALIDARG;} 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_ExpoAGain(_h:*mut c_void,gain:*mut u16)->c_int{if gain.is_null(){return -1;} *gain=GAIN.load(Ordering::SeqCst) as u16; 0}
#[no_mangle] pub extern "C" fn Ogmacam_put_ExpoAGain(_h:*mut c_void,gain:u16)->c_int{GAIN.store(gain.clamp(100,5000) as i32,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_ExpoAGainRange(_h:*mut c_void,min:*mut u16,max:*mut u16,def:*mut u16)->c_int{if !min.is_null(){*min=100;} if !max.is_null(){*max=5000;} if !def.is_null(){*def=150;} 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_Temperature(_h:*mut c_void,temp:*mut i16)->c_int{if !has(0x400){return E_NOTIMPL;} if !temp.is_null(){*temp=TEMP.load(Ordering::SeqCst) as i16;} 0}
#[no_mangle] pub extern "C" fn Ogmacam_put_Temperature(_h:*mut c_void,temp:i16)->c_int{if !has(0x20000){return E_NOTIMPL;} OPTIONS.lock().unwrap()[0x0f]=temp as c_int; TEMP.store(temp as i32,Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn Ogmacam_put_Option(_h:*mut c_void,opt:c_uint,value:c_int)->c_int{
    let cooled=has(0x80);
    match opt{
        0x3d=>{let mut q=QUEUE.lock().unwrap(); let n=q.len() as c_int; q.clear(); return n;}
        0x04|0x23 if running()=>return E_UNEXPECTED,
        0x17=>{let n=value&0x0f; if value&!0xcf!=0||!(1..=4).contains(&n){return E_INVALIDARG;} BIN.store(value,Ordering::SeqCst);}
        0x15=>{if !has(0x400000){return E_NOTIMPL;} if value<0||value>31*(1<<(bits()-8)){return E_INVALIDARG;}}
        0x08|0x0f|0x07|0x37|0x21 if !cooled=>return E_NOTIMPL,
        0x20|0x6d=>return E_INVALIDARG,
        o if o>=256=>return E_INVALIDARG,
        _=>{}
    }
    OPTIONS.lock().unwrap()[opt as usize]=value; 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_Option(_h:*mut c_void,opt:c_uint,value:*mut c_int)->c_int{
    if value.is_null()||opt>=256{return E_INVALIDARG;}
    let cooled=has(0x80); let o=*OPTIONS.lock().unwrap();
    *value=match opt{
        0x08|0x0f|0x07|0x37|0x21 if !cooled=>return E_NOTIMPL,
        0x15 if !has(0x400000)=>return E_NOTIMPL,
        0x20=>{if !cooled{return E_NOTIMPL;} if o[0x08]==1{40}else{0}}
        0x6d=>{if !cooled{return E_NOTIMPL;} ((300i32)<<16)|((-500i32)&0xffff)}
        _=>o[opt as usize],
    }; 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_RawFormat(_h:*mut c_void,fourcc:*mut c_uint,bits_out:*mut c_uint)->c_int{if !fourcc.is_null(){*fourcc=u32::from_le_bytes(if has(0x10){*b"YYYY"}else{*b"RGGB"}) as c_uint;} if !bits_out.is_null(){*bits_out=bits();} 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_Size(_h:*mut c_void,width:*mut c_int,height:*mut c_int)->c_int{let (w,h)=full(ACTIVE.load(Ordering::SeqCst)); if !width.is_null(){*width=w as c_int;} if !height.is_null(){*height=h as c_int;} 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_FinalSize(_h:*mut c_void,width:*mut c_int,height:*mut c_int)->c_int{let (w,h)=final_size(*ROI.lock().unwrap(),BIN.load(Ordering::SeqCst)); if !width.is_null(){*width=w as c_int;} if !height.is_null(){*height=h as c_int;} 0}
#[no_mangle] pub extern "C" fn Ogmacam_put_Roi(_h:*mut c_void,x:c_uint,y:c_uint,width:c_uint,height:c_uint)->c_int{let (fw,fh)=full(ACTIVE.load(Ordering::SeqCst)); if (x,y,width,height)==(0,0,0,0){*ROI.lock().unwrap()=[0,0,fw,fh]; return 0;} if x%2!=0||y%2!=0||width%2!=0||height%2!=0||width<16||height<16||x+width>fw||y+height>fh{return E_INVALIDARG;} *ROI.lock().unwrap()=[x,y,width,height]; 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_get_SerialNumber(_h:*mut c_void,buf:*mut c_char)->c_int{if buf.is_null(){return -1;} let text=IDS[ACTIVE.load(Ordering::SeqCst)].as_bytes(); for i in 0..text.len(){*buf.add(i)=text[i] as c_char;} *buf.add(text.len())=0; 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_StartPullModeWithCallback(_h:*mut c_void,callback:Callback,ctx:*mut c_void)->c_int{let mut s=STREAM.lock().unwrap(); s.0=ctx as usize; s.2=true; CALLBACK.store(callback as usize,Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn Ogmacam_Trigger(_h:*mut c_void,number:c_ushort)->c_int{let generation={let mut s=STREAM.lock().unwrap(); if !s.2{return E_UNEXPECTED;} s.1+=1; s.1}; if number==0{return 0;} let us=EXPO_US.load(Ordering::SeqCst); let o=*OPTIONS.lock().unwrap(); let frame=(SEQ.fetch_add(1,Ordering::SeqCst)+1,*ROI.lock().unwrap(),BIN.load(Ordering::SeqCst),us/LINE_US*LINE_US,GAIN.load(Ordering::SeqCst) as u16,o[0x15] as u16,bits(),o[0x23]==1); std::thread::spawn(move||{std::thread::sleep(std::time::Duration::from_micros(us as u64)); let s=STREAM.lock().unwrap(); if s.2&&s.1==generation{let event=if std::env::var("SK_TOUPTEK_PULL_ERROR").is_ok(){0x80}else{QUEUE.lock().unwrap().push(frame); 0x04}; let callback:Callback=unsafe{std::mem::transmute(CALLBACK.load(Ordering::SeqCst))}; unsafe{callback(event,s.0 as *mut c_void)};}}); 0}
#[no_mangle] pub unsafe extern "C" fn Ogmacam_PullImageV3(_h:*mut c_void,buf:*mut c_void,_still:c_int,_bits:c_int,_row:c_int,info:*mut OgmacamFrameInfoV3)->c_int{
    if buf.is_null(){return E_INVALIDARG;}
    let frame={let mut q=QUEUE.lock().unwrap(); if q.is_empty(){return E_PENDING;} q.remove(0)};
    let (seq,roi,bin,expotime,gain,black,bits,reversed)=frame;
    let (w,h)=final_size(roi,bin); let n=(bin&0x0f).max(1) as u32; let top=(1u32<<bits)-1;
    if !info.is_null(){*info=OgmacamFrameInfoV3{width:w,height:h,flag:0x01|0x04|0x08|if has(0x400000){0x10}else{0},seq,timestamp:0,shutterseq:0,expotime,expogain:gain,blacklevel:black};}
    let out=buf as *mut u8;
    for row in 0..h{ for col in 0..w{
        let mut sum=0u32; for dy in 0..n{for dx in 0..n{sum+=sensor_value(roi[0]+col*n+dx,roi[1]+row*n+dy,seq);}}
        let v=if bits==8{(sum>>4).min(top)}else{sum.min(top)};
        let out_row=if reversed{h-1-row}else{row}; let i=(out_row*w+col) as usize;
        if bits==8{*out.add(i)=v as u8;}else{*out.add(i*2)=(v&0xff) as u8; *out.add(i*2+1)=(v>>8) as u8;}
    }}
    0}
