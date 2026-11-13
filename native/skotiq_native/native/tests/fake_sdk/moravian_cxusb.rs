#![allow(non_snake_case)]
use std::ffi::{c_char,c_double,c_float,c_int,c_void};
type B=u8; type PCCamera=*mut c_void; type EnumCallback=unsafe extern "C" fn(u32);
fn id_of(camera:PCCamera)->usize{camera as usize}
unsafe fn put(buf:*mut c_char,high:u32,text:&[u8])->B{if buf.is_null(){return 0;} let size=high as usize+1; for i in 0..size{*buf.add(i)=0;} for i in 0..text.len().min(size-1){*buf.add(i)=text[i] as c_char;} 1}
#[no_mangle] pub unsafe extern "C" fn Enumerate(callback:EnumCallback){callback(1); callback(2);}
#[no_mangle] pub extern "C" fn Initialize(id:u32)->PCCamera{if id==1||id==2{id as usize as PCCamera}else{usize::MAX as PCCamera}}
#[no_mangle] pub extern "C" fn Release(_camera:PCCamera){}
#[no_mangle] pub unsafe extern "C" fn GetBooleanParameter(camera:PCCamera,index:u32,value:*mut B)->B{if value.is_null(){return 0;} let cooled=id_of(camera)==1; *value=match index{0=>1,1=>1,3=>cooled as B,4=>cooled as B,7=>1,128=>(!cooled) as B,129|130=>0,131=>0,132=>(!cooled) as B,_=>return 0}; 1}
#[no_mangle] pub unsafe extern "C" fn GetIntegerParameter(camera:PCCamera,index:u32,value:*mut c_int)->B{if value.is_null(){return 0;} let cooled=id_of(camera)==1; *value=match index{1=>if cooled{72}else{48},2=>if cooled{54}else{32},3|4=>3760,5|6=>if cooled{4}else{2},12=>0,16=>if cooled{100}else{0},17=>if cooled{65535}else{4095},_=>return 0}; 1}
#[no_mangle] pub unsafe extern "C" fn GetStringParameter(camera:PCCamera,index:u32,high:u32,buf:*mut c_char)->B{let cooled=id_of(camera)==1; match index{0=>put(buf,high,if cooled{b"C3-61000 Pro"}else{b"C1-3000"}),2=>put(buf,high,if cooled{b"MOR-COOLED-0001"}else{b"MOR-COLOR-0002"}),_=>0}}
#[no_mangle] pub unsafe extern "C" fn GetValue(camera:PCCamera,index:u32,value:*mut c_float)->B{if value.is_null(){return 0;} let cooled=id_of(camera)==1; *value=match index{0=>-9.5,11=>if cooled{0.41}else{return 0},_=>return 0}; 1}
#[no_mangle] pub unsafe extern "C" fn GetLastErrorString(_camera:PCCamera,high:u32,buf:*mut c_char){put(buf,high,b"fake cxusb error");}
#[no_mangle] pub extern "C" fn SetTemperature(camera:PCCamera,_temp:c_float)->B{(id_of(camera)==1) as B}
#[no_mangle] pub extern "C" fn SetBinning(camera:PCCamera,x:u32,y:u32)->B{let max=if id_of(camera)==1{4}else{2}; (x>=1&&y>=1&&x<=max&&y<=max) as B}
#[no_mangle] pub extern "C" fn SetGain(camera:PCCamera,_gain:u32)->B{(id_of(camera)==1) as B}
#[no_mangle] pub extern "C" fn SetReadMode(_camera:PCCamera,mode:u32)->B{(mode<=1) as B}
#[no_mangle] pub unsafe extern "C" fn EnumerateReadModes(_camera:PCCamera,index:u32,high:u32,buf:*mut c_char)->B{match index{0=>put(buf,high,b"Normal"),1=>put(buf,high,b"Low noise"),_=>0}}
#[no_mangle] pub extern "C" fn StartExposure(_camera:PCCamera,exp_time:c_double,_use_shutter:B,x:c_int,y:c_int,w:c_int,d:c_int)->B{(!(exp_time<0.0||x<0||y<0||w<=0||d<=0||std::env::var("SK_MORAVIAN_BEGIN_ERROR").is_ok())) as B}
#[no_mangle] pub extern "C" fn AbortExposure(_camera:PCCamera,_download:B)->B{1}
#[no_mangle] pub unsafe extern "C" fn ImageReady(_camera:PCCamera,ready:*mut B)->B{if ready.is_null(){return 0;} *ready=1; 1}
#[no_mangle] pub unsafe extern "C" fn ReadImage(_camera:PCCamera,len:u32,buf:*mut c_void)->B{if buf.is_null(){return 0;} let out=buf as *mut u8; for i in 0..(len as usize/2){let v=9000u16.wrapping_add((i as u16).wrapping_mul(7)); *out.add(i*2)=(v&0xff) as u8; *out.add(i*2+1)=(v>>8) as u8;} 1}
