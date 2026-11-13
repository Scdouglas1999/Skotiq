#![allow(non_snake_case)]
use std::ffi::{c_char,c_float,c_int,c_void};
use std::sync::atomic::{AtomicI32,Ordering};
static GAIN:AtomicI32=AtomicI32::new(0); static OFFSET:AtomicI32=AtomicI32::new(0); static BIN_X:AtomicI32=AtomicI32::new(1); static BIN_Y:AtomicI32=AtomicI32::new(1); static SETPOINT:AtomicI32=AtomicI32::new(-1000); static FILTER_POS:AtomicI32=AtomicI32::new(0); static COOLING_ON:AtomicI32=AtomicI32::new(0);
static mut IMAGE:[u8;384]=[0;384];
#[repr(C)] struct ArtemisProperties{protocol:c_int,pixels_x:c_int,pixels_y:c_int,pixel_microns_x:c_float,pixel_microns_y:c_float,ccd_flags:c_int,camera_flags:c_int,description:[c_char;40],manufacturer:[c_char;40]}
// SAFETY: callers pass buffers of >=100 bytes per the fake SDK contract.
fn write_cstr(buf:*mut c_char,text:&[u8]){unsafe{for i in 0..100{*buf.add(i)=0;} for i in 0..text.len(){*buf.add(i)=text[i] as c_char;}}}
fn write_fixed(buf:&mut [c_char],text:&[u8]){for b in buf.iter_mut(){*b=0;} for i in 0..text.len().min(buf.len().saturating_sub(1)){buf[i]=text[i] as c_char;}}
#[no_mangle] pub extern "C" fn ArtemisDeviceCount()->c_int{1}
#[no_mangle] pub extern "C" fn ArtemisDevicePresent(device:c_int)->c_int{if device==0{1}else{0}}
#[no_mangle] pub unsafe extern "C" fn ArtemisDeviceName(device:c_int,name:*mut c_char)->c_int{if device!=0||name.is_null(){return 0;} write_cstr(name,b"Skotiq Fake Atik Horizon II"); 1}
#[no_mangle] pub unsafe extern "C" fn ArtemisDeviceSerial(device:c_int,serial:*mut c_char)->c_int{if device!=0||serial.is_null(){return 0;} write_cstr(serial,b"ATIK-FAKE-0001"); 1}
#[no_mangle] pub extern "C" fn ArtemisDeviceIsCamera(device:c_int)->c_int{if device==0{1}else{0}}
#[no_mangle] pub extern "C" fn ArtemisConnect(device:c_int)->*mut c_void{if device==0{1usize as *mut c_void}else{std::ptr::null_mut()}}
#[no_mangle] pub extern "C" fn ArtemisDisconnect(_handle:*mut c_void)->c_int{1}
#[no_mangle] pub extern "C" fn ArtemisIsConnected(_handle:*mut c_void)->c_int{1}
#[no_mangle] pub unsafe extern "C" fn ArtemisProperties(_handle:*mut c_void,prop:*mut ArtemisProperties)->c_int{if prop.is_null(){return 1;} let mut p:ArtemisProperties=std::mem::zeroed(); p.pixels_x=32; p.pixels_y=24; p.pixel_microns_x=3.8; p.pixel_microns_y=3.8; p.camera_flags=16|32; p.ccd_flags=0; write_fixed(&mut p.description,b"Fake Horizon II"); write_fixed(&mut p.manufacturer,b"Atik"); *prop=p; 0}
// ARTEMISCOLOURTYPE 2 = ARTEMIS_COLOUR_RGGB. It must be a determinate value:
// 0 is ARTEMIS_COLOUR_UNKNOWN and the driver now refuses to connect on it
// rather than publish an undetermined sensor as monochrome.
#[no_mangle] pub unsafe extern "C" fn ArtemisColourProperties(_handle:*mut c_void,colour:*mut c_int,nx:*mut c_int,ny:*mut c_int,px:*mut c_int,py:*mut c_int)->c_int{if !colour.is_null(){*colour=2;} if !nx.is_null(){*nx=0;} if !ny.is_null(){*ny=0;} if !px.is_null(){*px=0;} if !py.is_null(){*py=0;} 0}
#[no_mangle] pub extern "C" fn ArtemisBin(_handle:*mut c_void,x:c_int,y:c_int)->c_int{BIN_X.store(x,Ordering::SeqCst); BIN_Y.store(y,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn ArtemisGetMaxBin(_handle:*mut c_void,x:*mut c_int,y:*mut c_int)->c_int{if !x.is_null(){*x=4;} if !y.is_null(){*y=4;} 0}
#[no_mangle] pub extern "C" fn ArtemisSubframe(_handle:*mut c_void,_x:c_int,_y:c_int,_w:c_int,_h:c_int)->c_int{0}
#[no_mangle] pub extern "C" fn ArtemisStartExposure(_handle:*mut c_void,_seconds:c_float)->c_int{0}
#[no_mangle] pub extern "C" fn ArtemisAbortExposure(_handle:*mut c_void)->c_int{0}
#[no_mangle] pub extern "C" fn ArtemisImageReady(_handle:*mut c_void)->c_int{1}
#[no_mangle] pub extern "C" fn ArtemisExposureTimeRemaining(_handle:*mut c_void)->c_float{0.0}
#[no_mangle] pub unsafe extern "C" fn ArtemisGetImageData(_handle:*mut c_void,x:*mut c_int,y:*mut c_int,w:*mut c_int,h:*mut c_int,binx:*mut c_int,biny:*mut c_int)->c_int{if !x.is_null(){*x=0;} if !y.is_null(){*y=0;} if !w.is_null(){*w=16;} if !h.is_null(){*h=12;} if !binx.is_null(){*binx=BIN_X.load(Ordering::SeqCst);} if !biny.is_null(){*biny=BIN_Y.load(Ordering::SeqCst);} for i in 0..192{let v=2000u16.wrapping_add(i as u16); IMAGE[i*2]=(v&0xff) as u8; IMAGE[i*2+1]=(v>>8) as u8;} 0}
// SAFETY: IMAGE is a static test buffer; tests are single-threaded over this fake SDK.
#[no_mangle] pub extern "C" fn ArtemisImageBuffer(_handle:*mut c_void)->*mut c_void{unsafe{IMAGE.as_mut_ptr() as *mut c_void}}
#[no_mangle] pub extern "C" fn ArtemisSetCooling(_handle:*mut c_void,setpoint:c_int)->c_int{SETPOINT.store(setpoint,Ordering::SeqCst); COOLING_ON.store(64,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn ArtemisCoolingInfo(_handle:*mut c_void,flags:*mut c_int,level:*mut c_int,minlvl:*mut c_int,maxlvl:*mut c_int,setpoint:*mut c_int)->c_int{if !flags.is_null(){*flags=1|16|COOLING_ON.load(Ordering::SeqCst);} if !level.is_null(){*level=35;} if !minlvl.is_null(){*minlvl=0;} if !maxlvl.is_null(){*maxlvl=100;} if !setpoint.is_null(){*setpoint=SETPOINT.load(Ordering::SeqCst);} 0}
#[no_mangle] pub extern "C" fn ArtemisCoolerWarmUp(_handle:*mut c_void)->c_int{COOLING_ON.store(0,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn ArtemisTemperatureSensorInfo(_handle:*mut c_void,_sensor:c_int,temp:*mut c_int)->c_int{if !temp.is_null(){*temp=-950;} 0}
#[no_mangle] pub extern "C" fn ArtemisSetGain(_handle:*mut c_void,_preview:c_int,gain:c_int,offset:c_int)->c_int{GAIN.store(gain,Ordering::SeqCst); OFFSET.store(offset,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn ArtemisGetGain(_handle:*mut c_void,_preview:c_int,gain:*mut c_int,offset:*mut c_int)->c_int{if !gain.is_null(){*gain=GAIN.load(Ordering::SeqCst);} if !offset.is_null(){*offset=OFFSET.load(Ordering::SeqCst);} 0}
#[no_mangle] pub extern "C" fn ArtemisAPIVersion()->c_int{66000}
#[no_mangle] pub extern "C" fn ArtemisSetDarkMode(_handle:*mut c_void,_enable:c_int)->c_int{0}
#[no_mangle] pub extern "C" fn ArtemisEightBitMode(_handle:*mut c_void,_eightbit:c_int)->c_int{0}
#[no_mangle] pub extern "C" fn ArtemisEFWIsPresent(device:c_int)->c_int{if device==0{1}else{0}}
#[no_mangle] pub unsafe extern "C" fn ArtemisEFWGetDeviceDetails(device:c_int,efw_type:*mut c_int,serial:*mut c_char)->c_int{if device!=0{return 1;} if !efw_type.is_null(){*efw_type=2;} if !serial.is_null(){write_cstr(serial,b"ATIK-EFW-FAKE-0001");} 0}
#[no_mangle] pub extern "C" fn ArtemisEFWConnect(device:c_int)->*mut c_void{if device==0{2usize as *mut c_void}else{std::ptr::null_mut()}}
#[no_mangle] pub extern "C" fn ArtemisEFWIsConnected(handle:*mut c_void)->bool{!handle.is_null()}
#[no_mangle] pub extern "C" fn ArtemisEFWDisconnect(_handle:*mut c_void)->c_int{0}
#[no_mangle] pub unsafe extern "C" fn ArtemisEFWNmrPosition(_handle:*mut c_void,count:*mut c_int)->c_int{if !count.is_null(){*count=7;} 0}
#[no_mangle] pub extern "C" fn ArtemisEFWSetPosition(_handle:*mut c_void,pos:c_int)->c_int{FILTER_POS.store(pos,Ordering::SeqCst);0}
#[no_mangle] pub unsafe extern "C" fn ArtemisEFWGetPosition(_handle:*mut c_void,pos:*mut c_int,is_moving:*mut bool)->c_int{if !pos.is_null(){*pos=FILTER_POS.load(Ordering::SeqCst);} if !is_moving.is_null(){*is_moving=false;} 0}
