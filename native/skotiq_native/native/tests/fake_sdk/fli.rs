#![allow(non_snake_case)]
use std::ffi::{c_char,c_double,c_long,CStr};
use std::sync::Mutex;
use std::sync::atomic::{AtomicI64,Ordering};
use std::time::Instant;
// Behaves as libfli does for a USB camera, where the driver relies on it: pixel size in meters
// (libfli-camera-usb.c), FLISetImageArea's lower-right corner is ul + binned size and the camera
// reads (lr - ul) * bin sensor pixels from ul (libfli.c), FLIGrabRow fails while the exposure
// runs, a grabbed row is host-endian. Env: SK_FLI_KERNEL_NAMES lists devices under FLI's Linux
// driver names (/dev/fliusbN); SK_FLI_STATUS_UNKNOWN answers FLI_CAMERA_STATUS_UNKNOWN like a
// MaxCam; SK_FLI_GRAB_ERROR fails FLIGrabRow; SK_FLI_UNPLUGGED fails every call on an open device.
const FLIDEVICE_CAMERA:c_long=0x100; const FLIDEVICE_FILTERWHEEL:c_long=0x200; const FLIDEVICE_FOCUSER:c_long=0x300;
const EIO:c_long=-5; const ENODEV:c_long=-19; const EINVAL:c_long=-22; const ETIMEDOUT:c_long=-110;
const SENSOR_W:c_long=64; const SENSOR_H:c_long=48;
static LIST_DOMAIN:AtomicI64=AtomicI64::new(0); static FOCUS_POS:AtomicI64=AtomicI64::new(0); static FILTER_POS:AtomicI64=AtomicI64::new(0);
struct Cam{area:[c_long;4],hbin:c_long,vbin:c_long,exposure_ms:c_long,setpoint:c_double,started:Option<Instant>,rows_read:c_long,frame_pending:bool,cancels:c_long}
static CAM:Mutex<Cam>=Mutex::new(Cam{area:[0,0,SENSOR_W,SENSOR_H],hbin:1,vbin:1,exposure_ms:0,setpoint:0.0,started:None,rows_read:0,frame_pending:false,cancels:0});
fn env(name:&str)->bool{std::env::var_os(name).is_some()}
fn devices()->[(&'static str,c_long,&'static [u8],&'static [u8]);3]{if env("SK_FLI_KERNEL_NAMES"){[("/dev/fliusb0",FLIDEVICE_CAMERA,b"FLI ProLine PL16803\0",b"PL0001\0"),("/dev/fliusb1",FLIDEVICE_FOCUSER,b"FLI PDF Focuser\0",b"PDF0002\0"),("/dev/fliusb2",FLIDEVICE_FILTERWHEEL,b"FLI CFW-5-7\0",b"CFW0003\0")]}else{[("fake-camera",FLIDEVICE_CAMERA,b"FLI ProLine PL16803\0",b"PL0001\0"),("fake-focuser",FLIDEVICE_FOCUSER,b"FLI PDF Focuser\0",b"PDF0002\0"),("fake-filter",FLIDEVICE_FILTERWHEEL,b"FLI CFW-5-7\0",b"CFW0003\0")]}}
fn device(kind:c_long)->(&'static str,c_long,&'static [u8],&'static [u8]){devices().into_iter().find(|d|d.1==kind).unwrap()}
unsafe fn put(buf:*mut c_char,len:usize,text:&[u8]){if buf.is_null(){return;} for i in 0..len{*buf.add(i)=0;} for i in 0..text.len().min(len.saturating_sub(1)){*buf.add(i)=text[i] as c_char;}}
fn exposing(c:&Cam)->Option<c_long>{c.started.map(|t|(c.exposure_ms-t.elapsed().as_millis() as c_long).max(0)).filter(|left|*left>0)}
macro_rules! live{()=>{if env("SK_FLI_UNPLUGGED"){return ENODEV;}}}
// Test hooks (not libfli): what the camera was last told.
#[no_mangle] pub unsafe extern "C" fn FakeFliLastImageArea(out:*mut c_long)->c_long{let c=CAM.lock().unwrap(); for i in 0..4{*out.add(i)=c.area[i];} 0}
#[no_mangle] pub extern "C" fn FakeFliLastExposureMs()->c_long{CAM.lock().unwrap().exposure_ms}
#[no_mangle] pub extern "C" fn FakeFliLastSetpoint()->c_double{CAM.lock().unwrap().setpoint}
#[no_mangle] pub extern "C" fn FakeFliCancelCount()->c_long{CAM.lock().unwrap().cancels}
#[no_mangle] pub unsafe extern "C" fn FLIOpen(dev:*mut c_long,name:*const c_char,domain:c_long)->c_long{if dev.is_null()||name.is_null(){return EINVAL;} let name=CStr::from_ptr(name).to_string_lossy().to_string(); match devices().into_iter().find(|d|d.0==name){Some(d) if d.1==domain&0x0f00=>{*dev=d.1; 0},_=>ENODEV}}
#[no_mangle] pub extern "C" fn FLIClose(_dev:c_long)->c_long{0}
#[no_mangle] pub unsafe extern "C" fn FLIGetModel(dev:c_long,model:*mut c_char,len:usize)->c_long{live!(); put(model,len,device(dev).2); 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetSerialString(dev:c_long,serial:*mut c_char,len:usize)->c_long{live!(); put(serial,len,device(dev).3);0}
#[no_mangle] pub unsafe extern "C" fn FLIGetPixelSize(_dev:c_long,x:*mut c_double,y:*mut c_double)->c_long{live!(); if !x.is_null(){*x=9.0e-6;} if !y.is_null(){*y=9.0e-6;} 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetVisibleArea(_dev:c_long,ulx:*mut c_long,uly:*mut c_long,lrx:*mut c_long,lry:*mut c_long)->c_long{live!(); if !ulx.is_null(){*ulx=0;} if !uly.is_null(){*uly=0;} if !lrx.is_null(){*lrx=SENSOR_W;} if !lry.is_null(){*lry=SENSOR_H;} 0}
#[no_mangle] pub extern "C" fn FLISetExposureTime(_dev:c_long,ms:c_long)->c_long{live!(); CAM.lock().unwrap().exposure_ms=ms; 0}
#[no_mangle] pub extern "C" fn FLISetImageArea(_dev:c_long,ulx:c_long,uly:c_long,lrx:c_long,lry:c_long)->c_long{live!(); if ulx<0||uly<0{return EINVAL;} CAM.lock().unwrap().area=[ulx,uly,lrx,lry]; 0}
#[no_mangle] pub extern "C" fn FLISetHBin(_dev:c_long,bin:c_long)->c_long{live!(); if !(1..=255).contains(&bin){return EINVAL;} CAM.lock().unwrap().hbin=bin; 0}
#[no_mangle] pub extern "C" fn FLISetVBin(_dev:c_long,bin:c_long)->c_long{live!(); if !(1..=255).contains(&bin){return EINVAL;} CAM.lock().unwrap().vbin=bin; 0}
#[no_mangle] pub extern "C" fn FLISetFrameType(_dev:c_long,_t:c_long)->c_long{live!(); 0}
#[no_mangle] pub extern "C" fn FLIExposeFrame(_dev:c_long)->c_long{live!(); let mut c=CAM.lock().unwrap(); let [ulx,uly,lrx,lry]=c.area; let (w,h)=(lrx-ulx,lry-uly); if w<=0||h<=0||ulx+w*c.hbin>SENSOR_W||uly+h*c.vbin>SENSOR_H{return EINVAL;} c.started=Some(Instant::now()); c.rows_read=0; c.frame_pending=true; 0}
#[no_mangle] pub extern "C" fn FLICancelExposure(_dev:c_long)->c_long{live!(); let mut c=CAM.lock().unwrap(); c.started=None; c.frame_pending=false; c.cancels+=1; 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetExposureStatus(_dev:c_long,time:*mut c_long)->c_long{live!(); if !time.is_null(){*time=exposing(&CAM.lock().unwrap()).unwrap_or(0);} 0}
#[no_mangle] pub extern "C" fn FLISetTemperature(_dev:c_long,temp:c_double)->c_long{live!(); CAM.lock().unwrap().setpoint=temp; 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetTemperature(_dev:c_long,temp:*mut c_double)->c_long{live!(); if !temp.is_null(){*temp=-10.0;} 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetCoolerPower(_dev:c_long,power:*mut c_double)->c_long{live!(); if !power.is_null(){*power=42.0;} 0}
#[no_mangle] pub unsafe extern "C" fn FLIGrabRow(_dev:c_long,buff:*mut u8,width:usize)->c_long{live!(); if env("SK_FLI_GRAB_ERROR"){return EIO;} if buff.is_null(){return EINVAL;} let mut c=CAM.lock().unwrap(); if exposing(&c).is_some(){return ETIMEDOUT;} let [ulx,uly,lrx,lry]=c.area; if !c.frame_pending||c.rows_read>=lry-uly{return ETIMEDOUT;} let y=uly+c.rows_read*c.vbin; for i in 0..width.min((lrx-ulx) as usize){let x=ulx+(i as c_long)*c.hbin; let v=(1000+y*SENSOR_W+x) as u16; let b=v.to_ne_bytes(); *buff.add(i*2)=b[0]; *buff.add(i*2+1)=b[1];} c.rows_read+=1; if c.rows_read==lry-uly{c.frame_pending=false; c.started=None;} 0}
#[no_mangle] pub extern "C" fn FLISetBitDepth(_dev:c_long,_bits:c_long)->c_long{live!(); EINVAL}
#[no_mangle] pub unsafe extern "C" fn FLIGetDeviceStatus(_dev:c_long,status:*mut c_long)->c_long{if status.is_null(){return EINVAL;} *status=0xffffffffu32 as c_long; live!(); if _dev!=FLIDEVICE_CAMERA{*status=0; return 0;} if env("SK_FLI_STATUS_UNKNOWN"){return 0;} let c=CAM.lock().unwrap(); *status=if exposing(&c).is_some(){0x02}else if c.frame_pending{0x80000000u32 as c_long}else{0x00}; 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetLibVersion(ver:*mut c_char,len:usize)->c_long{put(ver,len,b"fake-libfli-1.0\0");0}
#[no_mangle] pub extern "C" fn FLICreateList(domain:c_long)->c_long{LIST_DOMAIN.store(domain as i64,Ordering::SeqCst);0}
#[no_mangle] pub extern "C" fn FLIDeleteList()->c_long{0}
#[no_mangle] pub unsafe extern "C" fn FLIListFirst(domain:*mut c_long,filename:*mut c_char,fnlen:usize,name:*mut c_char,namelen:usize)->c_long{let d=device(LIST_DOMAIN.load(Ordering::SeqCst) as c_long & 0x0f00); put(filename,fnlen,format!("{}\0",d.0).as_bytes()); put(name,namelen,d.2); if !domain.is_null(){*domain=LIST_DOMAIN.load(Ordering::SeqCst) as c_long;} 0}
#[no_mangle] pub unsafe extern "C" fn FLIListNext(_domain:*mut c_long,_filename:*mut c_char,_fnlen:usize,_name:*mut c_char,_namelen:usize)->c_long{-9}
#[no_mangle] pub unsafe extern "C" fn FLIGetFilterName(_dev:c_long,filter:c_long,name:*mut c_char,len:usize)->c_long{live!(); let names:[&[u8];5]=[b"Red\0",b"Green\0",b"Blue\0",b"Lum\0",b"\0"]; if !(0..5).contains(&filter){return EINVAL;} put(name,len,names[filter as usize]); 0}
#[no_mangle] pub extern "C" fn FLISetFilterPos(_dev:c_long,pos:c_long)->c_long{live!(); FILTER_POS.store(pos as i64,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn FLIGetFilterPos(_dev:c_long,pos:*mut c_long)->c_long{live!(); if !pos.is_null(){*pos=FILTER_POS.load(Ordering::SeqCst) as c_long;} 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetFilterCount(_dev:c_long,count:*mut c_long)->c_long{live!(); if !count.is_null(){*count=5;} 0}
#[no_mangle] pub extern "C" fn FLIStepMotor(_dev:c_long,steps:c_long)->c_long{live!(); FOCUS_POS.fetch_add(steps as i64,Ordering::SeqCst);0}
#[no_mangle] pub extern "C" fn FLIStepMotorAsync(_dev:c_long,steps:c_long)->c_long{live!(); FOCUS_POS.fetch_add(steps as i64,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn FLIGetStepperPosition(_dev:c_long,pos:*mut c_long)->c_long{live!(); if !pos.is_null(){*pos=FOCUS_POS.load(Ordering::SeqCst) as c_long;} 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetStepsRemaining(_dev:c_long,steps:*mut c_long)->c_long{live!(); if !steps.is_null(){*steps=0;} 0}
#[no_mangle] pub unsafe extern "C" fn FLIGetFocuserExtent(_dev:c_long,extent:*mut c_long)->c_long{live!(); if !extent.is_null(){*extent=50000;} 0}
#[no_mangle] pub unsafe extern "C" fn FLIReadTemperature(_dev:c_long,_channel:c_long,temp:*mut c_double)->c_long{live!(); if !temp.is_null(){*temp=20.5;} 0}
#[no_mangle] pub extern "C" fn FLIEndExposure(_dev:c_long)->c_long{live!(); 0}
