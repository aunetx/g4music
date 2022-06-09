namespace Music {

    public const string ACTION_WIN = "win.";
    public const string ACTION_EXPORT_COVER = "export-cover";

    enum SearchType {
        ALL,
        ALBUM,
        ARTIST,
        TITLE
    }

    [GtkTemplate (ui = "/com/github/neithern/g4music/gtk/window.ui")]
    public class Window : Adw.ApplicationWindow {
        [GtkChild]
        private unowned Gtk.Label index_title;
        [GtkChild]
        private unowned Gtk.Box content_box;
        [GtkChild]
        private unowned Gtk.Image cover_image;
        [GtkChild]
        public unowned Gtk.Label song_album;
        [GtkChild]
        public unowned Gtk.Label song_artist;
        [GtkChild]
        public unowned Gtk.Label song_title;
        [GtkChild]
        private unowned Adw.Flap flap;
        [GtkChild]
        private unowned Gtk.ListView list_view;
        [GtkChild]
        public unowned Gtk.ToggleButton search_btn;
        [GtkChild]
        public unowned Gtk.SearchBar search_bar;
        [GtkChild]
        public unowned Gtk.SearchEntry search_entry;
        [GtkChild]
        public unowned Gtk.ToggleButton shuffle_btn;

        private CrossFadePaintable _bkgnd_paintable = new CrossFadePaintable ();
        private CrossFadePaintable _cover_paintable = new CrossFadePaintable ();
        private Gdk.Paintable? _loading_paintable = create_text_paintable ("...");

        private string _loading_text = _("Loading...");
        private Bytes? _cover_data = null;
        private string? _cover_type = null;

        private string _search_text = "";
        private string _search_property = "";
        private SearchType _search_type = SearchType.ALL;

        public Window (Application app) {
            Object (application: app);
            this.icon_name = app.application_id;

            add_action_entries ({
                { ACTION_EXPORT_COVER, on_export_cover }
            }, this);

            setup_drop_target ();

            flap.bind_property ("folded", this, "flap_folded", BindingFlags.DEFAULT);

            app.bind_property ("shuffle", shuffle_btn, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);

            search_btn.toggled.connect (() => {
                if (search_btn.active)
                    search_entry.grab_focus ();
                update_song_filter ();
            });
            search_entry.search_changed.connect (on_search_text_changed);

            var provider = new Gtk.CssProvider ();
            provider.load_from_data ("searchbar revealer box {box-shadow: none; background-color: transparent;}".data);
            Gtk.StyleContext.add_provider_for_display (this.display, provider, Gtk.STYLE_PROVIDER_PRIORITY_USER);
            search_bar.key_capture_widget = this.content;

            _bkgnd_paintable.queue_draw.connect (this.queue_draw);

            _cover_paintable.queue_draw.connect (cover_image.queue_draw);

            var scale_paintable = new ScalePaintable (new RoundPaintable (_cover_paintable, 12, 2));
            scale_paintable.scale = 0.8;
            cover_image.paintable = scale_paintable;
            scale_paintable.queue_draw.connect (cover_image.queue_draw);

            song_album.activate_link.connect (on_song_info_link);
            song_artist.activate_link.connect (on_song_info_link);

            var play_bar = new PlayBar ();
            content_box.append (play_bar);
            action_set_enabled (ACTION_APP + ACTION_PREV, false);
            action_set_enabled (ACTION_APP + ACTION_PLAY, false);
            action_set_enabled (ACTION_APP + ACTION_NEXT, false);

            var factory = new Gtk.SignalListItemFactory ();
            factory.setup.connect ((item) => {
                item.child = new SongEntry ();
            });
            factory.bind.connect (on_bind_item);
            factory.unbind.connect ((item) => {
                var entry = (SongEntry) item.child;
                entry.cover = null;
            });
            list_view.factory = factory;
            list_view.model = new Gtk.NoSelection (app.song_list);
            list_view.activate.connect ((index) => {
                app.current_item = (int) index;
            });

            index_title.label = _loading_text;
            app.loading_changed.connect ((loading, size) => {
                index_title.label = loading ? _loading_text : size.to_string ();
            });
            app.index_changed.connect (on_index_changed);
            app.song_changed.connect (on_song_changed);
            app.song_tag_parsed.connect (on_song_tag_parsed);
            app.player.state_changed.connect (on_player_state_changed);
        }

        public bool flap_folded {
            set {
                var flap_box = flap.flap;
                if (value) {
                    Timeout.add (flap.fold_duration, () => {
                        if (flap.folded && !flap_box.has_css_class ("background"))
                            flap_box.add_css_class ("background");
                        return false;
                    });
                } else if (!value && flap_box.has_css_class ("background")) {
                    flap_box.remove_css_class ("background");
                }
            }
        }

        public override void size_allocate (int width, int height, int baseline) {
            base.size_allocate (width, height, baseline);
            update_blur_paintable (width, height);
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            var width = get_width ();
            var height = get_height ();
            snapshot.push_opacity (0.25);
            _bkgnd_paintable.snapshot (snapshot, width, height);
            snapshot.pop ();
            if (!flap.folded) {
                var right = width - flap.content.get_width ();
                var rect = (!)Graphene.Rect ().init (right - 0.5f, 0, 0.5f, (float) height);
                draw_gray_linear_gradient_line (snapshot, rect);
            }
            base.snapshot (snapshot);
        }

        private async void on_bind_item (Gtk.ListItem item) {
            var entry = (SongEntry) item.child;
            var song = (Song) item.item;
            entry.artist = song.artist;
            entry.title = song.title;

            var app = (Application) application;
            entry.playing = item.position == app.current_item;
            //  print ("bind: %u\n", item.position);

            var thumbnailer = app.thumbnailer;
            var paintable = thumbnailer.find (song.uri);
            entry.cover = paintable ?? _loading_paintable;
            if (paintable == null) {
                var saved_pos = item.position;
                var saved_song = song;
                var paintable2 = yield thumbnailer.load_async (song);
                if (saved_pos != item.position) {
                    // item rebinded, notify changed later to update it
                    Idle.add (() => {
                        app.song_list.items_changed (saved_pos, 0, 0);
                        return false;
                    });
                } else if (paintable2 != null) {
                    // maybe changed, update it
                    entry.artist = saved_song.artist;
                    entry.title = saved_song.title;
                    entry.cover = paintable2;
                }
            }
        }

        private void on_export_cover () {
            var pos = _cover_type?.index_of_char ('/') ?? -1;
            var ext = _cover_type?.substring (pos + 1) ?? "";
            var name = this.title.replace ("/", "&") + "." + ext;
            var filter = new Gtk.FileFilter ();
            filter.add_mime_type (_cover_type ??  "image/*");
            var chooser = new Gtk.FileChooserNative (null, this, Gtk.FileChooserAction.SAVE, null, null);
            chooser.set_current_name (name);
            chooser.set_filter (filter);
            chooser.modal = true;
            chooser.response.connect ((id) => {
                var file = chooser.get_file ();
                if (id == Gtk.ResponseType.ACCEPT && file != null && _cover_data != null) {
                    save_data_to_file.begin ((!)file, (!)_cover_data, (obj, res) => {
                        save_data_to_file.end (res);
                    });
                }
            });
            chooser.show ();
        }

        private Adw.Animation? _scale_animation = null;

        private void on_player_state_changed (Gst.State state) {
            if (state >= Gst.State.PAUSED) {
                var scale_paintable = (!)(cover_image.paintable as ScalePaintable);
                var target = new Adw.CallbackAnimationTarget ((value) => {
                    scale_paintable.scale = value;
                });
                _scale_animation?.pause ();
                _scale_animation = new Adw.TimedAnimation (cover_image,  scale_paintable.scale,
                                            state == Gst.State.PLAYING ? 1 : 0.8, 500, target);
                _scale_animation?.play ();
            }
        }

        private void on_search_text_changed () {
            string text = search_entry.text;
            if (text.ascii_ncasecmp ("album=", 6) == 0) {
                _search_property = text.substring (6);
                _search_type = SearchType.ALBUM;
            } else if (text.ascii_ncasecmp ("artist=", 7) == 0) {
                _search_property = text.substring (7);
                _search_type = SearchType.ARTIST;
            } else if (text.ascii_ncasecmp ("title=", 6) == 0) {
                _search_property = text.substring (6);
                _search_type = SearchType.TITLE;
            } else {
                _search_type = SearchType.ALL;
            }
            _search_text = text;
            update_song_filter ();
            print (@"commit: $(text)\n");
        }

        private void on_index_changed (int index, uint size) {
            action_set_enabled (ACTION_APP + ACTION_PREV, index > 0);
            action_set_enabled (ACTION_APP + ACTION_NEXT, index < (int) size - 1);
            scroll_to_item (index);
            index_title.label = size > 0 ? @"$(index+1)/$(size)" : "0";
        }

        private void on_song_changed (Song song) {
            update_song_info (song);
            action_set_enabled (ACTION_APP + ACTION_PLAY, true);
            print ("Play: %s\n", Uri.unescape_string (song.uri) ?? song.uri);
        }

        private async void on_song_tag_parsed (Song song, Bytes? image, string? itype) {
            update_song_info (song);

            _cover_data = image;
            _cover_type = itype;
            action_set_enabled (ACTION_WIN + ACTION_EXPORT_COVER, image != null);

            var app = (Application) application;
            if (image != null) {
                var pixbufs = new Gdk.Pixbuf?[2] {null, null};
                yield run_async<void> (() => {
                    var pixbuf = pixbufs[0] = load_clamp_pixbuf ((!)image, 640);
                    if (pixbuf != null)
                        pixbufs[1] = create_clamp_pixbuf ((!)pixbuf, Thumbnailer.icon_size);
                }, true);
                if (song == app.current_song && pixbufs[0] != null) {
                    var paintable = Gdk.Texture.for_pixbuf ((!)pixbufs[0]);
                    update_cover_paintable (song, paintable);
                    if (pixbufs[1] != null) {
                        app.thumbnailer.put (song.uri, Gdk.Texture.for_pixbuf ((!)pixbufs[1]));
                        app.song_list.items_changed (app.current_item, 0, 0);
                    }
                    return;
                }
            }

            if (song == app.current_song) {
                var paintable = yield app.thumbnailer.load_directly_async (song, 640);
                update_cover_paintable (song, paintable);
            }
        }

        private bool on_song_info_link (string uri) {
            search_entry.text = Uri.unescape_string (uri) ?? uri;
            search_btn.active = true;
            return true;
        }

        private void scroll_to_item (int index) {
            list_view.activate_action ("list.scroll-to-item", "u", index);
        }

        private void setup_drop_target () {
            var drop_target = new Gtk.DropTarget (Type.INVALID, Gdk.DragAction.COPY);
            drop_target.set_gtypes ({typeof (Gdk.FileList)});
            drop_target.on_drop.connect ((value, x, y) => {
                var file_list = ((Gdk.FileList) value).get_files ();
                var count = file_list.length ();
                var files = new File[count];
                var index = 0;
                foreach (var file in file_list) {
                    files[index++] = file;
                }
                var app = (Application) application;
                app.load_songs_async.begin (files, (obj, res) => {
                    var item = app.load_songs_async.end (res);
                    scroll_to_item (item);
                });
                return true;
            });
            this.content.add_controller (drop_target);
        }

        private static string simple_html_encode (string text) {
            return text.replace ("&", "&amp;").replace ("<",  "&lt;").replace (">", "&gt;");
        }

        private void update_song_info (Song song) {
            var album_uri = Uri.escape_string (song.album);
            var artist_uri = Uri.escape_string (song.artist);
            var album_text = simple_html_encode (song.album);
            var artist_text = simple_html_encode (song.artist);
            song_album.set_markup (@"<a href=\"album=$(album_uri)\">$(album_text)</a>");
            song_artist.set_markup (@"<a href=\"artist=$(artist_uri)\">$(artist_text)</a>");
            song_title.label = song.title;
            this.title = song.artist == UNKOWN_ARTIST ? song.title : @"$(song.artist) - $(song.title)";
        }

        private void update_song_filter () {
            var app = (Application) application;
            if (search_btn.active && _search_text.length > 0) {
                app.song_list.filter = new Gtk.CustomFilter ((obj) => {
                    var song = (Song) obj;
                    switch (_search_type) {
                        case SearchType.ALBUM:
                            return song.album == _search_property;
                        case SearchType.ARTIST:
                            return song.artist == _search_property;
                        case SearchType.TITLE:
                            return song.title == _search_property;
                        default:
                            return _search_text.match_string (song.album, false)
                                || _search_text.match_string (song.artist, false)
                                || _search_text.match_string (song.title, false);
                    }
                });
            } else {
                app.song_list.set_filter (null);
            }
            if (!app.find_current_item ()) {
                app.index_changed (app.current_item, app.song_list.get_n_items ());
            }
        }

        private Adw.Animation? _fade_animation = null;

        private void update_cover_paintable (Song song, Gdk.Paintable? paintable) {
            var app = (Application) application;
            _cover_paintable.paintable = paintable ?? app.thumbnailer.find (song.uri);

            var width = get_width ();
            var height = get_height ();
            if (width > 0 && height > 0) {
                update_blur_paintable (width, height, true);
            }

            var target = new Adw.CallbackAnimationTarget ((value) => {
                _cover_paintable.fade = value;
                _bkgnd_paintable.fade = value;
            });
            _fade_animation?.pause ();
            _fade_animation = new Adw.TimedAnimation (cover_image, 1 - _cover_paintable.fade, 0, 800, target);
            ((!)_fade_animation).done.connect (() => {
                _cover_paintable.previous = null;
                _fade_animation = null;
            });
            _fade_animation?.play ();
        }

        private int _blur_width = 0;
        private int _blur_height = 0;

        private bool update_blur_paintable (int width, int height, bool force = false) {
            var paintable = _cover_paintable.paintable;
            if (paintable != null) {
                if (force || _blur_width != width || _blur_height != height) {
                    _blur_width = width;
                    _blur_height = height;
                    _bkgnd_paintable.paintable = create_blur_texture (this, (!)paintable, width, height);
                    print ("Update blur: %dx%d\n", width, height);
                    return true;
                }
            } else if (force) {
                _bkgnd_paintable.paintable = null;
                return true;
            }
            return false;
        }
    }

    public static async void save_data_to_file (File file, Bytes data) {
        try {
            var stream = yield file.create_async (FileCreateFlags.NONE);
            yield stream.write_bytes_async (data);
            yield stream.close_async ();
        } catch (Error e) {
        }
    }
}
