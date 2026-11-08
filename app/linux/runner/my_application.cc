#include "my_application.h"

#include <cstring>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Below this (logical pixels) the editor's panels would overflow (WindowChrome.minimumSize in Dart).
static const gint kMinimumWidth = 960;
static const gint kMinimumHeight = 620;

// Sets the window title and icon from Dart (window_chrome.dart).
static void window_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  FlValue* args = fl_method_call_get_args(call);
  if (strcmp(fl_method_call_get_name(call), "setDocument") == 0 &&
      fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* title = fl_value_lookup_string(args, "title");
    if (title != nullptr && fl_value_get_type(title) == FL_VALUE_TYPE_STRING) {
      const gchar* text = fl_value_get_string(title);
      GtkWidget* bar = gtk_window_get_titlebar(window);
      if (bar != nullptr && GTK_IS_HEADER_BAR(bar)) {
        gtk_header_bar_set_title(GTK_HEADER_BAR(bar), text);
      }
      gtk_window_set_title(window, text);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(fl_method_call_get_name(call), "setAppIcon") == 0 &&
             fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    // The window's icon: the mascot's PNG, or none (the desktop file's) when null.
    FlValue* png = fl_value_lookup_string(args, "png");
    if (png != nullptr && fl_value_get_type(png) == FL_VALUE_TYPE_UINT8_LIST) {
      g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
      gboolean read = gdk_pixbuf_loader_write(loader, fl_value_get_uint8_list(png),
                                              fl_value_get_length(png), nullptr);
      read = gdk_pixbuf_loader_close(loader, nullptr) && read;
      gtk_window_set_icon(window, read ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr);
    } else {
      gtk_window_set_icon(window, nullptr);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(fl_method_call_get_name(call), "getFrame") == 0) {
    // Kept by Dart as the app quits (AppSettings.windowFrame). While maximised GTK's size is
    // the screen's: only that it is, the size from before is kept.
    g_autoptr(FlValue) frame = fl_value_new_map();
    gboolean maximized = gtk_window_is_maximized(window);
    if (!maximized) {
      gint x = 0, y = 0, width = 0, height = 0;
      gtk_window_get_position(window, &x, &y);
      gtk_window_get_size(window, &width, &height);
      fl_value_set_string_take(frame, "x", fl_value_new_int(x));
      fl_value_set_string_take(frame, "y", fl_value_new_int(y));
      fl_value_set_string_take(frame, "width", fl_value_new_int(width));
      fl_value_set_string_take(frame, "height", fl_value_new_int(height));
    }
    fl_value_set_string_take(frame, "maximized", fl_value_new_bool(maximized));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(frame));
  } else if (strcmp(fl_method_call_get_name(call), "setFrame") == 0 &&
             fl_value_get_type(args) == FL_VALUE_TYPE_MAP &&
             !gtk_widget_get_visible(GTK_WIDGET(window))) {
    // Before the first frame shows the window. Wayland leaves the position to the compositor.
    auto number = [&](const char* key, gint64* out) {
      FlValue* v = fl_value_lookup_string(args, key);
      if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_INT) return false;
      *out = fl_value_get_int(v);
      return true;
    };
    gint64 x, y, width, height;
    if (number("x", &x) && number("y", &y) && number("width", &width) &&
        number("height", &height) && width > 0 && height > 0) {
      // Only onto a monitor that is there.
      GdkRectangle wanted = {static_cast<int>(x), static_cast<int>(y),
                             static_cast<int>(width), static_cast<int>(height)};
      GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
      gboolean on_screen = FALSE;
      for (int i = 0; i < gdk_display_get_n_monitors(display) && !on_screen; i++) {
        GdkRectangle area;
        gdk_monitor_get_geometry(gdk_display_get_monitor(display, i), &area);
        on_screen = gdk_rectangle_intersect(&wanted, &area, nullptr);
      }
      if (on_screen) {
        gtk_window_resize(window, wanted.width, wanted.height);
        gtk_window_move(window, wanted.x, wanted.y);
        FlValue* maximized = fl_value_lookup_string(args, "maximized");
        if (maximized != nullptr && fl_value_get_type(maximized) == FL_VALUE_TYPE_BOOL &&
            fl_value_get_bool(maximized)) {
          gtk_window_maximize(window);
        }
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Curator");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Curator");
  }

  gtk_window_set_default_size(window, 1280, 720);
  GdkGeometry geometry;
  geometry.min_width = kMinimumWidth;
  geometry.min_height = kMinimumHeight;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "curated_score/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(window_channel, window_method_cb,
                                            window, nullptr);
  // Lives as long as the window.
  g_object_set_data_full(G_OBJECT(window), "window-channel", window_channel,
                         g_object_unref);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
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
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
