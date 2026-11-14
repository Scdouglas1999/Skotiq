// How PixInsight reads float ranges, and float files written by PixInsight for Skotiq's tests.
#include <pjsr/ColorSpace.jsh>
#include <pjsr/SampleType.jsh>
// A scratch folder: in/ holds the files make_scene.py writes, out/ receives PixInsight's.
var BASE = "/path/to/scratch/";
var IN = BASE + "in/", OUT = BASE + "out/";
console.beginLog();
function statsOf(img) {
   var w = img.width, h = img.height, n = w * h, res = [];
   for (var c = 0; c < img.numberOfChannels; ++c) {
      var a = new Float64Array(n);
      img.getSamples(a, new Rect(w, h), c);
      var mn = 1e300, mx = -1e300, sum = 0;
      for (var i = 0; i < n; ++i) { var v = a[i]; if (v < mn) mn = v; if (v > mx) mx = v; sum += v; }
      img.selectedChannel = c;
      res.push({ min: mn, max: mx, mean: sum / n, median: img.median(), p0: a[0], p1: a[1], p2: a[2] });
   }
   img.resetSelections();
   return res;
}
function viaFormat(path, ext) {
   var r = { file: path, how: "format" };
   try {
      var f = new FileFormatInstance(new FileFormat(ext, true, false));
      var d = f.open(path, "");
      r.bits = d[0].bitsPerSample; r.real = d[0].ieeefpSampleFormat;
      var img = new Image(1, 1, 1, ColorSpace_Gray, 32, SampleType_Real);
      r.read = f.readImage(img);
      r.stats = statsOf(img);
      f.close(); img.free();
   } catch (e) { r.error = String(e); }
   return r;
}
function viaWindow(path) {
   var r = { file: path, how: "window" };
   try {
      var ws = ImageWindow.open(path, "", "", true);
      var im = ws[0].mainView.image;
      r.bits = im.bitsPerSample; r.real = im.isReal;
      r.stats = statsOf(im);
      ws[0].forceClose();
   } catch (e) { r.error = String(e); }
   return r;
}
var results = [];
var inputs = ["scene_u16.fits", "scene_f32_adu.fits", "scene_f32_unit.fits", "scene_f32_adu_datamax.fits",
              "scene_f32_bounds_adu.xisf", "scene_f32_bounds_adu_outliers.xisf"];
for (var i = 0; i < inputs.length; ++i) {
   var ext = inputs[i].substring(inputs[i].lastIndexOf("."));
   results.push(viaFormat(IN + inputs[i], ext));
   results.push(viaWindow(IN + inputs[i]));
}
// Files written by PixInsight from the 16-bit scene.
function save(src, name, bits, real, rgb) {
   var r = { out: OUT + name };
   try {
      var w = ImageWindow.open(IN + src, "", "", true)[0];
      if (rgb) {
         var c = new ConvertToRGBColor; c.executeOn(w.mainView, false);
         var pm = new PixelMath; pm.useSingleExpression = false;
         pm.expression = "$T*0.8"; pm.expression1 = "$T"; pm.expression2 = "$T*0.6";
         pm.rescale = false; pm.truncate = true; pm.createNewImage = false;
         pm.executeOn(w.mainView, false);
      }
      w.setSampleFormat(bits, real);
      r.saved = w.saveAs(OUT + name, false, false, false, false, name.indexOf(".xisf") > 0 ? "compression-codec zstd+sh" : "");
      r.stats = statsOf(w.mainView.image);
      w.forceClose();
   } catch (e) { r.error = String(e); }
   results.push(r);
}
save("scene_u16.fits", "pi_scene_f32.xisf", 32, true, false);
save("scene_u16.fits", "pi_scene_f64.xisf", 64, true, false);
save("scene_u16.fits", "pi_scene_u16.xisf", 16, false, false);
save("scene_u16.fits", "pi_scene_u32.xisf", 32, false, false);
save("scene_u16.fits", "pi_scene_f32.fits", 32, true, false);
save("scene_u16.fits", "pi_scene_rgb_f32.xisf", 32, true, true);
save("scene_u16.fits", "pi_scene_rgb_u16.xisf", 16, false, true);
// Re-open what PixInsight wrote, and whatever Skotiq wrote for it (second run).
var back = ["pi_scene_f32.fits", "pi_scene_f32.xisf", "sk_master_f32_adu.xisf", "sk_master_f32_adu.fits", "sk_resave_pi_f32.xisf"];
for (var i = 0; i < back.length; ++i)
   if (File.exists(OUT + back[i])) results.push(viaWindow(OUT + back[i]));
File.writeTextFile(OUT + "float.jsonl", results.map(function (x) { return JSON.stringify(x); }).join("\n") + "\n");
File.writeTextFile(OUT + "console.log", console.endLog().toString());
File.writeTextFile(OUT + "done.txt", "ok\n");
