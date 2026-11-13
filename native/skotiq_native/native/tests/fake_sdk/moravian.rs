#![allow(non_snake_case)]
use std::ffi::{c_char,c_double,c_float,c_int,c_void};
use std::sync::atomic::{AtomicI32,Ordering};
type GxBool=u8; type PCCamera=*mut c_void; type EnumCallback=unsafe extern "C" fn(c_int);
static TARGET_1:AtomicI32=AtomicI32::new(0); static READ_MODE:AtomicI32=AtomicI32::new(0);
fn id_of(camera:PCCamera)->usize{camera as usize}
unsafe fn put(buf:*mut c_char,size:usize,text:&[u8])->c_int{if buf.is_null()||size==0{return -1;} for i in 0..size{*buf.add(i)=0;} for i in 0..text.len().min(size-1){*buf.add(i)=text[i] as c_char;} 0}
#[no_mangle] pub unsafe extern "C" fn gxccd_enumerate_usb(callback:EnumCallback){callback(1); callback(2);}
#[no_mangle] pub extern "C" fn gxccd_initialize_usb(camera_id:c_int)->PCCamera{if camera_id==1||camera_id==2{camera_id as usize as PCCamera}else{std::ptr::null_mut()}}
#[no_mangle] pub extern "C" fn gxccd_release(_camera:PCCamera){}
#[no_mangle] pub unsafe extern "C" fn gxccd_get_boolean_parameter(camera:PCCamera,index:c_int,value:*mut GxBool)->c_int{if value.is_null(){return -1;} let cooled=id_of(camera)==1; *value=match index{0=>1,1=>1,3=>cooled as GxBool,4=>cooled as GxBool,7=>1,13=>cooled as GxBool,128=>(!cooled) as GxBool,129|130=>0,131=>0,132=>(!cooled) as GxBool,_=>0}; 0}
#[no_mangle] pub unsafe extern "C" fn gxccd_get_integer_parameter(camera:PCCamera,index:c_int,value:*mut c_int)->c_int{if value.is_null(){return -1;} let cooled=id_of(camera)==1; *value=match index{1=>if cooled{72}else{48},2=>if cooled{54}else{32},3|4=>3760,5|6=>if cooled{4}else{2},7=>2,12=>0,16=>if cooled{100}else{0},17=>if cooled{65535}else{4095},_=>return -1}; 0}
#[no_mangle] pub unsafe extern "C" fn gxccd_get_string_parameter(camera:PCCamera,index:c_int,buf:*mut c_char,size:usize)->c_int{let cooled=id_of(camera)==1; match index{0=>put(buf,size,if cooled{b"Moravian C3-61000 Pro"}else{b"Moravian G1-1600"}),2=>put(buf,size,if cooled{b"MOR-COOLED-0001"}else{b"MOR-COLOR-0002"}),_=>-1}}
#[no_mangle] pub unsafe extern "C" fn gxccd_get_value(camera:PCCamera,index:c_int,value:*mut c_float)->c_int{if value.is_null(){return -1;} let cooled=id_of(camera)==1; *value=match index{0=>-9.5,11=>if cooled{0.41}else{return -1},_=>return -1}; 0}
#[no_mangle] pub extern "C" fn gxccd_set_temperature(camera:PCCamera,temp:c_float)->c_int{if id_of(camera)!=1{return -1;} TARGET_1.store(temp as i32,Ordering::SeqCst); 0}
#[no_mangle] pub extern "C" fn gxccd_set_binning(camera:PCCamera,x:c_int,y:c_int)->c_int{let max=if id_of(camera)==1{4}else{2}; if x<1||y<1||x>max||y>max{-1}else{0}}
#[no_mangle] pub extern "C" fn gxccd_set_gain(camera:PCCamera,_gain:u16)->c_int{if id_of(camera)==1{0}else{-1}}
#[no_mangle] pub extern "C" fn gxccd_set_read_mode(_camera:PCCamera,mode:c_int)->c_int{if mode<0||mode>1{return -1;} READ_MODE.store(mode,Ordering::SeqCst); 0}
#[no_mangle] pub unsafe extern "C" fn gxccd_enumerate_read_modes(_camera:PCCamera,index:c_int,buf:*mut c_char,size:usize)->c_int{match index{0=>put(buf,size,b"Normal"),1=>put(buf,size,b"Low noise"),_=>-1}}
#[no_mangle] pub extern "C" fn gxccd_start_exposure(_camera:PCCamera,exp_time:c_double,_use_shutter:GxBool,x:c_int,y:c_int,w:c_int,h:c_int)->c_int{if exp_time<0.0||x<0||y<0||w<=0||h<=0||std::env::var("SK_MORAVIAN_BEGIN_ERROR").is_ok(){-1}else{0}}
#[no_mangle] pub extern "C" fn gxccd_abort_exposure(_camera:PCCamera,_download:GxBool)->c_int{0}
#[no_mangle] pub unsafe extern "C" fn gxccd_image_ready(_camera:PCCamera,ready:*mut GxBool)->c_int{if ready.is_null(){return -1;} *ready=1; 0}
#[no_mangle] pub unsafe extern "C" fn gxccd_read_image(_camera:PCCamera,buf:*mut c_void,size:usize)->c_int{if buf.is_null(){return -1;} let out=buf as *mut u8; for i in 0..(size/2){let v=9000u16.wrapping_add((i as u16).wrapping_mul(7)); *out.add(i*2)=(v&0xff) as u8; *out.add(i*2+1)=(v>>8) as u8;} 0}
#[no_mangle] pub unsafe extern "C" fn gxccd_get_last_error(_camera:PCCamera,buf:*mut c_char,size:usize){put(buf,size,b"fake gxccd error");}
