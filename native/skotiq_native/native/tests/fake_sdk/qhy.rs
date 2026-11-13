#![allow(non_snake_case)]
use std::ffi::{c_char,c_double,c_int,c_uint,c_void,CStr};
use std::sync::atomic::{AtomicI32,AtomicU32,AtomicU64,Ordering};
static CAMERA_KIND:AtomicI32=AtomicI32::new(1); static WIDTH:AtomicU32=AtomicU32::new(64); static HEIGHT:AtomicU32=AtomicU32::new(48); static BIN:AtomicU32=AtomicU32::new(1); static CFW_POS:AtomicI32=AtomicI32::new(0); static READ_MODE:AtomicU32=AtomicU32::new(0);
static GAIN_BITS:AtomicU64=AtomicU64::new(0); static OFFSET_BITS:AtomicU64=AtomicU64::new(0); static COOLER_BITS:AtomicU64=AtomicU64::new(0);
fn set_f64(slot:&AtomicU64,value:f64){slot.store(value.to_bits(),Ordering::SeqCst);} fn get_f64(slot:&AtomicU64)->f64{f64::from_bits(slot.load(Ordering::SeqCst))}
unsafe fn write_cstr(buf:*mut c_char,text:&[u8]){for i in 0..256{*buf.add(i)=0;} for i in 0..text.len(){*buf.add(i)=text[i] as c_char;}}
#[no_mangle] pub extern "C" fn InitQHYCCDResource()->c_uint{0}
#[no_mangle] pub extern "C" fn ReleaseQHYCCDResource()->c_uint{0}
#[no_mangle] pub extern "C" fn ScanQHYCCD()->c_uint{2}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDSDKVersion(year:*mut c_uint,month:*mut c_uint,day:*mut c_uint,subday:*mut c_uint)->c_uint{if !year.is_null(){*year=2026;} if !month.is_null(){*month=5;} if !day.is_null(){*day=25;} if !subday.is_null(){*subday=1;} 0}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDId(index:c_uint,id:*mut c_char)->c_uint{if id.is_null(){return 1;} match index{0=>write_cstr(id,b"QHY268M-FAKE0001"),1=>write_cstr(id,b"QHY5III462C-FAKE0002"),_=>return 1} 0}
#[no_mangle] pub unsafe extern "C" fn OpenQHYCCD(id:*const c_char)->*mut c_void{if id.is_null(){return std::ptr::null_mut();} let s=CStr::from_ptr(id).to_string_lossy(); if s.contains("QHY5III"){CAMERA_KIND.store(2,Ordering::SeqCst); WIDTH.store(48,Ordering::SeqCst); HEIGHT.store(32,Ordering::SeqCst);}else{CAMERA_KIND.store(1,Ordering::SeqCst); WIDTH.store(64,Ordering::SeqCst); HEIGHT.store(48,Ordering::SeqCst);} 1usize as *mut c_void}
#[no_mangle] pub extern "C" fn CloseQHYCCD(_handle:*mut c_void)->c_uint{0}
#[no_mangle] pub extern "C" fn SetQHYCCDStreamMode(_handle:*mut c_void,_mode:c_uint)->c_uint{0}
#[no_mangle] pub extern "C" fn InitQHYCCD(_handle:*mut c_void)->c_uint{0}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDChipInfo(_handle:*mut c_void,chip_w:*mut c_double,chip_h:*mut c_double,img_w:*mut c_uint,img_h:*mut c_uint,pixel_w:*mut c_double,pixel_h:*mut c_double,bpp:*mut c_uint)->c_uint{let kind=CAMERA_KIND.load(Ordering::SeqCst); if !chip_w.is_null(){*chip_w=if kind==1{23.5}else{5.6};} if !chip_h.is_null(){*chip_h=if kind==1{15.7}else{3.2};} if !img_w.is_null(){*img_w=WIDTH.load(Ordering::SeqCst);} if !img_h.is_null(){*img_h=HEIGHT.load(Ordering::SeqCst);} if !pixel_w.is_null(){*pixel_w=if kind==1{3.76}else{2.9};} if !pixel_h.is_null(){*pixel_h=if kind==1{3.76}else{2.9};} if !bpp.is_null(){*bpp=16;} 0}
#[no_mangle] pub extern "C" fn IsQHYCCDControlAvailable(_handle:*mut c_void,control:c_int)->c_uint{let kind=CAMERA_KIND.load(Ordering::SeqCst); match control{18|19=>if kind==1{0}else{1},20=>if kind==2{3}else{u32::MAX},59=>if kind==2{0}else{1},21|22|23|24|35=>0,_=>0}}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDEffectiveArea(_handle:*mut c_void,x:*mut c_uint,y:*mut c_uint,w:*mut c_uint,h:*mut c_uint)->c_uint{if !x.is_null(){*x=0;} if !y.is_null(){*y=0;} if !w.is_null(){*w=WIDTH.load(Ordering::SeqCst);} if !h.is_null(){*h=HEIGHT.load(Ordering::SeqCst);} 0}
#[no_mangle] pub extern "C" fn SetQHYCCDParam(_handle:*mut c_void,control:c_int,value:c_double)->c_uint{match control{6=>set_f64(&GAIN_BITS,value),7=>set_f64(&OFFSET_BITS,value),17=>CFW_POS.store((value as i32)-48,Ordering::SeqCst),18=>set_f64(&COOLER_BITS,value),_=>{}} 0}
#[no_mangle] pub extern "C" fn GetQHYCCDParam(_handle:*mut c_void,control:c_int)->c_double{match control{6=>get_f64(&GAIN_BITS),7=>get_f64(&OFFSET_BITS),12=>40.0,14=>-9.25,15=>35.0,17=>(CFW_POS.load(Ordering::SeqCst)+48) as f64,18=>get_f64(&COOLER_BITS),20=>4.0,44=>7.0,62=>23.0,63=>900.0,_=>0.0}}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDParamMinMaxStep(_handle:*mut c_void,control:c_int,min:*mut c_double,max:*mut c_double,step:*mut c_double)->c_uint{let (lo,hi)=if control==8{(1.0,3_600_000_000.0)}else{(0.0,600.0)}; if !min.is_null(){*min=lo;} if !max.is_null(){*max=hi;} if !step.is_null(){*step=1.0;} 0}
#[no_mangle] pub extern "C" fn SetQHYCCDResolution(_handle:*mut c_void,_x:c_uint,_y:c_uint,width:c_uint,height:c_uint)->c_uint{if width==0||height==0{return 1;} WIDTH.store(width,Ordering::SeqCst); HEIGHT.store(height,Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn SetQHYCCDBinMode(_handle:*mut c_void,bin_x:c_uint,bin_y:c_uint)->c_uint{if bin_x==0||bin_x!=bin_y{return 1;} BIN.store(bin_x,Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn SetQHYCCDBitsMode(_handle:*mut c_void,_bits:c_uint)->c_uint{0}
#[no_mangle] pub extern "C" fn ExpQHYCCDSingleFrame(_handle:*mut c_void)->c_uint{if std::env::var("SK_QHY_EXPOSURE_ERROR").is_ok(){u32::MAX}else{0}}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDSingleFrame(_handle:*mut c_void,width:*mut c_uint,height:*mut c_uint,bpp:*mut c_uint,channels:*mut c_uint,buf:*mut u8)->c_uint{let w=WIDTH.load(Ordering::SeqCst); let h=HEIGHT.load(Ordering::SeqCst); if !width.is_null(){*width=w;} if !height.is_null(){*height=h;} if !bpp.is_null(){*bpp=16;} if !channels.is_null(){*channels=1;} if buf.is_null(){return 1;} for i in 0..((w*h) as usize){let v=6000u16.wrapping_add(i as u16); *buf.add(i*2)=(v&0xff) as u8; *buf.add(i*2+1)=(v>>8) as u8;} 0}
#[no_mangle] pub extern "C" fn CancelQHYCCDExposingAndReadout(_handle:*mut c_void)->c_uint{0}
#[no_mangle] pub extern "C" fn GetQHYCCDMemLength(_handle:*mut c_void)->c_uint{WIDTH.load(Ordering::SeqCst)*HEIGHT.load(Ordering::SeqCst)*2}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDReadModeName(_handle:*mut c_void,index:c_uint,name:*mut c_char)->c_uint{if name.is_null(){return 1;} match index{0=>write_cstr(name,b"Photographic DSO"),1=>write_cstr(name,b"High Gain"),_=>return 1} 0}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDNumberOfReadModes(_handle:*mut c_void,count:*mut c_uint)->c_uint{if count.is_null(){return 1;} *count=2; 0}
#[no_mangle] pub extern "C" fn SetQHYCCDReadMode(_handle:*mut c_void,mode:c_uint)->c_uint{if mode>1{return 1;} READ_MODE.store(mode,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn GetQHYCCDReadMode(_handle:*mut c_void,mode:*mut c_uint)->c_uint{if mode.is_null(){return 1;} *mode=READ_MODE.load(Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn IsQHYCCDCFWPlugged(_handle:*mut c_void)->c_uint{if CAMERA_KIND.load(Ordering::SeqCst)==1{0}else{1}}
