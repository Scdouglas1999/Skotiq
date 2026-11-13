#![allow(non_snake_case)]
use std::ffi::{c_char,c_long,c_ulong,c_void};
use std::sync::atomic::{AtomicI32,Ordering};
type XsdkHandle=*mut c_void;
static ISO:AtomicI32=AtomicI32::new(800);
static LAST_ERROR:AtomicI32=AtomicI32::new(0);
static OPEN:AtomicI32=AtomicI32::new(0);
static LIVE:AtomicI32=AtomicI32::new(0);
static LIVE_STARTS:AtomicI32=AtomicI32::new(0);
static LIVE_QUALITY:AtomicI32=AtomicI32::new(0);
static LIVE_SIZE:AtomicI32=AtomicI32::new(0);
static DELETES:AtomicI32=AtomicI32::new(0);
static FRAMES:AtomicI32=AtomicI32::new(0);
static FOCUS_MODE:AtomicI32=AtomicI32::new(0x8001);
static FOCUS_PULSE:AtomicI32=AtomicI32::new(160);
static FOCUS_TARGET:AtomicI32=AtomicI32::new(160);
static RELEASES:AtomicI32=AtomicI32::new(0);
#[repr(C,packed)] struct XsdkCameraList{str_product:[c_char;256],str_serial_no:[c_char;256],str_ip_address:[c_char;256],str_framework:[c_char;256],b_valid:bool}
#[repr(C,packed)] struct XsdkDeviceInformation{str_vendor:[c_char;256],str_manufacturer:[c_char;256],str_product:[c_char;256],str_firmware:[c_char;256],str_device_type:[c_char;256],str_serial_no:[c_char;256],str_framework:[c_char;256],b_device_id:u8,str_device_name:[c_char;32],str_y_no:[c_char;32]}
#[repr(C,packed)] struct XsdkImageInformation{str_internal_name:[c_char;32],l_format:c_long,l_data_size:c_long,l_image_pix_height:c_long,l_image_pix_width:c_long,l_image_bit_depth:c_long,l_preview_size:c_long,h_image:*mut c_void}
#[repr(C)] struct FocusPosCap{size:c_long,version:c_long,infinity:c_long,closest:c_long,over_infinity:c_long,over_closest:c_long,depth:c_long,step:c_long}
fn fail(code:i32)->c_long{LAST_ERROR.store(code,Ordering::SeqCst); -1}
unsafe fn fill<const N:usize>(buf:&mut [c_char;N],text:&[u8]){for b in buf.iter_mut(){*b=0;} for i in 0..text.len().min(N.saturating_sub(1)){buf[i]=text[i] as c_char;}}
/// Test access to the fake's state: 0 resets it, 1.. read one counter.
#[no_mangle] pub extern "C" fn SkotiqFake(which:c_long)->c_long{let all=[&OPEN,&LIVE,&LIVE_STARTS,&LIVE_QUALITY,&LIVE_SIZE,&DELETES,&FOCUS_MODE,&FOCUS_TARGET,&RELEASES]; if which==0{for c in all{c.store(0,Ordering::SeqCst);} FOCUS_MODE.store(0x8001,Ordering::SeqCst); FOCUS_PULSE.store(160,Ordering::SeqCst); FOCUS_TARGET.store(160,Ordering::SeqCst); return 0;} all[(which-1) as usize].load(Ordering::SeqCst)}
#[no_mangle] pub extern "C" fn XSDK_Init(_h:*mut c_void)->c_long{0}
#[no_mangle] pub extern "C" fn XSDK_Exit()->c_long{0}
#[no_mangle] pub unsafe extern "C" fn XSDK_Detect(_interface:c_long,_p_interface:*mut c_char,_p_device_name:*mut c_char,count:*mut c_long)->c_long{if !count.is_null(){*count=2;} 0}
#[no_mangle] pub unsafe extern "C" fn XSDK_Append(_interface:c_long,_p_interface:*mut c_char,_p_device_name:*mut c_char,count:*mut c_long,list:*mut XsdkCameraList)->c_long{if !count.is_null(){*count=2;} if list.is_null(){return 0;} let mut first:XsdkCameraList=std::mem::zeroed(); fill(&mut first.str_product,b"GFX100 II"); fill(&mut first.str_serial_no,b"FUJI-GFX-0001"); fill(&mut first.str_framework,b"USB"); first.b_valid=true; *list.add(0)=first; let mut second:XsdkCameraList=std::mem::zeroed(); fill(&mut second.str_product,b"X-T5"); fill(&mut second.str_serial_no,b"FUJI-XT5-0002"); fill(&mut second.str_framework,b"USB"); second.b_valid=true; *list.add(1)=second; 0}
/// A body that is already open is refused, as the SDK refuses it.
#[no_mangle] pub unsafe extern "C" fn XSDK_OpenEx(_device:*const c_char,handle:*mut XsdkHandle,mode:*mut c_long,_opt:*mut c_void)->c_long{if handle.is_null(){return -1;} if OPEN.load(Ordering::SeqCst)>0{return fail(0x1001);} OPEN.store(1,Ordering::SeqCst); *handle=1usize as XsdkHandle; if !mode.is_null(){*mode=0;} 0}
#[no_mangle] pub extern "C" fn XSDK_Close(_h:XsdkHandle)->c_long{OPEN.store(0,Ordering::SeqCst); LIVE.store(0,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn XSDK_GetErrorNumber(_h:XsdkHandle,api:*mut c_long,err:*mut c_long)->c_long{if !api.is_null(){*api=0;} let last=LAST_ERROR.swap(0,Ordering::SeqCst); if !err.is_null(){*err=if std::env::var("SK_FUJIFILM_RELEASE_ERROR").is_ok(){0x00001006}else{last};} 0}
#[no_mangle] pub unsafe extern "C" fn XSDK_GetDeviceInfo(_h:XsdkHandle,info:*mut XsdkDeviceInformation)->c_long{if info.is_null(){return -1;} let mut v:XsdkDeviceInformation=std::mem::zeroed(); fill(&mut v.str_vendor,b"FUJIFILM"); fill(&mut v.str_manufacturer,b"FUJIFILM"); fill(&mut v.str_product,b"GFX100 II"); fill(&mut v.str_firmware,b"9.99"); fill(&mut v.str_device_type,b"Digital Camera"); if std::env::var("SK_FUJIFILM_INFO_NO_SERIAL").is_err(){fill(&mut v.str_serial_no,b"FUJI-GFX-0001");} fill(&mut v.str_framework,b"USB"); v.b_device_id=1; fill(&mut v.str_device_name,b"Skotiq Fuji"); *info=v; 0}
#[no_mangle] pub extern "C" fn XSDK_SetPriorityMode(_h:XsdkHandle,_mode:c_long)->c_long{0}
/// The shutter is refused while live view runs.
#[no_mangle] pub unsafe extern "C" fn XSDK_Release(_h:XsdkHandle,_mode:c_long,shot:*mut c_long,af:*mut c_long)->c_long{if std::env::var("SK_FUJIFILM_RELEASE_ERROR").is_ok(){return -1;} if LIVE.load(Ordering::SeqCst)==1{return fail(0x1006);} RELEASES.fetch_add(1,Ordering::SeqCst); if !shot.is_null(){*shot=0;} if !af.is_null(){*af=0;} 0}
#[no_mangle] pub unsafe extern "C" fn XSDK_ReadImageInfo(_h:XsdkHandle,info:*mut XsdkImageInformation)->c_long{if info.is_null(){return -1;} let live=LIVE.load(Ordering::SeqCst)==1; (*info).l_format=if live{4}else{7}; (*info).l_data_size=if live{6}else{0}; (*info).l_image_pix_width=0; (*info).l_image_pix_height=0; (*info).l_image_bit_depth=0; 0}
#[no_mangle] pub unsafe extern "C" fn XSDK_ReadImage(_h:XsdkHandle,data:*mut u8,size:c_ulong)->c_long{if LIVE.load(Ordering::SeqCst)==1&&size>=6&&!data.is_null(){let n=FRAMES.fetch_add(1,Ordering::SeqCst) as u8; for (i,b) in [0xFF,0xD8,n,0,0xFF,0xD9].iter().enumerate(){*data.add(i)=*b;}} 0}
#[no_mangle] pub extern "C" fn XSDK_DeleteImage(_h:XsdkHandle)->c_long{DELETES.fetch_add(1,Ordering::SeqCst); 0}
/// Live view keeps three frames waiting.
#[no_mangle] pub unsafe extern "C" fn XSDK_GetBufferCapacity(_h:XsdkHandle,shot:*mut c_long,total:*mut c_long)->c_long{let n=if LIVE.load(Ordering::SeqCst)==1{3}else{0}; if !shot.is_null(){*shot=n;} if !total.is_null(){*total=n;} 0}
#[no_mangle] pub unsafe extern "C" fn XSDK_CapShutterSpeed(_h:XsdkHandle,num:*mut c_long,speeds:*mut c_long,bulb:*mut c_long)->c_long{if !num.is_null(){*num=3;} if !speeds.is_null(){*speeds.add(0)=-1; *speeds.add(1)=9843; *speeds.add(2)=976;} if !bulb.is_null(){*bulb=0;} 0}
#[no_mangle] pub extern "C" fn XSDK_SetShutterSpeed(_h:XsdkHandle,_speed:c_long,_bulb:c_long)->c_long{0}
#[no_mangle] pub unsafe extern "C" fn XSDK_CapSensitivity(_h:XsdkHandle,num:*mut c_long,values:*mut c_long)->c_long{if !num.is_null(){*num=5;} if !values.is_null(){for (i,v) in [100,200,400,800,1600].iter().enumerate(){*values.add(i)=*v;}} 0}
#[no_mangle] pub extern "C" fn XSDK_SetSensitivity(_h:XsdkHandle,value:c_long)->c_long{ISO.store(value as i32,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn XSDK_GetSensitivity(_h:XsdkHandle,value:*mut c_long)->c_long{if !value.is_null(){*value=ISO.load(Ordering::SeqCst) as c_long;} 0}
#[no_mangle] pub extern "C" fn XSDK_SetDynamicRange(_h:XsdkHandle,_dr:c_long)->c_long{0}
// The SDK's property calls are variadic. On x64 Windows the first four
// arguments travel in registers either way, so a callee with four fixed
// arguments reads the value the driver passes, and ignores it for the codes
// that pass none.
#[no_mangle] pub extern "C" fn XSDK_SetProp(_h:XsdkHandle,api:c_long,param:c_long,value:c_long)->c_long{match (api,param){(0x3301,0)=>{if LIVE.load(Ordering::SeqCst)==0{LIVE.store(1,Ordering::SeqCst); LIVE_STARTS.fetch_add(1,Ordering::SeqCst);}} (0x3302,0)=>LIVE.store(0,Ordering::SeqCst),(0x3323,1)=>LIVE_QUALITY.store(value,Ordering::SeqCst),(0x3325,1)=>LIVE_SIZE.store(value,Ordering::SeqCst),(0x2201,1)=>{if std::env::var("SK_FUJIFILM_FOCUS_SWITCH_AF").is_ok(){return fail(0x2003);} FOCUS_MODE.store(value,Ordering::SeqCst)},(0x2207,1)=>FOCUS_TARGET.store(value,Ordering::SeqCst),(0x2145,1)=>{},_=>return fail(0x1002)} 0}
/// A lens read moves the fake lens 150 pulses toward its target; it comes to rest 30 pulses short, as some lenses do.
#[no_mangle] pub unsafe extern "C" fn XSDK_GetProp(_h:XsdkHandle,api:c_long,param:c_long,out:*mut c_long)->c_long{if param!=1||out.is_null(){return fail(0x1002);} *out=match api{0x2208=>{let target=FOCUS_TARGET.load(Ordering::SeqCst); let rest=if target==FOCUS_PULSE.load(Ordering::SeqCst){target}else{target-30}; let now=FOCUS_PULSE.load(Ordering::SeqCst); let next=if (rest-now).abs()<=150{rest}else{now+150*(rest-now).signum()}; FOCUS_PULSE.store(next,Ordering::SeqCst); next} 0x2202=>FOCUS_MODE.load(Ordering::SeqCst),0x2146=>2,0x2161=>1,_=>return fail(0x1013)}; 0}
/// CapFocusPos with the structure's size in and the structure out (SDK Programming Reference 4.2.1.37).
/// Outside manual focus it reports no range, as a GFX100S II does (owner's NINA plugin 3.1.0.0).
#[no_mangle] pub unsafe extern "C" fn XSDK_CapProp(_h:XsdkHandle,api:c_long,param:c_long,size:*mut c_long,cap:*mut FocusPosCap)->c_long{if api!=0x2259||param!=2||size.is_null()||cap.is_null(){return fail(0x1002);} if std::env::var("SK_FUJIFILM_NO_LENS").is_ok(){return fail(0x1005);} if *size!=std::mem::size_of::<FocusPosCap>() as c_long||(*cap).version!=0x00010000{return fail(0x1002);} if FOCUS_MODE.load(Ordering::SeqCst)!=1{*cap=FocusPosCap{size:*size,version:0x00010000,infinity:0,closest:0,over_infinity:0,over_closest:0,depth:0,step:0}; return 0;} *cap=FocusPosCap{size:*size,version:0x00010000,infinity:100,closest:900,over_infinity:40,over_closest:20,depth:5,step:3}; 0}
