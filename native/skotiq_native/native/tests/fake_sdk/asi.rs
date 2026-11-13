#![allow(non_snake_case)]
// Models ASICamera2.h for three cameras. Camera 0: cooled mono, bins 1/2/4,
// exposures up to 60 s. Camera 1: uncooled RGGB color, bins 1/2, 12-bit,
// exposures up to 2000 s, with FLIP and MONO_BIN, which FAKE_ASI_FLIP and
// FAKE_ASI_MONO_BIN preset the way another program can leave them. Camera 2:
// uncooled mono that reads out RAW8 only. FAKE_ASI_GONE=1 takes every camera
// off the bus: the SDK lists none and answers a call on any id with
// ASI_ERROR_INVALID_ID. FAKE_ASI_UNREADABLE lists control ids (comma
// separated) whose reads answer ASI_ERROR_GENERAL_ERROR.
// Every pixel holds 1000 + 256 * row + column of the binned sensor grid, so a
// frame shows where on the sensor it was read.
use std::ffi::{c_char, c_int, c_long, c_uchar};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Mutex;
const MAX_W: [c_int; 3] = [64, 96, 32];
const MAX_H: [c_int; 3] = [48, 64, 16];
const BINS: [&[c_int]; 3] = [&[1, 2, 4], &[1, 2], &[1, 2]];
const FORMATS: [&[c_int]; 3] = [&[0, 2], &[0, 1, 2, 3], &[0, 3]];
type Control = (c_int, &'static [u8], i64, i64, i64);
const CONTROLS: [&[Control]; 3] = [
    &[(0, b"Gain", 0, 600, 0), (1, b"Exposure", 1, 60_000_000, 10_000), (5, b"Offset", 0, 100, 0), (6, b"BandWidth", 40, 100, 40), (8, b"Temperature", -500, 1000, -105), (15, b"CoolerPowerPerc", 0, 100, 37), (16, b"TargetTemp", -40, 30, -10), (17, b"CoolerOn", 0, 1, 0), (21, b"AntiDewHeater", 0, 1, 1)],
    &[(0, b"Gain", 0, 570, 0), (1, b"Exposure", 32, 2_000_000_000, 10_000), (5, b"Offset", 0, 255, 0), (6, b"BandWidth", 40, 100, 50), (8, b"Temperature", -500, 1000, 255), (9, b"Flip", 0, 3, 0), (18, b"Mono bin", 0, 1, 0)],
    &[(0, b"Gain", 0, 100, 50), (1, b"Exposure", 64, 2_000_000_000, 10_000), (5, b"Offset", 0, 100, 0), (6, b"BandWidth", 40, 100, 50), (8, b"Temperature", -500, 1000, 300)],
];
static WIDTH: [AtomicI32; 3] = [AtomicI32::new(64), AtomicI32::new(96), AtomicI32::new(32)];
static HEIGHT: [AtomicI32; 3] = [AtomicI32::new(48), AtomicI32::new(64), AtomicI32::new(16)];
static BIN: [AtomicI32; 3] = [AtomicI32::new(1), AtomicI32::new(1), AtomicI32::new(1)];
static IMG_TYPE: [AtomicI32; 3] = [AtomicI32::new(2), AtomicI32::new(2), AtomicI32::new(0)];
static START_X: [AtomicI32; 3] = [AtomicI32::new(0), AtomicI32::new(0), AtomicI32::new(0)];
static START_Y: [AtomicI32; 3] = [AtomicI32::new(0), AtomicI32::new(0), AtomicI32::new(0)];
static VALUES: Mutex<[[Option<i64>; 32]; 3]> = Mutex::new([[None; 32]; 3]);
#[repr(C)]
struct ASICameraInfo{ name:[c_char;64], camera_id:c_int, max_height:c_long, max_width:c_long, is_color_cam:c_int, bayer_pattern:c_int, supported_bins:[c_int;16], supported_video_format:[c_int;8], pixel_size:f64, mechanical_shutter:c_int, st4_port:c_int, is_cooler_cam:c_int, is_usb3_host:c_int, is_usb3_camera:c_int, elec_per_adu:f32, bit_depth:c_int, is_trigger_cam:c_int, unused:[c_char;16] }
#[repr(C)]
struct ASIControlCaps{ name:[c_char;64], description:[c_char;128], max_value:c_long, min_value:c_long, default_value:c_long, is_auto_supported:c_int, is_writable:c_int, control_type:c_int, unused:[c_char;32] }
fn write_cstr(buf:&mut [c_char], text:&[u8]){ for slot in buf.iter_mut(){*slot=0;} for i in 0..text.len().min(buf.len().saturating_sub(1)){buf[i]=text[i] as c_char;} }
fn camera(id:c_int)->Option<usize>{ if (0..3).contains(&id)&&std::env::var("FAKE_ASI_GONE").is_err() {Some(id as usize)} else {None} }
fn control(cam:usize, control:c_int)->Option<&'static Control>{ CONTROLS[cam].iter().find(|c| c.0==control) }
fn env_value(name:&str)->Option<i64>{ std::env::var(name).ok().and_then(|v| v.parse().ok()) }
#[no_mangle] pub extern "C" fn ASIGetNumOfConnectedCameras()->c_int{ if std::env::var("FAKE_ASI_GONE").is_ok(){0}else{3} }
#[no_mangle] pub extern "C" fn ASIGetSDKVersion()->*const c_char{b"fake-asi-1.0\0".as_ptr() as *const c_char}
#[no_mangle] pub unsafe extern "C" fn ASIGetCameraProperty(info:*mut ASICameraInfo,index:c_int)->c_int{ let Some(cam)=camera(index) else {return 1;}; if info.is_null(){return 1;} let mut value:ASICameraInfo=std::mem::zeroed(); value.camera_id=index; value.max_width=MAX_W[cam] as c_long; value.max_height=MAX_H[cam] as c_long; for (i,b) in BINS[cam].iter().enumerate(){value.supported_bins[i]=*b;} for (i,f) in FORMATS[cam].iter().enumerate(){value.supported_video_format[i]=*f;} value.supported_video_format[FORMATS[cam].len()]=-1; value.st4_port=1; value.is_usb3_host=1; value.is_usb3_camera=1; if cam==0 { write_cstr(&mut value.name,b"Skotiq Fake ASI2600MM Pro"); value.pixel_size=3.76; value.is_cooler_cam=1; value.elec_per_adu=0.8; value.bit_depth=16; } else if cam==2 { write_cstr(&mut value.name,b"Skotiq Fake ASI120MM Mini"); value.pixel_size=3.75; value.elec_per_adu=4.0; value.bit_depth=12; value.is_usb3_host=0; value.is_usb3_camera=0; } else { write_cstr(&mut value.name,b"Skotiq Fake ASI224MC"); value.pixel_size=3.75; value.is_color_cam=1; value.bayer_pattern=0; value.elec_per_adu=3.0; value.bit_depth=12; } *info=value; 0 }
#[no_mangle] pub extern "C" fn ASIOpenCamera(id:c_int)->c_int{if camera(id).is_some(){0}else{2}}
#[no_mangle] pub extern "C" fn ASIInitCamera(id:c_int)->c_int{if camera(id).is_some(){0}else{2}}
#[no_mangle] pub extern "C" fn ASICloseCamera(_id:c_int)->c_int{0}
#[no_mangle] pub unsafe extern "C" fn ASIGetControlValue(id:c_int,control_type:c_int,value:*mut c_long,is_auto:*mut c_int)->c_int{ let Some(cam)=camera(id) else {return 2;}; if value.is_null()||is_auto.is_null(){return 16;} let Some(caps)=control(cam,control_type) else {return 3;}; if std::env::var("FAKE_ASI_UNREADABLE").is_ok_and(|ids| ids.split(',').any(|id| id.trim()==control_type.to_string())){return 16;} *is_auto=0; let preset=match control_type{9=>env_value("FAKE_ASI_FLIP"),18=>env_value("FAKE_ASI_MONO_BIN"),_=>None}; let stored=VALUES.lock().unwrap()[cam][control_type as usize]; *value=preset.or(stored).unwrap_or(caps.4) as c_long; 0 }
#[no_mangle] pub extern "C" fn ASISetControlValue(id:c_int,control_type:c_int,value:c_long,_is_auto:c_int)->c_int{ let Some(cam)=camera(id) else {return 2;}; let Some(caps)=control(cam,control_type) else {return 3;}; let clamped=(value as i64).clamp(caps.2,caps.3); VALUES.lock().unwrap()[cam][control_type as usize]=Some(clamped); 0 }
#[no_mangle] pub extern "C" fn ASISetROIFormat(id:c_int,width:c_int,height:c_int,bin:c_int,img_type:c_int)->c_int{ let Some(cam)=camera(id) else {return 2;}; if !FORMATS[cam].contains(&img_type){return 9;} if !BINS[cam].contains(&bin)||width<=0||height<=0||width%8!=0||height%2!=0||width*bin>MAX_W[cam]||height*bin>MAX_H[cam]{return 8;} WIDTH[cam].store(width,Ordering::SeqCst); HEIGHT[cam].store(height,Ordering::SeqCst); BIN[cam].store(bin,Ordering::SeqCst); IMG_TYPE[cam].store(img_type,Ordering::SeqCst); START_X[cam].store((MAX_W[cam]/bin-width)/2,Ordering::SeqCst); START_Y[cam].store((MAX_H[cam]/bin-height)/2,Ordering::SeqCst); 0 }
#[no_mangle] pub extern "C" fn ASISetStartPos(id:c_int,x:c_int,y:c_int)->c_int{ let Some(cam)=camera(id) else {return 2;}; let bin=BIN[cam].load(Ordering::SeqCst); if x<0||y<0||x+WIDTH[cam].load(Ordering::SeqCst)>MAX_W[cam]/bin||y+HEIGHT[cam].load(Ordering::SeqCst)>MAX_H[cam]/bin{return 10;} START_X[cam].store(x,Ordering::SeqCst); START_Y[cam].store(y,Ordering::SeqCst); 0 }
#[no_mangle] pub unsafe extern "C" fn ASIGetStartPos(id:c_int,x:*mut c_int,y:*mut c_int)->c_int{ let Some(cam)=camera(id) else {return 2;}; if x.is_null()||y.is_null(){return 16;} *x=START_X[cam].load(Ordering::SeqCst); *y=START_Y[cam].load(Ordering::SeqCst); 0 }
#[no_mangle] pub unsafe extern "C" fn ASIGetROIFormat(id:c_int,width:*mut c_int,height:*mut c_int,bin:*mut c_int,img_type:*mut c_int)->c_int{ let Some(cam)=camera(id) else {return 2;}; if width.is_null()||height.is_null()||bin.is_null()||img_type.is_null(){return 16;} *width=WIDTH[cam].load(Ordering::SeqCst); *height=HEIGHT[cam].load(Ordering::SeqCst); *bin=BIN[cam].load(Ordering::SeqCst); *img_type=IMG_TYPE[cam].load(Ordering::SeqCst); 0 }
#[no_mangle] pub extern "C" fn ASIStartExposure(id:c_int,_dark:c_int)->c_int{ if camera(id).is_none(){return 2;} 0 }
#[no_mangle] pub extern "C" fn ASIStopExposure(id:c_int)->c_int{ if camera(id).is_none(){return 2;} 0 }
#[no_mangle] pub unsafe extern "C" fn ASIGetExpStatus(id:c_int,status:*mut c_int)->c_int{ if camera(id).is_none(){return 2;} if status.is_null(){return 16;} *status=2; 0 }
#[no_mangle] pub unsafe extern "C" fn ASIGetDataAfterExp(id:c_int,buffer:*mut c_uchar,size:c_long)->c_int{ let Some(cam)=camera(id) else {return 2;}; let (w,h)=(WIDTH[cam].load(Ordering::SeqCst),HEIGHT[cam].load(Ordering::SeqCst)); let (x0,y0)=(START_X[cam].load(Ordering::SeqCst),START_Y[cam].load(Ordering::SeqCst)); let bytes=if IMG_TYPE[cam].load(Ordering::SeqCst)==2 {2} else {1}; if buffer.is_null()||(size as i64)<(w as i64)*(h as i64)*bytes{return 13;} for row in 0..h { for col in 0..w { let value=(1000+256*(y0+row)+(x0+col)) as u16; let i=(row*w+col) as usize; if bytes==2 { *buffer.add(i*2)=(value&0xff) as u8; *buffer.add(i*2+1)=(value>>8) as u8; } else { *buffer.add(i)=(value&0xff) as u8; } } } 0 }
#[no_mangle] pub unsafe extern "C" fn ASIGetNumOfControls(id:c_int,count:*mut c_int)->c_int{ let Some(cam)=camera(id) else {return 2;}; if count.is_null(){return 16;} *count=CONTROLS[cam].len() as c_int; 0 }
#[no_mangle] pub unsafe extern "C" fn ASIGetControlCaps(id:c_int,index:c_int,caps:*mut ASIControlCaps)->c_int{ let Some(cam)=camera(id) else {return 2;}; if caps.is_null(){return 16;} if index<0||index as usize>=CONTROLS[cam].len(){return 1;} let (control_type,name,min,max,default_value)=CONTROLS[cam][index as usize]; let mut value:ASIControlCaps=std::mem::zeroed(); write_cstr(&mut value.name,name); write_cstr(&mut value.description,b"Skotiq fake SDK control"); value.min_value=min as c_long; value.max_value=max as c_long; value.default_value=default_value as c_long; value.is_writable=if control_type==8||control_type==15 {0} else {1}; value.control_type=control_type; *caps=value; 0 }
