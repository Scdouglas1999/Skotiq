#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // Owned for the window's lifetime: an unreferenced channel is finalized
  // and its handler never called.
  FlMethodChannel* window_chrome_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView *view)
{
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Answers the window-chrome questions Dart cannot answer itself — the one
// here being what a title-bar double click should do, which on Linux is the
// desktop's own `gtk-titlebar-double-click` setting.
static void window_chrome_method_call_cb(FlMethodChannel* channel,
                                         FlMethodCall* method_call,
                                         gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "getTitlebarDoubleClickAction") == 0) {
    g_autofree gchar* action = nullptr;
    GtkSettings* settings = gtk_settings_get_default();
    if (settings != nullptr) {
      g_object_get(settings, "gtk-titlebar-double-click", &action, nullptr);
    }
    g_autoptr(FlValue) result = fl_value_new_string(
        action != nullptr ? action : "toggle-maximize");
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Wayland app id + X11 WM_CLASS: the compositor maps this toplevel to
  // com.skotiq.desktop.desktop so the taskbar and dock show the right icon
  // and name. Must be set before the first window is realized — it is the
  // default the window below is created with.
  gdk_set_program_class(APPLICATION_ID);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // A plain opaque toplevel. The shell draws its own chrome (g1-glass), so no
  // GTK header bar is installed on ANY environment, and an undecorated window
  // gets no decorations or CSD shadow margins from the toolkit — square
  // corners come free. Opaque, not transparent: a transparent toplevel pays
  // for every frame in pacing.
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_title(window, "Skotiq");

  // Must match WindowOptions.size in lib/main.dart. When they disagree, Dart's
  // windowManager resize lands while the engine is still producing its first
  // frame, and the embedder blocks in "Timed out waiting for OpenGL frame of
  // size 1600x900 (have 1280x720)". On a slow GL stack (software rasterisers,
  // remote X, old drivers) that first frame misses the deadline and the app
  // dies during startup with no user-visible error.
  gtk_window_set_default_size(window, 1600, 900);

  // The window icon LIST, not one bitmap: the compositor picks the size it
  // wants (32 through 512) instead of scaling a single file. Resolved via
  // /proc/self/exe so the icons are found regardless of the working
  // directory at launch time.
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path != nullptr) {
    g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
    GList* icons = nullptr;
    static const char* const kIconFiles[] = {
        "skotiq_32.png",  "skotiq_48.png",  "skotiq_64.png",
        "skotiq_128.png", "skotiq_256.png", "skotiq_512.png",
    };
    for (gsize i = 0; i < G_N_ELEMENTS(kIconFiles); i++) {
      g_autofree gchar* icon_path =
          g_build_filename(exe_dir, "icons", kIconFiles[i], nullptr);
      GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(icon_path, nullptr);
      if (pixbuf != nullptr) {
        icons = g_list_append(icons, pixbuf);
      }
    }
    if (icons != nullptr) {
      gtk_window_set_icon_list(window, icons);
      g_list_free_full(icons, g_object_unref);
    }
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Opaque, and the same ground the shell paints (SkotiqColors.dark
  // .background / WindowOptions.backgroundColor) so the first frame is
  // indistinguishable from the settled one.
  gdk_rgba_parse(&background_color, "#0B0D12");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_chrome_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "com.skotiq.desktop/window_chrome", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_chrome_channel, window_chrome_method_call_cb, self,
      nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_chrome_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window_chrome_channel = nullptr;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
