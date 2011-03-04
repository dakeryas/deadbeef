/*
    DeaDBeeF - ultimate music player for GNU/Linux systems with X11
    Copyright (C) 2009-2011 Alexey Yakovenko <waker@users.sourceforge.net>

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.
    
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    
    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/
#ifdef HAVE_CONFIG_H
#  include <config.h>
#endif
#include <gtk/gtk.h>
#include <gdk/gdkkeysyms.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include "../../gettext.h"
#include "ddblistview.h"
#include "trkproperties.h"
#include "interface.h"
#include "support.h"
#include "../../deadbeef.h"
#include "gtkui.h"
#include "mainplaylist.h"
#include "search.h"
#include "ddbcellrenderertextmultiline.h"

//#define trace(...) { fprintf(stderr, __VA_ARGS__); }
#define trace(fmt,...)

#define min(x,y) ((x)<(y)?(x):(y))

static GtkWidget *trackproperties;
static GtkCellRenderer *rend_text2;
static GtkListStore *store;
static GtkListStore *propstore;
static int trkproperties_modified;
static DB_playItem_t **tracks;
static int numtracks;

static int
build_key_list (const char ***pkeys) {
    int sz = 20;
    const char **keys = malloc (sizeof (const char *) * sz);
    if (!keys) {
        fprintf (stderr, "fatal: out of memory allocating key list\n");
        assert (0);
        return 0;
    }

    int n = 0;

    for (int i = 0; i < numtracks; i++) {
        DB_metaInfo_t *meta = deadbeef->pl_get_metadata (tracks[i]);
        while (meta) {
            if (meta->key[0] != ':') {
                int k = 0;
                for (; k < n; k++) {
                    if (meta->key == keys[k]) {
                        break;
                    }
                }
                if (k == n) {
                    if (n >= sz) {
                        sz *= 2;
                        keys = realloc (keys, sizeof (const char *) * sz);
                        if (!keys) {
                            fprintf (stderr, "fatal: out of memory reallocating key list (%d keys)\n", sz);
                            assert (0);
                        }
                    }
                    keys[n++] = meta->key;
                }
            }
            meta = meta->next;
        }
    }

    *pkeys = keys;
    return n;
}

static int
get_field_value (char *out, int size, const char *key) {
    int multiple = 0;
    *out = 0;
    if (numtracks == 0) {
        return 0;
    }
    char *p = out;
    const char **prev = malloc (sizeof (const char *) * numtracks);
    memset (prev, 0, sizeof (const char *) * numtracks);
    for (int i = 0; i < numtracks; i++) {
        const char *val = deadbeef->pl_find_meta (tracks[i], key);
        if (val && val[0] == 0) {
            val = NULL;
        }
        if (i > 0) {
            int n = 0;
            for (; n < i; n++) {
                if (prev[n] == val) {
                    break;
                }
            }
            if (n == i) {
                multiple = 1;
                if (val) {
                    size_t l = snprintf (out, size, out == p ? "%s" : "; %s", val ? val : "");
                    l = min (l, size);
                    out += l;
                    size -= l;
                }
            }
        }
        else if (val) {
            size_t l = snprintf (out, size, "%s", val ? val : "");
            l = min (l, size);
            out += l;
            size -= l;
        }
        prev[i] = val;
        if (size <= 1) {
            break;
        }
    }
    if (size <= 1) {
        strcpy (out-2, "…");
    }
    free (prev);
    return multiple;
}

gboolean
on_trackproperties_delete_event        (GtkWidget       *widget,
                                        GdkEvent        *event,
                                        gpointer         user_data)
{
    if (trkproperties_modified) {
        GtkWidget *dlg = gtk_message_dialog_new (GTK_WINDOW (mainwin), GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING, GTK_BUTTONS_YES_NO, _("You've modified data for this track."));
        gtk_window_set_transient_for (GTK_WINDOW (dlg), GTK_WINDOW (trackproperties));
        gtk_message_dialog_format_secondary_text (GTK_MESSAGE_DIALOG (dlg), _("Really close the window?"));
        gtk_window_set_title (GTK_WINDOW (dlg), _("Warning"));

        int response = gtk_dialog_run (GTK_DIALOG (dlg));
        gtk_widget_destroy (dlg);
        if (response != GTK_RESPONSE_YES) {
            return TRUE;
        }
    }
    gtk_widget_destroy (widget);
    rend_text2 = NULL;
    trackproperties = NULL;
    if (tracks) {
        for (int i = 0; i < numtracks; i++) {
            deadbeef->pl_item_unref (tracks[i]);
        }
        free (tracks);
        tracks = NULL;
        numtracks = 0;
    }
    return TRUE;
}

gboolean
on_trackproperties_key_press_event     (GtkWidget       *widget,
                                        GdkEventKey     *event,
                                        gpointer         user_data)
{
    if (event->keyval == GDK_Escape) {
        on_trackproperties_delete_event (trackproperties, NULL, NULL);
        return TRUE;
    }
    return FALSE;
}

void
trkproperties_destroy (void) {
    if (trackproperties) {
        on_trackproperties_delete_event (trackproperties, NULL, NULL);
    }
}

void
on_closebtn_clicked                    (GtkButton       *button,
                                        gpointer         user_data)
{
    trkproperties_destroy ();
}

void
on_metadata_edited (GtkCellRendererText *renderer, gchar *path, gchar *new_text, gpointer user_data) {
    GtkListStore *store = GTK_LIST_STORE (user_data);
    GtkTreePath *treepath = gtk_tree_path_new_from_string (path);
    GtkTreeIter iter;
    gtk_tree_model_get_iter (GTK_TREE_MODEL (store), &iter, treepath);
    gtk_tree_path_free (treepath);
    GValue value = {0,};
    gtk_tree_model_get_value (GTK_TREE_MODEL (store), &iter, 1, &value);
    const char *svalue = g_value_get_string (&value);
    if (strcmp (svalue, new_text)) {
        gtk_list_store_set (store, &iter, 1, new_text, 3, 0, -1);
        trkproperties_modified = 1;
    }
}

// full metadata
static const char *types[] = {
    "artist", "Artist",
    "title", "Track Title",
    "performer", "Performer",
    "album", "Album",
    "year", "Date",
    "track", "Track Number",
    "numtracks", "Total Tracks",
    "genre", "Genre",
    "composer", "Composer",
    "disc", "Disc Number",
    "comment", "Comment",
    NULL
};

static inline float
amp_to_db (float amp) {
    return 20*log10 (amp);
}

void
add_field (GtkListStore *store, const char *key, const char *title) {
    // get value to edit
    const char mult[] = _("[Multiple values] ");
    char val[1000];
    size_t ml = strlen (mult);
    memcpy (val, mult, ml+1);
    int n = get_field_value (val + ml, sizeof (val) - ml, key);

    GtkTreeIter iter;
    gtk_list_store_append (store, &iter);
    gtk_list_store_set (store, &iter, 0, title, 1, n ? val : val + ml, 2, key, 3, n ? 1 : 0, -1);
}

void
trkproperties_fill_metadata (void) {
    if (!trackproperties) {
        return;
    }
    trkproperties_modified = 0;
    gtk_list_store_clear (store);
    deadbeef->pl_lock ();

    struct timeval tm1;
    gettimeofday (&tm1, NULL);

    const char **keys = NULL;
    int nkeys = build_key_list (&keys);

    int k;

    // add "standard" fields
    for (int i = 0; types[i]; i += 2) {
        add_field (store, types[i], _(types[i+1]));
    }

    // add all other fields
    for (int k = 0; k < nkeys; k++) {
        int i;
        for (i = 0; types[i]; i += 2) {
            if (!strcmp (keys[k], types[i])) {
                break;
            }
        }
        if (types[i]) {
            continue;
        }

        char title[1000];
        if (!types[i]) {
            snprintf (title, sizeof (title), "<%s>", keys[k]);
        }
        add_field (store, keys[k], title);
    }
    if (keys) {
        free (keys);
    }

    // unknown fields and properties
    if (numtracks == 1) {
        DB_playItem_t *track = tracks[0];

        DB_metaInfo_t *meta = deadbeef->pl_get_metadata (track);
        while (meta) {
            if (meta->key[0] == ':') {
                int l = strlen (meta->key)-1;
                char title[l+3];
                snprintf (title, sizeof (title), "<%s>", meta->key+1);
                const char *value = meta->value;

                GtkTreeIter iter;
                gtk_list_store_append (propstore, &iter);
                gtk_list_store_set (propstore, &iter, 0, title, 1, value, -1);
                meta = meta->next;
                continue;
            }
            meta = meta->next;
        }

        // properties
        char temp[200];
        GtkTreeIter iter;
        gtk_list_store_clear (propstore);
        gtk_list_store_append (propstore, &iter);
        gtk_list_store_set (propstore, &iter, 0, _("Location"), 1, track->fname, -1);
        gtk_list_store_append (propstore, &iter);
        snprintf (temp, sizeof (temp), "%d", track->tracknum);
        gtk_list_store_set (propstore, &iter, 0, _("Subtrack Index"), 1, temp, -1);
        gtk_list_store_append (propstore, &iter);
        deadbeef->pl_format_time (deadbeef->pl_get_item_duration (track), temp, sizeof (temp));
        gtk_list_store_set (propstore, &iter, 0, _("Duration"), 1, temp, -1);
        gtk_list_store_append (propstore, &iter);
        deadbeef->pl_format_title (track, -1, temp, sizeof (temp), -1, "%T");
        gtk_list_store_set (propstore, &iter, 0, _("Tag Type(s)"), 1, temp, -1);
        gtk_list_store_append (propstore, &iter);
        gtk_list_store_set (propstore, &iter, 0, _("Embedded Cuesheet"), 1, (deadbeef->pl_get_item_flags (track) & DDB_HAS_EMBEDDED_CUESHEET) ? _("Yes") : _("No"), -1);
        gtk_list_store_append (propstore, &iter);
        gtk_list_store_set (propstore, &iter, 0, _("Codec"), 1, track->decoder_id, -1);

        gtk_list_store_append (propstore, &iter);
        snprintf (temp, sizeof (temp), "%0.2f dB", track->replaygain_album_gain);
        gtk_list_store_set (propstore, &iter, 0, "ReplayGain Album Gain", 1, temp, -1);
        gtk_list_store_append (propstore, &iter);
        snprintf (temp, sizeof (temp), "%0.6f", track->replaygain_album_peak);
        gtk_list_store_set (propstore, &iter, 0, "ReplayGain Album Peak", 1, temp, -1);

        gtk_list_store_append (propstore, &iter);
        snprintf (temp, sizeof (temp), "%0.2f dB", track->replaygain_track_gain);
        gtk_list_store_set (propstore, &iter, 0, "ReplayGain Track Gain", 1, temp, -1);
        gtk_list_store_append (propstore, &iter);
        snprintf (temp, sizeof (temp), "%0.6f", track->replaygain_track_peak);
        gtk_list_store_set (propstore, &iter, 0, "ReplayGain Track Peak", 1, temp, -1);

        struct timeval tm2;
        gettimeofday (&tm2, NULL);
        int ms = (tm2.tv_sec*1000+tm2.tv_usec/1000) - (tm1.tv_sec*1000+tm1.tv_usec/1000);
    }

    deadbeef->pl_unlock ();
}

void
show_track_properties_dlg (DB_playItem_t *it) {

    deadbeef->plt_lock ();
    deadbeef->pl_lock ();

    if (tracks) {
        for (int i = 0; i < numtracks; i++) {
            deadbeef->pl_item_unref (tracks[i]);
        }
        free (tracks);
        tracks = NULL;
        numtracks = 0;
    }

    int nsel = deadbeef->pl_getselcount ();
    if (0 < nsel) {
        tracks = malloc (sizeof (DB_playItem_t *) * nsel);
        if (tracks) {
            int n = 0;
            DB_playItem_t *it = deadbeef->pl_get_first (PL_MAIN);
            while (it) {
                if (deadbeef->pl_is_selected (it)) {
                    assert (n < nsel);
                    deadbeef->pl_item_ref (it);
                    tracks[n++] = it;
                }
                DB_playItem_t *next = deadbeef->pl_get_next (it, PL_MAIN);
                deadbeef->pl_item_unref (it);
                it = next;
            }
            numtracks = nsel;
        }
        else {
            deadbeef->pl_unlock ();
            deadbeef->plt_unlock ();
            return;
        }
    }

    deadbeef->pl_unlock ();
    deadbeef->plt_unlock ();

    int allow_editing = 0;

    int is_subtrack = deadbeef->pl_get_item_flags (it) & DDB_IS_SUBTRACK;

    if (!is_subtrack && deadbeef->is_local_file (it->fname)) {
        // get decoder plugin by id
        DB_decoder_t *dec = NULL;
        if (it->decoder_id) {
            DB_decoder_t **decoders = deadbeef->plug_get_decoder_list ();
            for (int i = 0; decoders[i]; i++) {
                if (!strcmp (decoders[i]->plugin.id, it->decoder_id)) {
                    dec = decoders[i];
                    break;
                }
            }
        }

        if (dec && dec->write_metadata) {
            allow_editing = 1;
        }
    }

    GtkTreeView *tree;
    GtkTreeView *proptree;
    if (!trackproperties) {
        trackproperties = create_trackproperties ();
        gtk_window_set_transient_for (GTK_WINDOW (trackproperties), GTK_WINDOW (mainwin));

        // metadata tree
        tree = GTK_TREE_VIEW (lookup_widget (trackproperties, "metalist"));
        store = gtk_list_store_new (4, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_INT);
        gtk_tree_view_set_model (tree, GTK_TREE_MODEL (store));
        GtkCellRenderer *rend_text = gtk_cell_renderer_text_new ();
        rend_text2 = GTK_CELL_RENDERER (ddb_cell_renderer_text_multiline_new ());
        if (allow_editing) {
            g_signal_connect ((gpointer)rend_text2, "edited",
                    G_CALLBACK (on_metadata_edited),
                    store);
        }
        GtkTreeViewColumn *col1 = gtk_tree_view_column_new_with_attributes (_("Key"), rend_text, "text", 0, NULL);
        GtkTreeViewColumn *col2 = gtk_tree_view_column_new_with_attributes (_("Value"), rend_text2, "text", 1, NULL);
        gtk_tree_view_append_column (tree, col1);
        gtk_tree_view_append_column (tree, col2);

        // properties tree
        proptree = GTK_TREE_VIEW (lookup_widget (trackproperties, "properties"));
        propstore = gtk_list_store_new (2, G_TYPE_STRING, G_TYPE_STRING);
        gtk_tree_view_set_model (proptree, GTK_TREE_MODEL (propstore));
        GtkCellRenderer *rend_propkey = gtk_cell_renderer_text_new ();
        GtkCellRenderer *rend_propvalue = gtk_cell_renderer_text_new ();
        g_object_set (G_OBJECT (rend_propvalue), "editable", TRUE, NULL);
        col1 = gtk_tree_view_column_new_with_attributes (_("Key"), rend_propkey, "text", 0, NULL);
        col2 = gtk_tree_view_column_new_with_attributes (_("Value"), rend_propvalue, "text", 1, NULL);
        gtk_tree_view_append_column (proptree, col1);
        gtk_tree_view_append_column (proptree, col2);
    }
    else {
        tree = GTK_TREE_VIEW (lookup_widget (trackproperties, "metalist"));
        store = GTK_LIST_STORE (gtk_tree_view_get_model (tree));
        gtk_list_store_clear (store);
        proptree = GTK_TREE_VIEW (lookup_widget (trackproperties, "properties"));
        propstore = GTK_LIST_STORE (gtk_tree_view_get_model (proptree));
        gtk_list_store_clear (propstore);
    }

    g_object_set (G_OBJECT (rend_text2), "editable", TRUE, NULL);

    GtkWidget *widget = trackproperties;
    GtkWidget *w;
    const char *meta;

    trkproperties_fill_metadata ();

    if (allow_editing) {
        gtk_widget_set_sensitive (lookup_widget (widget, "write_tags"), TRUE);
    }
    else {
        gtk_widget_set_sensitive (lookup_widget (widget, "write_tags"), FALSE);
    }

    gtk_widget_show (widget);
    gtk_window_present (GTK_WINDOW (widget));
}

static gboolean
set_metadata_cb (GtkTreeModel *model, GtkTreePath *path, GtkTreeIter *iter, gpointer data) {
    GValue mult = {0,};
    gtk_tree_model_get_value (model, iter, 3, &mult);
    int smult = g_value_get_int (&mult);
    if (!smult) {
        GValue key = {0,}, value = {0,};
        gtk_tree_model_get_value (model, iter, 2, &key);
        gtk_tree_model_get_value (model, iter, 1, &value);
        const char *skey = g_value_get_string (&key);
        const char *svalue = g_value_get_string (&value);

        for (int i = 0; i < numtracks; i++) {
            deadbeef->pl_replace_meta (tracks[i], skey, svalue);
        }
    }

    return FALSE;
}

void
on_write_tags_clicked                  (GtkButton       *button,
                                        gpointer         user_data)
{
    // put all metainfo into track
    GtkTreeView *tree = GTK_TREE_VIEW (lookup_widget (trackproperties, "metalist"));
    GtkTreeModel *model = GTK_TREE_MODEL (gtk_tree_view_get_model (tree));
    gtk_tree_model_foreach (model, set_metadata_cb, NULL);
    for (int t = 0; t < numtracks; t++) {
        DB_playItem_t *track = tracks[t];
        if (track && track->decoder_id) {
            // find decoder
            DB_decoder_t *dec = NULL;
            DB_decoder_t **decoders = deadbeef->plug_get_decoder_list ();
            for (int i = 0; decoders[i]; i++) {
                if (!strcmp (decoders[i]->plugin.id, track->decoder_id)) {
                    dec = decoders[i];
                    if (dec->write_metadata) {
                        dec->write_metadata (track);
                    }
                    break;
                }
            }
        }
    }
    main_refresh ();
    search_refresh ();
    trkproperties_modified = 0;
}

void
on_add_field_activate                 (GtkMenuItem     *menuitem,
                                        gpointer         user_data) {
    GtkWidget *dlg = create_entrydialog ();
    gtk_dialog_set_default_response (GTK_DIALOG (dlg), GTK_RESPONSE_OK);
    gtk_window_set_title (GTK_WINDOW (dlg), _("Edit playlist"));
    GtkWidget *e;
    e = lookup_widget (dlg, "title_label");
    gtk_label_set_text (GTK_LABEL(e), _("Name:"));
    int res = gtk_dialog_run (GTK_DIALOG (dlg));
    if (res == GTK_RESPONSE_OK) {
        e = lookup_widget (dlg, "title");
        const char *text = gtk_entry_get_text (GTK_ENTRY(e));

        int l = strlen (text);
        char title[l+3];
        snprintf (title, sizeof (title), "<%s>", text);
        const char *value = "";
        const char *key = text;

        GtkTreeIter iter;
        gtk_list_store_append (store, &iter);
        gtk_list_store_set (store, &iter, 0, title, 1, value, 2, key, -1);
        trkproperties_modified = 1;

    }
    gtk_widget_destroy (dlg);
}

void
on_remove_field_activate                 (GtkMenuItem     *menuitem,
                                        gpointer         user_data) {

    GtkTreePath *path;
    GtkTreeViewColumn *col;
    GtkTreeView *treeview = GTK_TREE_VIEW (lookup_widget (trackproperties, "metalist"));
    gtk_tree_view_get_cursor (treeview, &path, &col);
    if (!path || !col) {
        return;
    }

    GtkWidget *dlg = gtk_message_dialog_new (GTK_WINDOW (mainwin), GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING, GTK_BUTTONS_YES_NO, _("Really remove selected field?"));
    gtk_window_set_title (GTK_WINDOW (dlg), _("Warning"));

    int response = gtk_dialog_run (GTK_DIALOG (dlg));
    gtk_widget_destroy (dlg);
    if (response != GTK_RESPONSE_YES) {
        return;
    }

    GtkTreeIter iter;
    gtk_tree_model_get_iter (GTK_TREE_MODEL (store), &iter, path);
    GValue value = {0,};
    gtk_tree_model_get_value (GTK_TREE_MODEL (store), &iter, 2, &value);
    const char *svalue = g_value_get_string (&value);

    // delete unknown fields completely; otherwise just clear
    int i = 0;
    for (; types[i]; i += 2) {
        if (!strcmp (svalue, types[i])) {
            break;
        }
    }
    if (types[i]) { // known val, clear
        gtk_list_store_set (store, &iter, 1, "", -1);
    }
    else {
        gtk_list_store_remove (store, &iter);
    }
    gtk_tree_path_free (path);
    trkproperties_modified = 1;
}

gboolean
on_metalist_button_press_event         (GtkWidget       *widget,
                                        GdkEventButton  *event,
                                        gpointer         user_data)
{
    if (event->button == 3) {
        GtkWidget *menu;
        GtkWidget *add;
        GtkWidget *remove;
        menu = gtk_menu_new ();
        add = gtk_menu_item_new_with_mnemonic (_("Add field"));
        gtk_widget_show (add);
        gtk_container_add (GTK_CONTAINER (menu), add);
        remove = gtk_menu_item_new_with_mnemonic (_("Remove field"));
        gtk_widget_show (remove);
        gtk_container_add (GTK_CONTAINER (menu), remove);

        g_signal_connect ((gpointer) add, "activate",
                G_CALLBACK (on_add_field_activate),
                NULL);

        g_signal_connect ((gpointer) remove, "activate",
                G_CALLBACK (on_remove_field_activate),
                NULL);

        gtk_menu_popup (GTK_MENU (menu), NULL, NULL, NULL, widget, event->button, gtk_get_current_event_time());
    }
  return FALSE;
}

